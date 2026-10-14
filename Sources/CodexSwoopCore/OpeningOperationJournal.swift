import CryptoKit
import Darwin
import Foundation

public enum OpeningJournalError: Error, LocalizedError, Sendable {
    case invalid, unavailable, busy, conflict, legacyUninitialized
    public var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("review.journalInvalid")
        case .unavailable: L10n.text("review.journalUnavailable")
        case .busy: L10n.text("review.journalBusy")
        case .conflict: L10n.text("review.journalConflict")
        case .legacyUninitialized: L10n.text("review.journalLegacy")
        }
    }
}

/// Evidence only. Never deserialize a capability, profile name, authorization or launch arguments.
public struct PendingOpeningOperation: Codable, Equatable, Sendable {
    public struct Receiver: Codable, Equatable, Sendable {
        public let environmentID: UUID
        public let instance: DesktopInstance
    }
    public let id: UUID
    public let mode: AccountOpeningMode
    public let bootSession: String
    public let buildFingerprint: OpeningBuildFingerprint
    public let catalogDigest: String
    public let targetEnvironmentID: UUID
    public let targetInstance: DesktopInstance?
    public let others: [Receiver]
    public var effects: [EnvironmentSubmittedEffect]

    public init(scope: EnvironmentOperationScope, bootSession: String, buildFingerprint: OpeningBuildFingerprint) throws {
        id = scope.id; mode = scope.mode; self.bootSession = bootSession; self.buildFingerprint = buildFingerprint
        catalogDigest = try Self.digest(profiles: scope.profiles, associations: scope.associations,
                                        managed: scope.managed, retained: scope.retainedResearch)
        targetEnvironmentID = scope.target.environmentID; targetInstance = scope.targetInstance
        others = scope.others.map { Receiver(environmentID: $0.association.environmentID, instance: $0.instance) }
        effects = []
        try validate()
    }
    public static func digest(profiles: ProfileCatalog, associations: AssociationCatalog,
                              managed: ManagedEnvironmentCatalog, retained: [EnvironmentAssociation]) throws -> String {
        struct Snapshot: Encodable {
            let profiles: ProfileCatalog, associations: AssociationCatalog
            let managed: ManagedEnvironmentCatalog
            let retained: [EnvironmentAssociation]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Snapshot(profiles: profiles, associations: associations,
                                                           managed: managed, retained: retained)))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        try buildFingerprint.validate()
        guard !bootSession.isEmpty, bootSession.count <= 128, catalogDigest.count == 64,
              catalogDigest.allSatisfy({ $0.isHexDigit }), others.count <= 128,
              mode == .closeOthersAndOpen || others.isEmpty,
              !others.contains(where: { $0.environmentID == targetEnvironmentID }),
              Set(others.map(\.environmentID)).count == others.count else { throw OpeningJournalError.invalid }
        var pids = Set<Int32>()
        for instance in others.map(\.instance) + (targetInstance.map { [$0] } ?? []) {
            _ = try DesktopObservation(matching: [instance], ambiguous: false).unique()
            for generation in instance.related {
                guard pids.insert(generation.pid).inserted else { throw OpeningJournalError.invalid }
            }
        }
        var quits = Set<DesktopInstanceKey>(), launched = false, activated = false
        for effect in effects {
            guard !activated else { throw OpeningJournalError.invalid }
            switch effect {
            case .normalQuit(let instance):
                guard !launched, mode == .closeOthersAndOpen, others.contains(where: { $0.instance == instance }),
                      quits.insert(DesktopInstanceKey(instance)).inserted else { throw OpeningJournalError.invalid }
            case .launch:
                guard targetInstance == nil, !launched, quits.count == others.count else { throw OpeningJournalError.invalid }
                launched = true
            case .activation(let instance):
                _ = try DesktopObservation(matching: [instance], ambiguous: false).unique()
                guard (targetInstance == instance || (targetInstance == nil && launched)),
                      quits.count == others.count else { throw OpeningJournalError.invalid }
                activated = true
            case .unknown: throw OpeningJournalError.invalid
            }
        }
    }
    private struct DesktopInstanceKey: Hashable {
        let main: DesktopGeneration
        init(_ instance: DesktopInstance) { main = instance.main }
    }
}

/// One operation across all Swoop processes. The lease is held until postflight or failure,
/// never by a recovered record. Every record transition also uses the existing metadata lock.
public final class OpeningOperationJournal: @unchecked Sendable {
    struct Envelope: Codable {
        var schemaVersion = 2
        let storeID: UUID
        let revision: UInt64
        let state: String
        let pending: PendingOpeningOperation?
        let settled: PendingOpeningOperation?
        var supersession: OpeningEpochProvenance? = nil
    }
    struct Watermark: Codable {
        var schemaVersion = 1
        let storeID: UUID
        let revision: UInt64
        let journalSHA256: String
    }
    private let root: URL
    private let writer: AtomicMetadataWriter
    private let mutex = NSLock()
    private var lease: Int32 = -1
    private var ownedID: UUID?
    public init(root: URL, writer: AtomicMetadataWriter = AtomicMetadataWriter()) {
        self.root = root; self.writer = writer
    }
    deinit { if lease >= 0 { close(lease) } }
    public static func bootSession() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else {
            throw OpeningJournalError.unavailable
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw OpeningJournalError.unavailable }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public func pending() throws -> PendingOpeningOperation? {
        mutex.lock(); defer { mutex.unlock() }
        if !FileManager.default.fileExists(atPath: root.path) {
            var info = stat()
            guard lstat(root.path, &info) != 0, errno == ENOENT else { throw OpeningJournalError.invalid }
            return nil
        }
        return try metadataLock { try Self.readLocked(root: root) }
    }
    /// Used by ProfileStore while already holding metadata.lock. Never bootstrap on a read.
    static func readLocked(root: URL) throws -> PendingOpeningOperation? {
        try envelopeLocked(root: root)?.pending
    }
    private static func bytesLocked(_ root: URL, _ name: String) throws -> Data? {
        let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { guard errno == ENOENT else { throw OpeningJournalError.invalid }; return nil }
        defer { close(fd) }
        try checkFile(fd)
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size <= 262_144 else { throw OpeningJournalError.invalid }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    private static func envelopeLocked(root: URL) throws -> Envelope? {
        let journal = try bytesLocked(root, "opening-journal.json")
        let marker = try bytesLocked(root, "opening-journal-watermark.json")
        if journal == nil && marker == nil {
            guard !ProfileStore.hasExistingOpeningMetadataLocked(root: root) else { throw OpeningJournalError.legacyUninitialized }
            return nil
        }
        guard let journal, let marker else { throw OpeningJournalError.invalid }
        let value = try decodePair(journal, marker)
        if value.schemaVersion == 3 {
            do { try OpeningEpochEngine.verifyProvenance(root: root, provenance: value.supersession, storeID: value.storeID) }
            catch { throw OpeningJournalError.invalid }
        }
        return value
    }
    static func decodePair(_ journal: Data, _ marker: Data) throws -> Envelope {
        guard journal.count <= 262_144, marker.count <= 262_144 else { throw OpeningJournalError.invalid }
        let value: Envelope, watermark: Watermark
        do {
            value = try JSONDecoder().decode(Envelope.self, from: journal)
            watermark = try JSONDecoder().decode(Watermark.self, from: marker)
        } catch { throw OpeningJournalError.invalid }
        guard (value.schemaVersion == 2 && value.supersession == nil)
                || (value.schemaVersion == 3 && value.supersession != nil) else { throw OpeningJournalError.invalid }
        guard watermark.schemaVersion == 1,
              value.storeID == watermark.storeID, value.revision == watermark.revision,
              hash(journal) == watermark.journalSHA256,
              (value.state == "idle" && value.pending == nil)
                || (value.state == "pending" && value.pending != nil && value.settled == nil) else { throw OpeningJournalError.invalid }
        try value.pending?.validate(); try value.settled?.validate()
        return value
    }
    /// Only a store with no previous account/setup metadata can bootstrap automatically.
    static func initializeFreshStoreLocked(root: URL, writer: AtomicMetadataWriter = AtomicMetadataWriter()) throws {
        if try envelopeLocked(root: root) != nil { return }
        let journal = OpeningOperationJournal(root: root, writer: writer)
        try journal.persist(Envelope(storeID: UUID(), revision: 0, state: "idle", pending: nil, settled: nil))
    }
    /// Safe only for empty Swoop metadata storage; existing legacy stores are explicitly rejected.
    public func initializeFreshStore() throws {
        mutex.lock(); defer { mutex.unlock() }
        try acquireLease(); defer { releaseLease() }
        try metadataLock { try Self.initializeFreshStoreLocked(root: root, writer: writer) }
    }
    /// Separate reviewed migration API; not exposed by startup, Check Again, or a Reset button.
    /// The caller must first resolve the older running app's volatile recovery and obtain write consent.
    public func initializeAfterLegacyRecoveryReview(expectedCatalogDigest: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try acquireLease(); defer { releaseLease() }
        try metadataLock {
            guard try Self.bytesLocked(root, "opening-journal.json") == nil,
                  try Self.bytesLocked(root, "opening-journal-watermark.json") == nil,
                  try ProfileStore.openingCatalogDigestLocked(root: root, mode: .closeOthersAndOpen) == expectedCatalogDigest else {
                throw OpeningJournalError.conflict
            }
            try persist(Envelope(storeID: UUID(), revision: 0, state: "idle", pending: nil, settled: nil))
        }
    }
    public func begin(_ record: PendingOpeningOperation) throws {
        mutex.lock(); defer { mutex.unlock() }
        try record.validate()
        try acquireLease()
        do {
            try metadataLock {
                guard let current = try Self.envelopeLocked(root: root), current.pending == nil,
                      try ProfileStore.openingCatalogDigestLocked(root: root, mode: record.mode) == record.catalogDigest else {
                    throw OpeningJournalError.conflict
                }
                try save(record)
                ownedID = record.id
            }
        } catch { releaseLease(); throw error }
    }
    public func append(_ effect: EnvironmentSubmittedEffect, operation: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard lease >= 0, ownedID == operation else { throw OpeningJournalError.conflict }
        try metadataLock {
            guard var record = try Self.readLocked(root: root), record.id == operation else { throw OpeningJournalError.conflict }
            record.effects.append(effect); try record.validate(); try save(record)
        }
    }
    /// Acquire a fresh exclusive lease before any read-only reconciliation. A live owner blocks it.
    public func acquireRecovery(expectedOperation: UUID? = nil) throws -> PendingOpeningOperation {
        mutex.lock(); defer { mutex.unlock() }
        try acquireLease()
        do {
            return try metadataLock {
                guard let envelope = try Self.envelopeLocked(root: root),
                      let value = envelope.pending ?? (envelope.settled?.id == expectedOperation ? envelope.settled : nil),
                      expectedOperation == nil || value.id == expectedOperation else { throw OpeningJournalError.conflict }
                ownedID = value.id; return value
            }
        } catch { releaseLease(); throw error }
    }
    public func complete(_ operation: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard lease >= 0, ownedID == operation else { throw OpeningJournalError.conflict }
        try metadataLock {
            guard let envelope = try Self.envelopeLocked(root: root),
                  let record = envelope.pending ?? envelope.settled, record.id == operation,
                  try ProfileStore.openingCatalogDigestLocked(root: root, mode: record.mode) == record.catalogDigest else { throw OpeningJournalError.conflict }
            try save(nil, settled: record)
        }
        releaseLease()
    }
    public func abandon() {
        mutex.lock(); defer { mutex.unlock() }
        releaseLease() // The pending record remains intact; no cleanup or replay.
    }
    private func save(_ record: PendingOpeningOperation?, settled: PendingOpeningOperation? = nil) throws {
        guard let current = try Self.envelopeLocked(root: root), current.revision < UInt64.max else { throw OpeningJournalError.invalid }
        try persist(Envelope(schemaVersion: current.schemaVersion, storeID: current.storeID, revision: current.revision + 1,
            state: record == nil ? "idle" : "pending", pending: record, settled: settled, supersession: current.supersession))
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func persist(_ envelope: Envelope) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= 262_144 else { throw OpeningJournalError.invalid }
        let marker = try encoder.encode(Watermark(storeID: envelope.storeID, revision: envelope.revision, journalSHA256: Self.hash(data)))
        // Prepare watermark FIRST. Any crash before the matching journal is durable leaves a
        // detectable mismatch. Never silently adopt the older journal or repair a torn pair.
        try durableWrite(marker, name: "opening-journal-watermark.json")
        try durableWrite(data, name: "opening-journal.json")
    }
    private func durableWrite(_ data: Data, name: String) throws {
        try writer.write(data, to: root.appendingPathComponent(name))
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OpeningJournalError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw OpeningJournalError.unavailable }
    }
    private func acquireLease() throws {
        guard lease < 0 else { throw OpeningJournalError.busy }
        _ = try EnvironmentValidator(managedRoot: root).directory(root.path, privateOnly: true)
        let fd = open(root.appendingPathComponent("opening-operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw OpeningJournalError.unavailable }
        do {
            try Self.checkFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OpeningJournalError.busy }
            lease = fd
        } catch { close(fd); throw error }
    }
    private func releaseLease() {
        if lease >= 0 { _ = flock(lease, LOCK_UN); close(lease) }
        lease = -1; ownedID = nil
    }
    private func metadataLock<T>(_ body: () throws -> T) throws -> T {
        _ = try EnvironmentValidator(managedRoot: root).directory(root.path, privateOnly: true)
        let fd = open(root.appendingPathComponent("metadata.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw OpeningJournalError.unavailable }
        defer { close(fd) }
        try Self.checkFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OpeningJournalError.busy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private static func checkFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw OpeningJournalError.invalid }
    }
}
