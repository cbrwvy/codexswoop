import Foundation
import Darwin

public enum EnvironmentKind: String, Codable, CaseIterable, Sendable {
    case standardExternal, isolatedExternal, managed, temporaryResearch
}

public enum AssociationOrigin: String, Codable, Sendable { case userSelected, currentDefaults, guardedResearch }
public enum EnvironmentCheck: String, Codable, Sendable { case directoryMetadataVerified }
public enum ProfileConnectionState: String, Sendable {
    case notConnected, environmentLinked, verificationRequired, connected, active, reauthenticationRequired, accountMismatch, unavailable, error
    public var title: String {
        switch self {
        case .notConnected: L10n.text("message.0303e18246")
        case .environmentLinked: L10n.text("message.2444bd5ab3")
        case .verificationRequired: L10n.text("message.4585bf8efa")
        case .connected: L10n.text("message.11aa986ff4")
        case .active: L10n.text("message.9234069589")
        case .reauthenticationRequired: L10n.text("message.0fcfb12dfa")
        case .accountMismatch: L10n.text("message.b802bd2f80")
        case .unavailable: L10n.text("common.none")
        case .error: L10n.text("message.54a0e8c17e")
        }
    }
}

public enum EnvironmentError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath, missingDirectory, unsafeDirectory, changedDirectory, duplicateAssociation
    case missingAssociation, profileLinked, invalidMetadata, unsupportedSchema, identityUnverified, incompatibleBuild, ambiguousInstance
    case readinessTimedOut, processChanged, launchFailed, recoveryRequired, releaseGateClosed, environmentPrepared
    case codexNotInstalled, authenticationRequired, accountMismatch, verificationError, keychainUncertain, activationUnavailable, missingPermissions
    public var errorDescription: String? {
        switch self {
        case .invalidPath: L10n.text("message.57ce189a39")
        case .missingDirectory: L10n.text("message.05a64cfe86")
        case .unsafeDirectory: L10n.text("message.76263ac694")
        case .changedDirectory: L10n.text("message.9611212cdd")
        case .duplicateAssociation: L10n.text("message.547855e3a8")
        case .missingAssociation: L10n.text("message.8cad1ab7dd")
        case .profileLinked: L10n.text("message.a2e174d314")
        case .invalidMetadata: L10n.text("message.c09bd6c0fb")
        case .unsupportedSchema: L10n.text("message.fd203e3b54")
        case .identityUnverified: L10n.text("message.527713b41f")
        case .incompatibleBuild: L10n.text("message.8ca62aa4f2")
        case .ambiguousInstance: L10n.text("message.54dbf3f981")
        case .processChanged: L10n.text("message.193149e5c0")
        case .readinessTimedOut: L10n.text("message.b41732cbc9")
        case .launchFailed: L10n.text("message.314e6d47e7")
        case .recoveryRequired: L10n.text("message.30d80dc546")
        case .releaseGateClosed: L10n.text("message.93e95e0c73")
        case .environmentPrepared: L10n.text("message.0d7cf20cc5")
        case .codexNotInstalled: L10n.text("message.90366fe7c8")
        case .authenticationRequired: L10n.text("message.cfeaf63d44")
        case .accountMismatch: L10n.text("message.6bbc80c8c4")
        case .verificationError: L10n.text("message.dd25f0255a")
        case .keychainUncertain: L10n.text("message.4e774de9dc")
        case .missingPermissions: L10n.text("message.60717ca80a")
        case .activationUnavailable: L10n.text("message.12fb36cc76")
        }
    }
}

public struct DirectoryIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: UInt32
    public let permissions: UInt16
}

/// Contains references and directory metadata only; never authentication or a persisted runtime claim.
public struct EnvironmentAssociation: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let environmentID: UUID
    public let kind: EnvironmentKind
    public let codexHome: String
    public let electronData: String
    public let homeIdentity: DirectoryIdentity
    public let electronIdentity: DirectoryIdentity
    public let origin: AssociationOrigin
    public let lastCheck: EnvironmentCheck
    public let checkedAt: Date
    public var isTemporary: Bool { kind == .temporaryResearch }
    public var requiresIdentityVerification: Bool { true }
}

public struct AssociationCatalog: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision: UInt64 = 0
    public var associations: [EnvironmentAssociation] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw EnvironmentError.unsupportedSchema }
        guard Set(associations.map(\.profileID)).count == associations.count,
              Set(associations.map(\.environmentID)).count == associations.count else { throw EnvironmentError.invalidMetadata }
        var paths = Set<String>()
        var directories = Set<String>()
        for value in associations {
            guard value.checkedAt.timeIntervalSince1970.isFinite,
                  EnvironmentValidator.canonical(value.codexHome), EnvironmentValidator.canonical(value.electronData),
                  !paths.contains(where: { EnvironmentValidator.overlaps($0, value.codexHome) || EnvironmentValidator.overlaps($0, value.electronData) }),
                  !EnvironmentValidator.overlaps(value.codexHome, value.electronData),
                  directories.insert("\(value.homeIdentity.device):\(value.homeIdentity.inode)").inserted,
                  directories.insert("\(value.electronIdentity.device):\(value.electronIdentity.inode)").inserted else {
                throw EnvironmentError.invalidMetadata
            }
            paths.formUnion([value.codexHome, value.electronData])
        }
    }
}

public struct EnvironmentValidator: Sendable {
    public let userHome: URL
    public let managedRoot: URL
    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser, managedRoot: URL = ProfileStore.defaultRoot) {
        self.userHome = userHome; self.managedRoot = managedRoot
    }
    public static func canonical(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.hasSuffix("/") && !path.contains("//")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public static func beneath(_ path: String, _ root: String) -> Bool { path.hasPrefix(root + "/") }
    public static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || beneath(first, second) || beneath(second, first)
    }

    /// lstat directory ancestors only. Does not enumerate/open Codex state or repair permissions.
    public func directory(_ path: String, privateOnly: Bool) throws -> DirectoryIdentity {
        guard Self.canonical(path) else { throw EnvironmentError.invalidPath }
        var cursor = URL(fileURLWithPath: path)
        while cursor.path != "/" {
            var value = stat()
            guard lstat(cursor.path, &value) == 0 else {
                throw errno == ENOENT ? EnvironmentError.missingDirectory : EnvironmentError.unsafeDirectory
            }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw EnvironmentError.unsafeDirectory }
            cursor.deleteLastPathComponent()
        }
        var value = stat()
        guard lstat(path, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o022 == 0,
              !privateOnly || value.st_mode & 0o777 == 0o700 else { throw EnvironmentError.unsafeDirectory }
        return DirectoryIdentity(device: UInt64(value.st_dev), inode: value.st_ino, owner: value.st_uid,
                                 permissions: UInt16(value.st_mode & 0o777))
    }

    public func link(profileID: UUID, environmentID: UUID, kind: EnvironmentKind,
                     home: String, electron: String, now: Date = Date()) throws -> EnvironmentAssociation {
        guard Self.canonical(home), Self.canonical(electron), home != electron,
              !Self.beneath(home, electron), !Self.beneath(electron, home) else { throw EnvironmentError.invalidPath }
        let defaultHome = userHome.appendingPathComponent(".codex").path
        let defaultElectron = userHome.appendingPathComponent("Library/Application Support/Codex").path
        var origin = AssociationOrigin.userSelected
        switch kind {
        case .standardExternal:
            guard home == defaultHome, electron == defaultElectron else { throw EnvironmentError.invalidPath }
            origin = .currentDefaults // Effective running configuration still requires runtime proof.
        case .managed:
            let base = managedRoot.appendingPathComponent("Profiles/\(profileID.uuidString.lowercased())").path
            guard environmentID == profileID, home == base + "/codex-home", electron == base + "/electron-user-data" else {
                throw EnvironmentError.invalidPath
            }
        case .isolatedExternal, .temporaryResearch:
            let base = URL(fileURLWithPath: home).deletingLastPathComponent()
            guard UUID(uuidString: base.lastPathComponent) == environmentID,
                  home == base.path + "/codex-home", electron == base.path + "/electron-user-data" else { throw EnvironmentError.invalidPath }
            if kind == .temporaryResearch {
                let profiles = base.deletingLastPathComponent(), root = profiles.deletingLastPathComponent()
                guard profiles.lastPathComponent == "Profiles", root.deletingLastPathComponent().path == "/private/tmp",
                      root.lastPathComponent.hasPrefix("codexswoop-lab-"),
                      let runID = UUID(uuidString: String(root.lastPathComponent.dropFirst("codexswoop-lab-".count))) else {
                    throw EnvironmentError.invalidPath
                }
                _ = try directory(root.path, privateOnly: true)
                _ = try directory(profiles.path, privateOnly: true)
                try researchMarker(root: root, runID: runID, environmentID: environmentID)
                origin = .guardedResearch
            } else {
                guard Self.beneath(base.path, userHome.path), !Self.beneath(base.path, managedRoot.path) else {
                    throw EnvironmentError.invalidPath
                }
            }
        }
        if kind != .standardExternal {
            guard home != defaultHome, electron != defaultElectron else { throw EnvironmentError.invalidPath }
            _ = try directory(URL(fileURLWithPath: home).deletingLastPathComponent().path, privateOnly: true)
        }
        return try EnvironmentAssociation(profileID: profileID, environmentID: environmentID, kind: kind,
            codexHome: home, electronData: electron, homeIdentity: directory(home, privateOnly: kind != .standardExternal),
            electronIdentity: directory(electron, privateOnly: kind != .standardExternal), origin: origin,
            lastCheck: .directoryMetadataVerified, checkedAt: now)
    }

    public func revalidate(_ value: EnvironmentAssociation) throws {
        let current = try link(profileID: value.profileID, environmentID: value.environmentID, kind: value.kind,
                               home: value.codexHome, electron: value.electronData)
        guard current.homeIdentity == value.homeIdentity, current.electronIdentity == value.electronIdentity,
              current.origin == value.origin else { throw EnvironmentError.changedDirectory }
    }

    private func researchMarker(root: URL, runID: UUID, environmentID: UUID) throws {
        let path = root.appendingPathComponent("lab.json")
        var value = stat()
        guard lstat(path.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_nlink == 1, value.st_mode & 0o777 == 0o600, value.st_size <= 8192 else { throw EnvironmentError.unsafeDirectory }
        // lab.json is our bounded non-secret marker, never an app-created file.
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              object["schema"] as? Int == 1, object["mode"] as? String == "guarded",
              object["owner_uid"] as? UInt32 == getuid(), object["protected_uid"] as? UInt32 == getuid(),
              let id = object["run_id"] as? String, UUID(uuidString: id) == runID,
              let profiles = object["profiles"] as? [String: String], profiles.count == 2,
              profiles.values.contains(where: { UUID(uuidString: $0) == environmentID }) else { throw EnvironmentError.invalidMetadata }
    }
}
