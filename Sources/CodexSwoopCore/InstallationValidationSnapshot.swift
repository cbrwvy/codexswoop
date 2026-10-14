import CryptoKit
import Foundation
import Darwin

/// Metadata only, including nanosecond change times. Never reads application/user file contents.
/// A cached full signature/archive validation is reusable only for this exact bundle generation.
public struct InstallationValidationSnapshot: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        let path: String
        let device: UInt64, inode: UInt64, size: Int64
        let mode: UInt16, owner: UInt32, group: UInt32
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        let link: String?
    }
    private let entries: [Entry]

    public var fingerprint: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
    public static func capture(_ location: URL) throws -> Self {
        var original = stat()
        guard location.isFileURL, lstat(location.path, &original) == 0,
              original.st_mode & S_IFMT == S_IFDIR else { throw EnvironmentError.incompatibleBuild }
        // macOS also canonicalizes parent aliases such as /private/tmp to /tmp.
        // Accept those aliases, but never a symlink in place of the bundle itself.
        let root = location.resolvingSymlinksInPath()
        var canonical = stat()
        guard lstat(root.path, &canonical) == 0, canonical.st_dev == original.st_dev,
              canonical.st_ino == original.st_ino else { throw EnvironmentError.incompatibleBuild }
        let fm = FileManager.default
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            enumerationFailed = true; return false
        }) else { throw EnvironmentError.incompatibleBuild }
        var paths = [root]
        while let path = enumerator.nextObject() as? URL {
            guard paths.count < 100_000 else { throw EnvironmentError.incompatibleBuild }
            paths.append(path)
        }
        guard !enumerationFailed else { throw EnvironmentError.incompatibleBuild }
        let entries = try paths.map { path -> Entry in
            var value = stat()
            guard lstat(path.path, &value) == 0 else { throw EnvironmentError.incompatibleBuild }
            let type = value.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { throw EnvironmentError.incompatibleBuild }
            var link: String?
            if type == S_IFLNK {
                let resolved = path.resolvingSymlinksInPath().path
                guard EnvironmentValidator.beneath(resolved, root.path) else { throw EnvironmentError.incompatibleBuild }
                link = try fm.destinationOfSymbolicLink(atPath: path.path)
            }
            return Entry(path: String(path.path.dropFirst(root.path.count)), device: UInt64(value.st_dev),
                inode: value.st_ino, size: value.st_size, mode: value.st_mode, owner: value.st_uid, group: value.st_gid,
                modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
                changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec, link: link)
        }.sorted { $0.path < $1.path }
        return Self(entries: entries)
    }
}
