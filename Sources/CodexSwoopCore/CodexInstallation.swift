import Foundation

public struct CodexInstallation: Equatable, Sendable {
    public let url: URL
    public let version: String
    public let bundleIdentifier: String
    public let build: String
    public let executableName: String

    public init(url: URL, version: String, bundleIdentifier: String = CodexBundleInspector.bundleIdentifier, build: String = "Unknown", executableName: String = "ChatGPT") {
        self.url = url; self.version = version; self.bundleIdentifier = bundleIdentifier; self.build = build; self.executableName = executableName
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
        let rawBuild = info["CFBundleVersion"] as? String ?? "Unknown"
        let build = rawBuild.count <= 80 && !rawBuild.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? rawBuild : "Unknown"
        return CodexInstallation(url: url, version: version, bundleIdentifier: bundleIdentifier, build: build, executableName: executable)
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

public enum CodexAvailability: String, CaseIterable, Sendable {
    case missing, checking, verified, unverified
    public var messageKey: String { "onboarding.codex." + rawValue }
    public var permitsSetup: Bool { true }
    public var permitsOpening: Bool { self == .verified }
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
