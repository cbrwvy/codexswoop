import Foundation

/// An explicit, short-lived capability supplied only by a separately approved trial.
/// Normal app construction supplies nil; no preferences or CLI flags create this capability.
public struct PIDActivationScope: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let revision: UInt64
    public let instance: DesktopInstance
    public let expiresAt: Date
    public init(association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance,
                expiresAt: Date = Date().addingTimeInterval(60)) throws {
        guard association.kind == .managed, !association.isTemporary,
              association.lastCheck == .directoryMetadataVerified, revision > 0,
              expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 300 else { throw EnvironmentOpeningError.unavailable }
        self.association = association; self.revision = revision; self.instance = instance; self.expiresAt = expiresAt
    }
    public func permits(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) -> Bool {
        self.association == association && self.revision == revision && self.instance == instance && expiresAt > Date()
    }
}

public struct PIDEnvironmentOpeningPlan: Equatable, Sendable {
    public let id: UUID
    public let profile: AccountProfile
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public let guarantees: EnvironmentOpeningGuarantees
    let profiles: ProfileCatalog
    let associations: AssociationCatalog
    let managed: ManagedEnvironmentCatalog
}

public protocol PIDEnvironmentOpeningDriver: Sendable {
    func planPIDEnvironmentOpening(profile: AccountProfile, manual: ManualAccountConfirmation?) async throws -> PIDEnvironmentOpeningPlan
    func recheckPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) async throws
    func activatePIDEnvironment(_ plan: PIDEnvironmentOpeningPlan, confirmedPlanID: UUID) async throws
    func verifyPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) async throws
    func finishPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) async
}
