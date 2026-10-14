import Foundation

/// Independent of lifecycle and account API policy. No runtime preference can unlock native actions.
public enum EnvironmentOpeningPolicy {
    public static let nativeActivationEnabled = false
    public static var explanation: String { L10n.text("message.4ead23a313") }
    public static var blockedReason: String { L10n.text("message.958a2bd790") }
}

/// Five independent claims. A manual note is never an AccountVerification or a UsageContext.
public struct EnvironmentOpeningGuarantees: Equatable, Sendable {
    public let environmentOwnershipVerified: Bool
    public let processOwnershipVerified: Bool
    public let windowOwnershipVerified: Bool
    public let accountIdentityUserConfirmed: Bool
    public var accountIdentityTechnicallyVerified: Bool { false }
}

public struct EnvironmentOpeningPlan: Equatable, Sendable {
    public let id: UUID
    public let profile: AccountProfile
    public let association: EnvironmentAssociation
    public let evidence: DesktopActivationEvidence
    public let guarantees: EnvironmentOpeningGuarantees
    let profiles: ProfileCatalog
    let associations: AssociationCatalog
}

public enum EnvironmentOpeningError: Error, LocalizedError, Equatable, Sendable {
    case unavailable, targetNotRunning, stalePlan, confirmationRequired
    public var errorDescription: String? {
        switch self {
        case .unavailable: EnvironmentOpeningPolicy.blockedReason
        case .targetNotRunning: L10n.text("message.078326b85f")
        case .stalePlan: L10n.text("message.af3dfd842a")
        case .confirmationRequired: L10n.text("message.91b956370c")
        }
    }
}

/// Activation-only capability: no lifecycle or identity methods are available to this coordinator path.
public protocol EnvironmentOpeningDriver: Sendable {
    func planEnvironmentOpening(profile: AccountProfile, manual: ManualAccountConfirmation?) async throws -> EnvironmentOpeningPlan
    func recheckEnvironmentOpening(_ plan: EnvironmentOpeningPlan) async throws
    func activateEnvironment(_ plan: EnvironmentOpeningPlan, confirmedPlanID: UUID) async throws
    func finishEnvironmentOpening(_ plan: EnvironmentOpeningPlan, success: Bool) async
}
