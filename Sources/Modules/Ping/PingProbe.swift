import Foundation

struct PingResult: Equatable {
    let ok: Bool
    /// Round-trip time, when the reply arrived.
    let latency: TimeInterval?
    /// Why it failed, in a few words ("No reply", "Cannot resolve example.com").
    let detail: String?
}

enum PingTarget {
    /// What the user typed, reduced to a host for ping: `https://example.com:8443/path` →
    /// `example.com`, `[::1]` → `::1`. Nil when nothing usable is left. Never starts with `-`,
    /// so it cannot be read as a ping option.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("://") { s = URLComponents(string: s)?.host ?? "" }
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            s = String(s[s.index(after: s.startIndex)..<end])
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        // host:port — a single colon. IPv6 literals have at least two.
        if s.filter({ $0 == ":" }).count == 1 { s = String(s[..<s.firstIndex(of: ":")!]) }
        s = s.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-"), !s.hasPrefix("."),
              s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return s
    }
}

/// One ICMP echo through `/sbin/ping` (`/sbin/ping6` for IPv6 literals), which macOS lets any
/// user run — no raw socket, no privilege. Blocking: call it from a serial background queue.
/// The run is bounded by the timeout even while a host name is still being resolved.
final class PingProbe {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(host: String, timeout: TimeInterval) -> PingResult {
        let v6 = host.contains(":")
        let ping = Process()
        ping.executableURL = URL(fileURLWithPath: v6 ? "/sbin/ping6" : "/sbin/ping")
        var arguments = ["-c", "1", "-n", "-q"]
        // ping6 has no -t: the termination below bounds it.
        if !v6 { arguments += ["-t", String(max(1, Int(timeout.rounded(.up))))] }
        ping.arguments = arguments + ["--", host]
        let output = Pipe()
        ping.standardOutput = output
        ping.standardError = output
        ping.standardInput = FileHandle.nullDevice

        lock.lock()
        guard !cancelled else { lock.unlock(); return PingResult(ok: false, latency: nil, detail: "Cancelled") }
        do {
            try ping.run()
        } catch {
            lock.unlock()
            return PingResult(ok: false, latency: nil, detail: "Could not run ping")
        }
        process = ping
        lock.unlock()

        let deadline = DispatchWorkItem { [weak ping] in
            if let ping, ping.isRunning { ping.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 0.5, execute: deadline)
        // Read before waiting: a full pipe would otherwise block ping forever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ping.waitUntilExit()
        deadline.cancel()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()

        let text = String(decoding: data, as: UTF8.self)
        if ping.terminationReason == .exit, ping.terminationStatus == 0 {
            return PingResult(ok: true, latency: Self.latency(in: text), detail: nil)
        }
        if wasCancelled { return PingResult(ok: false, latency: nil, detail: "Cancelled") }
        if ping.terminationReason == .uncaughtSignal || ping.terminationStatus == 2 {
            return PingResult(ok: false, latency: nil, detail: "No reply")
        }
        if ping.terminationStatus == 68 {
            return PingResult(ok: false, latency: nil, detail: "Cannot resolve \(host)")
        }
        // "ping: sendto: No route to host" → "No route to host".
        let message = text.split(separator: "\n").first { $0.hasPrefix("ping") }
            .flatMap { $0.split(separator: ":").last }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return PingResult(ok: false, latency: nil, detail: message.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No reply")
    }

    /// Ends the ping in flight and refuses new ones until `resume()`.
    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func resume() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    var isPinging: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
    }

    /// `round-trip min/avg/max/stddev = 4.969/4.969/4.969/nan ms` → 0.004969.
    static func latency(in text: String) -> TimeInterval? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("round-trip") }),
              let values = line.split(separator: "=").last?.split(separator: "/"),
              let avg = values.count > 1 ? Double(values[1].trimmingCharacters(in: .whitespaces)) : nil
        else { return nil }
        return avg / 1000
    }
}
