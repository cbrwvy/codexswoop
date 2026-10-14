import Foundation

public enum AccountOpeningMode: String, Codable, CaseIterable, Sendable {
    case openSeparately, closeOthersAndOpen
    public var title: String { self == .openSeparately ? L10n.text("message.47c40f7547") : L10n.text("message.b9c00fd9e0") }
    public var subtitle: String {
        self == .openSeparately ? L10n.text("message.2a0870a04d") : L10n.text("message.cb2ee77508")
    }
}

public enum AccountOpeningError: Error, LocalizedError, Equatable, Sendable {
    case targetNotLinked, identityUnverified, instanceAlreadyOpen, windowUnavailable, ambiguousInstance
    case missingPermissions, processChanged, launchFailure, terminationTimeout, busy, activityUnknown
    case userCancelled, partialCompletion, recoveryRequired, unknownInstances, primaryConsentRequired
    public var errorDescription: String? {
        switch self {
        case .targetNotLinked: L10n.text("message.0301e88b40")
        case .identityUnverified: L10n.text("message.14d704f31c")
        case .instanceAlreadyOpen: L10n.text("message.0186eaf5f9")
        case .windowUnavailable: L10n.text("message.5ed251166f")
        case .ambiguousInstance: L10n.text("message.18b6768fd3")
        case .missingPermissions: L10n.text("message.36be42b4fd")
        case .processChanged: L10n.text("message.3100fee388")
        case .launchFailure: L10n.text("message.2b5386b862")
        case .terminationTimeout: L10n.text("message.0ef2e8f506")
        case .busy: L10n.text("message.86d7fe1e18")
        case .activityUnknown: L10n.text("message.3a5cedce65")
        case .userCancelled: L10n.text("message.abb4a62b3a")
        case .partialCompletion: L10n.text("message.275e5420ee")
        case .recoveryRequired: L10n.text("message.543aeaca22")
        case .unknownInstances: L10n.text("message.a7f4e51df7")
        case .primaryConsentRequired: L10n.text("message.b3140d0e6e")
        }
    }
}

public struct DesktopInventoryEntry: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public init(association: EnvironmentAssociation, instance: DesktopInstance) { self.association = association; self.instance = instance }
}
public struct DesktopInstanceInventory: Sendable {
    public let entries: [DesktopInventoryEntry]
    public let unknownCount: Int
    public let observedAt: Date
    public init(entries: [DesktopInventoryEntry], unknownCount: Int, observedAt: Date = Date()) {
        self.entries = entries; self.unknownCount = unknownCount; self.observedAt = observedAt
    }
    public func validate() throws {
        guard observedAt <= Date(), Date().timeIntervalSince(observedAt) <= 5, unknownCount >= 0,
              Set(entries.map { $0.instance.main.pid }).count == entries.count,
              Set(entries.map { $0.association.environmentID }).count == entries.count else { throw AccountOpeningError.ambiguousInstance }
        var members = Set<Int32>()
        for entry in entries {
            _ = try DesktopObservation(matching: [entry.instance], ambiguous: false).unique()
            for generation in entry.instance.related {
                guard members.insert(generation.pid).inserted else { throw AccountOpeningError.ambiguousInstance }
            }
        }
        guard unknownCount == 0 else { throw AccountOpeningError.unknownInstances }
    }
}
public struct OpeningInstance: Equatable, Sendable {
    public let profile: AccountProfile
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public var displayName: String { association.isTemporary ? L10n.text("message.59e231637b") : profile.name }
    public var operationID: UUID { association.isTemporary ? association.environmentID : profile.id }
    public var isPrimary: Bool { association.kind == .standardExternal }
}
/// Runtime-only exact inventory. No active/running state is persisted or inferred from profile names.
public struct AccountOpeningPlan: Sendable {
    public let id: UUID
    public let mode: AccountOpeningMode
    public let target: AccountProfile
    public let association: EnvironmentAssociation
    public let targetInstance: DesktopInstance?
    public let others: [OpeningInstance]
    let profiles: ProfileCatalog
    let associations: AssociationCatalog
}
public struct AccountCloseConfirmation: Equatable, Sendable {
    public let target: AccountProfile
    public let affected: [OpeningInstance]
    public let activities: [CodexActivityStatus]
    public let unknownInstanceCount: Int
    public var targetEnvironment: EnvironmentAssociation? = nil
    public var requiresPrimaryConsent: Bool { affected.contains(where: \.isPrimary) }
    public var detail: String {
        var lines = [L10n.text("message.60b621bd7e"), L10n.text("message.11eb59c448", affected.count, unknownInstanceCount), L10n.text("message.53e2b9f9d3", target.name), L10n.text("message.dae991678d")]
        if let environment = targetEnvironment {
            lines.append(L10n.text("message.fc25a80dbe", environment.codexHome, environment.electronData))
        }
        for (index, item) in affected.enumerated() {
            let activity = activities[index]
            let label: String
            switch activity { case .idle: label = L10n.text("status.idle"); case .busy: label = L10n.text("status.busy"); case .unknown: label = L10n.text("status.unknown") }
            lines.append(L10n.text("message.ef191576ee", item.displayName, item.instance.main.pid, label, item.isPrimary ? " · Standard External" : ""))
            if let warning = SwitchingWarning(activity: activity) { lines.append(warning.detail) }
        }
        return lines.joined(separator: "\n\n")
    }
}
public enum AccountCloseDecision: Sendable { case cancel, confirm(allowPrimary: Bool) }
public enum AccountOpeningResult: Equatable, Sendable { case activatedExisting(UUID), launched(UUID) }
public struct AccountOpeningProgress: Equatable, Sendable {
    public var closedProfileIDs: [UUID] = []
    public var closedInstanceNames: [String] = []
    public var actionMayHaveOccurred = false
    public init() {}
}

public extension AccountSwitchingDriver {
    func planOpening(profile: AccountProfile, mode: AccountOpeningMode) async throws -> AccountOpeningPlan { throw SwitchingError.unavailable }
    func recheckOpening(_ plan: AccountOpeningPlan, remaining: [OpeningInstance]) async throws { throw SwitchingError.unavailable }
    func quitOpeningInstance(_ item: OpeningInstance, plan: AccountOpeningPlan, allowPrimary: Bool) async throws { throw SwitchingError.unavailable }
    func waitForOpeningExit(_ item: OpeningInstance, timeout: Duration) async throws { throw SwitchingError.unavailable }
    func finishOpening(_ plan: AccountOpeningPlan, success: Bool) async {}
}
