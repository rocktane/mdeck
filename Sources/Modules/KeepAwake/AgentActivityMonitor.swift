import Cocoa
import Darwin

/// Detects Claude Code and Codex at work without hooks or configuration. An open but idle session
/// is not work: its process keeps running (and spending CPU on MCP servers), so neither process
/// presence nor CPU time is a usable signal. Instead:
/// - transcripts are appended on every message and tool result (FSEvents, no polling of files);
/// - a running tool shows up as a child of the agent process (a short process scan): a shell, or
///   any process started well after the agent, since MCP servers start with it and stay.
/// A transcript write counts for `grace` seconds, to cover long model turns without writes.
final class AgentActivityMonitor {
    enum Agent: String, CaseIterable { case claude = "Claude Code", codex = "Codex" }

    struct Source {
        let agent: Agent
        let processName: String
        let transcripts: URL
        /// The native installer runs a versioned binary (~/.local/share/claude/versions/2.1.x),
        /// so the kernel's process name is the version; the path identifies it instead.
        var pathMarkers: [String] = []
    }

    static let defaultSources: [Source] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Source(agent: .claude, processName: "claude", transcripts: home.appendingPathComponent(".claude/projects"),
                   pathMarkers: ["/claude/versions/", "/claude-code/"]),
            Source(agent: .codex, processName: "codex", transcripts: home.appendingPathComponent(".codex/sessions")),
        ]
    }()
    /// Agents run tools through a shell, which `sh -c cmd` may replace with the command itself.
    private static let toolProcesses: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "sandbox-exec"]
    private static let startupWindow: UInt64 = 30
    static let pollInterval: TimeInterval = 10

    private(set) var working: Set<Agent> = []
    var grace: TimeInterval
    private let sources: [Source]
    private let onChange: (Set<Agent>) -> Void
    private var watches: [String: Watch] = [:]
    private var lastWrite: [Agent: Date] = [:]
    private var timer: Timer?

    init(sources: [Source] = defaultSources, grace: TimeInterval, onChange: @escaping (Set<Agent>) -> Void) {
        self.sources = sources
        self.grace = grace
        self.onChange = onChange
    }

    deinit { stop() }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.evaluate() }
        newTimer.tolerance = 2
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for watch in watches.values { watch.invalidate() }
        watches = [:]
        lastWrite = [:]
        working = []
    }

    /// Main thread only. Also (re)creates watches for transcript folders that appeared later.
    func evaluate() {
        guard timer != nil else { return }
        for source in sources where watches[source.transcripts.path] == nil {
            let watch = Watch(source.transcripts, agent: source.agent) { [weak self] agent in self?.noteWrite(agent) }
            if watch.isWatching { watches[source.transcripts.path] = watch }
        }
        let now = Date()
        var current = Set(lastWrite.filter { now.timeIntervalSince($0.value) < grace }.keys)
        current.formUnion(Self.agentsRunningTools(sources))
        guard current != working else { return }
        working = current
        onChange(current)
    }

    private func noteWrite(_ agent: Agent) {
        lastWrite[agent] = Date()
        if !working.contains(agent) { evaluate() }
    }

    static func agentsRunningTools(_ sources: [Source]) -> Set<Agent> {
        let capacity = max(4096, Int(proc_listallpids(nil, 0)) + 1024)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var names: [pid_t: String] = [:]
        var parents: [pid_t: pid_t] = [:]
        var starts: [pid_t: UInt64] = [:]
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { continue }
            names[pid] = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            parents[pid] = pid_t(info.pbi_ppid)
            starts[pid] = info.pbi_start_tvsec
        }
        var agents: [pid_t: Agent?] = [:]
        func agent(_ pid: pid_t) -> Agent? {
            if let known = agents[pid] { return known }
            var found = sources.first { $0.processName == names[pid] }?.agent
            if found == nil {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                    let path = String(cString: buffer)
                    found = sources.first { source in source.pathMarkers.contains { path.contains($0) } }?.agent
                }
            }
            agents[pid] = found
            return found
        }
        var result = Set<Agent>()
        for (pid, parent) in parents where names[parent] != nil {
            guard let found = agent(parent), !result.contains(found),
                  toolProcesses.contains(names[pid] ?? "")
                    || (starts[pid] ?? 0) >= (starts[parent] ?? 0) + startupWindow else { continue }
            result.insert(found)
        }
        return result
    }

    /// One FSEvents stream per transcript folder. Missing folders are retried on the next poll.
    private final class Watch {
        private var stream: FSEventStreamRef?
        private let agent: Agent
        private let onWrite: (Agent) -> Void

        init(_ folder: URL, agent: Agent, onWrite: @escaping (Agent) -> Void) {
            self.agent = agent
            self.onWrite = onWrite
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                let watch = Unmanaged<Watch>.fromOpaque(info).takeUnretainedValue()
                watch.onWrite(watch.agent)
            }, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
            guard let stream else { return }
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }

        var isWatching: Bool { stream != nil }

        func invalidate() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        deinit { invalidate() }
    }

    #if DEBUG
    var debugWatchCount: Int { watches.count }
    #endif
}
