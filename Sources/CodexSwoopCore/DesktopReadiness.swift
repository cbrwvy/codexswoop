import Foundation

/// Repeats only strict read-only ownership observations. Never dispatches launch, activation or quit.
public enum DesktopReadiness {
    private enum ReceiverMismatch: Error { case changed }
    /// A GUI's normal exit can race NSWorkspace and kernel inventory updates.
    /// Repeat only the strict inventory read; no lifecycle request is repeated.
    public static func inventory(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(150),
        observe: @Sendable (Duration) async throws -> DesktopInstanceInventory) async throws -> DesktopInstanceInventory {
        let deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(10)))
        var lastReason = EnvironmentError.processChanged
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do { return try await observe(min(ContinuousClock.now.duration(to: deadline), .seconds(5))) }
            catch let error as EnvironmentError where error == .processChanged || error == .ambiguousInstance || error == .backendNotReady {
                lastReason = error
            }
            let delay = min(interval, ContinuousClock.now.duration(to: deadline))
            if delay > .zero { try await Task.sleep(for: delay) }
        }
        throw lastReason
    }
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

/// A signed GUI retains its exact generation while Electron adds/removes descendants.
/// Every caller must first obtain fresh strict root/signature/ancestry ownership evidence.
public enum DesktopOpeningTarget {
    public static func matches(_ observed: DesktopInstance?, expected: DesktopInstance?, newlyLaunched: Bool, allowChildChanges: Bool = false) -> Bool {
        if observed == expected { return true }
        guard newlyLaunched || allowChildChanges, let observed, let expected,
              expected.main.startTimeMicroseconds != nil, expected.signingIdentity != nil else { return false }
        return observed.main == expected.main && observed.nativeLaunchDate == expected.nativeLaunchDate
            && observed.signingIdentity == expected.signingIdentity
    }
    public static func confirms(_ inventory: DesktopInstanceInventory, expected: [DesktopInventoryEntry],
        launchedTarget: DesktopInventoryEntry?, allowChildChanges: Bool = false) -> Bool {
        inventory.entries.count == expected.count && expected.allSatisfy { entry in
            inventory.entries.contains { fresh in
                fresh.association == entry.association && matches(fresh.instance, expected: entry.instance,
                    newlyLaunched: launchedTarget == entry, allowChildChanges: allowChildChanges)
            }
        }
    }
}

extension DesktopSystem {
    /// Repeats read-only observations only. The caller still checks catalogs and the full inventory.
    func observeOpeningTarget(_ association: EnvironmentAssociation, launchedReceiver: DesktopInstance?, expectedReceiver: DesktopInstance? = nil) async throws -> DesktopInstance? {
        guard let receiver = launchedReceiver ?? expectedReceiver else { return try await observe(association).unique() }
        return try await DesktopReadiness.wait(timeout: .seconds(5), expectedReceiver: receiver, preserveReason: true) {
            try await self.observe(association, timeout: $0)
        }
    }
}
