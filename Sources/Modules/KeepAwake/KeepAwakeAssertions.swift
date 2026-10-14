import Foundation
import IOKit.pwr_mgt

/// Owns only this module's assertions. No subprocess, helper or persistent power setting.
final class KeepAwakeAssertions {
    enum Kind: CaseIterable {
        case system, display
        var type: String {
            self == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
    }
    private(set) var ids: [Kind: IOPMAssertionID] = [:]

    deinit { _ = releaseAll() }

    /// Failed acquisition rolls back the whole set, so the UI never claims partial protection.
    func acquire(system: Bool, display: Bool, timeout: TimeInterval?) -> IOReturn? {
        if let error = releaseAll() { return error }
        for kind in Kind.allCases where kind == .system ? system : display {
            var id: IOPMAssertionID = 0
            #if DEBUG
            let result: IOReturn
            if debugFailKind == kind {
                result = kIOReturnError
            } else {
                result = create(kind, timeout: timeout, id: &id)
            }
            #else
            let result = create(kind, timeout: timeout, id: &id)
            #endif
            guard result == kIOReturnSuccess else {
                _ = releaseAll()
                return result
            }
            ids[kind] = id
            #if DEBUG
            debugDidCreate?(id)
            #endif
        }
        return nil
    }

    private func create(_ kind: Kind, timeout: TimeInterval?, id: inout IOPMAssertionID) -> IOReturn {
        IOPMAssertionCreateWithDescription(
            kind.type as CFString, "mdeck Keep Awake — \(kind == .system ? "system" : "display")" as CFString,
            "User-requested Keep Awake session" as CFString, nil, nil,
            // powerd handles whole seconds; rounding up avoids an early timeout when a
            // settings change reapplies, for example, 59.9 seconds remaining.
            timeout.map { ceil($0) } ?? 0, kIOPMAssertionTimeoutActionRelease as CFString, &id)
    }

    @discardableResult
    func releaseAll() -> IOReturn? {
        var error: IOReturn?
        for (kind, id) in ids {
            let result = IOPMAssertionRelease(id)
            // A timed assertion may already have been released by powerd.
            if result == kIOReturnSuccess || IOPMAssertionCopyProperties(id)?.takeRetainedValue() == nil {
                ids.removeValue(forKey: kind)
            } else {
                error = result // Retain ownership so a later stop can retry.
            }
        }
        return error
    }

    #if DEBUG
    var debugFailKind: Kind?
    var debugDidCreate: ((IOPMAssertionID) -> Void)?
    static func properties(_ id: IOPMAssertionID) -> NSDictionary? {
        IOPMAssertionCopyProperties(id)?.takeRetainedValue() as NSDictionary?
    }
    #endif
}
