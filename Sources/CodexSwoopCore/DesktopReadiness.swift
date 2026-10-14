import Foundation

/// Repeats only strict read-only ownership observations. Never dispatches launch, activation or quit.
public enum DesktopReadiness {
    private enum ReceiverMismatch: Error { case changed }
    public static func wait(timeout: Duration = .seconds(20), interval: Duration = .milliseconds(150),
        expectedReceiver: DesktopInstance? = nil, preserveReason: Bool = false,
        observe: @Sendable (Duration) async throws -> DesktopObservation) async throws -> DesktopInstance {
        let deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(20)))
        var candidate: DesktopInstance?
        var lastReason: EnvironmentError?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            do {
                if let fresh = try await observe(min(remaining, .seconds(5))).unique() {
                    if let expectedReceiver {
                        guard fresh.main == expectedReceiver.main, fresh.nativeLaunchDate == expectedReceiver.nativeLaunchDate,
                              fresh.signingIdentity == expectedReceiver.signingIdentity else { throw ReceiverMismatch.changed }
                    }
                    // Two consecutive complete stable snapshots, including native GUI launchDate,
                    // both roots and backend ancestry. A replacement generation starts over.
                    if candidate == fresh {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else { throw EnvironmentError.readinessTimedOut }
                        return fresh
                    }
                    candidate = fresh
                } else { candidate = nil; lastReason = .readinessTimedOut }
            } catch is ReceiverMismatch { throw EnvironmentError.processChanged }
            catch let error as EnvironmentError where error == .ambiguousInstance || error == .processChanged || error == .backendNotReady {
                // These can describe a GUI/backend still starting, but are never accepted as readiness.
                // A genuinely ambiguous inventory stays unconfirmed until this bounded wait expires.
                candidate = nil
                lastReason = error == .ambiguousInstance ? .ownershipUnconfirmed : error
            }
            let delay = min(interval, ContinuousClock.now.duration(to: deadline))
            if delay > .zero { try await Task.sleep(for: delay) }
        }
        throw preserveReason ? (lastReason ?? .readinessTimedOut) : .readinessTimedOut
    }
}
