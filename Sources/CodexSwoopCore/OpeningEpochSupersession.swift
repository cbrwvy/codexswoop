import AppKit
import CryptoKit
import Darwin
import Foundation

public enum OpeningEpochError: Error, Equatable, Sendable {
    case consentRequired, swoopRunning, evidenceChanged, originalPIDAbsenceUnproven(Int32)
    case invalidArchive, alreadySuperseded, unavailable
}

/// Only the separately invoked recovery executable constructs this native-only facade.
/// Startup, the coordinator, Check Again and legacy initialization never call it.
public struct OpeningEpochRecovery: Sendable {
    public init() {}
    public func inspect() async throws -> OpeningEpochReview {
        try await engine().run(consent: nil)
    }
    public func apply(consent: String, acceptingUnknownOutcome: Bool) async throws -> OpeningEpochReview {
        guard acceptingUnknownOutcome else { throw OpeningEpochError.consentRequired }
        return try await engine().run(consent: consent)
    }
    static func requiresSwoopShutdown(pid: Int32, bundleID: String?, executable: String?,
        terminated: Bool, inspectorPID: Int32) -> Bool {
        guard !terminated else { return false }
        // Launch Services may associate the nested CLI with its containing bundle.
        // Exclude only this exact helper PID; an actual GUI or another instance blocks.
        if pid == inspectorPID && executable == "codexswoop-recovery" { return false }
        return bundleID == "io.github.cbrwvy.codexswoop" || executable == "CodexSwoop"
    }
    private func engine() -> OpeningEpochEngine {
        let native = NativeDesktopSystem()
        return OpeningEpochEngine(root: ProfileStore.defaultRoot, sample: { references, originals in
            let running = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains {
                    Self.requiresSwoopShutdown(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                        executable: $0.executableURL?.lastPathComponent, terminated: $0.isTerminated, inspectorPID: getpid())
                }
            }
            // ESRCH is required for each original PID. Any existing PID, even another
            // UID or a zombie or a reused generation, blocks. No kill/quit API is used.
            func requireAbsent() throws {
                for pid in originals.sorted() {
                    var info = proc_bsdinfo(); errno = 0
                    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                    guard count == 0, errno == ESRCH else { throw OpeningEpochError.originalPIDAbsenceUnproven(pid) }
                }
            }
            try requireAbsent()
            let boot = try OpeningOperationJournal.bootSession()
            let build = try await native.openingBuildFingerprint()
            let inventory = try await native.environmentInstanceInventory(associations: references)
            guard try OpeningOperationJournal.bootSession() == boot,
                  try await native.openingBuildFingerprint() == build else { throw OpeningEpochError.evidenceChanged }
            try requireAbsent()
            let runningAfter = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains {
                    Self.requiresSwoopShutdown(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                        executable: $0.executableURL?.lastPathComponent, terminated: $0.isTerminated, inspectorPID: getpid())
                }
            }
            return OpeningEpochObservation(boot: boot, build: build, inventory: inventory,
                originalPIDsAbsent: true, swoopRunning: running || runningAfter)
        })
    }
}

public struct OpeningEpochReview: Sendable {
    public let storeID: UUID, operationID: UUID
    public let journalSHA256: String
    public let swoopRunning: Bool
    public let alreadyApplied: Bool
    public var consent: String { "supersede-unresolved:\(storeID.uuidString):\(operationID.uuidString):\(journalSHA256)" }
}

struct OpeningEpochObservation: Sendable {
    let boot: String
    let build: OpeningBuildFingerprint
    let inventory: DesktopInstanceInventory
    let originalPIDsAbsent: Bool, swoopRunning: Bool
}

/// On-disk provenance is retained by every subsequent journal transition. Schema 3
/// prevents an older reader from silently ignoring the required unresolved archive.
struct OpeningEpochProvenance: Codable, Equatable, Sendable {
    let manifestSHA256: String
    let originalStoreID: UUID, operationID: UUID
}

struct OpeningEpochManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let historicalOutcome: String
    let authorization: String
    let originalStoreID: UUID, operationID: UUID, newStoreID: UUID
    let rootIdentity: DirectoryIdentity
    let profilesIdentity: DirectoryIdentity
    let catalogIdentities: [String: OpeningEpochFileIdentity]
    let hashes: [String: String]
}

struct OpeningEpochFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64, inode: UInt64
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(_ s: ReplacementFileSnapshot) {
        device = s.device; inode = s.inode; modifiedSeconds = s.modifiedSeconds; modifiedNanos = s.modifiedNanos
        changedSeconds = s.changedSeconds; changedNanos = s.changedNanos
    }
}
struct OpeningEpochCommit: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let manifestSHA256: String
    let storeID: UUID
    let state: String
}

/// Internal injection surface for synthetic QA only. The public facade cannot accept
/// a substitute probe, writer, root or fault hook.
struct OpeningEpochEngine: Sendable {
    static let archiveName = "UnresolvedOpeningEpoch"
    static let catalogs = ["profiles.json", "profiles.backup.json", "environments.json", "environments.backup.json",
        "managed-environments.json", "managed-environments.backup.json", "retained-environments.json", "retained-environments.backup.json"]
    static let pair = ["opening-journal.json", "opening-journal-watermark.json"]
    let root: URL
    var sample: @Sendable ([EnvironmentAssociation], Set<Int32>) async throws -> OpeningEpochObservation
    var fault: @Sendable (String) throws -> Void = { _ in }
    var writer = AtomicMetadataWriter()
    var validator: EnvironmentValidator { EnvironmentValidator(managedRoot: root) }
    var archive: URL { root.appendingPathComponent(Self.archiveName) }

    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func absent(_ path: URL) throws -> Bool {
        var s = stat()
        if lstat(path.path, &s) == 0 { return false }
        guard errno == ENOENT else { throw OpeningEpochError.unavailable }; return true
    }
    func snapshot() throws -> [String: ReplacementFileSnapshot] {
        guard try Self.absent(root.appendingPathComponent("setup-journal.json")) else { throw AccountSetupError.recoveryRequired }
        var result: [String: ReplacementFileSnapshot] = [:]
        for name in Self.catalogs + Self.pair { result[name] = try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: Self.catalogs.contains(name)) }
        return result
    }
    func catalogs(_ files: [String: ReplacementFileSnapshot], record: PendingOpeningOperation) throws -> [EnvironmentAssociation] {
        func decode<T: Decodable>(_ name: String, _ empty: T) throws -> T {
            guard let data = files[name]?.bytes else { return empty }
            return try JSONDecoder().decode(T.self, from: data)
        }
        // Preserve ProfileStore's missing-primary/available-backup refusal. An absent
        // catalog is not an empty catalog when its previous snapshot still exists.
        for name in ["profiles", "environments", "managed-environments", "retained-environments"] {
            guard files[name + ".json"]?.bytes != nil || files[name + ".backup.json"]?.bytes == nil else { throw OpeningEpochError.evidenceChanged }
        }
        let profiles = try decode("profiles.json", ProfileCatalog())
        let associations = try decode("environments.json", AssociationCatalog())
        let managed = try decode("managed-environments.json", ManagedEnvironmentCatalog())
        let retained = try decode("retained-environments.json", RetainedEnvironmentCatalog())
        let backup = try decode("environments.backup.json", AssociationCatalog())
        try profiles.validate(); try associations.validate(); try managed.validate(); try retained.validate(); try backup.validate()
        try decode("profiles.backup.json", ProfileCatalog()).validate()
        try decode("managed-environments.backup.json", ManagedEnvironmentCatalog()).validate()
        try decode("retained-environments.backup.json", RetainedEnvironmentCatalog()).validate()
        let ids = Set(profiles.profiles.map(\.id))
        guard Set(associations.associations.map(\.profileID)).isSubset(of: ids),
              Set(managed.prepared.map(\.profileID)).isSubset(of: ids) else { throw OpeningEpochError.evidenceChanged }
        let research = backup.associations.filter { a in
            a.isTemporary && ids.contains(a.profileID) && !associations.associations.contains(a)
                && !associations.associations.contains(where: { $0.environmentID == a.environmentID })
        }
        guard try PendingOpeningOperation.digest(profiles: profiles, associations: associations, managed: managed,
            retained: record.mode == .closeOthersAndOpen ? research : []) == record.catalogDigest else { throw OpeningEpochError.evidenceChanged }
        var references = associations.associations
        for a in managed.prepared + retained.environments.map(\.association) + research {
            if let old = references.first(where: { $0.environmentID == a.environmentID }) {
                guard old.profileID == a.profileID, old.kind == a.kind,
                      old.codexHome == a.codexHome, old.electronData == a.electronData,
                      old.homeIdentity == a.homeIdentity, old.electronIdentity == a.electronIdentity else { throw OpeningEpochError.evidenceChanged }
            } else { references.append(a) }
        }
        guard references.contains(where: { $0.environmentID == record.targetEnvironmentID }),
              record.others.allSatisfy({ r in references.contains { $0.environmentID == r.environmentID } }) else { throw OpeningEpochError.evidenceChanged }
        return references
    }
    func run(consent: String?) async throws -> OpeningEpochReview {
        let lease = try OpeningEpochLocks(root: root)
        defer { lease.release() }
        let files = try snapshot()
        if try !Self.absent(archive) { _ = try validator.directory(archive.path, privateOnly: true) }
        let manifestBytes = try ReplacementFileSnapshot.read(archive.appendingPathComponent("manifest.json"), optional: true).bytes
        let manifest: OpeningEpochManifest?
        let originalJournal: Data, originalWatermark: Data
        if let manifestBytes {
            _ = try validator.directory(archive.path, privateOnly: true)
            let value = try JSONDecoder().decode(OpeningEpochManifest.self, from: manifestBytes)
            try Self.validateManifest(value)
            guard value.rootIdentity == lease.identity else { throw OpeningEpochError.evidenceChanged }
            manifest = value
            originalJournal = try archiveBytes(Self.pair[0])
            originalWatermark = try archiveBytes(Self.pair[1])
            try verifyArchive(value)
        } else {
            // An incomplete archive without a manifest never authorizes active-pair repair.
            manifest = nil
            guard let j = files[Self.pair[0]]?.bytes, let w = files[Self.pair[1]]?.bytes else { throw OpeningJournalError.invalid }
            originalJournal = j; originalWatermark = w
        }
        let original = try OpeningOperationJournal.decodePair(originalJournal, originalWatermark)
        guard original.schemaVersion == 2, original.supersession == nil, let record = original.pending else {
            throw OpeningEpochError.alreadySuperseded
        }
        let review = OpeningEpochReview(storeID: original.storeID, operationID: record.id,
            journalSHA256: Self.hash(originalJournal), swoopRunning: false, alreadyApplied: false)
        if let consent, consent != review.consent { throw OpeningEpochError.consentRequired }
        if let manifest {
            guard manifest.originalStoreID == original.storeID, manifest.operationID == record.id,
                  manifest.authorization == review.consent else { throw OpeningEpochError.invalidArchive }
            // Idempotent status, even after later operations in the new epoch: never
            // republish idle, change revisions, or supersede a second pending operation.
            if let j = files[Self.pair[0]]?.bytes, let w = files[Self.pair[1]]?.bytes,
               let current = try? OpeningOperationJournal.decodePair(j, w), current.storeID == manifest.newStoreID,
               try !Self.absent(archive.appendingPathComponent("epoch-commit.json")) {
                try Self.verifyProvenance(root: root, provenance: current.supersession, storeID: current.storeID)
                return OpeningEpochReview(storeID: original.storeID, operationID: record.id,
                    journalSHA256: review.journalSHA256, swoopRunning: false, alreadyApplied: true)
            }
            try verifyCatalogHashes(files, manifest)
            // Resume only the exact old pair or watermark-first torn transition that
            // this manifest prepared. Arbitrary corrupt/rolled-back bytes are never fixed.
            let prepared = try Self.newPair(manifest)
            let oldOrTorn = files[Self.pair[0]]?.bytes == originalJournal
                && (files[Self.pair[1]]?.bytes == originalWatermark || files[Self.pair[1]]?.bytes == prepared.watermark)
            let awaitingCommit = files[Self.pair[0]]?.bytes == prepared.journal && files[Self.pair[1]]?.bytes == prepared.watermark
            guard oldOrTorn || awaitingCommit,
                  try Self.absent(archive.appendingPathComponent("epoch-commit.json")) else { throw OpeningEpochError.invalidArchive }
        }
        let references = try catalogs(files, record: record)
        let profilesIdentity = try validator.directory(root.appendingPathComponent("Profiles").path, privateOnly: true)
        if let manifest, manifest.profilesIdentity != profilesIdentity { throw OpeningEpochError.evidenceChanged }
        let instances = (record.targetInstance.map { [$0] } ?? []) + record.others.map(\.instance) + record.effects.compactMap {
            switch $0 { case .activation(let i), .normalQuit(let i): return i; default: return nil }
        }
        let generations = instances.flatMap(\.related)
        guard !generations.isEmpty, generations.allSatisfy({ $0.startTimeMicroseconds != nil }) else { throw OpeningEpochError.evidenceChanged }
        let originalPIDs = Set(generations.map(\.pid))
        func revalidate() throws {
            try lease.validate()
            guard try validator.directory(root.appendingPathComponent("Profiles").path, privateOnly: true) == profilesIdentity else { throw OpeningEpochError.evidenceChanged }
            for a in references { try validator.revalidate(a) }
            guard try snapshot() == files else { throw OpeningEpochError.evidenceChanged }
            try Task.checkCancellation()
        }
        func observation() async throws -> OpeningEpochObservation {
            try revalidate()
            let result = try await sample(references, originalPIDs)
            try result.inventory.validate(); try result.build.validate()
            guard result.boot == record.bootSession, result.build == record.buildFingerprint,
                  result.originalPIDsAbsent else { throw OpeningEpochError.evidenceChanged }
            for entry in result.inventory.entries {
                guard references.contains(entry.association), entry.instance.signingIdentity != nil,
                      entry.instance.related.allSatisfy({ $0.startTimeMicroseconds != nil && !originalPIDs.contains($0.pid) }) else { throw OpeningEpochError.evidenceChanged }
            }
            try revalidate(); return result
        }
        func same(_ a: OpeningEpochObservation, _ b: OpeningEpochObservation) -> Bool {
            a.boot == b.boot && a.build == b.build && a.inventory.entries.count == b.inventory.entries.count
                && a.inventory.entries.allSatisfy { x in b.inventory.entries.contains { $0.association == x.association && $0.instance == x.instance } }
        }
        let first = try await observation(), second = try await observation()
        guard same(first, second) else { throw OpeningEpochError.evidenceChanged }
        guard let consent else {
            return OpeningEpochReview(storeID: review.storeID, operationID: review.operationID,
                journalSHA256: review.journalSHA256, swoopRunning: first.swoopRunning || second.swoopRunning, alreadyApplied: false)
        }
        guard !first.swoopRunning, !second.swoopRunning else { throw OpeningEpochError.swoopRunning }
        let prepared: OpeningEpochManifest
        if let manifest { prepared = manifest }
        else {
            try prepareDirectory()
            // File writes are resumable only with identical bytes. A conflicting file
            // is evidence, never overwritten to make a partial archive look complete.
            for name in Self.catalogs + Self.pair {
                if let bytes = files[name]?.bytes { try archiveWrite(bytes, name: name) }
            }
            let newID = UUID()
            var hashes: [String: String] = [:]
            for name in Self.catalogs + Self.pair { hashes[name] = files[name]?.bytes.map(Self.hash) ?? "absent" }
            prepared = OpeningEpochManifest(schemaVersion: 1, historicalOutcome: "unknown", authorization: consent,
                originalStoreID: original.storeID, operationID: record.id, newStoreID: newID,
                rootIdentity: lease.identity, profilesIdentity: profilesIdentity,
                catalogIdentities: Dictionary(uniqueKeysWithValues: Self.catalogs.map { ($0, OpeningEpochFileIdentity(files[$0]!)) }), hashes: hashes)
            try archiveWrite(Self.encode(prepared), name: "manifest.json")
        }
        try verifyArchive(prepared)
        let newPair = try Self.newPair(prepared)
        try fault("archive-verified")
        // Archive is durable before any live journal byte changes. Repeat all native
        // evidence after archival, while both original locks are still held.
        let final = try await observation()
        guard !final.swoopRunning, same(second, final) else { throw OpeningEpochError.evidenceChanged }
        try revalidate()
        let pairPrepared = files[Self.pair[0]]?.bytes == newPair.journal && files[Self.pair[1]]?.bytes == newPair.watermark
        if !pairPrepared {
            try write(newPair.watermark, to: root.appendingPathComponent(Self.pair[1]), stage: "new-watermark")
        }
        // A crash here is a mismatched pair and blocks ordinary readers. Only an
        // explicitly consented rerun can recognize this exact prepared watermark.
        try lease.validate()
        for name in Self.catalogs {
            guard try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true) == files[name] else { throw OpeningEpochError.evidenceChanged }
        }
        try verifyArchive(prepared)
        try fault("before-commit")
        if !pairPrepared {
            try write(newPair.journal, to: root.appendingPathComponent(Self.pair[0]), stage: "commit-journal")
        } else {
            try sync(root, stage: "resume-prepared-pair")
        }
        guard try ReplacementFileSnapshot.read(root.appendingPathComponent(Self.pair[0]), optional: false).bytes == newPair.journal,
              try ReplacementFileSnapshot.read(root.appendingPathComponent(Self.pair[1]), optional: false).bytes == newPair.watermark else { throw OpeningEpochError.evidenceChanged }
        try archiveWrite(Self.encode(OpeningEpochCommit(schemaVersion: 1, manifestSHA256: Self.hash(try Self.encode(prepared)),
            storeID: prepared.newStoreID, state: "committed")), name: "epoch-commit.json")
        try Self.verifyProvenance(root: root,
            provenance: try OpeningOperationJournal.decodePair(newPair.journal, newPair.watermark).supersession, storeID: prepared.newStoreID)
        try fault("committed")
        return review
    }
    func archiveBytes(_ name: String) throws -> Data {
        _ = try validator.directory(archive.path, privateOnly: true)
        guard let data = try ReplacementFileSnapshot.read(archive.appendingPathComponent(name), optional: false).bytes else { throw OpeningEpochError.invalidArchive }
        return data
    }
    func verifyCatalogHashes(_ files: [String: ReplacementFileSnapshot], _ m: OpeningEpochManifest) throws {
        for name in Self.catalogs {
            guard (files[name]?.bytes.map(Self.hash) ?? "absent") == m.hashes[name],
                  files[name].map(OpeningEpochFileIdentity.init) == m.catalogIdentities[name] else { throw OpeningEpochError.evidenceChanged }
        }
    }
    static func validateManifest(_ m: OpeningEpochManifest) throws {
        guard m.schemaVersion == 1, m.historicalOutcome == "unknown", m.originalStoreID != m.newStoreID,
              Set(m.hashes.keys) == Set(catalogs + pair),
              Set(m.catalogIdentities.keys) == Set(catalogs) else { throw OpeningEpochError.invalidArchive }
        let oldHash = m.hashes[pair[0]] ?? ""
        guard m.authorization == "supersede-unresolved:\(m.originalStoreID.uuidString):\(m.operationID.uuidString):\(oldHash)" else { throw OpeningEpochError.invalidArchive }
        let pair = try newPair(m)
        let new = try OpeningOperationJournal.decodePair(pair.journal, pair.watermark)
        guard new.schemaVersion == 3, new.storeID == m.newStoreID, new.revision == 0,
              new.state == "idle", new.pending == nil, new.settled == nil,
              new.supersession == OpeningEpochProvenance(manifestSHA256: hash(try encode(m)), originalStoreID: m.originalStoreID, operationID: m.operationID) else { throw OpeningEpochError.invalidArchive }
    }
    static func newPair(_ m: OpeningEpochManifest) throws -> (journal: Data, watermark: Data) {
        let journal = try encode(OpeningOperationJournal.Envelope(schemaVersion: 3, storeID: m.newStoreID,
            revision: 0, state: "idle", pending: nil, settled: nil,
            supersession: OpeningEpochProvenance(manifestSHA256: hash(try encode(m)),
                originalStoreID: m.originalStoreID, operationID: m.operationID)))
        let watermark = try encode(OpeningOperationJournal.Watermark(storeID: m.newStoreID,
            revision: 0, journalSHA256: hash(journal)))
        return (journal, watermark)
    }
    func verifyArchive(_ m: OpeningEpochManifest) throws {
        try Self.validateManifest(m)
        _ = try validator.directory(archive.path, privateOnly: true)
        for name in Self.catalogs + Self.pair {
            let data = try ReplacementFileSnapshot.read(archive.appendingPathComponent(name), optional: true).bytes
            guard (data.map(Self.hash) ?? "absent") == m.hashes[name] else { throw OpeningEpochError.invalidArchive }
        }
        guard try archiveBytes("manifest.json") == Self.encode(m) else { throw OpeningEpochError.invalidArchive }
        let original = try OpeningOperationJournal.decodePair(archiveBytes(Self.pair[0]), archiveBytes(Self.pair[1]))
        guard original.schemaVersion == 2, original.supersession == nil,
              original.storeID == m.originalStoreID, original.pending?.id == m.operationID else { throw OpeningEpochError.invalidArchive }
    }
    static func verifyProvenance(root: URL, provenance: OpeningEpochProvenance?, storeID: UUID) throws {
        guard let p = provenance else { throw OpeningEpochError.invalidArchive }
        let engine = OpeningEpochEngine(root: root, sample: { _, _ in throw OpeningEpochError.unavailable })
        let bytes = try engine.archiveBytes("manifest.json")
        guard p.manifestSHA256 == hash(bytes) else { throw OpeningEpochError.invalidArchive }
        let m = try JSONDecoder().decode(OpeningEpochManifest.self, from: bytes)
        try engine.verifyArchive(m)
        let commit = try JSONDecoder().decode(OpeningEpochCommit.self, from: engine.archiveBytes("epoch-commit.json"))
        guard commit == OpeningEpochCommit(schemaVersion: 1, manifestSHA256: p.manifestSHA256, storeID: storeID, state: "committed"),
              m.newStoreID == storeID, m.originalStoreID == p.originalStoreID, m.operationID == p.operationID,
              try engine.validator.directory(root.path, privateOnly: true) == m.rootIdentity,
              try engine.validator.directory(root.appendingPathComponent("Profiles").path, privateOnly: true) == m.profilesIdentity else { throw OpeningEpochError.invalidArchive }
    }
    func prepareDirectory() throws {
        if try Self.absent(archive) {
            try fault("before-archive-create")
            guard mkdir(archive.path, 0o700) == 0 else { throw OpeningEpochError.unavailable }
            try fault("after-archive-create")
            try sync(root, stage: "archive-parent")
        }
        _ = try validator.directory(archive.path, privateOnly: true)
        try sync(root, stage: "archive-parent-existing")
    }
    func archiveWrite(_ bytes: Data, name: String) throws {
        let path = archive.appendingPathComponent(name)
        if let old = try ReplacementFileSnapshot.read(path, optional: true).bytes {
            guard old == bytes else { throw OpeningEpochError.invalidArchive }
            try sync(archive, stage: "archive-existing-\(name)"); return
        }
        try write(bytes, to: path, stage: "archive-\(name)")
    }
    func write(_ data: Data, to path: URL, stage: String) throws {
        try fault("before-write-\(stage)")
        try writer.write(data, to: path) { try fault("file-fsynced-\(stage)") }
        try fault("renamed-\(stage)")
        try sync(path.deletingLastPathComponent(), stage: stage)
    }
    func sync(_ directory: URL, stage: String) throws {
        try fault("before-fsync-\(stage)")
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OpeningEpochError.unavailable }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw OpeningEpochError.unavailable }
        try fault("after-fsync-\(stage)")
    }
}

/// Existing files only; no bootstrap or lock creation. Retain descriptors through
/// all async observations, verify root and lock identities before commit.
private final class OpeningEpochLocks {
    let root: URL, identity: DirectoryIdentity
    private var fds: [Int32] = []
    private var snapshots: [String: ReplacementFileSnapshot] = [:]
    init(root: URL) throws {
        self.root = root
        identity = try EnvironmentValidator(managedRoot: root).directory(root.path, privateOnly: true)
        do {
            for name in ["opening-operation.lock", "metadata.lock"] {
                let path = root.appendingPathComponent(name)
                let snapshot = try ReplacementFileSnapshot.read(path, optional: false)
                let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw OpeningEpochError.unavailable }; fds.append(fd)
                var s = stat()
                guard fstat(fd, &s) == 0, UInt64(s.st_dev) == snapshot.device, s.st_ino == snapshot.inode else { throw OpeningEpochError.evidenceChanged }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OpeningJournalError.busy }
                snapshots[name] = snapshot
            }
        } catch { release(); throw error }
    }
    deinit { release() }
    func release() { for fd in fds { close(fd) }; fds = [] }
    func validate() throws {
        guard try EnvironmentValidator(managedRoot: root).directory(root.path, privateOnly: true) == identity else { throw OpeningEpochError.evidenceChanged }
        for (name, snapshot) in snapshots {
            guard try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: false) == snapshot else { throw OpeningEpochError.evidenceChanged }
        }
    }
}
