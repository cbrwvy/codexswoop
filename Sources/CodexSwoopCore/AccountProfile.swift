import Foundation

public enum ProfileError: Error, LocalizedError, Equatable, Sendable {
    case invalidName, duplicateName, missingProfile, corruptedStore, unsupportedVersion
    case unsafePath, storeBusy, storageUnavailable, missingBackup

    public var errorDescription: String? {
        switch self {
        case .invalidName: L10n.text("message.0444eae0ac")
        case .duplicateName: L10n.text("message.24d9bda6f8")
        case .missingProfile: L10n.text("message.0f20c66c33")
        case .corruptedStore: L10n.text("message.72ae99f8b5")
        case .unsupportedVersion: L10n.text("message.cf04b8b855")
        case .unsafePath: L10n.text("message.2d9efee894")
        case .storeBusy: L10n.text("message.ae3e2b0895")
        case .storageUnavailable: L10n.text("message.4f1a31a200")
        case .missingBackup: L10n.text("message.923b5dcf1c")
        }
    }
}

public struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    /// A path component derived exclusively from a UUID, never from user input.
    public var directoryIdentifier: String { id.uuidString.lowercased() }

    public init(id: UUID = UUID(), name: String, now: Date = Date()) throws {
        self.id = id
        self.name = try Self.validatedName(name)
        self.createdAt = now
        self.updatedAt = now
    }

    public static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80, name.utf8.count <= 512,
              name.unicodeScalars.contains(where: {
                  $0.value != 0x200C && $0.value != 0x200D && !CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              !name.unicodeScalars.contains(where: {
                  // Joiners are required for compound emoji and some languages; other format/control characters stay blocked.
                  CharacterSet.controlCharacters.contains($0) && $0.value != 0x200C && $0.value != 0x200D
              }) else {
            throw ProfileError.invalidName
        }
        return name
    }

    public static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct ProfileCatalog: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision: UInt64 = 0
    public var profiles: [AccountProfile] = []
    public init() {}

    public func validate() throws {
        guard schemaVersion == 1 else { throw ProfileError.unsupportedVersion }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ProfileError.corruptedStore }
        var names = Set<String>()
        for profile in profiles {
            guard (try? AccountProfile.validatedName(profile.name)) == profile.name,
                  profile.createdAt.timeIntervalSince1970.isFinite,
                  profile.updatedAt >= profile.createdAt,
                  names.insert(AccountProfile.nameKey(profile.name)).inserted else {
                throw ProfileError.corruptedStore
            }
        }
    }
}
