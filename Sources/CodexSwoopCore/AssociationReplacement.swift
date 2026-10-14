import Foundation
import Darwin

public enum AssociationReplacementError: Error, LocalizedError, Equatable, Sendable {
    case conflict, invalidTransition, backupFailed, writeFailedPreviousRetained, outcomeUncertain
    public var errorDescription: String? {
        switch self {
        case .conflict: L10n.text("message.ecfea25ef6")
        case .invalidTransition: L10n.text("message.13ca412a22")
        case .backupFailed: L10n.text("message.80fbafe4c9")
        case .writeFailedPreviousRetained: L10n.text("message.0303835640")
        case .outcomeUncertain: L10n.text("message.6cd2894127")
        }
    }
}

/// Immutable in-memory compare-and-replace capability. It contains only Swoop metadata.
/// Constructed only by a successful preview; never persisted as account identity evidence.
public struct AssociationReplacementPreview: Sendable {
    public let profile: AccountProfile
    public let previous: EnvironmentAssociation
    public let replacement: EnvironmentAssociation
    public let expectedRevision: UInt64
    public let backupURL: URL
    public let changedFields: [String]
    public let unchangedFields: [String]
    public let proposedCatalog: AssociationCatalog
    let root: URL
    let files: [String: ReplacementFileSnapshot]
    let directories: [String: DirectoryIdentity]
    let proposedBytes: Data
    /// Exact proposed JSON, for an explicitly requested metadata-only review; never account proof.
    public var proposedMetadata: Data { proposedBytes }
}

public enum AssociationReplacementOutcome: Sendable, Equatable {
    case committed(revision: UInt64)
    /// Atomic rename may have succeeded. Never automatically retry, roll back, or perform lifecycle actions.
    case reviewRequired
}

/// Includes bytes and filesystem generation, so replacement with identical bytes still conflicts.
struct ReplacementFileSnapshot: Equatable, Sendable {
    let bytes: Data?
    let device: UInt64, inode: UInt64, modifiedSeconds: Int64, modifiedNanos: Int64
    let changedSeconds: Int64, changedNanos: Int64
    static func read(_ url: URL, optional: Bool) throws -> Self {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, optional else { throw EnvironmentError.invalidMetadata }
            return Self(bytes: nil, device: 0, inode: 0, modifiedSeconds: 0, modifiedNanos: 0, changedSeconds: 0, changedNanos: 0)
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw EnvironmentError.invalidMetadata }
        defer { close(fd) }
        var retained = stat()
        guard fstat(fd, &retained) == 0, retained.st_mode & S_IFMT == S_IFREG,
              retained.st_uid == getuid(), retained.st_nlink == 1, retained.st_mode & 0o7777 == 0o600,
              retained.st_size >= 0, retained.st_size <= 1_048_576,
              retained.st_dev == info.st_dev, retained.st_ino == info.st_ino else { throw EnvironmentError.invalidMetadata }
        var bytes = Data(count: Int(retained.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw EnvironmentError.invalidMetadata }
                offset += count
            }
        }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              same(retained, after), same(after, pathAfter) else { throw AssociationReplacementError.conflict }
        return Self(bytes: bytes, device: UInt64(after.st_dev), inode: after.st_ino,
                    modifiedSeconds: Int64(after.st_mtimespec.tv_sec), modifiedNanos: Int64(after.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(after.st_ctimespec.tv_sec), changedNanos: Int64(after.st_ctimespec.tv_nsec))
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
