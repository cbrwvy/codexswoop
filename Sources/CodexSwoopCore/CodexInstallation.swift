import Foundation

public struct CodexInstallation: Equatable, Sendable {
    public let url: URL
    public let version: String
    public let bundleIdentifier: String
    public let build: String

    public init(url: URL, version: String, bundleIdentifier: String = CodexBundleInspector.bundleIdentifier, build: String = "Unknown") {
        self.url = url; self.version = version; self.bundleIdentifier = bundleIdentifier; self.build = build
    }
}

/// Read-only metadata inspection; bundle identity is discovery evidence, not signing/authentication proof.
public enum CodexBundleInspector {
    public static let bundleIdentifier = "com.openai.codex"

    public static func inspect(_ url: URL) -> CodexInstallation? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard url.pathExtension.lowercased() == "app",
              let attributes = try? FileManager.default.attributesOfItem(atPath: plist.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              let executableAttributes = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path),
              executableAttributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { return nil }
        let rawVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        // A manually selected bundle must not inject control characters or arbitrary text into diagnostics.
        let version = rawVersion.count <= 80 && !rawVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            ? rawVersion : "Unknown"
        return CodexInstallation(url: url, version: version, bundleIdentifier: bundleIdentifier, build: info["CFBundleVersion"] as? String ?? "Unknown")
    }

    public static func detect(candidates: [URL]) -> CodexInstallation? {
        candidates.lazy.compactMap(inspect).first
    }

    public static func standardLocations(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")].flatMap { directory in
            ["Codex.app", "ChatGPT.app"].map { directory.appendingPathComponent($0) }
        }
    }
}

/// Presentation preflight only. Native effects still require the complete fresh signature/archive proof.
public enum ReviewedCodexBuild {
    public static let path = "/Applications/ChatGPT.app"
    public static let version = "26.1007.21159"
    public static let build = "20052"
    public static let archiveSHA256 = "97b8e5fddfced82d782c5f3f3e7c5aba7940b8cb1068dd214ffa3d71687d9fdb"
    public static let signingRequirement = "identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
    public static func matches(_ installation: CodexInstallation) -> Bool {
        installation.url.path == path && installation.version == version && installation.build == build
            && installation.bundleIdentifier == CodexBundleInspector.bundleIdentifier
    }
}

public enum CodexAvailability: String, CaseIterable, Sendable {
    case missing, checking, verified, unverified
    public var messageKey: String { "onboarding.codex." + rawValue }
    public var permitsSetup: Bool { self == .verified }
}

/// A permission observation is never an account/window ownership proof or a request to macOS.
public enum AccessibilityStatus: Sendable {
    case allowed, denied
    public var messageKey: String { self == .allowed ? "settings.granted" : "settings.notGranted" }
    public var permitsPIDOpening: Bool { true }
    public var permitsWindowInspection: Bool { self == .allowed }
}

public enum FirstRunPresentation {
    public static func showsWelcome(profileCount: Int, storageReady: Bool) -> Bool {
        storageReady && profileCount == 0
    }
    // Use the official landing page rather than a version-specific installer URL.
    // Verified against OpenAI's documentation on 2026-10-13.
    public static let downloadURL = URL(string: "https://learn.chatgpt.com/docs/app")!
}
