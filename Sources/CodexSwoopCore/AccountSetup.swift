import Foundation

public enum AccountSetupError: Error, LocalizedError, Equatable, Sendable {
    case conflict, recoveryRequired, invalidJournal, backupFailed, writeFailed, alreadyRestored, incompatibleEnvironment
    public var errorDescription: String? {
        switch self {
        case .conflict: L10n.text("message.6b537cf877")
        case .recoveryRequired: L10n.text("message.baf25268c0")
        case .invalidJournal: L10n.text("message.c523467a88")
        case .backupFailed: L10n.text("message.426f610b55")
        case .writeFailed: L10n.text("message.cea499aadc")
        case .alreadyRestored: L10n.text("message.091bfcfb1f")
        case .incompatibleEnvironment: L10n.text("message.82268712b8")
        }
    }
}

public struct RetainedEnvironment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { association.environmentID }
    public let profile: AccountProfile
    public let association: EnvironmentAssociation
    public let retainedAt: Date
    public var status: String { L10n.text("settings.retained") }
}
public struct RetainedEnvironmentCatalog: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision: UInt64 = 0
    public var environments: [RetainedEnvironment] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1, Set(environments.map(\.id)).count == environments.count else { throw AccountSetupError.invalidJournal }
        for item in environments {
            guard item.profile.id == item.association.profileID, item.retainedAt.timeIntervalSince1970.isFinite else { throw AccountSetupError.invalidJournal }
            var catalog = AssociationCatalog(); catalog.associations = [item.association]; try catalog.validate()
        }
    }
}
public struct AccountSetupState: Equatable, Sendable {
    public let profiles: ProfileCatalog
    public let associations: AssociationCatalog
    public let managed: ManagedEnvironmentCatalog
    public let retained: RetainedEnvironmentCatalog
}
public struct AccountSetupPreview: Sendable {
    public let id: UUID
    public let operation: String
    public let removedProfiles: [AccountProfile]
    public var removedSavedEnvironmentCount: Int { before.retained.environments.count - after.retained.environments.count }
    public let before: AccountSetupState
    public let after: AccountSetupState
    let root: URL
    let validationHome: URL
    let files: [String: ReplacementFileSnapshot]
}
public enum AccountSetupOutcome: Sendable, Equatable { case committed(AccountSetupState), reviewRequired }
public enum AccountSetupRecovery: String, Sendable { case finish, restorePrevious }
public struct PendingAccountSetup: Sendable {
    public let id: UUID
    public let operation: String
    public let backupURL: URL
}
struct SetupFileBytes: Codable, Equatable, Sendable { let data: Data? }
struct AccountSetupJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let operation: String
    let before: [String: SetupFileBytes]
    let after: [String: SetupFileBytes]
}
