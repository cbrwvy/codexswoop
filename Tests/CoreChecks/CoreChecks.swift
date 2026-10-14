import Foundation
import Darwin
import CodexSwoopCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw CheckFailure(description: message) }
}

@MainActor
func expectError(_ expected: ProfileError, _ operation: () async throws -> Void) async throws {
    do { try await operation(); throw CheckFailure(description: "Expected \(expected)") }
    catch let error as ProfileError { try expect(error == expected, "Unexpected error: \(error)") }
}

@MainActor
private final class CoreCheckReporter {
    private(set) var passed = 0
    private(set) var failures = 0

    func run(_ name: String, _ body: @MainActor () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
    }
}

actor TestDriver: AccountSwitchingDriver {
    var events: [String] = []
    let identity: UUID?
    let launchFails: Bool
    let rollbackFails: Bool
    let delay: Bool
    let failAt: String?
    let pauseAt: String?
    let running: Bool
    init(identity: UUID?, launchFails: Bool = false, rollbackFails: Bool = false, delay: Bool = false, failAt: String? = nil, pauseAt: String? = nil, running: Bool = true) {
        self.identity = identity; self.launchFails = launchFails; self.rollbackFails = rollbackFails; self.delay = delay
        self.failAt = failAt; self.pauseAt = pauseAt; self.running = running
    }
    func validate(profile: AccountProfile) async throws {
        try await record("validate")
        if delay { try await Task.sleep(for: .milliseconds(150)) }
    }
    func record(_ event: String) async throws {
        events.append(event)
        if pauseAt == event { try await Task.sleep(for: .seconds(30)) }
        if failAt == event {
            if event == "wait" { throw SwitchingError.exitTimedOut }
            throw CheckFailure(description: "Injected \(event) failure")
        }
    }
    func requestGracefulQuit() async throws { try await record("quit") }
    func processIsRunning() async throws -> Bool { try await record("inspect"); return running }
    func waitForExit(timeout: Duration) async throws {
        try expect(timeout == .seconds(10), "Finite exit deadline")
        try await record("wait")
    }
    func prepare(profile: AccountProfile) async throws { try await record("prepare") }
    func launch(profile: AccountProfile) async throws {
        try await record("launch")
        if launchFails { throw CheckFailure(description: "Test launch failure") }
    }
    func authenticatedProfileID() async throws -> UUID? { try await record("verify"); return identity }
    func rollback() async throws {
        try Task.checkCancellation()
        try await record("rollback")
        if rollbackFails { throw CheckFailure(description: "Test rollback failure") }
    }
}

@main
struct CoreChecks {
    @MainActor static func main() async {
        L10n.setSessionLanguage(.english)
        if ProcessInfo.processInfo.arguments.contains("--opening-journal-worker") {
            do { try await openingJournalWorker() } catch { exit(3) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--isolation-worker") {
            do { try isolationWorker() }
            catch { exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--storage-worker") {
            await storageWorker()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--prepare-managed-fixture") {
            do { try await preparePersistentFixture() } catch { print("FAIL managed fixture preparation"); exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-environment-replacement") {
            do { try await previewRealReplacement() } catch { print("NO-GO: \(error)"); exit(1) }
            return
        }
        let reporter = CoreCheckReporter()
        let run = reporter.run
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/codexswoop-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        func root(_ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true) }

        if ProcessInfo.processInfo.arguments.contains("--opening-journal-checks") {
            await openingJournalChecks(base: base, run: run)
            print("\(reporter.passed) durable opening checks passed; \(reporter.failures) failed.")
            if reporter.failures != 0 { exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--pid-opening-checks") {
            await pidOpeningChecks(base: base, run: run)
            print("\(reporter.passed) PID mock checks passed; \(reporter.failures) failed.")
            if reporter.failures != 0 { exit(1) }
            return
        }

        await run("Names: whitespace, Unicode, empty, controls and length") {
            try expect(try AccountProfile(name: "  Рабочий 🚀  ").name == "Рабочий 🚀", "Unicode trimming")
            for name in ["", " \n ", "a\nb", "a\u{0}b", "\u{200D}", "text\u{202E}", String(repeating: "a", count: 81)] {
                do { _ = try AccountProfile(name: name); throw CheckFailure(description: "Invalid name accepted") }
                catch ProfileError.invalidName {}
            }
            _ = try AccountProfile(name: String(repeating: "a", count: 80))
        }
        await run("Create, rename, restart persistence and metadata-only delete") {
            let store = ProfileStore(root: root("crud"))
            try expect(try await store.load().profiles.isEmpty, "New store")
            let created = try await store.create(name: "Personal")
            let p = created.profiles[0]
            let renamed = try await store.rename(id: p.id, name: "Work")
            try expect(renamed.profiles[0].id == p.id, "Stable ID")
            try expect(renamed.profiles[0].directoryIdentifier == p.directoryIdentifier, "Stable directory")
            let restarted = ProfileStore(root: root("crud"))
            try expect(try await restarted.load().profiles[0].name == "Work", "Relaunch persistence")
            _ = try await restarted.removeRecord(id: p.id)
            try expect(try await store.load().profiles.isEmpty, "Deleted record")
            try expect(fm.fileExists(atPath: root("crud").appendingPathComponent("Profiles/\(p.directoryIdentifier)").path), "Profile directory retained")
        }
        await run("Duplicate names: case and canonical Unicode") {
            let store = ProfileStore(root: root("duplicates"))
            _ = try await store.create(name: "Café")
            try await expectError(.duplicateName) { _ = try await store.create(name: " CAFE\u{301} ") }
            let created = try await store.create(name: "Other")
            try await expectError(.duplicateName) { _ = try await store.rename(id: created.profiles[1].id, name: "CAFÉ") }
        }
        await run("User names never become filesystem paths; 15 profiles") {
            let store = ProfileStore(root: root("many"))
            for i in 0..<15 { _ = try await store.create(name: "../../Account \(i) 🐱") }
            let catalog = try await store.load()
            try expect(catalog.profiles.count == 15, "No two-account limit")
            let dirs = try fm.contentsOfDirectory(atPath: root("many").appendingPathComponent("Profiles").path)
            try expect(dirs.count == 15 && dirs.allSatisfy { UUID(uuidString: $0) != nil }, "UUID directories")
        }
        await run("Corrupt metadata blocks mutations; explicit backup recovery preserves original") {
            let r = root("corrupt")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "First")
            _ = try await store.create(name: "Second")
            let damaged = Data("broken test metadata".utf8)
            try damaged.write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.load() }
            try await expectError(.corruptedStore) { _ = try await store.create(name: "Must not overwrite") }
            try expect(try Data(contentsOf: r.appendingPathComponent("profiles.json")) == damaged, "Damaged file preserved")
            let recovered = try await store.recoverBackup()
            try expect(recovered.profiles.map(\.name) == ["First"], "Previous valid snapshot recovered")
            let quarantine = try fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("profiles-damaged-") }
            try expect(quarantine != nil, "Original retained")
            if let quarantine { try expect(try Data(contentsOf: quarantine) == damaged, "Original bytes retained") }
        }
        await run("Missing primary with existing backup cannot silently reset") {
            let r = root("missing")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "First")
            _ = try await store.create(name: "Second")
            try fm.removeItem(at: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.create(name: "No reset") }
            try expect(try await store.recoverBackup().profiles.count == 1, "Backup recovery without primary")
        }
        await run("No backup: preserve damaged data") {
            let r = root("no-backup")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "First")
            try Data("broken".utf8).write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.missingBackup) { _ = try await store.recoverBackup() }
        }
        await run("Unknown schema version cannot be edited or recovered over") {
            let r = root("schema")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "First")
            let url = r.appendingPathComponent("profiles.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            object["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            try await expectError(.unsupportedVersion) { _ = try await store.load() }
            try await expectError(.unsupportedVersion) { _ = try await store.recoverBackup() }
        }
        await run("Metadata and directory permissions") {
            let r = root("permissions")
            let store = ProfileStore(root: r)
            let p = try await store.create(name: "Private").profiles[0]
            for (url, expected) in [(r, 0o700), (r.appendingPathComponent("Profiles/\(p.directoryIdentifier)"), 0o700), (r.appendingPathComponent("profiles.json"), 0o600)] {
                let actual = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                try expect(actual?.intValue == expected, "Owner-only permissions")
            }
        }
        await run("Symbolic links in metadata and root fail closed") {
            let r = root("symlinks")
            let store = ProfileStore(root: r)
            _ = try await store.load()
            let outside = root("outside.json")
            try Data("untouched".utf8).write(to: outside)
            try fm.createSymbolicLink(at: r.appendingPathComponent("profiles.json"), withDestinationURL: outside)
            try await expectError(.unsafePath) { _ = try await store.create(name: "Blocked") }
            try expect(try String(contentsOf: outside, encoding: .utf8) == "untouched", "Link destination unchanged")
            let linkedRoot = root("linked-root")
            try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: r)
            try await expectError(.unsafePath) { _ = try await ProfileStore(root: linkedRoot).load() }
        }
        await run("Interprocess lock refuses a conflicting writer") {
            let r = root("locked")
            let store = ProfileStore(root: r)
            _ = try await store.load()
            let fd = open(r.appendingPathComponent("metadata.lock").path, O_RDWR)
            guard fd >= 0 else { throw CheckFailure(description: "Open lock") }
            defer { _ = flock(fd, LOCK_UN); close(fd) }
            try expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "Acquire lock")
            try await expectError(.storeBusy) { _ = try await store.create(name: "Blocked") }
        }
        await run("Different store instances reload disk before writing") {
            let a = ProfileStore(root: root("writers")), b = ProfileStore(root: root("writers"))
            _ = try await a.load(); _ = try await b.load()
            _ = try await a.create(name: "One"); _ = try await b.create(name: "Two")
            try expect(try await a.load().profiles.count == 2, "No lost update")
            try await expectError(.missingProfile) { _ = try await b.rename(id: UUID(), name: "Missing") }
        }
        await run("Storage path occupied by a file returns a controlled error") {
            let r = root("not-directory")
            try Data("existing file".utf8).write(to: r)
            try await expectError(.storageUnavailable) { _ = try await ProfileStore(root: r).load() }
        }
        await run("Default switching cannot operate any process") {
            let coordinator = AccountSwitchingCoordinator()
            do {
                try await coordinator.switchAccount(to: AccountProfile(name: "Test"), workInterruptionConfirmed: true)
                throw CheckFailure(description: "Switching unexpectedly available")
            } catch SwitchingError.unavailable {}
            try expect(await coordinator.state == .unavailable, "Unavailable status")
        }
        await run("Switching requires interruption consent before quitting") {
            let driver = TestDriver(identity: nil)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            do { try await coordinator.switchAccount(to: AccountProfile(name: "Test"), workInterruptionConfirmed: false) }
            catch SwitchingError.confirmationRequired {}
            try expect(await driver.events == ["validate"], "No quit before consent")
        }
        await run("Confirmed test identity required for active state; ordered stages") {
            let p = try AccountProfile(name: "Test")
            let driver = TestDriver(identity: p.id)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true)
            try expect(await coordinator.state == .active(p.id), "Verified active")
            try expect(await driver.events == ["validate", "inspect", "prepare", "quit", "wait", "launch", "verify"], "Stage order")
        }
        await run("Wrong or expired identity rolls back without false active state") {
            for identity in [nil, UUID()] {
                let driver = TestDriver(identity: identity)
                let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
                do { try await coordinator.switchAccount(to: AccountProfile(name: "Test"), workInterruptionConfirmed: true) }
                catch SwitchingError.identityUnconfirmed {}
                try expect(await coordinator.state == .failed, "No false success")
                try expect(await driver.events.last == "rollback", "Rollback requested")
            }
        }
        await run("Launch failure and rollback failure retain recovery-required state") {
            let driver = TestDriver(identity: nil, launchFails: true, rollbackFails: true)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            do { try await coordinator.switchAccount(to: AccountProfile(name: "Test"), workInterruptionConfirmed: true) }
            catch SwitchingError.launchFailed {}
            try expect(await coordinator.state == .recoveryRequired, "Recovery needed")
        }
        await run("Concurrent switching is rejected") {
            let p = try AccountProfile(name: "Test")
            let driver = TestDriver(identity: p.id, delay: true)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            let first = Task { try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) }
            // Wait for actual entry rather than depending only on scheduling.
            while await driver.events.isEmpty { await Task.yield() }
            do {
                try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true)
                throw CheckFailure(description: "Concurrent switch accepted")
            } catch SwitchingError.busy {}
            try await first.value
        }
        await additionalChecks(base: base, run: run)
        await safetyChecks(run: run)
        await isolationChecks(base: base, run: run)
        await associationChecks(base: base, run: run)
        await readinessChecks(base: base, run: run)
        await replacementChecks(base: base, run: run)
        await openingChecks(base: base, run: run)
        await environmentOpeningChecks(base: base, run: run)
        await pidOpeningChecks(base: base, run: run)
        await installationValidationChecks(base: base, run: run)
        await scopedOpeningChecks(base: base, run: run)
        await openingJournalChecks(base: base, run: run)
        await launchReadinessChecks(base: base, run: run)
        await localizationChecks(run: run)
        await accountSetupChecks(base: base, run: run)
        await usageChecks(base: base, run: run)
        await transportChecks(base: base, run: run)
        print("\(reporter.passed) checks passed; \(reporter.failures) failed. Temporary test storage removed on exit.")
        if reporter.failures != 0 { exit(1) }
    }
}
