import Foundation

/// Publisher policy, independent of the version/build currently installed.
/// Metadata is only discovery evidence; native admission also requires valid code signatures.
public enum OfficialCodexPolicy {
    public static let path = "/Applications/ChatGPT.app"
    public static let executable = "ChatGPT"
    public static let teamIdentifier = "2DC432GLL2"
    public static let signingRequirement = "identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""

    public static func acceptsMetadata(_ installation: CodexInstallation) -> Bool {
        installation.url.isFileURL && installation.url.path == path
            && installation.url.standardizedFileURL.path == path
            && installation.bundleIdentifier == CodexBundleInspector.bundleIdentifier
            && installation.executableName == executable
    }

    public static func validate(_ installation: CodexInstallation, signature: CodexSigningIdentity,
                                signatureValid: Bool, before: String, after: String) throws {
        guard acceptsMetadata(installation), signatureValid, !before.isEmpty, before == after else {
            throw EnvironmentError.incompatibleBuild
        }
        try signature.validate()
    }
}

/// Informational only. Never used to admit metadata changes or native effects.
public enum LastTestedCodexBuild {
    public static let version = "26.1007.21159"
    public static let build = "20052"
    public static func matches(_ installation: CodexInstallation) -> Bool {
        installation.version == version && installation.build == build
    }
}

/// Non-secret signature evidence bound to a particular process generation by DesktopInstance.
/// Different valid live and on-disk code hashes are allowed after an official update.
public struct CodexSigningIdentity: Codable, Equatable, Sendable {
    public let identifier: String
    public let teamIdentifier: String
    public let codeDirectoryHash: String
    public init(identifier: String, teamIdentifier: String, codeDirectoryHash: String) {
        self.identifier = identifier; self.teamIdentifier = teamIdentifier; self.codeDirectoryHash = codeDirectoryHash
    }
    public func validate() throws {
        guard identifier == CodexBundleInspector.bundleIdentifier,
              teamIdentifier == OfficialCodexPolicy.teamIdentifier,
              [40, 64].contains(codeDirectoryHash.utf8.count),
              codeDirectoryHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EnvironmentError.incompatibleBuild
        }
    }
}
