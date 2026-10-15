import Foundation

/// Runtime authority for one confirmed environment operation, never an account identity proof.
/// The native adapter retains the exact value and consumes each addressed effect before dispatch.
public struct EnvironmentOperationScope: Equatable, Sendable {
    public let id: UUID
    public let mode: AccountOpeningMode
    public let target: EnvironmentAssociation
    public let targetInstance: DesktopInstance?
    public let others: [DesktopInventoryEntry]
    public let profiles: ProfileCatalog
    public let associations: AssociationCatalog
    public let retainedResearch: [EnvironmentAssociation]
    public let managed: ManagedEnvironmentCatalog
    public let expiresAt: Date
    public let buildFingerprint: OpeningBuildFingerprint?
    public init(plan: AccountOpeningPlan, managed: ManagedEnvironmentCatalog, retainedResearch: [EnvironmentAssociation] = [], expiresAt: Date = Date().addingTimeInterval(120), buildFingerprint: OpeningBuildFingerprint? = nil) {
        id = plan.id; mode = plan.mode; target = plan.association; targetInstance = plan.targetInstance
        others = plan.others.map { DesktopInventoryEntry(association: $0.association, instance: $0.instance) }
        self.retainedResearch = retainedResearch
        profiles = plan.profiles; associations = plan.associations; self.managed = managed; self.expiresAt = expiresAt; self.buildFingerprint = buildFingerprint
    }
    public func validate() throws {
        try buildFingerprint?.validate()
        guard expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 300,
              target.kind == .managed || target.kind == .standardExternal,
              associations.associations.contains(target), profiles.profiles.contains(where: { $0.id == target.profileID }),
              mode == .closeOthersAndOpen || others.isEmpty,
              !others.contains(where: { $0.association == target }),
              others.allSatisfy({ (associations.associations + retainedResearch).contains($0.association) }) else { throw EnvironmentOpeningError.stalePlan }
        try profiles.validate(); try associations.validate(); try managed.validate()
        guard retainedResearch.allSatisfy({ candidate in candidate.isTemporary && profiles.profiles.contains(where: { $0.id == candidate.profileID }) }),
              Set(retainedResearch.map(\.environmentID)).count == retainedResearch.count else { throw EnvironmentOpeningError.stalePlan }
        let all = associations.associations + retainedResearch
        for (index, value) in all.enumerated() {
            for other in all.dropFirst(index + 1) {
                guard value.environmentID != other.environmentID,
                      ![value.codexHome, value.electronData].contains(where: { path in
                          [other.codexHome, other.electronData].contains(where: { EnvironmentValidator.overlaps(path, $0) })
                      }) else { throw EnvironmentOpeningError.stalePlan }
            }
        }
        try DesktopInstanceInventory(entries: others + (targetInstance.map { [DesktopInventoryEntry(association: target, instance: $0)] } ?? []), unknownCount: 0).validate()
    }
}

public protocol ScopedEnvironmentOpeningDriver: AccountSwitchingDriver {
    var independentOpeningAllowed: Bool { get async }
    func planEnvironmentAccount(profile: AccountProfile, mode: AccountOpeningMode) async throws -> AccountOpeningPlan
    func authorizeEnvironmentAccount(_ plan: AccountOpeningPlan, allowPrimary: Bool) async throws
    func verifyEnvironmentAccount(_ plan: AccountOpeningPlan) async throws
    func acknowledgeEnvironmentRecovery() async throws
    func openingEffectDisposition() async -> EnvironmentEffectDisposition
    func reconcileEnvironmentRecovery() async throws
}
public extension ScopedEnvironmentOpeningDriver {
    var independentOpeningAllowed: Bool { get async { false } }
    func openingEffectDisposition() async -> EnvironmentEffectDisposition { .unknown }
    func reconcileEnvironmentRecovery() async throws { throw AccountOpeningError.recoveryRequired }
}

public extension DesktopSystem {
    func environmentOpeningFailureStage() async -> OpeningFailureRecord.Stage? { nil }
    func environmentInstanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory {
        try await instanceInventory(associations: associations)
    }
    func authorizeEnvironmentOperation(_ scope: EnvironmentOperationScope, allowPrimary: Bool) async throws { throw EnvironmentOpeningError.unavailable }
    func activateScopedEnvironment(_ scope: EnvironmentOperationScope, instance: DesktopInstance) async throws { throw EnvironmentOpeningError.unavailable }
    func launchScopedEnvironment(_ scope: EnvironmentOperationScope) async throws -> DesktopInstance { throw EnvironmentOpeningError.unavailable }
    func launchScopedEnvironment(_ scope: EnvironmentOperationScope,
        recordReceiver: @Sendable (DesktopInstance) throws -> Void) async throws -> DesktopInstance {
        let instance = try await launchScopedEnvironment(scope)
        try recordReceiver(instance)
        return instance
    }
    func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope,
        effects: [EnvironmentSubmittedEffect], launchReceiver: DesktopInstance?, inventoryAssociations: [EnvironmentAssociation]) async throws {
        try await confirmPersistedEnvironmentOperationSettled(scope, effects: effects, inventoryAssociations: inventoryAssociations)
        if launchReceiver != nil {
            try await EnvironmentRecoveryProof.validateLaunchReceiver(launchReceiver, target: scope.target,
                inventory: environmentInstanceInventory(associations: inventoryAssociations))
        }
    }
    func quitScopedEnvironment(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws { throw EnvironmentOpeningError.unavailable }
    func waitForScopedExit(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws { throw EnvironmentOpeningError.unavailable }
    func finishEnvironmentOperation(_ id: UUID) async {}
    func environmentEffectDisposition(_ id: UUID) async -> EnvironmentEffectDisposition { .unknown }
    func confirmEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, inventoryAssociations: [EnvironmentAssociation]) async throws { throw AccountOpeningError.recoveryRequired }
    func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect], inventoryAssociations: [EnvironmentAssociation]) async throws { throw AccountOpeningError.recoveryRequired }
}
