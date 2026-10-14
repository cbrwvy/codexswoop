import Foundation
import Darwin

/// Serializes local I/O off the UI actor. A file lock also serializes different processes.
public actor ProfileStore {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexSwoop", isDirectory: true)
    }
    public let root: URL
    private let fm = FileManager.default
    private let writer: AtomicMetadataWriter
    public init(root: URL, writer: AtomicMetadataWriter = AtomicMetadataWriter()) {
        self.root = root
        self.writer = writer
    }

    /// Diagnostics never create directories, repair permissions, or write a lock file.
    public func inspect() throws -> ProfileCatalog {
        try checkPath(root)
        guard fm.fileExists(atPath: root.path) else { return ProfileCatalog() }
        return try withLock(readOnly: true) { try readCatalog(at: metadataURL) }
    }

    public func load() throws -> ProfileCatalog {
        try withLock(allowOpeningJournal: true) { try readCatalog(at: metadataURL) }
    }

    @discardableResult public func create(name: String) throws -> ProfileCatalog {
        try withLock {
            var catalog = try readCatalog(at: metadataURL)
            let profile = try AccountProfile(name: name)
            try ensureUnique(profile.name, in: catalog)
            let directory = profilesURL.appendingPathComponent(profile.directoryIdentifier, isDirectory: true)
            try privateDirectory(directory)
            // Empty reserved storage only. No Codex home, credentials or session files are imported.
            catalog.profiles.append(profile)
            try save(&catalog)
            return catalog
        }
    }

    @discardableResult public func rename(id: UUID, name: String) throws -> ProfileCatalog {
        try withLock {
            var catalog = try readCatalog(at: metadataURL)
            guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missingProfile }
            let name = try AccountProfile.validatedName(name)
            try ensureUnique(name, in: catalog, excluding: id)
            catalog.profiles[index].name = name
            catalog.profiles[index].updatedAt = max(Date(), catalog.profiles[index].createdAt)
            try save(&catalog)
            return catalog
        }
    }

    /// Convenience API; user-facing removal uses an immutable reviewed preview.
    @discardableResult public func removeRecord(id: UUID) throws -> ProfileCatalog {
        let preview = try previewProfileRemoval(id: id)
        switch try commitAccountSetup(preview) {
        case let .committed(state): return state.profiles
        case .reviewRequired: throw AccountSetupError.recoveryRequired
        }
    }

    /// Explicit recovery only, and only for corrupt metadata. The damaged original is preserved.
    public func recoverBackup() throws -> ProfileCatalog {
        try withLock {
            do {
                _ = try readCatalog(at: metadataURL)
                throw ProfileError.missingBackup
            } catch ProfileError.corruptedStore { /* recovery is allowed */ }
            guard fm.fileExists(atPath: backupURL.path) else { throw ProfileError.missingBackup }
            let backup = try readCatalog(at: backupURL)
            let ids = Set(backup.profiles.map(\.id))
            let references = try readAssociations(at: root.appendingPathComponent("environments.json"))
            let managed = try readManagedCatalog(at: root.appendingPathComponent("managed-environments.json"))
            guard Set(references.associations.map(\.profileID)).isSubset(of: ids),
                  Set(managed.prepared.map(\.profileID)).isSubset(of: ids) else { throw AccountSetupError.conflict }
            let damaged = root.appendingPathComponent("profiles-damaged-\(UUID().uuidString).json")
            if fm.fileExists(atPath: metadataURL.path) {
                try fm.copyItem(at: metadataURL, to: damaged)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: damaged.path)
            }
            try write(backup, to: metadataURL)
            return backup
        }
    }

    private var metadataURL: URL { root.appendingPathComponent("profiles.json") }
    private var backupURL: URL { root.appendingPathComponent("profiles.backup.json") }
    private var profilesURL: URL { root.appendingPathComponent("Profiles", isDirectory: true) }

    /// Creates only empty UUID storage. Does not connect, launch, enroll, move A, or alter profiles.json.
    /// On cancellation/I/O failure, retain any created directories for review; never recursively clean up.
    @discardableResult public func prepareManagedEnvironment(profileID: UUID) throws -> EnvironmentAssociation {
        try Task.checkCancellation()
        guard EnvironmentValidator.canonical(root.path) else { throw EnvironmentError.invalidPath }
        // Preparation never repairs a pre-existing store's unsafe permissions or ownership.
        let preflight = EnvironmentValidator(managedRoot: root)
        _ = try preflight.directory(root.path, privateOnly: true)
        _ = try preflight.directory(profilesURL.path, privateOnly: true)
        return try withLock {
            try Task.checkCancellation()
            guard try readCatalog(at: metadataURL).profiles.contains(where: { $0.id == profileID }) else {
                throw ProfileError.missingProfile
            }
            let references = try readAssociations()
            guard !references.associations.contains(where: { $0.profileID == profileID && $0.kind != .temporaryResearch }) else {
                throw EnvironmentError.profileLinked
            }
            var catalog = try readManagedCatalog()
            guard !catalog.prepared.contains(where: { $0.profileID == profileID }) else { throw EnvironmentError.environmentPrepared }
            let validator = EnvironmentValidator(managedRoot: root)
            let rootIdentity = try validator.directory(root.path, privateOnly: true)
            _ = try validator.directory(profilesURL.path, privateOnly: true)
            let base = profilesURL.appendingPathComponent(profileID.uuidString.lowercased())
            // Existing profile reservation must be owned and private; do not normalize its permissions.
            var info = stat()
            if lstat(base.path, &info) != 0 {
                guard errno == ENOENT, mkdir(base.path, 0o700) == 0 else { throw ProfileError.storageUnavailable }
            }
            let identity = try validator.directory(base.path, privateOnly: true)
            let fd = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EnvironmentError.unsafeDirectory }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, UInt64(info.st_dev) == identity.device, info.st_ino == identity.inode else {
                throw EnvironmentError.changedDirectory
            }
            for name in ["codex-home", "electron-user-data"] {
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw EnvironmentError.environmentPrepared
                }
            }
            for name in ["codex-home", "electron-user-data"] {
                try Task.checkCancellation()
                guard mkdirat(fd, name, 0o700) == 0 else { throw ProfileError.storageUnavailable }
            }
            let value = try validator.link(profileID: profileID, environmentID: profileID, kind: .managed,
                home: base.appendingPathComponent("codex-home").path,
                electron: base.appendingPathComponent("electron-user-data").path)
            guard try validator.directory(root.path, privateOnly: true) == rootIdentity,
                  try validator.directory(base.path, privateOnly: true) == identity else { throw EnvironmentError.changedDirectory }
            try Task.checkCancellation()
            guard catalog.revision < UInt64.max else { throw EnvironmentError.invalidMetadata }
            catalog.prepared.append(value); catalog.revision += 1
            try catalog.validate()
            let url = root.appendingPathComponent("managed-environments.json")
            if fm.fileExists(atPath: url.path) {
                try writeManaged(try readManagedCatalog(), to: root.appendingPathComponent("managed-environments.backup.json"))
            }
            try Task.checkCancellation()
            try writeManaged(catalog, to: url)
            return value
        }
    }

    public func inspectManagedEnvironments() throws -> ManagedEnvironmentCatalog {
        try checkPath(root)
        guard fm.fileExists(atPath: root.path) else { return ManagedEnvironmentCatalog() }
        return try withLock(readOnly: true) { try readManagedCatalog() }
    }

    /// Historical references are candidates only. Fresh directory/marker/process checks are
    /// required before displaying or closing a retained research instance; never reconnect it.
    public func inspectRetainedResearchEnvironments() throws -> [EnvironmentAssociation] {
        try checkPath(root)
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try withLock(readOnly: true) {
            let current = try readAssociations()
            let backup = try readAssociations(at: root.appendingPathComponent("environments.backup.json"))
            return backup.associations.filter { candidate in
                candidate.isTemporary && (try? readCatalog(at: metadataURL).profiles.contains(where: { $0.id == candidate.profileID })) == true
                    && !current.associations.contains(candidate)
                    && !current.associations.contains(where: { $0.environmentID == candidate.environmentID })
            }
        }
    }

    /// Explicit metadata rollback only. Never removes directories or undoes official authentication.
    public func recoverManagedEnvironmentBackup() throws -> ManagedEnvironmentCatalog {
        try withLock {
            do { _ = try readManagedCatalog(); throw ProfileError.missingBackup }
            catch EnvironmentError.invalidMetadata { /* explicit recovery only */ }
            let backup = root.appendingPathComponent("managed-environments.backup.json")
            guard fm.fileExists(atPath: backup.path) else { throw ProfileError.missingBackup }
            let catalog = try readManagedCatalog(at: backup)
            let ids = Set(try readCatalog(at: metadataURL).profiles.map(\.id))
            guard Set(catalog.prepared.map(\.profileID)).isSubset(of: ids) else { throw AccountSetupError.conflict }
            let original = root.appendingPathComponent("managed-environments.json")
            if fm.fileExists(atPath: original.path) {
                try checkPath(original)
                try fm.copyItem(at: original, to: root.appendingPathComponent("managed-environments-damaged-\(UUID().uuidString).json"))
            }
            try writeManaged(catalog, to: original)
            return catalog
        }
    }

    private func readManagedCatalog(at location: URL? = nil) throws -> ManagedEnvironmentCatalog {
        let url = location ?? root.appendingPathComponent("managed-environments.json")
        try checkPath(url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw ProfileError.storageUnavailable }
            if location == nil, fm.fileExists(atPath: root.appendingPathComponent("managed-environments.backup.json").path) {
                throw EnvironmentError.invalidMetadata
            }
            return ManagedEnvironmentCatalog()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size <= 1_048_576 else { throw EnvironmentError.invalidMetadata }
        let bytes = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let schema = object["schemaVersion"] as? Int else { throw EnvironmentError.invalidMetadata }
        guard schema == 1 else { throw EnvironmentError.unsupportedSchema }
        guard let catalog = try? JSONDecoder().decode(ManagedEnvironmentCatalog.self, from: bytes) else { throw EnvironmentError.invalidMetadata }
        try catalog.validate()
        if location == nil {
            let profileIDs = Set(try readCatalog(at: metadataURL).profiles.map(\.id))
            guard Set(catalog.prepared.map(\.profileID)).isSubset(of: profileIDs) else { throw EnvironmentError.invalidMetadata }
        }
        for value in catalog.prepared {
            let base = profilesURL.appendingPathComponent(value.profileID.uuidString.lowercased()).path
            guard value.codexHome == base + "/codex-home", value.electronData == base + "/electron-user-data" else {
                throw EnvironmentError.invalidMetadata
            }
        }
        return catalog
    }
    private func writeManaged(_ catalog: ManagedEnvironmentCatalog, to url: URL) throws {
        try checkPath(url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= 1_048_576 else { throw ProfileError.storageUnavailable }
        try writer.write(data, to: url)
    }

    /// Sidecar schema: existing profiles.json v1 is never migrated or rewritten by linking.
    public func inspectAssociations() throws -> AssociationCatalog {
        try checkPath(root)
        guard fm.fileExists(atPath: root.path) else { return AssociationCatalog() }
        return try withLock(readOnly: true) { try readAssociations() }
    }

    @discardableResult public func linkEnvironment(_ value: EnvironmentAssociation,
                                                   validator: EnvironmentValidator = EnvironmentValidator()) throws -> AssociationCatalog {
        try withLock {
            guard try readCatalog(at: metadataURL).profiles.contains(where: { $0.id == value.profileID }) else {
                throw ProfileError.missingProfile
            }
            try validator.revalidate(value)
            var catalog = try readAssociations()
            guard !catalog.associations.contains(where: {
                $0.profileID == value.profileID || $0.environmentID == value.environmentID
                    || [$0.codexHome, $0.electronData].contains(where: { old in
                        EnvironmentValidator.overlaps(old, value.codexHome) || EnvironmentValidator.overlaps(old, value.electronData)
                    })
                    || [$0.homeIdentity, $0.electronIdentity].contains(where: { old in
                        [value.homeIdentity, value.electronIdentity].contains(where: { old.device == $0.device && old.inode == $0.inode })
                    })
            }) else { throw EnvironmentError.duplicateAssociation }
            catalog.associations.append(value)
            try saveAssociations(&catalog)
            return catalog
        }
    }

    /// Metadata only; external, managed and temporary environments are all retained.
    @discardableResult public func disconnectEnvironment(profileID: UUID) throws -> AssociationCatalog {
        try withLock {
            var catalog = try readAssociations()
            guard catalog.associations.contains(where: { $0.profileID == profileID }) else { throw EnvironmentError.missingAssociation }
            catalog.associations.removeAll { $0.profileID == profileID }
            try saveAssociations(&catalog)
            return catalog
        }
    }

    public func recoverAssociationsBackup() throws -> AssociationCatalog {
        try withLock {
            do { _ = try readAssociations(); throw ProfileError.missingBackup }
            catch EnvironmentError.invalidMetadata { /* explicit recovery only */ }
            let backupURL = root.appendingPathComponent("environments.backup.json")
            guard fm.fileExists(atPath: backupURL.path) else { throw ProfileError.missingBackup }
            let backup = try readAssociations(at: backupURL)
            let ids = Set(try readCatalog(at: metadataURL).profiles.map(\.id))
            guard Set(backup.associations.map(\.profileID)).isSubset(of: ids) else { throw AccountSetupError.conflict }
            let original = root.appendingPathComponent("environments.json")
            if fm.fileExists(atPath: original.path) {
                try checkPath(original)
                try fm.copyItem(at: original, to: root.appendingPathComponent("environments-damaged-\(UUID().uuidString).json"))
            }
            try writeAssociations(backup, to: original)
            return backup
        }
    }

    private func readAssociations(at location: URL? = nil) throws -> AssociationCatalog {
        let url = location ?? root.appendingPathComponent("environments.json")
        try checkPath(url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno != ENOENT { throw ProfileError.storageUnavailable }
            if location == nil, fm.fileExists(atPath: root.appendingPathComponent("environments.backup.json").path) {
                throw EnvironmentError.invalidMetadata
            }
            return AssociationCatalog()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size <= 1_048_576 else { throw EnvironmentError.invalidMetadata }
        let bytes = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { throw EnvironmentError.invalidMetadata }
        guard version == 1 else { throw EnvironmentError.unsupportedSchema }
        guard let catalog = try? JSONDecoder().decode(AssociationCatalog.self, from: bytes) else {
            throw EnvironmentError.invalidMetadata
        }
        try catalog.validate()
        if location == nil {
            let profileIDs = Set(try readCatalog(at: metadataURL).profiles.map(\.id))
            guard Set(catalog.associations.map(\.profileID)).isSubset(of: profileIDs) else { throw EnvironmentError.invalidMetadata }
        }
        return catalog
    }

    private func saveAssociations(_ catalog: inout AssociationCatalog) throws {
        guard catalog.revision < UInt64.max else { throw EnvironmentError.invalidMetadata }
        catalog.revision += 1
        try catalog.validate()
        let url = root.appendingPathComponent("environments.json")
        if fm.fileExists(atPath: url.path) {
            try writeAssociations(readAssociations(), to: root.appendingPathComponent("environments.backup.json"))
        }
        try writeAssociations(catalog, to: url)
    }

    private func writeAssociations(_ catalog: AssociationCatalog, to url: URL) throws {
        try checkPath(url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= 1_048_576 else { throw ProfileError.storageUnavailable }
        try writer.write(data, to: url)
    }

    private func ensureUnique(_ name: String, in catalog: ProfileCatalog, excluding id: UUID? = nil) throws {
        guard !catalog.profiles.contains(where: { $0.id != id && AccountProfile.nameKey($0.name) == AccountProfile.nameKey(name) }) else {
            throw ProfileError.duplicateName
        }
    }

    private func checkPath(_ url: URL) throws {
        // Inspect every existing ancestor, including a dangling final symbolic link.
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw ProfileError.unsafePath }
            } else if errno != ENOENT { throw ProfileError.storageUnavailable }
            current.deleteLastPathComponent()
        }
    }

    private func privateDirectory(_ url: URL) throws {
        try checkPath(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func withLock<T>(readOnly: Bool = false, exclusiveExisting: Bool = false, allowSetupJournal: Bool = false, allowOpeningJournal: Bool = false, _ operation: () throws -> T) throws -> T {
        do {
            if !readOnly && !exclusiveExisting {
                try privateDirectory(root)
                try privateDirectory(profilesURL)
            }
            let lockURL = root.appendingPathComponent("metadata.lock")
            let flags = (readOnly || exclusiveExisting) ? O_RDONLY : O_CREAT | O_RDWR
            let descriptor = open(lockURL.path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw ProfileError.storageUnavailable }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1 else { throw ProfileError.unsafePath }
            guard flock(descriptor, (readOnly ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else { throw ProfileError.storeBusy }
            defer { _ = flock(descriptor, LOCK_UN) }
            if !allowSetupJournal {
                var journalInfo = stat()
                let present = lstat(root.appendingPathComponent("setup-journal.json").path, &journalInfo)
                guard present != 0, errno == ENOENT else { throw AccountSetupError.recoveryRequired }
            }
            if !readOnly && !exclusiveExisting && !Self.hasExistingOpeningMetadataLocked(root: root) {
                try OpeningOperationJournal.initializeFreshStoreLocked(root: root)
            }
            if !readOnly && !allowOpeningJournal {
                guard try OpeningOperationJournal.readLocked(root: root) == nil else { throw OpeningJournalError.conflict }
            }
            return try operation()
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProfileError { throw error }
        catch let error as EnvironmentError { throw error }
        catch let error as AssociationReplacementError { throw error }
        catch let error as AccountSetupError { throw error }
        catch let error as OpeningJournalError { throw error }
        catch { throw ProfileError.storageUnavailable } // Never expose arbitrary file contents/errors to UI logs.
    }

    private func readCatalog(at url: URL) throws -> ProfileCatalog {
        try checkPath(url)
        guard fm.fileExists(atPath: url.path) else {
            // Losing primary metadata is not permission to silently discard an existing backup.
            if url == metadataURL, fm.fileExists(atPath: backupURL.path) { throw ProfileError.corruptedStore }
            return ProfileCatalog()
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else { throw ProfileError.corruptedStore }
        let data = try Data(contentsOf: url)
        let catalog: ProfileCatalog
        do { catalog = try JSONDecoder().decode(ProfileCatalog.self, from: data) }
        catch { throw ProfileError.corruptedStore }
        try catalog.validate()
        return catalog
    }

    private func save(_ catalog: inout ProfileCatalog) throws {
        guard catalog.revision < UInt64.max else { throw ProfileError.corruptedStore }
        catalog.revision += 1
        try catalog.validate()
        if fm.fileExists(atPath: metadataURL.path) {
            let previous = try readCatalog(at: metadataURL)
            try write(previous, to: backupURL)
        }
        try write(catalog, to: metadataURL)
    }

    private func write(_ catalog: ProfileCatalog, to url: URL) throws {
        try checkPath(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= 1_048_576 else { throw ProfileError.storageUnavailable }
        try writer.write(data, to: url)
    }
}

/// Same-directory, owner-only temporary file; all fallible work precedes atomic rename.
public struct AtomicMetadataWriter: Sendable {
    private let beforeReplace: @Sendable (URL) throws -> Void

    /// The barrier permits deterministic I/O fault and interrupted-process tests. The app uses the no-op default.
    public init(beforeReplace: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.beforeReplace = beforeReplace
    }

    public func write(_ data: Data, to destination: URL, validateBeforeCommit: () throws -> Void = {}) throws {
        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".profiles-write-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw ProfileError.storageUnavailable }
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { close(descriptor); unlink(temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw ProfileError.storageUnavailable }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProfileError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ProfileError.storageUnavailable }
        try beforeReplace(destination)
        try validateBeforeCommit()
        guard Darwin.rename(temporary, destination.path) == 0 else { throw ProfileError.storageUnavailable }
        // Do not report a failed save after commit. Full power-loss durability is outside this contract.
    }
}

extension ProfileStore {
    private static let replacementFiles = ["profiles.json", "profiles.backup.json", "environments.json",
        "environments.backup.json", "managed-environments.json", "managed-environments.backup.json", "metadata.lock"]

    private func replacementSnapshot() throws -> [String: ReplacementFileSnapshot] {
        var result: [String: ReplacementFileSnapshot] = [:]
        for name in Self.replacementFiles {
            let url = root.appendingPathComponent(name)
            try checkPath(url)
            result[name] = try ReplacementFileSnapshot.read(url, optional: name.contains(".backup."))
        }
        return result
    }

    private func replacementDirectories(_ validator: EnvironmentValidator) throws -> [String: DirectoryIdentity] {
        guard validator.managedRoot == root, EnvironmentValidator.canonical(root.path) else { throw EnvironmentError.invalidPath }
        var result: [String: DirectoryIdentity] = [:]
        for url in [root, profilesURL] { result[url.path] = try validator.directory(url.path, privateOnly: true) }
        return result
    }

    /// Read-only, shared existing lock: no mkdir/chmod, lock creation, metadata or Codex writes.
    /// Both forward replacement and separately approved metadata restoration use this same path.
    public func previewEnvironmentReplacement(profileID: UUID, expectedProfile: AccountProfile,
        expectedRevision: UInt64, expectedCurrent: EnvironmentAssociation, target: EnvironmentAssociation,
        validator: EnvironmentValidator = EnvironmentValidator()) throws -> AssociationReplacementPreview {
        try Task.checkCancellation()
        let directories = try replacementDirectories(validator)
        return try withLock(readOnly: true) {
            let files = try replacementSnapshot()
            let profiles = try readCatalog(at: metadataURL)
            guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { throw ProfileError.missingProfile }
            guard profile == expectedProfile else { throw AssociationReplacementError.conflict }
            var catalog = try readAssociations()
            guard let index = catalog.associations.firstIndex(where: { $0.profileID == profileID }) else { throw EnvironmentError.missingAssociation }
            guard catalog.revision == expectedRevision, catalog.associations[index] == expectedCurrent else {
                throw AssociationReplacementError.conflict
            }
            guard target.profileID == profileID, expectedCurrent.profileID == profileID,
                  (expectedCurrent.kind == .temporaryResearch && target.kind == .managed)
                    || (expectedCurrent.kind == .managed && target.kind == .temporaryResearch) else {
                throw AssociationReplacementError.invalidTransition
            }
            let prepared = try readManagedCatalog()
            let managed = target.kind == .managed ? target : expectedCurrent
            guard let registered = prepared.prepared.first(where: { $0.profileID == profileID }),
                  Self.withCheckDate(managed, registered.checkedAt) == registered else {
                throw AssociationReplacementError.invalidTransition
            }
            // Validate existing optional backups now, before any write can replace their contents.
            if files["profiles.backup.json"]?.bytes != nil { _ = try readCatalog(at: backupURL) }
            if files["environments.backup.json"]?.bytes != nil { _ = try readAssociations(at: root.appendingPathComponent("environments.backup.json")) }
            if files["managed-environments.backup.json"]?.bytes != nil { _ = try readManagedCatalog(at: root.appendingPathComponent("managed-environments.backup.json")) }
            for value in catalog.associations where value.profileID != profileID {
                try Self.requireSeparate(target, from: value)
            }
            for value in catalog.associations + prepared.prepared { try validator.revalidate(value) }
            try validator.revalidate(target)
            // The source pair must remain separate even though it will be absent from the new catalog.
            try Self.requireSeparate(target, from: expectedCurrent)
            for value in prepared.prepared where value.profileID != profileID {
                try Self.requireSeparate(target, from: value)
            }
            let refreshed = Self.withCheckDate(target, Date())
            catalog.associations[index] = refreshed
            guard catalog.revision < UInt64.max else { throw EnvironmentError.invalidMetadata }
            catalog.revision += 1
            try catalog.validate()
            // Patch only the chosen object and revision, retaining unknown schema-1 fields everywhere.
            guard let before = files["environments.json"]?.bytes,
                  var object = try JSONSerialization.jsonObject(with: before) as? [String: Any],
                  var entries = object["associations"] as? [[String: Any]], entries.count == catalog.associations.count,
                  let replacement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(refreshed)) as? [String: Any] else {
                throw EnvironmentError.invalidMetadata
            }
            var changed: [String] = []
            for (key, value) in replacement {
                if !NSDictionary(dictionary: [key: value]).isEqual(to: [key: entries[index][key] as Any]) { changed.append("associations[\(index)].\(key)") }
                entries[index][key] = value
            }
            object["associations"] = entries; object["revision"] = NSNumber(value: catalog.revision)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard bytes.count <= 1_048_576, try JSONDecoder().decode(AssociationCatalog.self, from: bytes) == catalog else {
                throw EnvironmentError.invalidMetadata
            }
            guard try replacementSnapshot() == files, try replacementDirectories(validator) == directories else {
                throw AssociationReplacementError.conflict
            }
            try Task.checkCancellation()
            return AssociationReplacementPreview(profile: profile, previous: expectedCurrent, replacement: refreshed,
                expectedRevision: expectedRevision, backupURL: root.appendingPathComponent("environments.backup.json"),
                changedFields: ["revision"] + changed.sorted(),
                unchangedFields: ["schemaVersion", "all profile records and UUIDs", "other associations", "target profileID", "unknown schema-1 fields", "managed-environments.json"],
                proposedCatalog: catalog, root: root, files: files, directories: directories, proposedBytes: bytes)
        }
    }

    private static func withCheckDate(_ value: EnvironmentAssociation, _ date: Date) -> EnvironmentAssociation {
        EnvironmentAssociation(profileID: value.profileID, environmentID: value.environmentID, kind: value.kind,
            codexHome: value.codexHome, electronData: value.electronData, homeIdentity: value.homeIdentity,
            electronIdentity: value.electronIdentity, origin: value.origin, lastCheck: value.lastCheck, checkedAt: date)
    }

    private static func requireSeparate(_ a: EnvironmentAssociation, from b: EnvironmentAssociation) throws {
        guard a.environmentID != b.environmentID,
              ![a.codexHome, a.electronData].contains(where: { path in
                  [b.codexHome, b.electronData].contains(where: { EnvironmentValidator.overlaps(path, $0) })
              }), ![a.homeIdentity, a.electronIdentity].contains(where: { id in
                  [b.homeIdentity, b.electronIdentity].contains(where: { $0.device == id.device && $0.inode == id.inode })
              }) else { throw EnvironmentError.duplicateAssociation }
    }

    private func validateReplacement(_ preview: AssociationReplacementPreview,
        files: [String: ReplacementFileSnapshot], validator: EnvironmentValidator) throws {
        try Task.checkCancellation()
        guard preview.root == root, try replacementSnapshot() == files,
              try replacementDirectories(validator) == preview.directories else { throw AssociationReplacementError.conflict }
        for value in preview.proposedCatalog.associations + [preview.previous] { try validator.revalidate(value) }
        for value in try readManagedCatalog().prepared { try validator.revalidate(value) }
    }

    /// Exactly one entry under the existing actor and exclusive flock. No account/process/data operations.
    /// Caller must obtain separate user authorization before invoking this on real storage.
    public func replaceEnvironmentAssociation(profileID: UUID, preview: AssociationReplacementPreview,
        validator: EnvironmentValidator = EnvironmentValidator()) throws -> AssociationReplacementOutcome {
        guard profileID == preview.profile.id, profileID == preview.previous.profileID,
              profileID == preview.replacement.profileID else { throw AssociationReplacementError.invalidTransition }
        _ = try replacementDirectories(validator)
        return try withLock(exclusiveExisting: true) {
            try validateReplacement(preview, files: preview.files, validator: validator)
            guard let previousBytes = preview.files["environments.json"]?.bytes else { throw EnvironmentError.invalidMetadata }
            do {
                try writer.write(previousBytes, to: preview.backupURL) {
                    try validateReplacement(preview, files: preview.files, validator: validator)
                }
            } catch let error as AssociationReplacementError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw AssociationReplacementError.backupFailed }
            var backedUp = preview.files
            guard let backupSnapshot = try? ReplacementFileSnapshot.read(preview.backupURL, optional: false) else {
                throw AssociationReplacementError.outcomeUncertain
            }
            backedUp["environments.backup.json"] = backupSnapshot
            guard backedUp["environments.backup.json"]?.bytes == previousBytes else { throw AssociationReplacementError.outcomeUncertain }
            do {
                try validateReplacement(preview, files: backedUp, validator: validator)
                try writer.write(preview.proposedBytes, to: root.appendingPathComponent("environments.json")) {
                    try validateReplacement(preview, files: backedUp, validator: validator)
                }
            } catch {
                // Read back, never retry a potentially committed operation or restore automatically.
                guard let current = try? replacementSnapshot(), current == backedUp else {
                    throw AssociationReplacementError.outcomeUncertain
                }
                if let conflict = error as? AssociationReplacementError { throw conflict }
                if error is CancellationError { throw CancellationError() }
                throw AssociationReplacementError.writeFailedPreviousRetained
            }
            guard let after = try? replacementSnapshot(), after["environments.json"]?.bytes == preview.proposedBytes,
                  backedUp.allSatisfy({ $0.key == "environments.json" || after[$0.key] == $0.value }) else { return .reviewRequired }
            do { try validateReplacement(preview, files: after, validator: validator) }
            catch { return .reviewRequired }
            return .committed(revision: preview.proposedCatalog.revision)
        }
    }
}

// A bounded write-ahead journal coordinates only Swoop JSON files. No environment file is opened.
extension ProfileStore {
    private static let setupFiles = ["profiles.json", "profiles.backup.json", "environments.json", "environments.backup.json",
        "managed-environments.json", "managed-environments.backup.json", "retained-environments.json", "retained-environments.backup.json"]
    private var setupJournalURL: URL { root.appendingPathComponent("setup-journal.json") }
    private func setupEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 1_048_576 else { throw AccountSetupError.writeFailed }
        return bytes
    }
    private func setupSnapshot() throws -> [String: ReplacementFileSnapshot] {
        var files: [String: ReplacementFileSnapshot] = [:]
        for name in Self.setupFiles { files[name] = try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true) }
        return files
    }
    private func readRetained() throws -> RetainedEnvironmentCatalog {
        let bytes = try ReplacementFileSnapshot.read(root.appendingPathComponent("retained-environments.json"), optional: true).bytes
        guard let bytes else {
            guard !fm.fileExists(atPath: root.appendingPathComponent("retained-environments.backup.json").path) else { throw AccountSetupError.invalidJournal }
            return RetainedEnvironmentCatalog()
        }
        let catalog = try JSONDecoder().decode(RetainedEnvironmentCatalog.self, from: bytes)
        try catalog.validate(); return catalog
    }
    private func setupState() throws -> AccountSetupState {
        let directoryValidator = EnvironmentValidator(managedRoot: root)
        _ = try directoryValidator.directory(root.path, privateOnly: true)
        _ = try directoryValidator.directory(profilesURL.path, privateOnly: true)
        let state = try AccountSetupState(profiles: readCatalog(at: metadataURL), associations: readAssociations(),
            managed: readManagedCatalog(), retained: readRetained())
        try validateSetupState(state); return state
    }
    public func inspectAccountSetup() throws -> AccountSetupState {
        try withLock(readOnly: true) { try setupState() }
    }
    private func validateSetupState(_ state: AccountSetupState) throws {
        try state.profiles.validate(); try state.associations.validate(); try state.managed.validate(); try state.retained.validate()
        let ids = Set(state.profiles.profiles.map(\.id))
        guard Set(state.associations.associations.map(\.profileID)).isSubset(of: ids),
              Set(state.managed.prepared.map(\.profileID)).isSubset(of: ids) else { throw AccountSetupError.invalidJournal }
    }
    private func makeSetupPreview(operation: String, before: AccountSetupState, after: AccountSetupState,
                                  removed: [AccountProfile] = [], validationHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> AccountSetupPreview {
        try validateSetupState(before); try validateSetupState(after)
        return try AccountSetupPreview(id: UUID(), operation: operation, removedProfiles: removed, before: before,
            after: after, root: root, validationHome: validationHome, files: setupSnapshot())
    }
    private func retain(_ association: EnvironmentAssociation, profile: AccountProfile, in catalog: inout RetainedEnvironmentCatalog) {
        guard !catalog.environments.contains(where: { $0.id == association.environmentID }) else { return }
        catalog.environments.append(RetainedEnvironment(profile: profile, association: association, retainedAt: Date()))
    }
    private func retainHistoricalResearch(_ state: AccountSetupState, in catalog: inout RetainedEnvironmentCatalog) throws {
        let backup = try readAssociations(at: root.appendingPathComponent("environments.backup.json"))
        for reference in backup.associations where reference.isTemporary {
            if let profile = state.profiles.profiles.first(where: { $0.id == reference.profileID }) {
                retain(reference, profile: profile, in: &catalog)
            }
        }
    }
    public func previewProfileRemoval(id: UUID) throws -> AccountSetupPreview {
        try withLock(readOnly: true) {
            let before = try setupState()
            guard let profile = before.profiles.profiles.first(where: { $0.id == id }) else { throw ProfileError.missingProfile }
            return try removalPreview(before, removed: [profile], operation: "remove")
        }
    }
    /// Clears only the inactive Managed references displayed in Settings. Active catalogs and
    /// environment directories are outside this operation. Legacy reset journals remain recoverable.
    public func previewAccountSetupReset() throws -> AccountSetupPreview {
        try withLock(readOnly: true) {
            let before = try setupState()
            var retained = before.retained
            if retained.environments.contains(where: { $0.association.kind == .managed }) {
                guard retained.revision < UInt64.max else { throw AccountSetupError.conflict }
                retained.environments.removeAll { $0.association.kind == .managed }
                retained.revision += 1
            }
            return try makeSetupPreview(operation: "clearSavedManaged", before: before,
                after: AccountSetupState(profiles: before.profiles, associations: before.associations,
                    managed: before.managed, retained: retained))
        }
    }
    private func removalPreview(_ before: AccountSetupState, removed: [AccountProfile], operation: String) throws -> AccountSetupPreview {
        let ids = Set(removed.map(\.id))
        var profiles = before.profiles, associations = before.associations, managed = before.managed, retained = before.retained
        try retainHistoricalResearch(before, in: &retained)
        for profile in removed {
            for reference in before.associations.associations + before.managed.prepared where reference.profileID == profile.id {
                retain(reference, profile: profile, in: &retained)
            }
            // An interrupted old preparation may have retained directories with no registry entry.
            // Inspect only the pair's directory metadata; never its contents or authorization.
            if !retained.environments.contains(where: { $0.id == profile.id }) {
                let base = profilesURL.appendingPathComponent(profile.directoryIdentifier)
                if fm.fileExists(atPath: base.appendingPathComponent("codex-home").path),
                   fm.fileExists(atPath: base.appendingPathComponent("electron-user-data").path),
                   let reference = try? EnvironmentValidator(managedRoot: root).link(profileID: profile.id, environmentID: profile.id,
                       kind: .managed, home: base.path + "/codex-home", electron: base.path + "/electron-user-data") {
                    retain(reference, profile: profile, in: &retained)
                }
            }
        }
        profiles.profiles.removeAll { ids.contains($0.id) }; associations.associations.removeAll { ids.contains($0.profileID) }
        managed.prepared.removeAll { ids.contains($0.profileID) }
        guard profiles.revision < UInt64.max, associations.revision < UInt64.max,
              managed.revision < UInt64.max, retained.revision < UInt64.max else { throw AccountSetupError.conflict }
        profiles.revision += 1; associations.revision += 1; managed.revision += 1; retained.revision += 1
        return try makeSetupPreview(operation: operation, before: before,
            after: AccountSetupState(profiles: profiles, associations: associations, managed: managed, retained: retained), removed: removed)
    }
    public func previewSavedManagedRestore(environmentID: UUID) throws -> AccountSetupPreview {
        try withLock(readOnly: true) {
            let before = try setupState()
            guard let saved = before.retained.environments.first(where: { $0.id == environmentID }),
                  saved.association.kind == .managed, saved.profile.id == environmentID else { throw AccountSetupError.incompatibleEnvironment }
            guard !before.profiles.profiles.contains(where: { $0.id == saved.profile.id }),
                  !before.associations.associations.contains(where: { $0.environmentID == environmentID }) else { throw AccountSetupError.alreadyRestored }
            try ensureUnique(saved.profile.name, in: before.profiles)
            let validator = EnvironmentValidator(managedRoot: root); try validator.revalidate(saved.association)
            var profiles = before.profiles, associations = before.associations, managed = before.managed, retained = before.retained
            profiles.profiles.append(saved.profile); associations.associations.append(saved.association); managed.prepared.append(saved.association)
            retained.environments.removeAll { $0.id == environmentID }
            guard profiles.revision < UInt64.max, associations.revision < UInt64.max,
                  managed.revision < UInt64.max, retained.revision < UInt64.max else { throw AccountSetupError.conflict }
            profiles.revision += 1; associations.revision += 1; managed.revision += 1; retained.revision += 1
            return try makeSetupPreview(operation: "restoreManaged", before: before,
                after: AccountSetupState(profiles: profiles, associations: associations, managed: managed, retained: retained))
        }
    }
    /// The caller has selected a setup mode. Existing defaults are linked without sign-in or copying.
    public func previewNewAccount(name: String, managed: Bool, validator supplied: EnvironmentValidator? = nil) throws -> AccountSetupPreview {
        try withLock(exclusiveExisting: true) {
            let before = try setupState(), validator = supplied ?? EnvironmentValidator(managedRoot: root)
            guard validator.managedRoot == root else { throw AccountSetupError.incompatibleEnvironment }
            let profile = try AccountProfile(name: name); try ensureUnique(profile.name, in: before.profiles)
            let reference: EnvironmentAssociation
            if managed {
                let base = profilesURL.appendingPathComponent(profile.directoryIdentifier)
                // Never reuse a pre-existing directory, even for a UUID collision.
                guard mkdir(base.path, 0o700) == 0 else { throw AccountSetupError.incompatibleEnvironment }
                let fd = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw EnvironmentError.unsafeDirectory }; defer { close(fd) }
                for component in ["codex-home", "electron-user-data"] {
                    guard mkdirat(fd, component, 0o700) == 0 else { throw ProfileError.storageUnavailable }
                }
                reference = try validator.link(profileID: profile.id, environmentID: profile.id, kind: .managed,
                    home: base.path + "/codex-home", electron: base.path + "/electron-user-data")
            } else {
                reference = try validator.link(profileID: profile.id, environmentID: profile.id, kind: .standardExternal,
                    home: validator.userHome.appendingPathComponent(".codex").path,
                    electron: validator.userHome.appendingPathComponent("Library/Application Support/Codex").path)
            }
            guard !before.associations.associations.contains(where: { old in
                [old.codexHome, old.electronData].contains(where: { EnvironmentValidator.overlaps($0, reference.codexHome) || EnvironmentValidator.overlaps($0, reference.electronData) })
                    || [old.homeIdentity, old.electronIdentity].contains(where: { old in
                        [reference.homeIdentity, reference.electronIdentity].contains(where: { old.device == $0.device && old.inode == $0.inode }) })
            }) else { throw EnvironmentError.duplicateAssociation }
            var profiles = before.profiles, associations = before.associations, registry = before.managed, retained = before.retained
            try retainHistoricalResearch(before, in: &retained)
            profiles.profiles.append(profile); associations.associations.append(reference)
            if managed { registry.prepared.append(reference) }
            guard profiles.revision < UInt64.max, associations.revision < UInt64.max,
                  registry.revision < UInt64.max, retained.revision < UInt64.max else { throw AccountSetupError.conflict }
            profiles.revision += 1; associations.revision += 1; registry.revision += 1; retained.revision += 1
            return try makeSetupPreview(operation: managed ? "addManaged" : "linkExisting", before: before,
                after: AccountSetupState(profiles: profiles, associations: associations, managed: registry, retained: retained), validationHome: validator.userHome)
        }
    }
    private func setupBytes(_ preview: AccountSetupPreview) throws -> AccountSetupJournal {
        let before = preview.files.mapValues { SetupFileBytes(data: $0.bytes) }
        var after = before
        if preview.operation == "clearSavedManaged" {
            if preview.before.retained != preview.after.retained {
                after["retained-environments.backup.json"] = before["retained-environments.json"]
                after["retained-environments.json"] = SetupFileBytes(data: try setupEncode(preview.after.retained))
            }
            return AccountSetupJournal(schemaVersion: 1, id: preview.id, operation: preview.operation, before: before, after: after)
        }
        let values: [String: Data] = ["profiles.json": try setupEncode(preview.after.profiles),
            "environments.json": try setupEncode(preview.after.associations), "managed-environments.json": try setupEncode(preview.after.managed),
            "retained-environments.json": try setupEncode(preview.after.retained)]
        for (name, data) in values {
            let backup = String(name.dropLast(5)) + ".backup.json"
            after[backup] = before[name]; after[name] = SetupFileBytes(data: data)
        }
        return AccountSetupJournal(schemaVersion: 1, id: preview.id, operation: preview.operation, before: before, after: after)
    }
    private func syncSetupDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AccountSetupError.writeFailed }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw AccountSetupError.writeFailed }
    }
    private func setupBackupURL(_ id: UUID) -> URL {
        root.appendingPathComponent("SetupBackups/" + id.uuidString.lowercased())
    }
    private func verifySetupBackup(_ journal: AccountSetupJournal) throws {
        let parent = root.appendingPathComponent("SetupBackups"), folder = setupBackupURL(journal.id)
        let validator = EnvironmentValidator(managedRoot: root)
        _ = try validator.directory(parent.path, privateOnly: true); _ = try validator.directory(folder.path, privateOnly: true)
        let bytes = try ReplacementFileSnapshot.read(folder.appendingPathComponent("snapshot.json"), optional: false).bytes!
        guard try JSONDecoder().decode(AccountSetupJournal.self, from: bytes) == journal else { throw AccountSetupError.invalidJournal }
    }
    private func writeSetupBackup(_ journal: AccountSetupJournal) throws {
        let parent = root.appendingPathComponent("SetupBackups"), folder = setupBackupURL(journal.id)
        let validator = EnvironmentValidator(managedRoot: root)
        if !fm.fileExists(atPath: parent.path) { guard mkdir(parent.path, 0o700) == 0 else { throw AccountSetupError.backupFailed } }
        _ = try validator.directory(parent.path, privateOnly: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw AccountSetupError.backupFailed }
        try writer.write(setupEncode(journal), to: folder.appendingPathComponent("snapshot.json"))
        try syncSetupDirectory(folder); try syncSetupDirectory(parent); try syncSetupDirectory(root)
        try verifySetupBackup(journal)
    }
    private func applySetupBytes(_ files: [String: SetupFileBytes]) throws {
        // The journal blocks all other store APIs until the whole set is reconciled.
        for name in Self.setupFiles {
            guard let value = files[name] else { throw AccountSetupError.invalidJournal }
            let path = root.appendingPathComponent(name)
            let current = try ReplacementFileSnapshot.read(path, optional: true)
            if current.bytes == value.data { continue }
            if let data = value.data { try writer.write(data, to: path) }
            else { guard unlink(path.path) == 0 || errno == ENOENT else { throw AccountSetupError.writeFailed } }
            try syncSetupDirectory(root)
        }
        for name in Self.setupFiles {
            guard try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true).bytes == files[name]?.data else { throw AccountSetupError.invalidJournal }
        }
    }
    public func commitAccountSetup(_ preview: AccountSetupPreview) throws -> AccountSetupOutcome {
        try Task.checkCancellation()
        return try withLock(exclusiveExisting: true) {
            guard preview.root == root, try setupSnapshot() == preview.files, try setupState() == preview.before else { throw AccountSetupError.conflict }
            // Confirm newly linked/restored directories again after the user has reviewed the operation.
            let validator = EnvironmentValidator(userHome: preview.validationHome, managedRoot: root)
            for association in preview.after.associations.associations where !preview.before.associations.associations.contains(association) {
                try validator.revalidate(association)
            }
            let journal = try setupBytes(preview); try validateSetupJournal(journal)
            do { try writeSetupBackup(journal) } catch { throw AccountSetupError.backupFailed }
            // A backup is proof only after rereading it; recheck the reviewed files before writing intent.
            guard try setupSnapshot() == preview.files else { throw AccountSetupError.conflict }
            try Task.checkCancellation()
            do { try writer.write(setupEncode(journal), to: setupJournalURL); try syncSetupDirectory(root) }
            catch {
                if fm.fileExists(atPath: setupJournalURL.path) { return .reviewRequired }
                throw AccountSetupError.writeFailed
            }
            do {
                // Once intent is durable, cancellation leaves a recoverable journal rather than pretending nothing happened.
                try Task.checkCancellation(); try applySetupBytes(journal.after)
                guard try setupState() == preview.after else { throw AccountSetupError.invalidJournal }
                guard unlink(setupJournalURL.path) == 0 else { throw AccountSetupError.writeFailed }
                // Current files and journal removal are verified. If directory sync fails, a crash may
                // restore the journal; startup then requires explicit reconciliation of the same bytes.
                try? syncSetupDirectory(root)
                return .committed(preview.after)
            } catch { return .reviewRequired }
        }
    }
    private func validateSetupJournal(_ journal: AccountSetupJournal) throws {
        guard journal.schemaVersion == 1, ["remove", "reset", "clearSavedManaged", "addManaged", "linkExisting", "restoreManaged"].contains(journal.operation),
              Set(journal.before.keys) == Set(Self.setupFiles), Set(journal.after.keys) == Set(Self.setupFiles) else { throw AccountSetupError.invalidJournal }
        if journal.operation == "clearSavedManaged" {
            for name in Self.setupFiles where !name.hasPrefix("retained-environments") {
                guard journal.before[name] == journal.after[name] else { throw AccountSetupError.invalidJournal }
            }
            let before = try journal.before["retained-environments.json"]?.data.map {
                try JSONDecoder().decode(RetainedEnvironmentCatalog.self, from: $0)
            } ?? RetainedEnvironmentCatalog()
            let after = try journal.after["retained-environments.json"]?.data.map {
                try JSONDecoder().decode(RetainedEnvironmentCatalog.self, from: $0)
            } ?? RetainedEnvironmentCatalog()
            var expected = before
            if before.environments.contains(where: { $0.association.kind == .managed }) {
                guard before.revision < UInt64.max else { throw AccountSetupError.invalidJournal }
                expected.environments.removeAll { $0.association.kind == .managed }
                expected.revision += 1
                guard journal.after["retained-environments.backup.json"] == journal.before["retained-environments.json"] else {
                    throw AccountSetupError.invalidJournal
                }
            } else {
                guard journal.after == journal.before else { throw AccountSetupError.invalidJournal }
            }
            guard after == expected else { throw AccountSetupError.invalidJournal }
        }
        for files in [journal.before, journal.after] {
            func decode<T: Decodable>(_ type: T.Type, _ name: String, fallback: T) throws -> T {
                guard let data = files[name]?.data else { return fallback }
                return try JSONDecoder().decode(type, from: data)
            }
            let state = try AccountSetupState(profiles: decode(ProfileCatalog.self, "profiles.json", fallback: ProfileCatalog()),
                associations: decode(AssociationCatalog.self, "environments.json", fallback: AssociationCatalog()),
                managed: decode(ManagedEnvironmentCatalog.self, "managed-environments.json", fallback: ManagedEnvironmentCatalog()),
                retained: decode(RetainedEnvironmentCatalog.self, "retained-environments.json", fallback: RetainedEnvironmentCatalog()))
            try validateSetupState(state)
        }
    }
    private func readSetupJournal() throws -> AccountSetupJournal? {
        guard let bytes = try ReplacementFileSnapshot.read(setupJournalURL, optional: true).bytes else { return nil }
        let journal = try JSONDecoder().decode(AccountSetupJournal.self, from: bytes)
        try validateSetupJournal(journal); try verifySetupBackup(journal)
        for name in Self.setupFiles {
            let bytes = try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true).bytes
            guard bytes == journal.before[name]?.data || bytes == journal.after[name]?.data else { throw AccountSetupError.invalidJournal }
        }
        return journal
    }
    public func inspectPendingAccountSetup() throws -> PendingAccountSetup? {
        try withLock(readOnly: true, allowSetupJournal: true) {
            guard let journal = try readSetupJournal() else { return nil }
            return PendingAccountSetup(id: journal.id, operation: journal.operation, backupURL: setupBackupURL(journal.id))
        }
    }
    /// Explicit recovery is compare-and-reconcile, never a blind retry of removal or reset.
    public func recoverAccountSetup(id: UUID, decision: AccountSetupRecovery) throws -> AccountSetupOutcome {
        try withLock(exclusiveExisting: true, allowSetupJournal: true) {
            guard let journal = try readSetupJournal(), journal.id == id else { throw AccountSetupError.conflict }
            do {
                try applySetupBytes(decision == .finish ? journal.after : journal.before)
                let state = try setupState()
                guard unlink(setupJournalURL.path) == 0 else { throw AccountSetupError.writeFailed }
                // Current files and journal removal are verified. If directory sync fails, a crash may
                // restore the journal; startup then requires explicit reconciliation of the same bytes.
                try? syncSetupDirectory(root)
                return .committed(state)
            } catch { return .reviewRequired }
        }
    }
}


extension ProfileStore {
    /// Called only with metadata.lock held. Look at allowlisted Swoop metadata names, never Codex data.
    static func hasExistingOpeningMetadataLocked(root: URL) -> Bool {
        let names = ["profiles.json", "profiles.backup.json", "environments.json", "environments.backup.json",
            "managed-environments.json", "managed-environments.backup.json", "retained-environments.json",
            "retained-environments.backup.json", "setup-journal.json"]
        return names.contains { name in
            var info = stat()
            return lstat(root.appendingPathComponent(name).path, &info) == 0 || errno != ENOENT
        }
    }
    /// The journal invokes this synchronously under metadata.lock, after acquiring its operation lease.
    /// No actor hop or gap between the snapshot comparison and durable intent publication.
    static func openingCatalogDigestLocked(root: URL, mode: AccountOpeningMode) throws -> String {
        var setup = stat()
        guard lstat(root.appendingPathComponent("setup-journal.json").path, &setup) != 0, errno == ENOENT else {
            throw AccountSetupError.recoveryRequired
        }
        func read<T: Decodable>(_ name: String, default value: T) throws -> T {
            guard let data = try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true).bytes else { return value }
            return try JSONDecoder().decode(T.self, from: data)
        }
        let profiles = try read("profiles.json", default: ProfileCatalog())
        let associations = try read("environments.json", default: AssociationCatalog())
        let managed = try read("managed-environments.json", default: ManagedEnvironmentCatalog())
        try profiles.validate(); try associations.validate(); try managed.validate()
        var retained: [EnvironmentAssociation] = []
        if mode == .closeOthersAndOpen {
            let backup = try read("environments.backup.json", default: AssociationCatalog())
            try backup.validate()
            retained = backup.associations.filter { candidate in
                candidate.isTemporary && profiles.profiles.contains(where: { $0.id == candidate.profileID })
                    && !associations.associations.contains(candidate)
                    && !associations.associations.contains(where: { $0.environmentID == candidate.environmentID })
            }
        }
        return try PendingOpeningOperation.digest(profiles: profiles, associations: associations, managed: managed, retained: retained)
    }
}
