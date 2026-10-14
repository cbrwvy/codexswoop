import Foundation
import Darwin
import CodexSwoopCore

// Research fixtures only. These types never launch Codex or implement real authentication.
struct IsolationLayout: Sendable {
    let owner: URL
    let profile: UUID
    var directory: URL { owner.appendingPathComponent("Profiles/\(profile.uuidString)", isDirectory: true) }
    var codexHome: URL { directory.appendingPathComponent("codex-home", isDirectory: true) }
    var electronData: URL { directory.appendingPathComponent("electron-user-data", isDirectory: true) }

    func create() throws {
        try validateOwner()
        for url in [directory, codexHome, electronData] {
            guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
                throw CheckFailure(description: "Aliased fixture path")
            }
        }
        for url in [directory, codexHome, electronData] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try verify()
    }

    func validateOwner() throws {
        guard owner.path.hasPrefix("/private/tmp/codexswoop-checks-"),
              FileManager.default.fileExists(atPath: owner.appendingPathComponent("fixture-owner").path),
              owner.resolvingSymlinksInPath().path == owner.standardizedFileURL.path else {
            throw CheckFailure(description: "Unowned fixture root")
        }
    }

    func verify() throws {
        try validateOwner()
        for url in [directory, codexHome, electronData] {
            guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CheckFailure(description: "Missing or aliased fixture environment")
            }
        }
    }

    // Explicit allowlist; no inherited host environment, credentials, HOME override or default fallback.
    func launchEnvironment() throws -> [String: String] {
        try verify()
        return ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                "CODEX_HOME": codexHome.path, "CODEX_ELECTRON_USER_DATA_PATH": electronData.path]
    }
}

struct MockAuthenticationState: Sendable {
    // Synthetic account labels only, never tokens. This models a required contract, not macOS Keychain.
    private var accounts: [UUID: String] = [:]
    mutating func login(_ label: String, in profile: UUID) { accounts[profile] = label }
    mutating func logout(_ profile: UUID) { accounts[profile] = nil }
    func identity(in profile: UUID) -> String? { accounts[profile] }
}

struct MockLoginCallback: Sendable {
    let loginID: UUID
    let profile: UUID
    func accepts(loginID: UUID, profile: UUID) -> Bool { self.loginID == loginID && self.profile == profile }
}

struct MockProcessManager: Sendable {
    var runningProfile: UUID?
    var owned = true
    var exitTimesOut = false
    mutating func quit() throws {
        guard owned else { throw CheckFailure(description: "Unmanaged fixture process") }
        // A request is not an exit. The wait step decides whether launch may proceed.
    }
    mutating func wait(timeout: Duration) throws {
        guard timeout == .seconds(10) else { throw CheckFailure(description: "Missing finite deadline") }
        if exitTimesOut { throw SwitchingError.exitTimedOut }
        runningProfile = nil
    }
}

struct MockApplicationLauncher: Sendable {
    var fails = false
    var launches = 0
    mutating func launch(_ layout: IsolationLayout) throws {
        _ = try layout.launchEnvironment()
        if fails { throw CheckFailure(description: "Injected mock launch failure") }
        launches += 1
    }
}

actor IsolationFixtureDriver: AccountSwitchingDriver {
    let previous: UUID
    let target: IsolationLayout
    var authentication: MockAuthenticationState
    var process: MockProcessManager
    var launcher = MockApplicationLauncher()
    var selected: UUID
    var events: [String] = []
    var applicationAvailable = true
    var versionVerified = true
    var rollbackFails = false

    init(previous: UUID, target: IsolationLayout, authentication: MockAuthenticationState) {
        self.previous = previous; self.target = target; self.authentication = authentication
        self.selected = previous; self.process = MockProcessManager(runningProfile: previous)
    }
    func configure(appAvailable: Bool = true, verifiedVersion: Bool = true, owned: Bool = true,
                   launchFails: Bool = false, rollbackFails: Bool = false, timeout: Bool = false) {
        applicationAvailable = appAvailable; versionVerified = verifiedVersion
        process.owned = owned; process.exitTimesOut = timeout
        launcher.fails = launchFails; self.rollbackFails = rollbackFails
    }
    func validate(profile: AccountProfile) throws {
        events.append("validate")
        guard applicationAvailable, versionVerified, profile.id == target.profile else {
            throw CheckFailure(description: "Unverified fixture capability")
        }
        try target.verify()
    }
    func processIsRunning() throws -> Bool {
        events.append("inspect")
        guard process.owned else { throw CheckFailure(description: "Unmanaged fixture process") }
        return process.runningProfile != nil
    }
    func prepare(profile: AccountProfile) throws { events.append("prepare"); try target.verify() }
    func requestGracefulQuit() throws { events.append("quit"); try process.quit() }
    func waitForExit(timeout: Duration) throws { events.append("wait"); try process.wait(timeout: timeout) }
    func launch(profile: AccountProfile) throws {
        events.append("launch"); try launcher.launch(target); process.runningProfile = target.profile
    }
    func authenticatedProfileID() -> UUID? {
        events.append("verify")
        // This fixture deliberately knows its synthetic identity; production needs independent evidence.
        guard authentication.identity(in: target.profile) == "fixture-B" else { return nil }
        selected = target.profile
        return target.profile
    }
    func rollback() throws {
        events.append("rollback")
        if rollbackFails { throw CheckFailure(description: "Injected fixture recovery failure") }
        guard authentication.identity(in: previous) == "fixture-A" else {
            throw CheckFailure(description: "Previous fixture authentication unavailable")
        }
        process.runningProfile = previous; selected = previous
    }
    func snapshot() -> (selected: UUID, running: UUID?, launches: Int, events: [String]) {
        (selected, process.runningProfile, launcher.launches, events)
    }
}

extension CoreChecks {
    /// Child mode writes only benign fixture state under a parent-owned temporary root. No sockets or login.
    static func isolationWorker() throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 4, args[1] == "--isolation-worker", let id = UUID(uuidString: args[3]) else {
            throw CheckFailure(description: "Invalid fixture worker arguments")
        }
        let layout = IsolationLayout(owner: URL(fileURLWithPath: args[2], isDirectory: true), profile: id)
        let expected = try layout.launchEnvironment()
        let actual = ProcessInfo.processInfo.environment
        guard actual["CODEX_HOME"] == expected["CODEX_HOME"],
              actual["CODEX_ELECTRON_USER_DATA_PATH"] == expected["CODEX_ELECTRON_USER_DATA_PATH"] else {
            throw CheckFailure(description: "Fixture environment mismatch")
        }
        let history = layout.codexHome.appendingPathComponent("fixture-history.txt")
        let old = (try? String(contentsOf: history, encoding: .utf8)) ?? ""
        try (old + id.uuidString + "\n").write(to: history, atomically: true, encoding: .utf8)
        try id.uuidString.write(to: layout.electronData.appendingPathComponent("fixture-settings.txt"),
                               atomically: true, encoding: .utf8)
    }

    static func runIsolationWorker(_ layout: IsolationLayout, environment: [String: String]? = nil) throws -> Int32 {
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        worker.arguments = ["--isolation-worker", layout.owner.path, layout.profile.uuidString]
        worker.environment = try environment ?? layout.launchEnvironment()
        worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        // Bounded wait, only for our own child. Never escalate to SIGKILL.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while worker.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
        if worker.isRunning {
            worker.terminate()
            throw CheckFailure(description: "Own fixture child timed out; SIGTERM requested")
        }
        worker.waitUntilExit()
        return worker.terminationStatus
    }
}
