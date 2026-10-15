import Foundation
import IOKit.pwr_mgt

/// Keeps the display and the system awake for a run, and wakes a display that
/// has already gone to sleep. A sleeping or locked display captures black.
final class PowerAssertion: Sendable {
    private let display: IOPMAssertionID
    private let system: IOPMAssertionID

    init(reason: String) throws {
        display = try Self.create(kIOPMAssertPreventUserIdleDisplaySleep, reason: reason)
        system = try Self.create(kIOPMAssertPreventUserIdleSystemSleep, reason: reason)
        var activity = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activity)
    }

    func release() {
        IOPMAssertionRelease(display)
        IOPMAssertionRelease(system)
    }

    private static func create(_ type: String, reason: String) throws -> IOPMAssertionID {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { throw RunnerError.power(result) }
        return id
    }
}
