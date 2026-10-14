import Foundation
import CodexSwoopCore

extension CoreChecks {
    @MainActor
    static func isolationChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        let owner = base.appendingPathComponent("isolation-research", isDirectory: true)
        let a = IsolationLayout(owner: owner, profile: UUID())
        let b = IsolationLayout(owner: owner, profile: UUID())
        do {
            try fm.createDirectory(at: owner, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("synthetic-fixtures-only".utf8).write(to: owner.appendingPathComponent("fixture-owner"))
            try a.create(); try b.create()
        } catch {
            await run("Isolation fixture setup") { throw CheckFailure(description: "Cannot initialize owned fixture root") }
            return
        }
        var auth = MockAuthenticationState()
        auth.login("fixture-A", in: a.profile); auth.login("fixture-B", in: b.profile)
        func driver() -> IsolationFixtureDriver {
            IsolationFixtureDriver(previous: a.profile, target: b, authentication: auth)
        }
        func target() throws -> AccountProfile { try AccountProfile(id: b.profile, name: "Fixture B") }
        let untouched = owner.appendingPathComponent("unmanaged-fixture-sentinel.txt")
        let sentinel = Data("own unrelated fixture, never a real Codex directory".utf8)
        var savedProfileState: [URL: Data] = [:]
        do { try sentinel.write(to: untouched) }
        catch {
            await run("Isolation sentinel setup") { throw CheckFailure(description: "Cannot create fixture sentinel") }
            return
        }
        await run("Isolation: UUID environments are disjoint and owner-only") {
            try expect(a.codexHome != b.codexHome && a.electronData != b.electronData, "Separate roots")
            for layout in [a, b] {
                try layout.verify()
                for url in [layout.directory, layout.codexHome, layout.electronData] {
                    let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                    try expect(permissions?.intValue == 0o700, "Owner-only fixture environment")
                }
            }
        }
        await run("Isolation: launch environment is explicit, minimal and has both overrides") {
            let env = try a.launchEnvironment()
            try expect(Set(env.keys) == Set(["PATH", "LANG", "CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]), "No inherited host settings")
            try expect(env["CODEX_HOME"] == a.codexHome.path && env["CODEX_ELECTRON_USER_DATA_PATH"] == a.electronData.path, "Paired overrides")
            try expect(env["HOME"] == nil && env["OPENAI_API_KEY"] == nil, "No HOME redirection or host authentication")
        }
        await run("Isolation: own child persists separate history and GUI settings across restarts") {
            for layout in [a, b, a] { try expect(try runIsolationWorker(layout) == 0, "Own child succeeded") }
            for (layout, lines) in [(a, 2), (b, 1)] {
                let history = try String(contentsOf: layout.codexHome.appendingPathComponent("fixture-history.txt"), encoding: .utf8)
                try expect(history.split(separator: "\n").map(String.init) == Array(repeating: layout.profile.uuidString, count: lines), "No mixed fixture history")
                let settings = try String(contentsOf: layout.electronData.appendingPathComponent("fixture-settings.txt"), encoding: .utf8)
                try expect(settings == layout.profile.uuidString, "Separate GUI fixture state")
                for file in [layout.codexHome.appendingPathComponent("fixture-history.txt"),
                             layout.electronData.appendingPathComponent("fixture-settings.txt")] {
                    savedProfileState[file] = try Data(contentsOf: file)
                }
            }
        }
        await run("Isolation: child rejects missing overrides without default fallback or writes") {
            let before = try Data(contentsOf: a.codexHome.appendingPathComponent("fixture-history.txt"))
            try expect(try runIsolationWorker(a, environment: ["PATH": "/usr/bin:/bin"]) != 0, "Missing environment rejected")
            try expect(try Data(contentsOf: a.codexHome.appendingPathComponent("fixture-history.txt")) == before, "Fail before writes")
        }
        await run("Isolation: alias and missing owner fail before directory creation") {
            let escaped = owner.appendingPathComponent("own-alias-target", isDirectory: true)
            try fm.createDirectory(at: escaped, withIntermediateDirectories: false)
            let linked = IsolationLayout(owner: owner, profile: UUID())
            try fm.createSymbolicLink(at: linked.directory, withDestinationURL: escaped)
            do { try linked.create(); throw CheckFailure(description: "Symlink accepted") }
            catch let error as CheckFailure { try expect(error.description == "Aliased fixture path", "Alias rejected") }
            try expect(try fm.contentsOfDirectory(atPath: escaped.path).isEmpty, "No writes through alias")
            let unowned = IsolationLayout(owner: owner.appendingPathComponent("not-owned"), profile: UUID())
            do { try unowned.create(); throw CheckFailure(description: "Unowned root accepted") }
            catch let error as CheckFailure { try expect(error.description == "Unowned fixture root", "Ownership required") }
        }
        await run("Isolation: mock authentication logout and expiration affect only selected namespace") {
            var state = auth
            state.logout(b.profile)
            try expect(state.identity(in: b.profile) == nil && state.identity(in: a.profile) == "fixture-A", "Mock namespace preservation")
            state.login("fixture-B-reauthenticated", in: b.profile)
            try expect(state.identity(in: a.profile) == "fixture-A", "Reauth is scoped in model")
        }
        await run("Isolation: mock callback requires both login correlation and profile ownership") {
            let login = MockLoginCallback(loginID: UUID(), profile: b.profile)
            try expect(login.accepts(loginID: login.loginID, profile: b.profile), "Matching callback")
            try expect(!login.accepts(loginID: UUID(), profile: b.profile), "Wrong login ID")
            try expect(!login.accepts(loginID: login.loginID, profile: a.profile), "Wrong profile")
        }
        await run("Isolation: Busy and Unknown cancellation retain previous fixture account") {
            let busy = CodexActivityStatus.assess(operations: [.init(location: .local, kind: .waitingForApproval)], coverageComplete: true, fresh: true)
            for status in [busy, .unknown(.desktopConnectionUnverified)] {
                let d = driver(), confirmation = TestActivityConfirmation([false])
                let coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([status]))
                do {
                    try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                    throw CheckFailure(description: "Cancellation ignored")
                } catch SwitchingError.cancelled {}
                let state = await d.snapshot()
                try expect(state.selected == a.profile && state.running == a.profile && state.launches == 0, "Previous fixture untouched")
            }
        }
        await run("Isolation: absent app, unverified update and unmanaged process fail before interruption") {
            for scenario in 0..<3 {
                let d = driver()
                await d.configure(appAvailable: scenario != 0, verifiedVersion: scenario != 1, owned: scenario != 2)
                let coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.idle]))
                do {
                    try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
                    throw CheckFailure(description: "Unsafe fixture accepted")
                } catch let error as SwitchingError {
                    try expect(error == (scenario == 2 ? .processInspectionFailed : .validationFailed), "Controlled early failure")
                }
                let state = await d.snapshot()
                try expect(state.selected == a.profile && !state.events.contains("quit") && state.launches == 0, "No interruption")
            }
        }
        await run("Isolation: missing target directory blocks preparation without default account fallback") {
            try fm.moveItem(at: b.electronData, to: b.directory.appendingPathComponent("held-gui-fixture"))
            defer { try? fm.moveItem(at: b.directory.appendingPathComponent("held-gui-fixture"), to: b.electronData) }
            let d = driver(), coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.idle]))
            do {
                try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
                throw CheckFailure(description: "Missing environment accepted")
            } catch SwitchingError.validationFailed {}
            try expect(await d.snapshot().events == ["validate"], "No mutation")
        }
        await run("Isolation: confirmation cannot bypass missing authenticated identity") {
            var expired = auth; expired.logout(b.profile)
            let d = IsolationFixtureDriver(previous: a.profile, target: b, authentication: expired)
            let coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.unknown(.desktopConnectionUnverified)]))
            do {
                try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true, confirmActivity: { _ in true })
                throw CheckFailure(description: "Unknown identity accepted")
            } catch SwitchingError.identityUnconfirmed {}
            try expect(await coordinator.state == .failed, "No success")
            let state = await d.snapshot()
            try expect(state.selected == a.profile && state.running == a.profile, "Previous fixture restored")
        }
        await run("Isolation: launch failure restores previous fixture; retry can succeed") {
            let d = driver(), coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.idle]))
            await d.configure(launchFails: true)
            do {
                try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
                throw CheckFailure(description: "Failed launch accepted")
            } catch SwitchingError.launchFailed {}
            try expect(await d.snapshot().running == a.profile, "Previous fixture restored")
            try expect(await d.snapshot().selected == a.profile, "No premature commit")
            await d.configure()
            try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
            try expect(await coordinator.state == .active(b.profile), "Explicit retry completes model")
        }
        await run("Isolation: exit timeout prevents launch and preserves both fixture environments") {
            let d = driver(); await d.configure(timeout: true)
            let coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.idle]))
            do {
                try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
                throw CheckFailure(description: "Timeout accepted")
            } catch SwitchingError.exitTimedOut {}
            try expect(await d.snapshot().launches == 0, "No overlapping launch")
            try a.verify(); try b.verify()
        }
        await run("Isolation: failed rollback retains profiles and reports manual recovery") {
            let d = driver(); await d.configure(launchFails: true, rollbackFails: true)
            let coordinator = AccountSwitchingCoordinator(driver: d, activityChecker: ScenarioActivityChecker([.idle]))
            do {
                try await coordinator.switchAccount(to: target(), workInterruptionConfirmed: true)
                throw CheckFailure(description: "Failed launch accepted")
            } catch SwitchingError.launchFailed {}
            try expect(await coordinator.state == .recoveryRequired, "Recovery is explicit")
            try a.verify(); try b.verify()
            try expect(await d.snapshot().selected == a.profile, "Metadata not committed to failed target")
        }
        await run("Isolation: profile data and unrelated sentinel remain byte-identical after all fault scenarios") {
            try expect(try Data(contentsOf: untouched) == sentinel, "Unmanaged fixture unchanged")
            try expect(savedProfileState.count == 4, "Both profile snapshots captured")
            for (file, bytes) in savedProfileState {
                try expect(try Data(contentsOf: file) == bytes, "Fixture history/settings preserved across faults and rollback")
            }
            // This is no claim about real Codex files: they are intentionally never opened by this harness.
        }
    }
}
