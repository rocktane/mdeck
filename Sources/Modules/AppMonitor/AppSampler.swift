import Cocoa
import Darwin

struct MonitoredApp {
    let url: URL
    let name: String
    let icon: NSImage
    let roots: [NSRunningApplication]
    var cpu: Double = 0
    var memory: UInt64 = 0
    var count = 0
}

struct AppMonitorSnapshot {
    var apps: [MonitoredApp] = []
    var cpu: Double = 0
    var memory: Double = 0
    var ready = false
}

/// Confined to the sampling queue. AppKit metadata is supplied by the main thread.
final class AppSampler {
    private struct Sample { let time: UInt64; let birth: UInt64 }
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    #if DEBUG
    /// Compare the kernel's Mach-tick counters against getrusage's timeval units.
    static func debugVerifyCPUTimeUnits() -> Bool {
        func counters() -> (UInt64, Double)? {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
            }
            var usage = rusage()
            guard status == 0, getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            return (info.ri_user_time + info.ri_system_time, seconds)
        }
        guard let before = counters() else { return false }
        let end = ProcessInfo.processInfo.systemUptime + 0.2
        var value = 1.0
        while ProcessInfo.processInfo.systemUptime < end { value = sin(value) + 0.2 }
        guard value.isFinite, let after = counters() else { return false }
        let actual = after.1 - before.1
        let measured = Double(after.0 - before.0) * secondsPerTick
        return actual > 0.01 && abs(actual - measured) < max(0.001, actual * 0.1)
    }
    #endif

    private var previous: [pid_t: Sample] = [:]
    private var timestamp: TimeInterval?
    private var ticks: [UInt32]?

    static func appURL(for path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: "/" + parts[...index].joined(separator: "/"))
    }

    func sample(apps: [MonitoredApp]) -> AppMonitorSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = timestamp.map { now - $0 }
        timestamp = now
        var result = AppMonitorSnapshot(apps: apps, ready: elapsed != nil)
        let byURL = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($0.element.url.path, $0.offset) })
        var owners: [pid_t: Int] = [:]
        for (index, app) in apps.enumerated() { for root in app.roots { owners[root.processIdentifier] = index } }
        let capacity = max(4096, Int(proc_listallpids(nil, 0)) + 1024)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var parents: [pid_t: pid_t] = [:]
        var samples: [pid_t: Sample] = [:]
        var memories: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
               let url = Self.appURL(for: String(cString: path)), let owner = byURL[url.path] {
                owners[pid] = owner
            }
            var usage = rusage_info_v2()
            let success = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard success == 0 else { continue }
            samples[pid] = Sample(time: usage.ri_user_time + usage.ri_system_time, birth: usage.ri_proc_start_abstime)
            memories[pid] = usage.ri_phys_footprint
        }
        for (pid, sample) in samples {
            var cursor = pid
            var visited = Set<pid_t>()
            while owners[cursor] == nil, visited.insert(cursor).inserted, let parent = parents[cursor], parent > 1 { cursor = parent }
            guard let owner = owners[cursor] else { continue }
            result.apps[owner].count += 1
            result.apps[owner].memory += memories[pid] ?? 0
            if let elapsed, elapsed > 0, let old = previous[pid], old.birth == sample.birth, sample.time >= old.time {
                result.apps[owner].cpu += Double(sample.time - old.time) * Self.secondsPerTick / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
            }
        }
        previous = samples
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var load = host_cpu_load_info()
        var loadCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: load) / MemoryLayout<integer_t>.size)
        let loadOK = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &loadCount) }
        }
        if loadOK == KERN_SUCCESS {
            let current = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3]
            if let old = ticks {
                let delta = zip(current, old).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                result.cpu = total > 0 ? (total - delta[2]) / total : 0
            }
            ticks = current
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmOK = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmOK == KERN_SUCCESS {
            let used = Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
            result.memory = min(1, used * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory))
        }
        return result
    }
}
