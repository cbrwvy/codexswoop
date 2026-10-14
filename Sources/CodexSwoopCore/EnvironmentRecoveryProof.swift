import Foundation

/// Reconciles submitted requests with fresh strict ownership evidence, never account identity.
/// This proof authorizes no effect; a subsequent manual choice still needs a new plan and consent.
public enum EnvironmentRecoveryProof {
    public static func validate(scope: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect],
        inventory: DesktopInstanceInventory, livePIDs: Set<Int32>, launcherRunning: Bool) throws {
        try inventory.validate()
        guard !effects.isEmpty, !launcherRunning else { throw AccountOpeningError.recoveryRequired }
        let target = inventory.entries.first { $0.association == scope.target }?.instance
        // Missing processes alone cannot settle a partial close-and-open operation.
        guard target != nil else { throw AccountOpeningError.recoveryRequired }
        if let expected = scope.targetInstance, target != expected { throw AccountOpeningError.recoveryTargetChanged }
        for item in scope.others where !effects.contains(.normalQuit(item.instance)) {
            guard inventory.entries.first(where: { $0.association == item.association })?.instance == item.instance else {
                throw AccountOpeningError.recoveryRequired
            }
        }
        for effect in effects {
            switch effect {
            case .activation(let requested):
                guard target == requested else {
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
