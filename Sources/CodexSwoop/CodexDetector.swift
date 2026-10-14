import AppKit

import CodexSwoopCore

@MainActor
struct CodexDetector {
    static let bundleIdentifier = CodexBundleInspector.bundleIdentifier

    func detect(preferredPath: String?) -> CodexInstallation? {
        var candidates: [URL] = []
        if let preferredPath, !preferredPath.isEmpty { candidates.append(URL(fileURLWithPath: preferredPath)) }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) { candidates.append(registered) }
        candidates += CodexBundleInspector.standardLocations(home: FileManager.default.homeDirectoryForCurrentUser)
        return CodexBundleInspector.detect(candidates: candidates)
    }

    func inspect(_ url: URL) -> CodexInstallation? { CodexBundleInspector.inspect(url) }

    /// Read-only inventory. A future process manager must verify code identity before taking action.
    func runningProcessIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
    }
}
