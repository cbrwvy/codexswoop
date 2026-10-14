import Foundation
import Darwin
import CodexSwoopCore

extension CoreChecks {
    static func storageWorker() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 5, args[2].hasPrefix("/private/tmp/codexswoop-checks-"),
              !args[2].split(separator: "/").contains("..") else { exit(2) }
        let root = URL(fileURLWithPath: args[2])
        let interrupt = args[3] == "interrupt"
        let writer = AtomicMetadataWriter { destination in
            if interrupt && destination.lastPathComponent == "profiles.json" {
                try Data().write(to: root.appendingPathComponent("ready"))
                raise(SIGSTOP) // Only this disposable test worker pauses, never an application.
            }
        }
        let store = ProfileStore(root: root, writer: writer)
        do {
            for index in 0..<(interrupt ? 1 : 10) {
                var attempts = 0
                while true {
                    do { _ = try await store.create(name: "Worker \(args[4]) / \(index)"); break }
                    catch ProfileError.storeBusy {
                        attempts += 1
                        guard attempts < 500 else { throw ProfileError.storeBusy }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        } catch { exit(3) }
    }

    @MainActor
    static func worker(root: URL, mode: String, label: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["--storage-worker", root.path, mode, label]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure(description: "Test worker deadline expired") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func additionalChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        func root(_ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true) }
        await run("Empty JSON cannot reset existing metadata") {
            let r = root("empty-json")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "Existing")
            try Data().write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.create(name: "Blocked") }
            try expect(try Data(contentsOf: r.appendingPathComponent("profiles.json")).isEmpty, "Empty original preserved")
        }
        await run("Invalid UUID and duplicate profile IDs block all writes") {
            for invalid in [true, false] {
                let r = root("bad-id-\(invalid)")
                let store = ProfileStore(root: r)
                _ = try await store.create(name: "Existing")
                let url = r.appendingPathComponent("profiles.json")
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
                var profiles = object["profiles"] as? [[String: Any]] ?? []
                try expect(profiles.count == 1, "Fixture profile")
                if invalid { profiles[0]["id"] = "not-a-uuid" }
                else { var second = profiles[0]; second["name"] = "Duplicate ID"; profiles.append(second) }
                object["profiles"] = profiles
                let bytes = try JSONSerialization.data(withJSONObject: object)
                try bytes.write(to: url)
                try await expectError(.corruptedStore) { _ = try await store.removeRecord(id: UUID()) }
                try expect(try Data(contentsOf: url) == bytes, "Invalid data preserved byte-for-byte")
            }
        }
        await run("Corrupt backup cannot overwrite corrupt primary") {
            let r = root("bad-backup")
            let store = ProfileStore(root: r)
            _ = try await store.create(name: "One")
            _ = try await store.create(name: "Two")
            for file in ["profiles.json", "profiles.backup.json"] { try Data("bad".utf8).write(to: r.appendingPathComponent(file)) }
            try await expectError(.corruptedStore) { _ = try await store.recoverBackup() }
            try expect(try Data(contentsOf: r.appendingPathComponent("profiles.json")) == Data("bad".utf8), "No unsafe restore")
        }
        await run("No write permission returns controlled error without creating profiles") {
            let parent = root("read-only-parent")
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
            let child = parent.appendingPathComponent("store")
            try await expectError(.storageUnavailable) { _ = try await ProfileStore(root: child).create(name: "Blocked") }
            try expect(!fm.fileExists(atPath: child.path), "No partial catalog")
        }
        await run("Injected failure before atomic commit preserves primary and cleans temp file") {
            let r = root("failed-write")
            let store = ProfileStore(root: r)
            let original = try await store.create(name: "Existing")
            let bytes = try Data(contentsOf: r.appendingPathComponent("profiles.json"))
            let faulty = ProfileStore(root: r, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "profiles.json" { throw ProfileError.storageUnavailable }
            })
            try await expectError(.storageUnavailable) { _ = try await faulty.create(name: "Uncommitted") }
            try expect(try Data(contentsOf: r.appendingPathComponent("profiles.json")) == bytes, "Primary unchanged")
            try expect(try await store.load() == original, "Same catalog/revision")
            try expect(try fm.contentsOfDirectory(atPath: r.path).allSatisfy { !$0.hasPrefix(".profiles-write-") }, "Temporary file cleaned")
        }
        if !ProcessInfo.processInfo.arguments.contains("--safe-process-checks") {
            await run("Terminated writer retains complete old JSON and releases process lock") {
                let r = root("interrupted")
                let store = ProfileStore(root: r)
                let original = try await store.create(name: "Existing")
                let child = try worker(root: r, mode: "interrupt", label: "isolated")
                defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
                try await waitUntil { fm.fileExists(atPath: r.appendingPathComponent("ready").path) }
                try await expectError(.storeBusy) { _ = try await store.load() }
                // Kill only the exact Process object created above, paused at the test commit barrier.
                try expect(kill(child.processIdentifier, SIGKILL) == 0, "Stop disposable writer")
                child.waitUntilExit()
                try expect(try await store.load() == original, "Uncommitted profile never becomes visible")
                let leftovers = try fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".profiles-write-") }
                try expect(leftovers.count == 1, "Interrupted temp is ignored, never promoted")
                let permissions = try fm.attributesOfItem(atPath: leftovers[0].path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o600, "Even interrupted temp remains private")
                _ = try await store.create(name: "After restart")
                try expect(try await store.load().profiles.count == 2, "OS released dead writer lock")
            }
            await run("Four real writer processes preserve all 40 updates") {
                let r = root("parallel-processes")
                _ = try await ProfileStore(root: r).load()
                var children: [Process] = []
                defer { for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
                for i in 0..<4 { children.append(try worker(root: r, mode: "write", label: "\(i)")) }
                for child in children {
                    try await waitUntil { !child.isRunning }
                    child.waitUntilExit()
                    try expect(child.terminationStatus == 0, "Writer finished")
                }
                let catalog = try await ProfileStore(root: r).load()
                try expect(catalog.profiles.count == 40 && catalog.revision == 40, "No lost updates or duplicate revisions")
            }
        } else {
            print("SKIP two legacy worker-crash checks: safe process mode sends no force-termination signals")
        }
        await run("Diagnostics are read-only and report metadata errors") {
            let r = root("diagnostics")
            let store = ProfileStore(root: r)
            try expect(try await store.inspect().profiles.isEmpty, "Absent store count")
            try expect(!fm.fileExists(atPath: r.path), "Inspect does not initialize storage")
            _ = try await store.create(name: "Private name not logged")
            let bytes = try Data(contentsOf: r.appendingPathComponent("profiles.json"))
            try expect(try await store.inspect().profiles.count == 1, "Count available")
            try expect(try Data(contentsOf: r.appendingPathComponent("profiles.json")) == bytes, "Inspect does not rewrite")
            try Data("bad".utf8).write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.inspect() }
        }
        await run("Oversized files and exhausted revisions are rejected") {
            let r = root("limits")
            let store = ProfileStore(root: r)
            _ = try await store.load()
            try Data(repeating: 65, count: 1_048_577).write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.load() }
            var catalog = ProfileCatalog(); catalog.revision = UInt64.max
            try JSONEncoder().encode(catalog).write(to: r.appendingPathComponent("profiles.json"))
            try await expectError(.corruptedStore) { _ = try await store.create(name: "No overflow") }
        }
        await run("Emoji byte limit and special characters remain display-only") {
            _ = try AccountProfile(name: "../~/$HOME; `command` \\ : 👩🏽‍💻")
            do { _ = try AccountProfile(name: String(repeating: "👩🏽‍💻", count: 80)); throw CheckFailure(description: "UTF-8 limit not enforced") }
            catch ProfileError.invalidName {}
        }
        await run("Repeated loads release descriptors and locks") {
            let store = ProfileStore(root: root("descriptors"))
            _ = try await store.load()
            let before = try fm.contentsOfDirectory(atPath: "/dev/fd").count
            for _ in 0..<200 { _ = try await store.load() }
            let after = try fm.contentsOfDirectory(atPath: "/dev/fd").count
            try expect(after <= before + 2, "No accumulating open descriptors")
        }
        await run("Every switching operation has a controlled failure and rollback boundary") {
            let errors: [(String, SwitchingError)] = [("validate", .validationFailed), ("inspect", .processInspectionFailed), ("prepare", .preparationFailed), ("quit", .quitFailed), ("wait", .exitTimedOut), ("launch", .launchFailed), ("verify", .verificationFailed)]
            for (stage, expected) in errors {
                let p = try AccountProfile(name: "Mock")
                let driver = TestDriver(identity: p.id, failAt: stage)
                let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
                do {
                    try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true)
                    throw CheckFailure(description: "Failure not propagated")
                } catch let error as SwitchingError { try expect(error == expected, "Operation-specific error") }
                let lastError = await coordinator.lastError
                let state = await coordinator.state
                try expect(lastError == expected && state == .failed, "Controlled failure state")
                let events = await driver.events
                try expect(events.contains("rollback") == !["validate", "inspect"].contains(stage), "Rollback only after potential mutation")
            }
        }
        await run("Cancellation before execution prevents all driver operations") {
            let driver = TestDriver(identity: nil)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await coordinator.switchAccount(to: AccountProfile(name: "Mock"), workInterruptionConfirmed: true)
            }
            do { try await task.value; throw CheckFailure(description: "Cancellation ignored") }
            catch SwitchingError.cancelled {}
            try expect(await driver.events.isEmpty, "No effects after cancellation")
            try expect(await coordinator.state == .cancelled, "Cancelled status")
        }
        await run("Cancellation during preparation rolls back with an uncancelled cleanup task") {
            let p = try AccountProfile(name: "Mock")
            let driver = TestDriver(identity: p.id, pauseAt: "prepare")
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            let task = Task { try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await driver.events.contains("prepare")) {
                guard ContinuousClock.now < deadline else { task.cancel(); throw CheckFailure(description: "Preparation entry timeout") }
                await Task.yield()
            }
            task.cancel()
            do { try await task.value; throw CheckFailure(description: "Cancellation ignored") }
            catch SwitchingError.cancelled {}
            try expect(await driver.events == ["validate", "inspect", "prepare", "rollback"], "No quit/launch, cleanup completed")
            try expect(await coordinator.state == .cancelled, "No false active status")
        }
        await run("Stopped mock process needs no quit or exit wait") {
            let p = try AccountProfile(name: "Mock")
            let driver = TestDriver(identity: p.id, running: false)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true)
            try expect(await driver.events == ["validate", "inspect", "prepare", "launch", "verify"], "Process state respected")
        }
        await run("Rollback failure preserves original cause and permits a later attempt") {
            let driver = TestDriver(identity: nil, launchFails: true, rollbackFails: true)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            for _ in 0..<2 {
                do { try await coordinator.switchAccount(to: AccountProfile(name: "Mock"), workInterruptionConfirmed: true) }
                catch SwitchingError.launchFailed {}
                let lastError = await coordinator.lastError
                let rollbackFailed = await coordinator.rollbackFailed
                try expect(lastError == .launchFailed && rollbackFailed, "Primary and recovery failures retained")
                try expect(await coordinator.state == .recoveryRequired, "Recovery required, busy gate released")
            }
        }
        await run("Bundle detection supports arbitrary app names and fresh plist reads") {
            let app = root("custom/Anything.app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Contents/MacOS/TestExecutable")
            try Data().write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            func metadata(id: String, version: String, executableName: String = "TestExecutable") throws {
                let info = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": executableName]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            try metadata(id: CodexBundleInspector.bundleIdentifier, version: "1.2.3")
            try expect(CodexBundleInspector.inspect(app)?.version == "1.2.3", "Identity rather than app filename")
            try metadata(id: CodexBundleInspector.bundleIdentifier, version: "2.0")
            try expect(CodexBundleInspector.inspect(app)?.version == "2.0", "No stale Bundle cache")
            try metadata(id: "example.other", version: "2.0")
            try expect(CodexBundleInspector.inspect(app) == nil, "Other app rejected")
            try metadata(id: CodexBundleInspector.bundleIdentifier, version: "2.0", executableName: "../TestExecutable")
            try expect(CodexBundleInspector.inspect(app) == nil, "Executable traversal rejected")
            try metadata(id: CodexBundleInspector.bundleIdentifier, version: "2.0")
            try expect(CodexBundleInspector.detect(candidates: [root("gone.app"), app])?.url == app, "Stale preferred path falls through")
            try fm.removeItem(at: executable)
            try expect(CodexBundleInspector.inspect(app) == nil, "Missing executable rejected")
            try fm.createDirectory(at: executable, withIntermediateDirectories: false)
            try expect(CodexBundleInspector.inspect(app) == nil, "Executable directory rejected")
            try Data(repeating: 65, count: 1_048_577).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try expect(CodexBundleInspector.inspect(app) == nil, "Oversized metadata rejected")
            try expect(CodexBundleInspector.detect(candidates: [root("gone.app")]) == nil, "Not installed")
            let home = root("home")
            let paths = CodexBundleInspector.standardLocations(home: home).map(\.path)
            try expect(paths.contains("/Applications/Codex.app") && paths.contains(home.appendingPathComponent("Applications/Codex.app").path), "Both installation roots searched")
        }
    }
}
