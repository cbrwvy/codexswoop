import Foundation

/// Reconciles submitted requests with fresh strict ownership evidence, never account identity.
/// This proof authorizes no effect; a subsequent manual choice still needs a new plan and consent.
public enum EnvironmentRecoveryProof {
    public static func validateLaunchReceiver(_ receiver: DesktopInstance?, target: EnvironmentAssociation,
        inventory: DesktopInstanceInventory) throws {
        guard let receiver else { return }
        try inventory.validate()
        guard let owned = inventory.entries.first(where: { $0.association == target })?.instance,
              owned.main == receiver.main, owned.nativeLaunchDate == receiver.nativeLaunchDate,
              owned.signingIdentity == receiver.signingIdentity else { throw AccountOpeningError.recoveryTargetChanged }
    }
    public static func validate(scope: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect],
        inventory: DesktopInstanceInventory, livePIDs: Set<Int32>, launcherRunning: Bool) throws {
        try inventory.validate()
        guard !effects.isEmpty, !launcherRunning else { throw AccountOpeningError.recoveryRequired }
        let target = inventory.entries.first { $0.association == scope.target }?.instance
        // Missing processes alone cannot settle a partial close-and-open operation.
        guard target != nil else { throw AccountOpeningError.recoveryRequired }
        if let expected = scope.targetInstance, !DesktopOpeningTarget.matches(target, expected: expected, newlyLaunched: false, allowChildChanges: true) { throw AccountOpeningError.recoveryTargetChanged }
        for item in scope.others where !effects.contains(.normalQuit(item.instance)) {
            guard DesktopOpeningTarget.matches(inventory.entries.first(where: { $0.association == item.association })?.instance,
                expected: item.instance, newlyLaunched: false, allowChildChanges: true) else {
                throw AccountOpeningError.recoveryRequired
            }
        }
        for effect in effects {
            switch effect {
            case .activation(let requested):
                guard DesktopOpeningTarget.matches(target, expected: requested, newlyLaunched: false, allowChildChanges: true) else {
                    throw AccountOpeningError.recoveryTargetChanged
                }
            case .launch:
                guard target != nil else { throw AccountOpeningError.recoveryRequired }
            case .normalQuit(let requested):
                guard let item = scope.others.first(where: { $0.instance == requested }),
                      !inventory.entries.contains(where: { $0.association == item.association }),
                      requested.related.allSatisfy({ !livePIDs.contains($0.pid) }) else {
                    throw AccountOpeningError.recoveryRequired
                }
            case .unknown: throw AccountOpeningError.recoveryRequired
            }
        }
    }
}
