import Foundation

enum KeepAwakePrefs {
    @Pref("keepawake.preventSystemSleep", default: true) static var preventSystemSleep: Bool
    @Pref("keepawake.preventDisplaySleep", default: false) static var preventDisplaySleep: Bool
    @Pref("keepawake.startOnEnable", default: false) static var startOnEnable: Bool
    @Pref("keepawake.showCountdown", default: true) static var showCountdown: Bool
    @Pref("keepawake.defaultMinutes", default: 0) private static var defaultMinutesRaw: Int
    @Pref("keepawake.customMinutes", default: 45) private static var customMinutesRaw: Int
    @Pref("keepawake.whileAgentsWork", default: true) static var whileAgentsWork: Bool
    @Pref("keepawake.agentGraceMinutes", default: 5) private static var agentGraceMinutesRaw: Int

    static let durations = [0, 5, 15, 30, 60, 120, 240, 480]
    static let maximumMinutes = 7 * 24 * 60
    static var defaultMinutes: Int {
        get { durations.contains(defaultMinutesRaw) ? defaultMinutesRaw : 0 }
        set { defaultMinutesRaw = durations.contains(newValue) ? newValue : 0 }
    }
    static var customMinutes: Int {
        get { (1...maximumMinutes).contains(customMinutesRaw) ? customMinutesRaw : 45 }
        set { customMinutesRaw = min(max(newValue, 1), maximumMinutes) }
    }
    static let agentGraces = [1, 2, 5, 10, 15, 30]
    static var agentGraceMinutes: Int {
        get { agentGraces.contains(agentGraceMinutesRaw) ? agentGraceMinutesRaw : 5 }
        set { agentGraceMinutesRaw = agentGraces.contains(newValue) ? newValue : 5 }
    }
    static var hasProtection: Bool { preventSystemSleep || preventDisplaySleep }

    static func durationLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "Indefinitely" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Continuous time includes sleep; clock corrections cannot extend a timed session.
struct KeepAwakeSession {
    let continuousEnd: TimeInterval?
    let wallClockEnd: Date?

    init(duration: TimeInterval?, until: Date? = nil) {
        continuousEnd = duration.map { Self.now + $0 }
        wallClockEnd = until
    }

    var remaining: TimeInterval? {
        guard let continuousEnd else { return nil }
        let remaining = continuousEnd - Self.now
        return wallClockEnd.map { min(remaining, $0.timeIntervalSinceNow) } ?? remaining
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private static var now: TimeInterval {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
