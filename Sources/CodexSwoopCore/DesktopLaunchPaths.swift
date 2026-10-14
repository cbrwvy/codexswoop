import CryptoKit
import Darwin
import Foundation

/// Short, owner-only launch aliases. The original directories and associations never move.
/// Codex resolves CODEX_HOME lexically before binding ipc/ipc.sock (Darwin sun_path: 104 bytes).
public struct DesktopLaunchPaths: Sendable, Equatable {
    public let association: EnvironmentAssociation
    public let home: String
    public let electron: String
    private let container: URL?

    public init(association: EnvironmentAssociation, base: URL? = nil) {
        self.association = association
        if (association.codexHome + "/ipc/ipc.sock").utf8.count < 104 {
            home = association.codexHome; electron = association.electronData; container = nil
        } else {
            // Bind the aliases to both paths and directory identities, not merely a profile UUID.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(association.homeIdentity)) ?? Data()
            let other = (try? encoder.encode(association.electronIdentity)) ?? Data()
            let input = Data((association.codexHome + "\n" + association.electronData).utf8) + data + other
            let key = SHA256.hash(data: input).prefix(12).map { String(format: "%02x", $0) }.joined()
            let root = base ?? URL(fileURLWithPath: "/private/tmp/codexswoop-runtime-\(getuid())")
            let folder = root.appendingPathComponent(key)
            container = folder; home = folder.appendingPathComponent("h").path
            electron = folder.appendingPathComponent("e").path
        }
    }

    /// Only called after operation confirmation. No credential/state file is opened or copied.
    public func prepare(validator: EnvironmentValidator) throws {
        try validator.revalidate(association)
        guard (home + "/ipc/ipc.sock").utf8.count < 104 else { throw EnvironmentError.launchPathTooLong }
        guard let container else { return }
        for directory in [container.deletingLastPathComponent(), container] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw EnvironmentError.unsafeDirectory }
            _ = try validator.directory(directory.path, privateOnly: true)
        }
        for (link, target) in [(home, association.codexHome), (electron, association.electronData)] {
            if symlink(target, link) != 0 && errno != EEXIST { throw EnvironmentError.unsafeDirectory }
        }
        try validate(validator: validator)
    }

    public func validate(validator: EnvironmentValidator) throws {
        try validator.revalidate(association)
        guard let container else { return }
        _ = try validator.directory(container.deletingLastPathComponent().path, privateOnly: true)
        _ = try validator.directory(container.path, privateOnly: true)
        for (link, target, identity) in [(home, association.codexHome, association.homeIdentity), (electron, association.electronData, association.electronIdentity)] {
            var info = stat()
            var destination = stat()
            guard lstat(link, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
                  info.st_uid == getuid(), info.st_nlink == 1,
                  try FileManager.default.destinationOfSymbolicLink(atPath: link) == target,
                  stat(link, &destination) == 0, destination.st_mode & S_IFMT == S_IFDIR,
                  UInt64(destination.st_dev) == identity.device, destination.st_ino == identity.inode,
                  destination.st_uid == identity.owner, UInt16(destination.st_mode & 0o777) == identity.permissions else {
                throw EnvironmentError.changedDirectory
            }
        }
        try validator.revalidate(association)
    }

    /// Read-only; absent aliases are allowed before first launch. Present aliases must be exact.
    func existing(validator: EnvironmentValidator) throws -> Self? {
        guard let container else { return nil }
        var info = stat()
        if lstat(container.path, &info) != 0 {
            guard errno == ENOENT else { throw EnvironmentError.unsafeDirectory }; return nil
        }
        try validate(validator: validator); return self
    }
}
