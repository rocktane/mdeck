import Foundation

// MARK: - Bridge to CoreBrightness (private framework)
//
// Night Shift and True Tone can only be driven through CoreBrightness.framework, which is
// private: the library is loaded at run time and its objects are spoken to through @objc
// protocols whose selectors match the real methods.

@objc private protocol BlueLightClient {
    func setEnabled(_ enabled: Bool) -> Bool
    func getBlueLightStatus(_ status: UnsafeMutableRawPointer) -> Bool
}

@objc private protocol TrueToneClient {
    func enabled() -> Bool
    func setEnabled(_ enabled: Bool) -> Bool
    func supported() -> Bool
    func available() -> Bool
}

private enum CoreBrightness {
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)

    // Keep a strong reference to the ObjC object: the protocol-typed value does not retain it.
    private static var blueLightObject: NSObject?
    private static var trueToneObject: NSObject?

    static let blueLight: BlueLightClient? = {
        guard handle != nil, let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else { return nil }
        let object = cls.init()
        blueLightObject = object
        return unsafeBitCast(object, to: BlueLightClient.self)
    }()

    static let trueTone: TrueToneClient? = {
        guard handle != nil, let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type
        else { return nil }
        let object = cls.init()
        trueToneObject = object
        return unsafeBitCast(object, to: TrueToneClient.self)
    }()
}

// MARK: - Night Shift

/// Mirror of `CBBlueLightClient`'s StatusData (40 bytes), useful fields only.
struct NightShiftStatus {
    /// Whether the tint is on right now (the switch in System Settings).
    var enabled: Bool
    /// 0 = manual, ≠ 0 = scheduled (sunset to sunrise, or custom hours).
    var mode: Int
    var fromMinutes: Int
    var toMinutes: Int

    var isScheduled: Bool { mode != 0 }

    /// Does the schedule want Night Shift on at this moment?
    func inWindow(at date: Date = Date()) -> Bool {
        guard isScheduled, fromMinutes != toMinutes else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if fromMinutes < toMinutes { return now >= fromMinutes && now < toMinutes }
        return now >= fromMinutes || now < toMinutes
    }
}

enum NightShift {
    static var isAvailable: Bool { CoreBrightness.blueLight != nil }

    static func status() -> NightShiftStatus? {
        guard let client = CoreBrightness.blueLight else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64)
        let ok = buffer.withUnsafeMutableBytes { client.getBlueLightStatus($0.baseAddress!) }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> NightShiftStatus in
            func int32(_ offset: Int) -> Int {
                Int(raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
            }
            return NightShiftStatus(
                enabled: raw[1] != 0,
                mode: int32(4),
                fromMinutes: int32(8) * 60 + int32(12),
                toMinutes: int32(16) * 60 + int32(20))
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        CoreBrightness.blueLight?.setEnabled(enabled) ?? false
    }
}

// MARK: - True Tone

enum TrueTone {
    static var isAvailable: Bool {
        guard let client = CoreBrightness.trueTone else { return false }
        return client.supported() && client.available()
    }

    static var isEnabled: Bool { CoreBrightness.trueTone?.enabled() ?? false }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        CoreBrightness.trueTone?.setEnabled(enabled) ?? false
    }
}
