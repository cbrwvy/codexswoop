import Darwin
import Foundation
import OSLog

/// Small diagnostics only: closed action names and typed error codes, never raw errors or account data.
public final class ActionErrorLog: @unchecked Sendable {
    public enum Action: String, Codable, Sendable {
        case load, addAccount, editProfile, removeProfile, restoreProfile, resetSaved, linkEnvironment
        case prepareEnvironment, openProfile, reviewOperation, checkEnvironment, installation, login, openLog, other
    }
    public struct Entry: Codable, Sendable {
        public let timestamp: Date
        public let action: Action
        public let code: String
    }
    public let url: URL
    private let root: URL
    private let lock = NSLock()
    private let system = Logger(subsystem: "io.github.cbrwvy.codexswoop", category: "actions")
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CodexSwoop")) {
        self.root = root; url = root.appendingPathComponent("errors.log")
    }
    public func record(_ action: Action, error: Error) {
        let code = Self.code(error)
        system.error("action=\(action.rawValue, privacy: .public) code=\(code, privacy: .public)")
        lock.lock(); defer { lock.unlock() }
        do {
            try prepare()
            let previous = try read()
            let entry = Entry(timestamp: Date(), action: action, code: code)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            // Keep the latest 500 errors, one JSON object per line, across application restarts.
            let lines = previous.split(separator: 10).suffix(499).map { Data($0) }
            var data = Data()
            for line in lines { data.append(line); data.append(10) }
            data.append(try encoder.encode(entry)); data.append(10)
            try AtomicMetadataWriter().write(data, to: url)
        } catch { system.error("error_log_unavailable") }
    }
    public func fileForViewing() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try prepare(); _ = try read(); return url
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProfileError.unsafePath }
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw ProfileError.storageUnavailable }
            try AtomicMetadataWriter().write(Data(), to: url)
        }
    }
    private func read() throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ProfileError.storageUnavailable }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 262_144 else { throw ProfileError.unsafePath }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    private static func code(_ error: Error) -> String {
        // These local enums carry only closed vocabulary and numeric OS status codes.
        if let error = error as? ProfileError { return "profile." + String(describing: error) }
        if let error = error as? EnvironmentError { return "environment." + String(describing: error) }
        if let error = error as? AccountSetupError { return "setup." + String(describing: error) }
        if let error = error as? OpeningJournalError { return "journal." + String(describing: error) }
        if let error = error as? SwitchingError { return "opening." + String(describing: error) }
        if let error = error as? AccountOpeningError { return "opening." + String(describing: error) }
        if let error = error as? EnvironmentOpeningError { return "opening." + String(describing: error) }
        if error is CancellationError { return "cancelled" }
        return "unexpected.\((error as NSError).code)"
    }
}
