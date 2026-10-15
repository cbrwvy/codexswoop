import XCTest
import AppKit
import Darwin
@testable import CodexSwoopCore

private struct SyntheticIdentityReader: AccountIdentityReading {
    let key: AccountIdentityKey
    func read(_ request: AccountIdentityRequest) -> IdentityReadResult {
        .response(RoutedAccountIdentity(request: request, key: key, authenticated: true))
    }
}

private actor StartupOwnershipSamples {
    var samples: [Result<DesktopObservation, EnvironmentError>]
    var calls = 0
    init(_ samples: [Result<DesktopObservation, EnvironmentError>]) { self.samples = samples }
    func next(_ timeout: Duration) throws -> DesktopObservation {
        precondition(timeout > .zero && timeout <= .seconds(5))
        calls += 1
        return try (samples.count > 1 ? samples.removeFirst() : samples[0]).get()
    }
}

@MainActor final class P0LaunchTests: XCTestCase {
    private func fixture(running: Bool = false) async throws -> ReleaseFixture {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-p0-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await ReleaseFixture.make(root: root, running: running)
    }
    private func aliasRoot(_ fixture: ReleaseFixture) -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/csp0-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCloseOthersWithZeroOthersAllowsLaunchedReceiverTreeGrowth() async throws {
        let f = try await fixture()
        await f.system.removeSyntheticInstance(f.associations[0].environmentID)
        await f.system.configureLaunchedTreeGrowth()
        try await f.open(.closeOthersAndOpen)
        let effects = await f.system.effects, state = await f.coordinator.state
        XCTAssertEqual(effects, ["launch", "activate"])
        XCTAssertEqual(state, .environmentOpened(f.profiles[1].id))
        XCTAssertNil(try OpeningOperationJournal(root: f.validator.managedRoot).pending())
        let current = await f.system.instances[f.associations[1].environmentID]
        XCTAssertEqual(current?.main.startTimeMicroseconds, 100)
        XCTAssertEqual(current?.related.count, 2)
    }
    func testReceiverContinuityRejectsSamePIDWithDifferentGenerationDateOrSignature() throws {
        let generation = DesktopGeneration(pid: 190_010, uid: getuid(), started: "synthetic-launch", startTimeMicroseconds: 100)
        let signature = CodexSigningIdentity(identifier: "com.openai.codex", teamIdentifier: OfficialCodexPolicy.teamIdentifier,
            codeDirectoryHash: String(repeating: "b", count: 40))
        let receiver = DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date().addingTimeInterval(-1), signingIdentity: signature)
        let child = DesktopGeneration(pid: 190_050, uid: getuid(), started: "child", startTimeMicroseconds: 200)
        let grown = DesktopInstance(main: generation, related: [generation, child], nativeLaunchDate: receiver.nativeLaunchDate, signingIdentity: signature)
        XCTAssertNotEqual(receiver, grown, "Full snapshots remain distinct for quit/recovery evidence")
        XCTAssertTrue(DesktopOpeningTarget.matches(grown, expected: receiver, newlyLaunched: true))
        XCTAssertFalse(DesktopOpeningTarget.matches(grown, expected: receiver, newlyLaunched: false))
        XCTAssertTrue(DesktopOpeningTarget.matches(grown, expected: receiver, newlyLaunched: false, allowChildChanges: true))
        let changed = DesktopGeneration(pid: generation.pid, uid: generation.uid, started: generation.started, startTimeMicroseconds: 101)
        for bad in [DesktopInstance(main: changed, related: [changed], nativeLaunchDate: receiver.nativeLaunchDate, signingIdentity: signature),
                    DesktopInstance(main: generation, related: [generation], nativeLaunchDate: receiver.nativeLaunchDate.addingTimeInterval(1), signingIdentity: signature),
                    DesktopInstance(main: generation, related: [generation], nativeLaunchDate: receiver.nativeLaunchDate,
                        signingIdentity: CodexSigningIdentity(identifier: "com.openai.codex", teamIdentifier: OfficialCodexPolicy.teamIdentifier, codeDirectoryHash: String(repeating: "c", count: 40))),
                    DesktopInstance(main: generation, related: [generation], nativeLaunchDate: receiver.nativeLaunchDate)] {
            XCTAssertFalse(DesktopOpeningTarget.matches(bad, expected: receiver, newlyLaunched: true))
        }
        let incomplete = DesktopInstance(main: generation, related: [generation], nativeLaunchDate: receiver.nativeLaunchDate)
        XCTAssertFalse(DesktopOpeningTarget.matches(grown, expected: incomplete, newlyLaunched: true))
    }
    func testStageMarkerRoundTripsAndLegacyFailureStillDecodes() throws {
        let value = OpeningFailureRecord(.opening(.processChanged), stage: .activationScopeInventory)
        let restored = try JSONDecoder().decode(OpeningFailureRecord.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.stage, .activationScopeInventory)
        XCTAssertEqual(restored.error, .opening(.processChanged))
        let legacy = try JSONDecoder().decode(OpeningFailureRecord.self, from: Data(#"{"reason":"processChanged"}"#.utf8))
        XCTAssertNil(legacy.stage)
    }
    func testRealGenerationChangeAfterLaunchPreservesPendingAcrossRestart() async throws {
        let f = try await fixture()
        await f.system.removeSyntheticInstance(f.associations[0].environmentID)
        await f.system.configureLaunchedTreeGrowth(replaceGeneration: true)
        do { try await f.open(.closeOthersAndOpen); XCTFail("Same PID replacement accepted") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.processChanged)) }
        let journal = OpeningOperationJournal(root: f.validator.managedRoot), record = try XCTUnwrap(journal.pending())
        XCTAssertEqual(record.launchReceiver?.main.startTimeMicroseconds, 100)
        XCTAssertEqual(record.failure?.stage, .driverPostflightTarget)
        XCTAssertEqual(record.failure?.reason, .processChanged)
        let names = ["opening-journal.json", "opening-journal-watermark.json"]
        let before = try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }
        let restarted = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
            store: f.store, validator: f.validator, system: f.system))
        let review = try await restarted.refreshOpeningRecovery()
        XCTAssertTrue(review)
        XCTAssertEqual(try journal.pending(), record)
        XCTAssertEqual(try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }, before)
        let effects = await f.system.effects
        XCTAssertEqual(effects, ["launch", "activate"], "Startup neither retries nor reconciles")
    }
    func testNewTargetInventoryContinuityKeepsUnknownAndForeignOwnershipBlocked() async throws {
        let f = try await fixture()
        let main = DesktopGeneration(pid: 190_010, uid: getuid(), started: "synthetic-launch", startTimeMicroseconds: 100)
        let signature = CodexSigningIdentity(identifier: "com.openai.codex", teamIdentifier: OfficialCodexPolicy.teamIdentifier,
            codeDirectoryHash: String(repeating: "b", count: 40))
        let old = DesktopInstance(main: main, related: [main], nativeLaunchDate: Date().addingTimeInterval(-1), signingIdentity: signature)
        let child = DesktopGeneration(pid: 190_050, uid: getuid(), started: "child", startTimeMicroseconds: 200)
        let fresh = DesktopInstance(main: main, related: [main, child], nativeLaunchDate: old.nativeLaunchDate, signingIdentity: signature)
        let expected = DesktopInventoryEntry(association: f.associations[1], instance: old)
        let inventory = DesktopInstanceInventory(entries: [DesktopInventoryEntry(association: f.associations[1], instance: fresh)], unknownCount: 0)
        try inventory.validate()
        XCTAssertTrue(DesktopOpeningTarget.confirms(inventory, expected: [expected], launchedTarget: expected))
        XCTAssertFalse(DesktopOpeningTarget.confirms(inventory, expected: [expected], launchedTarget: nil))
        let foreign = DesktopInstanceInventory(entries: [DesktopInventoryEntry(association: f.associations[0], instance: fresh)], unknownCount: 0)
        XCTAssertFalse(DesktopOpeningTarget.confirms(foreign, expected: [expected], launchedTarget: expected))
        XCTAssertThrowsError(try DesktopInstanceInventory(entries: inventory.entries, unknownCount: 1).validate())
    }
    func testExactReceiverWaitsForBackendAndStableTreeWithoutChangingGUIGeneration() async throws {
        let main = DesktopGeneration(pid: 190_010, uid: getuid(), started: "synthetic-launch", startTimeMicroseconds: 100)
        let child = DesktopGeneration(pid: 190_050, uid: getuid(), started: "child", startTimeMicroseconds: 200)
        let signature = CodexSigningIdentity(identifier: "com.openai.codex", teamIdentifier: OfficialCodexPolicy.teamIdentifier,
            codeDirectoryHash: String(repeating: "b", count: 40))
        let receiver = DesktopInstance(main: main, related: [main], nativeLaunchDate: Date().addingTimeInterval(-1), signingIdentity: signature)
        let stable = DesktopInstance(main: main, related: [main, child], nativeLaunchDate: receiver.nativeLaunchDate, signingIdentity: signature)
        let script = StartupOwnershipSamples([.failure(.backendNotReady), .failure(.processChanged),
            .success(DesktopObservation(matching: [receiver], ambiguous: false)),
            .success(DesktopObservation(matching: [stable], ambiguous: false)),
            .success(DesktopObservation(matching: [stable], ambiguous: false))])
        let result = try await DesktopReadiness.wait(timeout: .seconds(1), interval: .milliseconds(1), expectedReceiver: receiver) {
            try await script.next($0)
        }
        XCTAssertEqual(result, stable)
        let calls = await script.calls
        XCTAssertEqual(calls, 5)
    }
    func testShortAliasesBindActualDarwinSocketWithoutMovingEnvironment() async throws {
        let f = try await fixture(), association = f.associations[1]
        let before = try await f.store.inspectAccountSetup()
        let paths = DesktopLaunchPaths(association: association, base: aliasRoot(f))
        try paths.prepare(validator: f.validator); try paths.prepare(validator: f.validator)
        XCTAssertEqual(URL(fileURLWithPath: paths.home).resolvingSymlinksInPath().path, URL(fileURLWithPath: association.codexHome).resolvingSymlinksInPath().path)
        let directory = paths.home + "/ipc"
        XCTAssertEqual(mkdir(directory, 0o700), 0)
        let name = directory + "/ipc.sock"
        XCTAssertLessThan(name.utf8.count, 104)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            name.utf8CString.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        let after = try await f.store.inspectAccountSetup()
        XCTAssertEqual(after, before)
        try f.validator.revalidate(association)
    }
    func testAliasRedirectionAndWritableParentFailClosed() async throws {
        let f = try await fixture()
        let paths = DesktopLaunchPaths(association: f.associations[1], base: aliasRoot(f))
        try paths.prepare(validator: f.validator)
        XCTAssertEqual(unlink(paths.home), 0)
        XCTAssertEqual(symlink(f.associations[0].codexHome, paths.home), 0)
        XCTAssertThrowsError(try paths.prepare(validator: f.validator))
        XCTAssertEqual(unlink(paths.home), 0)
        XCTAssertEqual(symlink(f.associations[1].codexHome, paths.home), 0)
        XCTAssertEqual(chmod(URL(fileURLWithPath: paths.home).deletingLastPathComponent().deletingLastPathComponent().path, 0o777), 0)
        XCTAssertThrowsError(try paths.validate(validator: f.validator))
    }
    func testOwnershipUsesGUIElectronAndItsDirectBackendHome() throws {
        let main = ReleaseDesktopSystem.instance(1).main, backend = ReleaseDesktopSystem.instance(2).main
        let rows = [DesktopProcessEvidence(generation: main, parent: 1, role: .main, electronDescriptors: 2),
                    DesktopProcessEvidence(generation: backend, parent: main.pid, role: .backend, homeDescriptors: 1)]
        XCTAssertEqual(try DesktopOwnership.resolve(before: rows, after: rows, standard: false).count, 1)
        for bad in [Array(rows.prefix(1)), [rows[0], DesktopProcessEvidence(generation: backend, parent: 99, role: .backend, homeDescriptors: 1)],
                    [DesktopProcessEvidence(generation: main, parent: 1, role: .main, homeDescriptors: 1), rows[1]]] {
            XCTAssertThrowsError(try DesktopOwnership.resolve(before: bad, after: bad, standard: false))
        }
    }
    func testReadinessCannotSubstituteAnotherLaunchServicesReceiver() async throws {
        let receiver = ReleaseDesktopSystem.instance(1), replacement = ReleaseDesktopSystem.instance(2)
        do {
            _ = try await DesktopReadiness.wait(expectedReceiver: receiver) { _ in
                DesktopObservation(matching: [replacement], ambiguous: false)
            }
            XCTFail("Replacement generation accepted")
        } catch { XCTAssertEqual(error as? EnvironmentError, .processChanged) }
    }
    func testNativeReadinessPreservesBackendOwnershipAndExitCauses() async throws {
        for cause in [EnvironmentError.backendNotReady, .ambiguousInstance, .launchedProcessExited] {
            do {
                _ = try await DesktopReadiness.wait(timeout: .milliseconds(10), interval: .milliseconds(1), preserveReason: true) { _ in throw cause }
                XCTFail("Missing readiness accepted")
            } catch { XCTAssertEqual(error as? EnvironmentError, cause == .ambiguousInstance ? .ownershipUnconfirmed : cause) }
        }
    }
    func testLaunchReceiverAndFailureSurviveCoordinatorRestart() async throws {
        let f = try await fixture()
        await f.system.configure(activation: true)
        do { try await f.open(); XCTFail("Activation failure accepted") } catch {}
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        let record = try XCTUnwrap(journal.pending())
        XCTAssertNotNil(record.launchReceiver)
        XCTAssertEqual(record.failure?.reason, .activation)
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let restarted = AccountSwitchingCoordinator(driver: driver)
        let pending = try await restarted.refreshOpeningRecovery(), failure = await restarted.lastError
        XCTAssertTrue(pending); XCTAssertEqual(failure, .activationFailed)
        let before = await f.system.effects
        try await restarted.reconcileOpeningRecovery()
        XCTAssertNil(try journal.pending())
        let after = await f.system.effects
        XCTAssertEqual(after, before, "Recovery performs no process effect")
    }
    func testLaunchServicesErrorAndProcessExitDiagnosticsRoundTripWithoutRawPayloads() throws {
        for error in [SwitchingError.environment(.launchServicesFailed(-10810)), .environment(.launchedProcessExited), .environment(.backendNotReady)] {
            let record = OpeningFailureRecord(error), data = try JSONEncoder().encode(record)
            XCTAssertEqual(try JSONDecoder().decode(OpeningFailureRecord.self, from: data).error, error)
            XCTAssertLessThan(data.count, 100)
        }
    }
    func testRestartRefusesAReplacementForTheRecordedLaunchReceiver() async throws {
        let f = try await fixture()
        await f.system.configure(activation: true)
        do { try await f.open() } catch {}
        await f.system.replace(f.associations[1])
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let restarted = AccountSwitchingCoordinator(driver: driver)
        _ = try await restarted.refreshOpeningRecovery()
        do { try await restarted.reconcileOpeningRecovery(); XCTFail("Replacement settled old launch") }
        catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryTargetChanged) }
        XCTAssertNotNil(try OpeningOperationJournal(root: f.validator.managedRoot).pending())
    }
    func testLaunchServicesReturnsExactSyntheticReceiverAndPassesBothRoots() async throws {
        let f = try await fixture(), paths = DesktopLaunchPaths(association: f.associations[1], base: aliasRoot(f))
        try paths.prepare(validator: f.validator)
        let app = f.root.appendingPathComponent("Probe.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let source = f.root.appendingPathComponent("probe.swift")
        try """
        import AppKit
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]!
        let electron = ProcessInfo.processInfo.environment["CODEX_ELECTRON_USER_DATA_PATH"]!
        let match = ProcessInfo.processInfo.arguments.contains("--user-data-dir=" + electron)
        let result = ["home": home, "electron": electron, "argumentMatches": String(match), "pid": String(ProcessInfo.processInfo.processIdentifier)]
        try! JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: home).appendingPathComponent("probe-result.json"))
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Stay alive until the worker has verified the receiver. Always self-exit
        // after a bounded deadline even if the worker crashes before acknowledging.
        let acknowledgement = URL(fileURLWithPath: home).appendingPathComponent("receiver-verified")
        let deadline = Date().addingTimeInterval(15)
        _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if FileManager.default.fileExists(atPath: acknowledgement.path) || Date() >= deadline {
                NSApplication.shared.terminate(nil)
            }
        }
        NSApplication.shared.run()
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", source.path, "-o", contents.appendingPathComponent("MacOS/Probe").path]
        try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
        let info: [String: Any] = ["CFBundleIdentifier": "test.codexswoop.probe." + UUID().uuidString,
            "CFBundleExecutable": "Probe", "CFBundleName": "Synthetic Launch Probe", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        // macOS 15 CI's hostless runner terminated during the in-process AppKit request.
        // Exercise the same request source in a physical-main-thread AppKit worker.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = f.root.appendingPathComponent("launch-worker")
        let workerCompiler = Process(); workerCompiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        workerCompiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library",
            repository.appendingPathComponent("Sources/CodexSwoopCore/LaunchServicesRequest.swift").path,
            repository.appendingPathComponent("Sources/CodexSwoop/MainThreadPreparation.swift").path,
            repository.appendingPathComponent("Tests/LaunchServices/LaunchWorker.swift").path, "-o", worker.path]
        try workerCompiler.run(); workerCompiler.waitUntilExit(); XCTAssertEqual(workerCompiler.terminationStatus, 0)
        let receipt = f.root.appendingPathComponent("receiver.json")
        let process = Process(); process.executableURL = worker
        process.arguments = [app.path, paths.home, paths.electron, receipt.path]
        let diagnostics = f.root.appendingPathComponent("worker-stderr.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnostics.path, contents: nil))
        let stderr = try FileHandle(forWritingTo: diagnostics)
        defer { try? stderr.close() }
        process.standardError = stderr
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let trace = try String(contentsOf: diagnostics, encoding: .utf8)
            XCTFail("AppKit QA worker reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus); \(trace)")
            return
        }
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(report["pid"] as? Int), 0)
        XCTAssertEqual(report["bundle"] as? String, app.path)
        let data = try Data(contentsOf: URL(fileURLWithPath: paths.home).appendingPathComponent("probe-result.json"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(result["home"], paths.home); XCTAssertEqual(result["electron"], paths.electron)
        XCTAssertEqual(result["argumentMatches"], "true")
        XCTAssertEqual(result["pid"], (report["pid"] as? Int).map(String.init), "LaunchServices must return the reporting probe itself")
    }
    func testLaunchServicesFailureKeepsConcreteErrorCode() async throws {
        let f = try await fixture()
        do {
            _ = try await NativeDesktopSystem.launchApplication(f.root.appendingPathComponent("Missing.app"),
                paths: DesktopLaunchPaths(association: f.associations[1]), environment: [:])
            XCTFail("Missing application launched")
        } catch let error as EnvironmentError {
            guard case .launchServicesFailed(let code) = error else { return XCTFail("Error detail lost") }
            XCTAssertNotEqual(code, 0)
        }
    }
}

@MainActor final class ReadinessTests: XCTestCase {
    func testManagedLaunchHomeFitsDarwinUnixSocketPath() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-socket-regression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await ReleaseFixture.make(root: root)
        let specification = try DesktopLaunchSpecification(association: f.associations[1])
        let home = try XCTUnwrap(specification.arguments.first { $0.hasPrefix("CODEX_HOME=") })
            .dropFirst("CODEX_HOME=".count)
        XCTAssertLessThan((String(home) + "/ipc/ipc.sock").utf8.count, 104,
            "Darwin sockaddr_un.sun_path cannot hold the original managed profile path")
    }
    func testPersistentPreparationRetainsLegacyUUIDAndDoesNotBind() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), profile = try await store.create(name: "Fixture Work").profiles[0]
        let before = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        let association = try await store.prepareManagedEnvironment(profileID: profile.id)
        try EnvironmentValidator(managedRoot: root).revalidate(association)
        XCTAssertEqual(association.environmentID, profile.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), before)
        let reopened = try await ProfileStore(root: root).inspectManagedEnvironments()
        XCTAssertEqual(reopened.prepared, [association])
        let bindings = try await store.inspectAssociations()
        XCTAssertTrue(bindings.associations.isEmpty)
        do { _ = try await store.prepareManagedEnvironment(profileID: profile.id); XCTFail("Recreation accepted") }
        catch { XCTAssertEqual(error as? EnvironmentError, .environmentPrepared) }
    }
    func testIdentityRequiresIndependentAnchorAndDefaultsToUnavailable() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), profile = try await store.create(name: "Fixture Work").profiles[0]
        let association = try await store.prepareManagedEnvironment(profileID: profile.id)
        let gen = DesktopGeneration(pid: 100_001, uid: getuid(), started: "synthetic")
        let instance = DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-1))
        let request = AccountIdentityRequest(association: association, instance: instance)
        let key = try AccountIdentityKey(namespace: "synthetic", subject: "fixture")
        let reader = SyntheticIdentityReader(key: key)
        let missing = try await AccountIdentityVerifier(reader: reader).assess(request)
        XCTAssertEqual(missing.state, .unverified)
        let matching = try await AccountIdentityVerifier(reader: reader, expected: [ExpectedAccountIdentity(association: association, key: key)]).assess(request)
        XCTAssertTrue(matching.proof.confirms(association, instance: instance))
        let blocked = try await AccountIdentityVerifier().assess(request)
        XCTAssertEqual(blocked.state, .verificationUnavailable)
    }
    func testWindowEvidenceRejectsWrongGenerationEvenWithSamePID() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), profile = try await store.create(name: "Fixture Work").profiles[0]
        let association = try await store.prepareManagedEnvironment(profileID: profile.id)
        let gen = DesktopGeneration(pid: 100_001, uid: getuid(), started: "synthetic")
        let instance = DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-1))
        let reused = DesktopGeneration(pid: gen.pid, uid: getuid(), started: "replacement")
        let evidence = DesktopActivationEvidence(association: association, instance: instance, windowIDs: [1], windowOwners: [reused], ownershipConfirmed: true)
        XCTAssertThrowsError(try evidence.validate(association: association, instance: instance)) {
            XCTAssertEqual($0 as? EnvironmentError, .activationUnavailable)
        }
    }
}

final class FirstRunTests: XCTestCase {
    func testWelcomeDependsOnActiveProfilesAndHealthyStorage() {
        XCTAssertTrue(FirstRunPresentation.showsWelcome(profileCount: 0, storageReady: true))
        XCTAssertFalse(FirstRunPresentation.showsWelcome(profileCount: 1, storageReady: true))
        XCTAssertFalse(FirstRunPresentation.showsWelcome(profileCount: 4, storageReady: true))
        XCTAssertFalse(FirstRunPresentation.showsWelcome(profileCount: 0, storageReady: false))
        XCTAssertEqual(FirstRunPresentation.downloadURL.scheme, "https")
        XCTAssertEqual(FirstRunPresentation.downloadURL.host, "learn.chatgpt.com")
    }
    func testDiscoveryIsVersionIndependentButNeverSignatureAuthority() {
        let reviewed = CodexInstallation(url: URL(fileURLWithPath: OfficialCodexPolicy.path),
            version: LastTestedCodexBuild.version, build: LastTestedCodexBuild.build)
        XCTAssertTrue(OfficialCodexPolicy.acceptsMetadata(reviewed))
        XCTAssertTrue(LastTestedCodexBuild.matches(reviewed))
        for candidate in [
            CodexInstallation(url: reviewed.url, version: "26.1007.71326", build: "updated"),
            CodexInstallation(url: reviewed.url, version: "future", build: "future")
        ] {
            XCTAssertTrue(OfficialCodexPolicy.acceptsMetadata(candidate))
            XCTAssertFalse(LastTestedCodexBuild.matches(candidate))
        }
        for candidate in [
            CodexInstallation(url: URL(fileURLWithPath: "/private/tmp/Codex.app"), version: reviewed.version),
            CodexInstallation(url: reviewed.url, version: reviewed.version, bundleIdentifier: "fixture.other"),
            CodexInstallation(url: reviewed.url, version: reviewed.version, executableName: "other")
        ] { XCTAssertFalse(OfficialCodexPolicy.acceptsMetadata(candidate)) }
        for state in CodexAvailability.allCases {
            XCTAssertTrue(state.permitsSetup)
            XCTAssertEqual(state.permitsOpening, state == .verified)
            XCTAssertFalse(L10n.format(state.messageKey, locale: "en").isEmpty)
        }
        for locale in ["en", "ru", "uz-Latn"] {
            XCTAssertTrue(L10n.format("onboarding.codex.untested", locale: locale, arguments: ["26.1007.71326"]).contains("26.1007.71326"))
        }
    }
    func testDeniedAccessibilityKeepsPIDOpeningButDoesNotPermitWindowInspection() {
        XCTAssertTrue(AccessibilityStatus.denied.permitsPIDOpening)
        XCTAssertFalse(AccessibilityStatus.denied.permitsWindowInspection)
        XCTAssertTrue(AccessibilityStatus.allowed.permitsPIDOpening)
        XCTAssertTrue(AccessibilityStatus.allowed.permitsWindowInspection)
        XCTAssertNotEqual(AccessibilityStatus.allowed.messageKey, AccessibilityStatus.denied.messageKey)
        // No permission status is passed into identity verification or environment ownership.
    }
    func testOnboardingAndSelectionSemanticsHaveThreeLocalesAndEnglishFallback() {
        for locale in ["en", "ru", "uz-Latn"] {
            let selected = L10n.format("onboarding.selected", locale: locale)
            XCTAssertNotEqual(selected, L10n.format("onboarding.notSelected", locale: locale))
            XCTAssertNotEqual(selected, "onboarding.selected")
            XCTAssertNotEqual(L10n.format("onboarding.restore", locale: locale, arguments: ["Fixture"]), "onboarding.restore")
            XCTAssertTrue(L10n.format("onboarding.restore", locale: locale, arguments: ["Fixture"]).contains("Fixture"))
        }
        XCTAssertEqual(L10n.format("onboarding.welcome", locale: "unsupported"), "Welcome to CodexSwoop")
    }
}

/// Entirely synthetic process records; no native process inspection or effects.
final class InstallationZombieTests: XCTestCase {
    private let seconds: Int64 = 1_700_000_000
    private func metadata() throws -> DesktopProcessMetadata {
        try DesktopProcessMetadata.parse("100002 100001 \(getuid()) Tue Nov 14 22:13:20 2023 <defunct>")
    }
    private func kernel(status: Int32 = SZOMB, parent: Int32 = 100_001,
                        usec: Int64 = 123, uid: UInt32 = getuid()) -> KernelProcessStatus {
        KernelProcessStatus(pid: 100_002, parent: parent, uid: uid, status: status,
                            seconds: seconds, microseconds: usec)
    }
    private func parent(start: UInt64 = 1_699_999_999_000_000) -> DesktopGeneration {
        DesktopGeneration(pid: 100_001, uid: getuid(), started: "synthetic parent", startTimeMicroseconds: start)
    }
    private func witness() throws -> InstallationZombieWitness {
        try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z", first: kernel(),
            second: kernel(), parent: parent(), hasChildren: false)
    }
    private func changed(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? EnvironmentError, .processChanged, file: file, line: line)
        }
    }
    func testLiveCorrectProcessRequiresPreciseGeneration() throws {
        let row = try metadata()
        let generation = DesktopGeneration(pid: row.pid, uid: row.uid, started: row.started,
            startTimeMicroseconds: UInt64(seconds * 1_000_000 + 123))
        let value = try InstallationProcessSample.read(metadata: row, psStatus: "S", hasChildren: false,
            parent: { XCTFail("Live parent bypass used"); throw EnvironmentError.processChanged },
            kernel: { _ in XCTFail("Live kernel fallback used"); throw EnvironmentError.processChanged },
            precise: { _ in generation })
        guard case .active(let found) = value else { return XCTFail("Live process excluded") }
        XCTAssertEqual(found, generation)
    }
    func testLiveUnconfirmedGenerationStillBlocks() throws {
        changed {
            _ = try InstallationProcessSample.read(metadata: metadata(), psStatus: "S", hasChildren: false,
                parent: { self.parent() }, kernel: { _ in self.kernel() },
                precise: { _ in throw EnvironmentError.processChanged })
        }
        changed {
            _ = try InstallationProcessSample.read(metadata: metadata(), psStatus: "S", hasChildren: false,
                parent: { self.parent() }, kernel: { _ in self.kernel() },
                precise: { DesktopGeneration(pid: $0.pid, uid: $0.uid, started: $0.started) })
        }
    }
    func testConfirmedZombieUsesKernelGeneration() throws {
        let found = try witness()
        XCTAssertEqual(found.kernel.status, SZOMB)
        XCTAssertEqual(found.kernel.microseconds, 123)
    }
    func testAmbiguousZombieAndDefunctTextAloneBlock() throws {
        for status in ["", "S", "<defunct>"] {
            changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: status,
                first: kernel(), second: kernel(), parent: parent(), hasChildren: false) }
        }
        changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(status: SRUN), second: kernel(status: SRUN), parent: parent(), hasChildren: false) }
    }
    func testZombieWithUnavailableLibprocNeedsIndependentKernelProof() throws {
        let found = try InstallationProcessSample.read(metadata: metadata(), psStatus: "Z", hasChildren: false,
            parent: { self.parent() }, kernel: { _ in self.kernel() },
            precise: { _ in XCTFail("Zombie libproc must not supply active generation"); throw EnvironmentError.processChanged })
        guard case .zombie = found else { return XCTFail("Zombie became active") }
    }
    func testUnavailableOrMissingKernelRecordBlocks() throws {
        changed { _ = try InstallationProcessSample.read(metadata: metadata(), psStatus: "Z", hasChildren: false,
            parent: { self.parent() }, kernel: { _ in throw EnvironmentError.processChanged }) }
    }
    func testZombieDisappearanceBetweenSnapshotsBlocks() throws {
        let session = InstallationPreflightSession()
        try session.check([100_002: witness()])
        changed { try session.check([:]) }
    }
    func testPIDReuseBetweenAndWithinSnapshotsBlocks() throws {
        changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(), second: kernel(usec: 124), parent: parent(), hasChildren: false) }
        let session = InstallationPreflightSession()
        try session.check([100_002: witness()])
        let reused = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(usec: 124), second: kernel(usec: 124), parent: parent(), hasChildren: false)
        changed { try session.check([100_002: reused]) }
        changed { try session.check([:]) } // A replacement live PID cannot erase a tombstone.
    }
    func testParentChangeAndParentReuseBlock() throws {
        changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(), second: kernel(parent: 100_003), parent: parent(), hasChildren: false) }
        let session = InstallationPreflightSession()
        try session.check([100_002: witness()])
        let reusedParent = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(), second: kernel(), parent: parent(start: 1_699_999_999_000_001), hasChildren: false)
        changed { try session.check([100_002: reusedParent]) }
    }
    func testUnknownChildAndUnconfirmedParentBlock() throws {
        changed { _ = try InstallationProcessSample.read(metadata: metadata(), psStatus: "?", hasChildren: false,
            parent: { self.parent() }, kernel: { _ in self.kernel() },
            precise: { _ in throw EnvironmentError.processChanged }) }
        changed { _ = try InstallationProcessSample.read(metadata: metadata(), psStatus: "Z", hasChildren: false,
            parent: { throw EnvironmentError.processChanged }, kernel: { _ in self.kernel() }) }
    }
    func testZombieWithChildrenOrWrongOwnerBlocks() throws {
        changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(), second: kernel(), parent: parent(), hasChildren: true) }
        changed { _ = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(uid: getuid() &+ 1), second: kernel(uid: getuid() &+ 1), parent: parent(), hasChildren: false) }
    }
    func testSameCountsCannotHideGenerationDriftBetweenPreflights() throws {
        let original = try witness()
        let replacement = try InstallationZombieWitness.confirm(metadata: metadata(), psStatus: "Z",
            first: kernel(usec: 124), second: kernel(usec: 124), parent: parent(), hasChildren: false)
        let first = InstallationProcessPreflightReport(entries: [], witnesses: [100_002: original])
        let second = InstallationProcessPreflightReport(entries: [], witnesses: [100_002: replacement])
        XCTAssertEqual(first.confirmedZombieCount, second.confirmedZombieCount)
        XCTAssertNotEqual(first, second)
    }
    func testCleanLegacyUpgradeObservationDoesNotInitializeJournal() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-zombie-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        _ = try await store.create(name: "Synthetic legacy profile")
        // Remove only this synthetic fixture's pair to model a pre-journal installation.
        for name in ["opening-journal.json", "opening-journal-watermark.json"] {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        let before = try await store.inspectAccountSetup()
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        let session = InstallationPreflightSession()
        try session.check([100_002: witness()]); try session.check([100_002: witness()])
        let report = InstallationProcessPreflightReport(entries: [], witnesses: session.witnesses!)
        XCTAssertEqual(report.confirmedZombieCount, 1)
        // Process success does not upgrade legacy absence to a clean recovery record.
        XCTAssertThrowsError(try OpeningOperationJournal(root: root).pending()) {
            XCTAssertEqual($0 as? OpeningJournalError, .legacyUninitialized)
        }
        let after = try await store.inspectAccountSetup()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), originalNames)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), originalBytes)
    }
}

/// Pure installation evidence fixtures. No native adapter, user data or process control.
struct InstallationGroupingFixture {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func identity(_ inode: UInt64, device: UInt64 = 1) -> DirectoryIdentity {
        DirectoryIdentity(device: device, inode: inode, owner: getuid(), permissions: 0o700)
    }
    func association(_ index: Int, home: UInt64, electron: UInt64,
                     kind: EnvironmentKind = .standardExternal, origin: AssociationOrigin = .currentDefaults,
                     homePath: String? = nil, electronPath: String? = nil) -> EnvironmentAssociation {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        return EnvironmentAssociation(profileID: id, environmentID: id, kind: kind,
            codexHome: homePath ?? "/synthetic/root-\(home)", electronData: electronPath ?? "/synthetic/root-\(electron)",
            homeIdentity: identity(home), electronIdentity: identity(electron), origin: origin,
            lastCheck: .directoryMetadataVerified, checkedAt: date)
    }
    var current: [EnvironmentAssociation] {
        [association(1, home: 1, electron: 2), association(2, home: 3, electron: 4, kind: .managed, origin: .userSelected)]
    }
    var aliases: [EnvironmentAssociation] { (3...5).map { association($0, home: 1, electron: 2) } }
    func profile(_ association: EnvironmentAssociation) throws -> AccountProfile {
        try AccountProfile(id: association.profileID, name: "Synthetic \(association.profileID.uuidString)", now: date)
    }
    func references(current selected: [EnvironmentAssociation]? = nil,
                    retained: [EnvironmentAssociation]? = nil,
                    prepared: [EnvironmentAssociation]? = nil,
                    extraProfiles: [AccountProfile] = []) throws -> InstallationAssociationReferences {
        let selected = selected ?? current
        var profiles = ProfileCatalog(); profiles.profiles = try selected.map(profile) + extraProfiles
        var catalog = AssociationCatalog(); catalog.associations = selected
        var registry = ManagedEnvironmentCatalog(); registry.prepared = prepared ?? [current[1]]
        var history = RetainedEnvironmentCatalog()
        history.environments = try (retained ?? aliases).map {
            RetainedEnvironment(profile: try profile($0), association: $0, retainedAt: date)
        }
        return try InstallationAssociationReferences(state: AccountSetupState(profiles: profiles,
            associations: catalog, managed: registry, retained: history), research: [])
    }
    func generation(_ pid: Int32, micros: UInt64 = 1_700_000_000_000_000) -> DesktopGeneration {
        DesktopGeneration(pid: pid, uid: getuid(), started: "synthetic", startTimeMicroseconds: micros)
    }
    func instance(_ pid: Int32) -> DesktopInstance {
        DesktopInstance(main: generation(pid), related: [generation(pid), generation(pid + 1)], nativeLaunchDate: date)
    }
    func observation(_ association: EnvironmentAssociation, target: Int32?, count: Int = 1,
                     reversed: Bool = false, instances: [DesktopInstance]? = nil) -> InstallationReferenceObservation {
        let instances = instances ?? [instance(100_001), instance(200_001)]
        let rows = instances.flatMap { value in
            [DesktopProcessEvidence(generation: value.main, parent: 1, role: .main,
                homeDescriptors: value.main.pid == target ? count : 0,
                electronDescriptors: value.main.pid == target ? count : 0),
             DesktopProcessEvidence(generation: value.related[1], parent: value.main.pid, role: .backend,
                homeDescriptors: value.main.pid == target ? count : 0)]
        }
        return InstallationReferenceObservation(association: association,
            instance: instances.first { $0.main.pid == target },
            before: reversed ? rows.reversed() : rows, after: rows)
    }
    var build: OpeningBuildFingerprint {
        OpeningBuildFingerprint(version: "synthetic", build: "fixture", signingRequirement: "synthetic-only",
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: "c", count: 64))
    }
    func snapshot(references refs: InstallationAssociationReferences? = nil,
                  observations: [InstallationReferenceObservation]? = nil,
                  mains: Set<DesktopGeneration>? = nil, nativePIDs: Set<Int32>? = nil,
                  witnesses: [Int32: InstallationZombieWitness] = [:],
                  build: OpeningBuildFingerprint? = nil) throws -> InstallationGroupingSnapshot {
        let refs = try refs ?? references()
        let samples = observations ?? refs.values.map {
            observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001)
        }
        return try InstallationGroupingSnapshot(references: refs, observations: samples,
            mains: mains ?? [generation(100_001), generation(200_001)], nativePIDs: nativePIDs ?? [100_001, 200_001],
            witnesses: witnesses, build: build ?? self.build)
    }
}

final class InstallationAliasGroupingTests: XCTestCase {
    private let f = InstallationGroupingFixture()
    func testTwoIndependentCurrentPairsRemainTwoInstances() throws {
        let snapshot = try f.snapshot(references: f.references(retained: []))
        let report = try InstallationProcessPreflightReport(first: snapshot, second: snapshot)
        XCTAssertEqual(report.activeInstances, 2); XCTAssertEqual(report.referenceCount, 2)
        XCTAssertEqual(report.historicalAliasCount, 0)
    }
    func testThreeHistoricalAliasesPreserveFiveReferencesAndAllProvenance() throws {
        let snapshot = try f.snapshot(), report = try InstallationProcessPreflightReport(first: snapshot, second: snapshot)
        XCTAssertEqual(report.activeInstances, 2); XCTAssertEqual(report.referenceCount, 5)
        XCTAssertEqual(report.historicalAliasCount, 3); XCTAssertEqual(report.referenceGroupIndices, [0, 1, 0, 0, 0])
        XCTAssertEqual(snapshot.references.values[1].sources, [.current, .managedRegistry])
        XCTAssertEqual(snapshot.observations.count, 5)
        XCTAssertEqual(snapshot.references.state.retained.environments.count, 3)
    }
    func testUnobservedRetainedOnlyReferenceRemainsInEvidence() throws {
        let retained = f.association(6, home: 5, electron: 6, kind: .isolatedExternal, origin: .userSelected)
        let refs = try f.references(retained: [retained])
        let observations = refs.values.enumerated().map { index, ref in
            f.observation(ref.association, target: index == 2 ? nil : index == 0 ? 100_001 : 200_001)
        }
        let snapshot = try f.snapshot(references: refs, observations: observations)
        XCTAssertEqual(snapshot.groups.count, 3); XCTAssertNil(snapshot.groups[2].instance)
        XCTAssertEqual(try InstallationProcessPreflightReport(first: snapshot, second: snapshot).referenceCount, 3)
    }
    func testObservedRetainedOnlyEnvironmentBlocksInsteadOfDisappearing() throws {
        let retained = f.association(6, home: 5, electron: 6, kind: .isolatedExternal, origin: .userSelected)
        let refs = try f.references(retained: [retained]), instances = [f.instance(100_001), f.instance(200_001), f.instance(300_001)]
        let observations = refs.values.enumerated().map { index, ref in
            f.observation(ref.association, target: instances[index].main.pid, instances: instances)
        }
        XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations,
            mains: Set(instances.map(\.main)), nativePIDs: Set(instances.map { $0.main.pid }))) {
            XCTAssertEqual($0 as? EnvironmentError, .missingAssociation)
        }
    }
    func testTwoCurrentOwnersOfOnePairBlock() {
        XCTAssertThrowsError(try f.references(current: [f.current[0], f.aliases[0]], retained: [], prepared: []))
    }
    func testRetainedAliasWithActiveProfileBlocks() throws {
        let refs = try f.references(extraProfiles: [f.profile(f.aliases[0])])
        XCTAssertThrowsError(try f.snapshot(references: refs))
    }
    func testSamePairWithIncompatibleKindOrOriginBlocks() throws {
        for retained in [f.association(6, home: 1, electron: 2, kind: .isolatedExternal),
                         f.association(6, home: 1, electron: 2, origin: .userSelected)] {
            XCTAssertThrowsError(try f.snapshot(references: f.references(retained: [retained])))
        }
    }
    func testOneMainUsingTwoIndependentPairsBlocks() throws {
        let refs = try f.references(retained: [])
        let observations = refs.values.map { f.observation($0.association, target: 100_001) }
        XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations))
    }
    func testPartialRootOverlapBlocksEvenIfRetainedIsUnobserved() throws {
        let refs = try f.references(retained: [f.association(6, home: 1, electron: 5)])
        let observations = refs.values.enumerated().map { index, ref in
            f.observation(ref.association, target: index == 2 ? nil : index == 0 ? 100_001 : 200_001)
        }
        XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations))
    }
    func testNestedRootsBlock() throws {
        let retained = f.association(6, home: 5, electron: 6, homePath: f.current[0].codexHome + "/nested")
        XCTAssertThrowsError(try f.snapshot(references: f.references(retained: [retained])))
    }
    func testCrossRoleOverlapBlocks() throws {
        let retained = f.association(6, home: 2, electron: 1)
        XCTAssertThrowsError(try f.snapshot(references: f.references(retained: [retained])))
    }
    func testSamePathsWithDifferentFilesystemIdentityBlock() throws {
        let retained = f.association(6, home: 5, electron: 6,
            homePath: f.current[0].codexHome, electronPath: f.current[0].electronData)
        XCTAssertThrowsError(try f.snapshot(references: f.references(retained: [retained])))
    }
    func testConflictingCompleteInstanceEvidenceBlocks() throws {
        let refs = try f.references()
        var observations = refs.values.map { f.observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001) }
        let old = observations[2], instance = old.instance!
        observations[2] = InstallationReferenceObservation(association: old.association,
            instance: DesktopInstance(main: instance.main, related: instance.related, nativeLaunchDate: instance.nativeLaunchDate.addingTimeInterval(-1)),
            before: old.before, after: old.after)
        XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations))
    }
    func testConflictingDuplicateReferenceIDCannotBeDropped() throws {
        let original = f.current[1]
        let changed = EnvironmentAssociation(profileID: original.profileID, environmentID: original.environmentID,
            kind: original.kind, codexHome: original.codexHome, electronData: original.electronData,
            homeIdentity: original.homeIdentity, electronIdentity: original.electronIdentity,
            origin: original.origin, lastCheck: original.lastCheck, checkedAt: original.checkedAt.addingTimeInterval(1))
        XCTAssertThrowsError(try f.references(prepared: [changed]))
    }
    func testMissingActiveProfileMetadataBlocks() throws {
        let refs = try f.references()
        var profiles = refs.state.profiles; profiles.profiles.removeFirst()
        XCTAssertThrowsError(try InstallationAssociationReferences(state: AccountSetupState(profiles: profiles,
            associations: refs.state.associations, managed: refs.state.managed, retained: refs.state.retained), research: []))
    }
    func testIncompleteDescriptorEvidenceBlocks() throws {
        let refs = try f.references()
        for missing in ["home", "electron", "backend"] {
            var observations = refs.values.map { f.observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001) }
            let old = observations[2]
            let rows = old.before.map { row in
                DesktopProcessEvidence(generation: row.generation, parent: row.parent, role: row.role,
                    homeDescriptors: missing == "home" && row.role == .main || missing == "backend" && row.role == .backend ? 0 : row.homeDescriptors,
                    electronDescriptors: missing == "electron" ? 0 : row.electronDescriptors, defaultDescriptors: row.defaultDescriptors)
            }
            observations[2] = InstallationReferenceObservation(association: old.association, instance: old.instance, before: rows, after: rows)
            XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations), missing)
        }
    }
    func testUnknownNativeInstanceBlocks() {
        XCTAssertThrowsError(try f.snapshot(nativePIDs: [100_001, 200_001, 300_001])) {
            XCTAssertEqual($0 as? AccountOpeningError, .unknownInstances)
        }
    }
    func testPIDReuseWithinObservationBlocks() throws {
        let refs = try f.references(), old = f.observation(refs.values[0].association, target: 100_001)
        var after = old.after
        after[0] = DesktopProcessEvidence(generation: f.generation(after[0].generation.pid, micros: 1_700_000_000_000_001),
            parent: after[0].parent, role: after[0].role, homeDescriptors: 1, electronDescriptors: 1)
        var observations = try f.snapshot().observations
        observations[0] = InstallationReferenceObservation(association: old.association, instance: old.instance, before: old.before, after: after)
        XCTAssertThrowsError(try f.snapshot(references: refs, observations: observations))
    }
    func testChangedGenerationBetweenSnapshotsBlocksEvenWithSameCounts() throws {
        let first = try f.snapshot(), replacement = f.generation(100_001, micros: 1_700_000_000_000_001)
        let instances = [DesktopInstance(main: replacement, related: [replacement, f.generation(100_002)], nativeLaunchDate: f.date), f.instance(200_001)]
        let observations = first.references.values.map {
            f.observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001, instances: instances)
        }
        let second = try f.snapshot(observations: observations, mains: [replacement, f.generation(200_001)])
        XCTAssertThrowsError(try InstallationProcessPreflightReport(first: first, second: second))
    }
    func testDescriptorEnumerationOrderDoesNotChangeEvidence() throws {
        let first = try f.snapshot()
        let observations = first.references.values.map {
            f.observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001, reversed: true)
        }
        let second = try f.snapshot(observations: observations)
        XCTAssertNoThrow(try InstallationProcessPreflightReport(first: first, second: second))
    }
    func testPositiveDescriptorCountVariationPreservesOriginalCountsAndStability() throws {
        let first = try f.snapshot()
        let observations = first.references.values.map {
            f.observation($0.association, target: $0.association.kind == .managed ? 200_001 : 100_001, count: 3)
        }
        let second = try f.snapshot(observations: observations)
        XCTAssertNotEqual(first.observations[0].before, second.observations[0].before)
        XCTAssertNoThrow(try InstallationProcessPreflightReport(first: first, second: second))
    }
    func testRootEvidencePresenceChangeBetweenSnapshotsBlocks() throws {
        let first = try f.snapshot()
        var observations = first.observations
        let old = observations[0]
        let rows = old.before.map { row in
            DesktopProcessEvidence(generation: row.generation, parent: row.parent, role: row.role,
                homeDescriptors: row.homeDescriptors, electronDescriptors: row.electronDescriptors,
                defaultDescriptors: row.generation.pid == 100_001 ? 1 : 0)
        }
        // Standard matching permits defaults, but a new evidence bucket is not stable.
        for index in [0, 2, 3, 4] {
            observations[index] = InstallationReferenceObservation(association: observations[index].association,
                instance: old.instance, before: rows, after: rows)
        }
        let second = try f.snapshot(observations: observations)
        XCTAssertThrowsError(try InstallationProcessPreflightReport(first: first, second: second))
    }
    func testBuildAndSignatureFingerprintChangesBlock() throws {
        let first = try f.snapshot()
        for hash in ["d", "e"] {
            let changed = OpeningBuildFingerprint(version: f.build.version, build: f.build.build,
                signingRequirement: f.build.signingRequirement, archiveSHA256: f.build.archiveSHA256,
                codeDirectoryHash: hash == "d" ? String(repeating: hash, count: 40) : f.build.codeDirectoryHash,
                bundleGenerationSHA256: String(repeating: hash, count: 64))
            XCTAssertThrowsError(try InstallationProcessPreflightReport(first: first, second: f.snapshot(build: changed)))
        }
    }
    func testChangedTerminalWitnessBetweenSnapshotsBlocks() throws {
        let metadata = try DesktopProcessMetadata.parse("100003 100001 \(getuid()) Tue Nov 14 22:13:20 2023 <defunct>")
        func witness(_ usec: Int64) throws -> InstallationZombieWitness {
            let kernel = KernelProcessStatus(pid: 100_003, parent: 100_001, uid: getuid(), status: SZOMB,
                seconds: 1_700_000_000, microseconds: usec)
            return try InstallationZombieWitness.confirm(metadata: metadata, psStatus: "Z", first: kernel,
                second: kernel, parent: f.generation(100_001), hasChildren: false)
        }
        let first = try f.snapshot(witnesses: [100_003: witness(1)])
        let second = try f.snapshot(witnesses: [100_003: witness(2)])
        XCTAssertThrowsError(try InstallationProcessPreflightReport(first: first, second: second))
        XCTAssertThrowsError(try InstallationProcessPreflightReport(first: first, second: f.snapshot()))
    }
    func testOriginalLifecycleInventoryStillRejectsAliases() throws {
        let snapshot = try f.snapshot()
        let entries = snapshot.observations.compactMap { observation in
            observation.instance.map { DesktopInventoryEntry(association: observation.association, instance: $0) }
        }
        XCTAssertThrowsError(try DesktopInstanceInventory(entries: entries, unknownCount: 0).validate())
    }
    func testStaleDirectoryMetadataBlocksFreshRevalidation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-alias-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user"), managed = root.appendingPathComponent("managed")
        let home = user.appendingPathComponent(".codex"), electron = user.appendingPathComponent("Library/Application Support/Codex")
        for path in [home, electron] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let validator = EnvironmentValidator(userHome: user, managedRoot: managed), original = f.current[0]
        let fresh = try validator.link(profileID: original.profileID, environmentID: original.environmentID,
            kind: .standardExternal, home: home.path, electron: electron.path)
        let refs = try f.references(current: [fresh], retained: [], prepared: [])
        try refs.revalidate(using: validator)
        try FileManager.default.moveItem(at: home, to: user.appendingPathComponent("old-home"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try refs.revalidate(using: validator)) {
            XCTAssertEqual($0 as? EnvironmentError, .changedDirectory)
        }
    }
}

/// Synthetic installations, metadata stores and process evidence only. No official Codex I/O/effects.
@MainActor
final class VersionIndependentCodexTests: XCTestCase {
    private func qaRoot() -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func signature(_ hash: String = "b", team: String = OfficialCodexPolicy.teamIdentifier,
                           identifier: String = CodexBundleInspector.bundleIdentifier) -> CodexSigningIdentity {
        CodexSigningIdentity(identifier: identifier, teamIdentifier: team, codeDirectoryHash: String(repeating: hash, count: 40))
    }
    private func updated() -> CodexInstallation {
        CodexInstallation(url: URL(fileURLWithPath: OfficialCodexPolicy.path), version: "26.1007.71326", build: "updated-fixture")
    }
    func testUpdatedAndFutureOfficialVersionsUsePublisherTrust() throws {
        for version in ["26.1007.71326", "99.1234.56789"] {
            let installation = CodexInstallation(url: updated().url, version: version, build: "future-fixture")
            try OfficialCodexPolicy.validate(installation, signature: signature(), signatureValid: true, before: "new-generation", after: "new-generation")
            XCTAssertFalse(LastTestedCodexBuild.matches(installation))
        }
    }
    func testCounterfeitPublisherIdentifierAndDamagedSignatureAreRejected() {
        for proof in [signature(team: "FAKE_TEAM"), signature(identifier: "fixture.counterfeit")] {
            XCTAssertThrowsError(try OfficialCodexPolicy.validate(updated(), signature: proof, signatureValid: true, before: "same", after: "same"))
        }
        XCTAssertThrowsError(try OfficialCodexPolicy.validate(updated(), signature: signature(), signatureValid: false, before: "same", after: "same"))
    }
    func testInstallationMutationDuringValidationIsRejected() {
        XCTAssertThrowsError(try OfficialCodexPolicy.validate(updated(), signature: signature(), signatureValid: true, before: "old-generation", after: "new-generation"))
    }
    func testLocalExistingAndManagedProfilesSurviveUpdateAndRename() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        for path in [f.validator.userHome.appendingPathComponent(".codex"), f.validator.userHome.appendingPathComponent("Library/Application Support/Codex")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for managed in [false, true] {
            let preview = try await f.store.previewNewAccount(name: managed ? "Updated Managed" : "Updated Existing", managed: managed, validator: f.validator)
            guard case .committed = try await f.store.commitAccountSetup(preview) else { return XCTFail("Metadata transaction failed") }
        }
        _ = try await f.store.rename(id: f.profiles[1].id, name: "Renamed after update")
        let reopened = try await ProfileStore(root: f.validator.managedRoot).inspectAccountSetup()
        XCTAssertEqual(reopened.profiles.profiles.count, 4)
        XCTAssertEqual(reopened.profiles.profiles.first { $0.id == f.profiles[1].id }?.name, "Renamed after update")
        XCTAssertTrue(f.associations.allSatisfy(reopened.associations.associations.contains))
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty, "Adding/renaming must not invoke the Desktop adapter")
    }
    func testUnverifiableSignatureAndUnknownProcessesDoNotBlockMetadataSetupOrRemoval() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.setSignatureValid(false); await f.system.configure(unknown: 2)
        let preview = try await f.store.previewNewAccount(name: "Offline Managed", managed: true, validator: f.validator)
        guard case let .committed(added) = try await f.store.commitAccountSetup(preview) else { return XCTFail("Local setup blocked") }
        let profile = try XCTUnwrap(added.profiles.profiles.last)
        _ = try await f.store.rename(id: profile.id, name: "Offline rename")
        let removal = try await f.store.previewProfileRemoval(id: profile.id)
        guard case let .committed(removed) = try await f.store.commitAccountSetup(removal) else { return XCTFail("Local removal blocked") }
        XCTAssertEqual(removed.profiles.profiles, f.profiles)
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testNewVersionLaunchesWithValidSignatureAndOwnedProcessEvidence() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot(), running: false)
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        try await f.open()
        let effects = await f.system.effects, result = await f.coordinator.openingResult
        XCTAssertEqual(effects, ["launch", "activate"])
        XCTAssertEqual(result, .launched(f.profiles[1].id))
        XCTAssertNil(try OpeningOperationJournal(root: f.validator.managedRoot).pending())
    }
    func testOfficialUpdateBetweenSwoopInstancesNeedsNoAllowlistChange() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        try await f.open()
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        let restarted = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
            store: ProfileStore(root: f.validator.managedRoot), validator: f.validator, system: f.system))
        try await restarted.openAccount(to: f.profiles[1], mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
        let effects = await f.system.effects
        XCTAssertEqual(effects, ["activate", "activate"])
    }
    func testOlderSignedLiveProcessIsIndependentOfReplacementOnDiskAndRecorded() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let stored = await f.system.instances[f.associations[1].environmentID]
        let old = try XCTUnwrap(stored)
        let oldSignature = signature("a")
        await f.system.setSyntheticInstance(f.associations[1].environmentID, DesktopInstance(main: old.main, related: old.related,
            nativeLaunchDate: old.nativeLaunchDate, signingIdentity: oldSignature))
        await f.system.updateInstallation(version: "26.1007.71326", build: "new-on-disk")
        try await f.open()
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: f.validator.managedRoot.appendingPathComponent("opening-journal.json"))) as! [String: Any]
        let settled = try XCTUnwrap(journal["settled"] as? [String: Any])
        let disk = try XCTUnwrap(settled["buildFingerprint"] as? [String: Any])
        let target = try XCTUnwrap(settled["targetInstance"] as? [String: Any])
        let live = try XCTUnwrap(target["signingIdentity"] as? [String: Any])
        XCTAssertEqual(disk["version"] as? String, "26.1007.71326")
        XCTAssertEqual(disk["codeDirectoryHash"] as? String, String(repeating: "b", count: 40))
        XCTAssertEqual(live["codeDirectoryHash"] as? String, oldSignature.codeDirectoryHash)
    }
    func testCounterfeitSignaturePreventsLifecycleEffects() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        await f.system.setSignatureValid(false)
        do { try await f.open(); XCTFail("Invalid signature admitted") } catch {}
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testUpdateWithUnknownOwnershipNeverClosesProcesses() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        await f.system.configure(unknown: 1)
        do { try await f.open(.closeOthersAndOpen); XCTFail("Unknown ownership admitted") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.unknownInstances)) }
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testSamePIDWithReusedGenerationPreventsDispatchAfterUpdate() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.updateInstallation(version: "26.1007.71326", build: "updated-fixture")
        let stored = await f.system.instances[f.associations[1].environmentID]
        let old = try XCTUnwrap(stored)
        let reused = DesktopGeneration(pid: old.main.pid, uid: old.main.uid, started: "reused-fixture", startTimeMicroseconds: 123)
        do {
            try await f.coordinator.openAccount(to: f.profiles[1], mode: .openSeparately, environmentScoped: true,
                confirmOpen: { _ in
                    await f.system.setSyntheticInstance(f.associations[1].environmentID, DesktopInstance(main: reused,
                        related: [reused], nativeLaunchDate: Date().addingTimeInterval(-1)))
                    return true
                })
            XCTFail("PID reuse admitted")
        } catch { XCTAssertEqual(error as? SwitchingError, .opening(.processChanged)) }
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testDiskUpdateAfterJournalIntentPreventsDispatch() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let plan = try await driver.planEnvironmentAccount(profile: f.profiles[1], mode: .openSeparately)
        try await driver.authorizeEnvironmentAccount(plan, allowPrimary: false)
        let record = try XCTUnwrap(OpeningOperationJournal(root: f.validator.managedRoot).pending())
        await f.system.updateInstallation(version: "26.1007.71326", build: "changed-during-operation")
        do { try await driver.activate(profile: f.profiles[1]); XCTFail("Installation drift admitted") }
        catch { XCTAssertEqual(error as? EnvironmentError, .incompatibleBuild) }
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(try OpeningOperationJournal(root: f.validator.managedRoot).pending(), record)
        await driver.finishOpening(plan, success: false)
    }
    func testUpdateCannotSettlePendingRecoveryOrRewriteItsEvidence() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.updateInstallation(version: "26.1007.71326", build: "intent-build")
        await f.system.configure(activation: true)
        do { try await f.open(); XCTFail("Synthetic failure ignored") } catch {}
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        let record = try XCTUnwrap(journal.pending())
        XCTAssertEqual(record.buildFingerprint.version, "26.1007.71326")
        let names = ["opening-journal.json", "opening-journal-watermark.json"]
        let before = try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }
        await f.system.updateInstallation(version: "future-version", build: "replacement", stamp: "e")
        let restarted = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
            store: ProfileStore(root: f.validator.managedRoot), validator: f.validator, system: f.system))
        let needsReview = try await restarted.refreshOpeningRecovery()
        XCTAssertTrue(needsReview)
        do { try await restarted.reconcileOpeningRecovery(); XCTFail("Updated build settled previous operation") } catch {}
        XCTAssertEqual(try journal.pending(), record)
        XCTAssertEqual(try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }, before)
        let effects = await f.system.effects
        XCTAssertEqual(effects, ["activate"])
    }
    func testNativeSignatureReaderRejectsAdHocAndTamperedSyntheticBundle() throws {
        let app = qaRoot().appendingPathComponent("FakeCodex.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/ChatGPT"))
        let info = ["CFBundleIdentifier": CodexBundleInspector.bundleIdentifier, "CFBundleExecutable": "ChatGPT", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let resource = contents.appendingPathComponent("Resources/fixture")
        try Data("synthetic signed content".utf8).write(to: resource)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try NativeDesktopSystem.staticSigningIdentity(app))
        try Data("tampered fixture".utf8).write(to: resource)
        XCTAssertThrowsError(try NativeDesktopSystem.staticSigningIdentity(app))
    }
}

final class ActionErrorLogTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-error-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testErrorsPersistWithoutRawDescriptionsDomainsOrPaths() throws {
        let root = try root(), log = ActionErrorLog(root: root)
        log.record(.addAccount, error: ProfileError.invalidName)
        log.record(.openProfile, error: NSError(domain: "fixture-private-domain", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "fixture-private-description", NSFilePathErrorKey: "/synthetic/private-location"]))
        let bytes = try Data(contentsOf: ActionErrorLog(root: root).fileForViewing())
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("profile.invalidName")); XCTAssertTrue(text.contains("unexpected.42"))
        for privateValue in ["fixture-private-domain", "fixture-private-description", "/synthetic/private-location"] {
            XCTAssertFalse(text.contains(privateValue))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try bytes.split(separator: 10).map { try decoder.decode(ActionErrorLog.Entry.self, from: Data($0)) }.count, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRetentionKeepsLatest500Errors() throws {
        let root = try root(), log = ActionErrorLog(root: root), url = try log.fileForViewing()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var previous = Data()
        for index in 0..<501 {
            previous.append(try encoder.encode(ActionErrorLog.Entry(timestamp: Date(), action: .other, code: "fixture.\(index)"))); previous.append(10)
        }
        try previous.write(to: url)
        log.record(.addAccount, error: ProfileError.invalidName)
        let lines = try Data(contentsOf: url).split(separator: 10)
        XCTAssertEqual(lines.count, 500)
        XCTAssertTrue(String(decoding: lines.first!, as: UTF8.self).contains("fixture.2"))
        XCTAssertTrue(String(decoding: lines.last!, as: UTF8.self).contains("profile.invalidName"))
    }
    func testSymlinkCannotRedirectLogWrites() throws {
        let root = try root(), outside = root.appendingPathComponent("sentinel")
        let original = Data("fixture content remains unchanged".utf8)
        try original.write(to: outside)
        let log = ActionErrorLog(root: root)
        try FileManager.default.createSymbolicLink(at: log.url, withDestinationURL: outside)
        log.record(.addAccount, error: ProfileError.invalidName)
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertThrowsError(try log.fileForViewing())
    }
}
