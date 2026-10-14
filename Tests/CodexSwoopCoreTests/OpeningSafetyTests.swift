import XCTest
import Darwin
@testable import CodexSwoopCore

@MainActor
final class OpeningSafetyTests: XCTestCase {
    private func qaRoot() -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testOpenSeparatelyPreservesOtherInstanceAndMetadata() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let before = try await f.store.inspectAccountSetup(), other = await f.system.instances[f.associations[0].environmentID]
        try await f.open(); try await f.open()
        let effects = await f.system.effects, retained = await f.system.instances[f.associations[0].environmentID]
        let after = try await f.store.inspectAccountSetup(), result = await f.coordinator.openingResult
        XCTAssertEqual(effects, ["activate", "activate"])
        XCTAssertEqual(retained, other)
        XCTAssertEqual(after, before)
        XCTAssertEqual(result, .activatedExisting(f.profiles[1].id))
        let state = await f.coordinator.state
        XCTAssertEqual(state, .environmentOpened(f.profiles[1].id), "Environment opening cannot mark an account Active")
        let selected = await f.system.instances[f.associations[1].environmentID]
        XCTAssertEqual(ConnectionPresentation.state(association: f.associations[1], instance: selected), .verificationRequired)
        let usage = UsageCoordinator()
        usage.synchronize(f.associations)
        XCTAssertEqual(usage.state(for: f.profiles[1].id).status, .verificationRequired)
    }
    func testAbsentTargetLaunchesOnceThenActivatesExisting() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot(), running: false)
        try await f.open(); try await f.open()
        let effects = await f.system.effects
        XCTAssertEqual(effects, ["launch", "activate", "activate"])
    }
    func testCloseOthersRequiresConsentEvenWhenActivityUnknown() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        do {
            try await f.coordinator.openAccount(to: f.profiles[1], mode: .closeOthersAndOpen, environmentScoped: true)
            XCTFail("Missing consent accepted")
        } catch { XCTAssertEqual(error as? SwitchingError, .opening(.userCancelled)) }
        let before = await f.system.effects
        XCTAssertTrue(before.isEmpty)
        try await f.coordinator.openAccount(to: f.profiles[1], mode: .closeOthersAndOpen, environmentScoped: true,
            confirmClose: { confirmation in
                XCTAssertTrue(confirmation.activities.contains { if case .unknown = $0 { return true }; return false })
                return .confirm(allowPrimary: false)
            })
        let effects = await f.system.effects, instances = await f.system.instances
        XCTAssertEqual(effects, ["quit", "wait", "activate"])
        XCTAssertNil(instances[f.associations[0].environmentID])
        XCTAssertNotNil(instances[f.associations[1].environmentID])
    }
    func testUnknownInstanceBlocksCloseOthersWithoutEffects() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.configure(unknown: 1)
        do { try await f.open(.closeOthersAndOpen); XCTFail("Unowned instance ignored") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.unknownInstances)) }
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testGenerationChangeDuringConsentPreventsDispatch() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        do {
            try await f.coordinator.openAccount(to: f.profiles[1], mode: .openSeparately, environmentScoped: true,
                confirmOpen: { _ in await f.system.replace(f.associations[1]); return true })
            XCTFail("Changed receiver accepted")
        } catch { XCTAssertEqual(error as? SwitchingError, .opening(.processChanged)) }
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testSubmittedActivationFailureCannotRetryUntilReadOnlyReconciliation() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        await f.system.configure(activation: true)
        do { try await f.open(); XCTFail("Failure ignored") }
        catch { XCTAssertEqual(error as? SwitchingError, .activationFailed) }
        do { try await f.open(); XCTFail("Uncertain dispatch retried") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.recoveryRequired)) }
        try await f.coordinator.reconcileOpeningRecovery()
        let effects = await f.system.effects, result = await f.coordinator.openingResult, state = await f.coordinator.state
        XCTAssertEqual(effects, ["activate"])
        XCTAssertNil(result)
        XCTAssertEqual(state, .idle)
    }
    func testLaunchFailureAfterClosurePreservesPartialOutcomeWithoutRollback() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot(), running: false)
        await f.system.configure(launch: true)
        do { try await f.open(.closeOthersAndOpen); XCTFail("Partial opening accepted") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.launchFailure)) }
        let effects = await f.system.effects, state = await f.coordinator.state
        XCTAssertEqual(effects, ["quit", "wait", "launch"])
        XCTAssertEqual(state, .recoveryRequired)
        do { try await f.coordinator.reconcileOpeningRecovery(); XCTFail("Absent launched target accepted") }
        catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryRequired) }
        let unchanged = await f.system.effects
        XCTAssertEqual(unchanged, effects)
    }
    func testPIDOpeningCapabilityIsOneShotAndCannotProveIdentity() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let association = f.associations[1], catalog = try await f.store.inspectAssociations()
        let captured = await f.system.instances[association.environmentID]
        let instance = try XCTUnwrap(captured)
        await f.system.configurePID(try PIDActivationScope(association: association, revision: catalog.revision, instance: instance))
        try await f.coordinator.openPIDEnvironment(to: f.profiles[1], manual: ManualAccountConfirmation(association: association)) { _ in true }
        let result = await f.coordinator.pidEnvironmentOpeningResult
        XCTAssertTrue(result?.guarantees.processOwnershipVerified == true)
        XCTAssertTrue(result?.guarantees.accountIdentityUserConfirmed == true)
        XCTAssertFalse(result?.guarantees.accountIdentityTechnicallyVerified == true)
        XCTAssertFalse(result?.guarantees.windowOwnershipVerified == true)
        do { try await f.coordinator.openPIDEnvironment(to: f.profiles[1]) { _ in true }; XCTFail("Capability reused") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.recoveryRequired)) }
        let effects = await f.system.effects
        XCTAssertEqual(effects, ["pidActivate"])
    }
    private func pendingRecord(_ f: ReleaseFixture, mode: AccountOpeningMode = .openSeparately,
                               boot: String = "synthetic-boot") async throws -> PendingOpeningOperation {
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let plan = try await driver.planEnvironmentAccount(profile: f.profiles[1], mode: mode)
        let managed = try await f.store.inspectManagedEnvironments()
        let retained = mode == .closeOthersAndOpen ? try await f.store.inspectRetainedResearchEnvironments() : []
        return try PendingOpeningOperation(scope: EnvironmentOperationScope(plan: plan, managed: managed, retainedResearch: retained), bootSession: boot, buildFingerprint: try await f.system.openingBuildFingerprint())
    }
    private func restartedCoordinator(_ f: ReleaseFixture, journal: OpeningOperationJournal? = nil) -> AccountSwitchingCoordinator {
        AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
            store: ProfileStore(root: f.validator.managedRoot), validator: f.validator, system: f.system, openingJournal: journal))
    }
    func testRestartRestoresSubmittedActivationAndCheckAgainNeverReplays() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
        let recovered = restartedCoordinator(f), review = try await recovered.refreshOpeningRecovery()
        XCTAssertTrue(review)
        do { try await recovered.openAccount(to: f.profiles[1], mode: .closeOthersAndOpen); XCTFail("Recovered intent replayed") }
        catch { XCTAssertEqual(error as? SwitchingError, .opening(.recoveryRequired)) }
        try await recovered.reconcileOpeningRecovery()
        let state = await recovered.state, effects = await f.system.effects
        XCTAssertEqual(state, .idle); XCTAssertTrue(effects.isEmpty); XCTAssertNil(try journal.pending())
    }
    func testCrashAfterIntentCannotBeDismissedByTimeoutOrManualAcknowledgement() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); journal.abandon()
        for _ in 0..<2 {
            let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.acknowledgeOpeningRecovery(userReviewed: true); XCTFail("Intent alone settled") }
            catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryRequired) }
            XCTAssertEqual(try journal.pending(), intent)
        }
        let effects = await f.system.effects; XCTAssertTrue(effects.isEmpty)
    }
    func testRestartWithPartialCloseRequiresOwnedTargetAndAllSubmittedGroupsGone() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f, mode: .closeOthersAndOpen)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot), other = intent.others[0]
        try journal.begin(intent); try journal.append(.normalQuit(other.instance), operation: intent.id); journal.abandon()
        let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
        do { try await recovered.reconcileOpeningRecovery(); XCTFail("Still running quit receiver accepted") }
        catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryRequired) }
        await f.system.removeSyntheticInstance(other.environmentID)
        try await recovered.reconcileOpeningRecovery()
        let effects = await f.system.effects; XCTAssertTrue(effects.isEmpty)
    }
    func testSuccessfulInstallationAliasGroupingCannotSettlePendingRecovery() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); journal.abandon()
        let names = ["opening-journal.json", "opening-journal-watermark.json"]
        let bytes = try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }
        let fixture = InstallationGroupingFixture(), snapshot = try fixture.snapshot()
        let report = try InstallationProcessPreflightReport(first: snapshot, second: snapshot)
        XCTAssertEqual(report.activeInstances, 2); XCTAssertEqual(report.historicalAliasCount, 3)
        let recovered = restartedCoordinator(f)
        let review = try await recovered.refreshOpeningRecovery()
        XCTAssertTrue(review)
        let state = await recovered.state, effects = await f.system.effects
        XCTAssertEqual(state, .recoveryRequired); XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(try journal.pending(), intent)
        XCTAssertEqual(try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }, bytes)
    }
    func testZombieInHistoricalQuitGroupCannotSettlePendingJournal() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let plan = try await driver.planEnvironmentAccount(profile: f.profiles[1], mode: .closeOthersAndOpen)
        let scope = EnvironmentOperationScope(plan: plan, managed: try await f.store.inspectManagedEnvironments())
        let intent = try PendingOpeningOperation(scope: scope, bootSession: "synthetic-boot",
            buildFingerprint: try await f.system.openingBuildFingerprint())
        let journal = OpeningOperationJournal(root: f.validator.managedRoot), other = scope.others[0]
        try journal.begin(intent); try journal.append(.normalQuit(other.instance), operation: intent.id); journal.abandon()
        await f.system.removeSyntheticInstance(other.association.environmentID)
        let system: any DesktopSystem = f.system
        let inventory = try await system.instanceInventory(associations: f.associations)
        let before = try journal.pending()
        // Terminal PID is still present. Production recovery uses the strict sampler and
        // cannot consume InstallationProcessPreflightReport or its omitted tombstones.
        XCTAssertThrowsError(try EnvironmentRecoveryProof.validate(scope: scope,
            effects: [.normalQuit(other.instance)], inventory: inventory,
            livePIDs: Set(other.instance.related.map(\.pid)), launcherRunning: false)) {
                XCTAssertEqual($0 as? AccountOpeningError, .recoveryRequired)
        }
        XCTAssertEqual(try journal.pending(), before)
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testRebootAndAbsentProcessesDoNotProvePriorCompletion() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f, boot: "previous-boot")
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
        await f.system.removeSyntheticInstance(f.associations[1].environmentID)
        let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
        do { try await recovered.reconcileOpeningRecovery(); XCTFail("New boot cleared warning") }
        catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryBootChanged) }
        XCTAssertNotNil(try journal.pending())
    }
    func testInvalidAndFutureJournalRemainBlockedAndUnmodified() async throws {
        for content in ["{", "{\"schemaVersion\":99,\"state\":\"idle\"}", "{\"schemaVersion\":1,\"state\":\"pending\"}"] {
            let f = try await ReleaseFixture.make(root: qaRoot()), path = f.validator.managedRoot.appendingPathComponent("opening-journal.json")
            try AtomicMetadataWriter().write(Data(content.utf8), to: path)
            let recovered = restartedCoordinator(f)
            do { _ = try await recovered.refreshOpeningRecovery(); XCTFail("Invalid journal ignored") } catch is OpeningJournalError {}
            let state = await recovered.state; XCTAssertEqual(state, .recoveryRequired)
            do { try await recovered.reconcileOpeningRecovery(); XCTFail("Invalid journal repaired silently") } catch is OpeningJournalError {}
            XCTAssertEqual(try Data(contentsOf: path), Data(content.utf8))
            let effects = await f.system.effects; XCTAssertTrue(effects.isEmpty)
        }
    }
    func testChangedGenerationAndUnknownInstanceRefuseCheckAgain() async throws {
        for unknown in [false, true] {
            let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
            let journal = OpeningOperationJournal(root: f.validator.managedRoot)
            try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
            if unknown { await f.system.configure(unknown: 1) } else { await f.system.replace(f.associations[1]) }
            let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.reconcileOpeningRecovery(); XCTFail("Unsafe result accepted") } catch is AccountOpeningError {}
            XCTAssertNotNil(try journal.pending())
            let effects = await f.system.effects; XCTAssertTrue(effects.isEmpty)
        }
    }
    func testSecondSwoopCannotBeginOrReconcileLiveOperationAndMetadataIsProtected() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let owner = OpeningOperationJournal(root: f.validator.managedRoot), second = OpeningOperationJournal(root: f.validator.managedRoot)
        try owner.begin(intent); defer { owner.abandon() }
        XCTAssertThrowsError(try second.begin(intent)) { XCTAssertEqual($0 as? OpeningJournalError, .busy) }
        XCTAssertThrowsError(try second.acquireRecovery()) { XCTAssertEqual($0 as? OpeningJournalError, .busy) }
        do { _ = try await f.store.rename(id: f.profiles[1].id, name: "Blocked"); XCTFail("Pending metadata changed") }
        catch { XCTAssertEqual(error as? OpeningJournalError, .conflict) }
        XCTAssertEqual(try owner.pending(), intent)
    }
    func testFailedPostflightJournalCommitSurvivesRestart() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), counter = JournalWriteCounter()
        let journal = OpeningOperationJournal(root: f.validator.managedRoot, writer: AtomicMetadataWriter { destination in
            if destination.lastPathComponent == "opening-journal-watermark.json", counter.next() == 3 { throw OpeningJournalError.unavailable }
        })
        let coordinator = restartedCoordinator(f, journal: journal)
        do {
            try await coordinator.openAccount(to: f.profiles[1], mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
            XCTFail("Failed completion write reported success")
        } catch is SwitchingError {}
        let recovered = restartedCoordinator(f); let review = try await recovered.refreshOpeningRecovery(); XCTAssertTrue(review)
        let before = await f.system.effects
        try await recovered.reconcileOpeningRecovery()
        let after = await f.system.effects; XCTAssertEqual(before, after); XCTAssertNil(try journal.pending())
    }
    func testLostOrRolledBackJournalPairNeverLooksLikeFirstInstall() async throws {
        for loss in ["journal", "watermark", "both", "rollback"] {
            let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
            let root = f.validator.managedRoot, path = root.appendingPathComponent("opening-journal.json")
            let watermark = root.appendingPathComponent("opening-journal-watermark.json")
            let idle = try Data(contentsOf: path), journal = OpeningOperationJournal(root: root)
            try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
            if loss == "journal" || loss == "both" { try FileManager.default.removeItem(at: path) }
            if loss == "watermark" || loss == "both" { try FileManager.default.removeItem(at: watermark) }
            if loss == "rollback" { try idle.write(to: path) }
            let recovered = restartedCoordinator(f)
            do { _ = try await recovered.refreshOpeningRecovery(); XCTFail("Missing pair accepted as new store") } catch is OpeningJournalError {}
            let state = await recovered.state; XCTAssertEqual(state, .recoveryRequired)
            do { try await recovered.reconcileOpeningRecovery(); XCTFail("Missing evidence dismissed") } catch is OpeningJournalError {}
            let effects = await f.system.effects; XCTAssertTrue(effects.isEmpty)
        }
    }
    func testBuildFingerprintChangePreservesPendingOperation() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
        await f.system.changeBuild()
        let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
        do { try await recovered.reconcileOpeningRecovery(); XCTFail("Changed build accepted") }
        catch { XCTAssertEqual(error as? EnvironmentError, .incompatibleBuild) }
        XCTAssertEqual(try journal.pending()?.buildFingerprint, intent.buildFingerprint)
    }
    func testSameSecondPIDReuseAndChildGenerationChangeRemainUnresolved() async throws {
        for childOnly in [false, true] {
            let f = try await ReleaseFixture.make(root: qaRoot())
            let original = await f.system.instances[f.associations[1].environmentID]!
            let main = DesktopGeneration(pid: original.main.pid, uid: getuid(), started: original.main.started, startTimeMicroseconds: 10_000_001)
            let child = DesktopGeneration(pid: original.main.pid + 10, uid: getuid(), started: original.main.started, startTimeMicroseconds: 10_000_002)
            await f.system.setSyntheticInstance(f.associations[1].environmentID,
                DesktopInstance(main: main, related: [main, child], nativeLaunchDate: original.nativeLaunchDate))
            let intent = try await pendingRecord(f), journal = OpeningOperationJournal(root: f.validator.managedRoot)
            try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
            let changedMain = childOnly ? main : DesktopGeneration(pid: main.pid, uid: main.uid, started: main.started, startTimeMicroseconds: 10_000_003)
            let changedChild = childOnly ? DesktopGeneration(pid: child.pid, uid: child.uid, started: child.started, startTimeMicroseconds: 10_000_004) : child
            await f.system.setSyntheticInstance(f.associations[1].environmentID,
                DesktopInstance(main: changedMain, related: [changedMain, changedChild], nativeLaunchDate: original.nativeLaunchDate))
            let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.reconcileOpeningRecovery(); XCTFail("Same-second replacement accepted") }
            catch { XCTAssertEqual(error as? AccountOpeningError, .recoveryTargetChanged) }
            XCTAssertNotNil(try journal.pending())
        }
    }
    func testRecoveryReportsSafetyRatherThanHistoricalActivationSuccess() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot()), intent = try await pendingRecord(f)
        let journal = OpeningOperationJournal(root: f.validator.managedRoot)
        try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
        let recovered = restartedCoordinator(f); _ = try await recovered.refreshOpeningRecovery()
        try await recovered.reconcileOpeningRecovery()
        let resolution = await recovered.openingRecoveryResolution, result = await recovered.openingResult
        XCTAssertEqual(resolution, .safeForNewOperation); XCTAssertNil(result)
        let foreground = await f.system.foreground; XCTAssertNil(foreground, "Safety proof is not a claim that activation occurred")
    }
    func testOwnershipRejectsReusedPIDAndDefaultRootLeak() throws {
        let main = DesktopGeneration(pid: 190_000, uid: getuid(), started: "synthetic-main")
        let backend = DesktopGeneration(pid: 190_001, uid: getuid(), started: "synthetic-backend")
        let rows = [DesktopProcessEvidence(generation: main, parent: 1, role: .main, homeDescriptors: 1, electronDescriptors: 1),
                    DesktopProcessEvidence(generation: backend, parent: main.pid, role: .backend, homeDescriptors: 1)]
        XCTAssertEqual(try DesktopOwnership.resolve(before: rows, after: rows, standard: false).count, 1)
        let reused = DesktopGeneration(pid: main.pid, uid: getuid(), started: "replacement")
        let changed = [DesktopProcessEvidence(generation: reused, parent: 1, role: .main, homeDescriptors: 1, electronDescriptors: 1), rows[1]]
        XCTAssertThrowsError(try DesktopOwnership.resolve(before: rows, after: changed, standard: false)) {
            XCTAssertEqual($0 as? EnvironmentError, .processChanged)
        }
        let leaked = [rows[0], DesktopProcessEvidence(generation: backend, parent: main.pid, role: .backend, homeDescriptors: 1, defaultDescriptors: 1)]
        XCTAssertThrowsError(try DesktopOwnership.resolve(before: leaked, after: leaked, standard: false))
    }
}


private final class JournalWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
