import Cocoa

/// What to put back. Written to disk for as long as something is suspended, so that a crash or
/// a `kill -9` in the middle of a suspension can be repaired at the next start.
struct Baseline: Codable {
    var nightShiftEnabled: Bool?
    var nightShiftMode: Int?
    var nightShiftInWindow: Bool?
    var trueToneEnabled: Bool?

    var isEmpty: Bool { nightShiftEnabled == nil && trueToneEnabled == nil }
}

enum NightShiftPrefs {
    /// Bundle IDs of the apps that force neutral colours while frontmost.
    @Pref("nightshift.watchedApps", default: [])
    static var watchedApps: [String]

    @Pref("nightshift.manageNightShift", default: true)
    static var manageNightShift: Bool

    @Pref("nightshift.manageTrueTone", default: true)
    static var manageTrueTone: Bool

    /// The watched list is pre-filled once, the first time the module starts.
    @Pref("nightshift.didSeed", default: false)
    static var didSeed: Bool

    /// Colour-critical apps worth watching out of the box, kept only if installed.
    static func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        let candidates = [
            "com.adobe.LightroomClassicCC7", "com.adobe.LightroomCC", "com.adobe.lightroom",
            "com.adobe.Photoshop", "com.adobe.bridge12", "com.adobe.AfterEffects",
            "com.apple.Photos", "com.apple.FinalCut", "com.blackmagic-design.DaVinciResolve",
            "com.pixelmatorteam.pixelmator.x", "com.seriflabs.affinityphoto2",
            "com.captureone.captureone16", "com.figma.Desktop",
        ]
        watchedApps = candidates.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }
}

enum NightShiftStore {
    private static let baselineURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mdeck/NightShiftFocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baseline.json")
    }()

    static func loadBaseline() -> Baseline? {
        guard let data = try? Data(contentsOf: baselineURL) else { return nil }
        return try? JSONDecoder().decode(Baseline.self, from: data)
    }

    static func save(_ baseline: Baseline?) {
        guard let baseline, !baseline.isEmpty else {
            try? FileManager.default.removeItem(at: baselineURL)
            return
        }
        try? JSONEncoder().encode(baseline).write(to: baselineURL, options: .atomic)
    }
}
