import Foundation
import Darwin
import CodexSwoopCore

/// No OS process, window, authentication or account API is used by this adapter.
actor OpeningSystem: DesktopSystem {
    nonisolated let lifecycleAllowed: Bool
    nonisolated let environmentActivationAllowed: Bool
    nonisolated let standardLifecycleAllowed: Bool
    var instances: [UUID: DesktopInstance] = [:]
    var events: [String] = []
    var unknownCount = 0
    var inventoryMutation: (@Sendable () async throws -> Void)?
    var ambiguous = false, permissions = true, windowAvailable = true
    var failLaunch = false, failQuit = false, timeoutExit = false, failInventory = false, failActivation = false
    var token = UUID()
    var evidenceOverride: DesktopActivationEvidence?
    var activatedEvidence: [DesktopActivationEvidence] = []
    var replaceAfterActivation = false
    var pidScope: PIDActivationScope?
    var pidConsumed = false, pidRefuses = false, pidWrongForeground = false
    var pidForeground: DesktopInstance?
    var axCalls = 0
    var failSecondQuit = false
    var operationScope: EnvironmentOperationScope?
    var operationHistory: [UUID] = []
    var operationActivated = false, operationLaunched = false
    var operationQuit = Set<UUID>()
    var scopedLaunchSpecifications: [DesktopLaunchSpecification] = []
    var badInstallation = false
    var noLaunchObservation = false
    var launchReadinessSamples: [Result<DesktopObservation, EnvironmentError>]?
    var preciseDispatch = false
    var beforeDispatchFailure: String?
    var nextLaunchGeneration: Int32 = 99
    var launcherStillRunning = false
    var orphanPIDs: Set<Int32> = []
    let dispatchLedger = EnvironmentDispatchLedger()
    func configurePreciseDispatch(failBefore: String? = nil) { preciseDispatch = true; beforeDispatchFailure = failBefore }
    init(primaryAllowed: Bool = false, lifecycle: Bool = true, environmentActivation: Bool = true) {
        standardLifecycleAllowed = primaryAllowed; lifecycleAllowed = lifecycle; environmentActivationAllowed = environmentActivation
    }
    func seed(_ associations: [EnvironmentAssociation], targetRunning: Bool = true) {
        for (i, a) in associations.enumerated() where targetRunning || i != 1 { instances[a.environmentID] = Self.instance(Int32(i)) }
    }
    static func instance(_ offset: Int32) -> DesktopInstance {
        let generation = DesktopGeneration(pid: 180_000 + offset, uid: getuid(), started: "synthetic generation \(offset)")
        return DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date().addingTimeInterval(-1))
    }
    func configure(unknown: Int = 0, ambiguous: Bool = false, permissions: Bool = true, window: Bool = true,
                   launch: Bool = false, quit: Bool = false, timeout: Bool = false, inventory: Bool = false, activation: Bool = false) {
        unknownCount = unknown; self.ambiguous = ambiguous; self.permissions = permissions; windowAvailable = window
        failLaunch = launch; failQuit = quit; timeoutExit = timeout; failInventory = inventory; failActivation = activation
    }
    func replace(_ a: EnvironmentAssociation) { instances[a.environmentID] = Self.instance(90) }
    func changeWindow() { token = UUID() }
    func configureReplacementAfterActivation() { replaceAfterActivation = true }
    func rejectSecondQuit() { failSecondQuit = true }
    var fingerprintMutation: (@Sendable () async throws -> Void)?
    var buildStamp = "c"
    func mutateNextFingerprint(_ body: @escaping @Sendable () async throws -> Void) { fingerprintMutation = body }
    func changeBuild() { buildStamp = "d" }
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint {
        if let mutation = fingerprintMutation { fingerprintMutation = nil; try await mutation() }
        return OpeningBuildFingerprint(version: "synthetic", build: "fixture", signingRequirement: "synthetic-only",
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: buildStamp, count: 64))
    }
    func validateInstallation() throws { if badInstallation { throw EnvironmentError.incompatibleBuild } }
    func mutateNextInventory(_ mutation: @escaping @Sendable () async throws -> Void) { inventoryMutation = mutation }
    func rejectInstallation() { badInstallation = true }
    func suppressLaunchedInstance() { noLaunchObservation = true }
    func observe(_ a: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        DesktopObservation(matching: instances[a.environmentID].map { [$0] } ?? [], ambiguous: ambiguous)
    }
    func instanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory {
        events.append("inventory")
        if let mutation = inventoryMutation { inventoryMutation = nil; try await mutation() }
        if failInventory { throw SwitchingError.processInspectionFailed }
        return DesktopInstanceInventory(entries: associations.compactMap { a in
            instances[a.environmentID].map { DesktopInventoryEntry(association: a, instance: $0) }
        }, unknownCount: unknownCount)
    }
    func activationEvidence(_ a: EnvironmentAssociation, instance: DesktopInstance) throws -> DesktopActivationEvidence {
        axCalls += 1
        if !permissions { throw EnvironmentError.missingPermissions }
        if let evidenceOverride { return evidenceOverride }
        return DesktopActivationEvidence(association: a, instance: instance, windowIDs: windowAvailable ? [1] : [],
            windowOwners: [instance.main], ownershipConfirmed: windowAvailable, windowToken: token)
    }
    func activate(_ evidence: DesktopActivationEvidence) throws {
        events.append("activate")
        activatedEvidence.append(evidence)
        if failActivation { throw EnvironmentError.activationUnavailable }
        if replaceAfterActivation { instances[evidence.association.environmentID] = Self.instance(91) }
    }
    func environmentActivationEvidence(_ a: EnvironmentAssociation, instance: DesktopInstance) throws -> DesktopActivationEvidence {
        try activationEvidence(a, instance: instance)
    }
    func activateEnvironment(_ evidence: DesktopActivationEvidence) throws { try activate(evidence) }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) throws {
        events.append("quit")
        if failQuit || (failSecondQuit && events.filter { $0 == "quit" }.count == 2) { throw SwitchingError.quitFailed }
        if !timeoutExit { instances.removeValue(forKey: association.environmentID) }
    }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) throws {
        events.append("wait")
        try expect(timeout == .seconds(10), "Finite normal exit deadline")
        if timeoutExit { throw SwitchingError.exitTimedOut }
    }
    func launch(_ specification: DesktopLaunchSpecification) throws {
        events.append("launch")
        if failLaunch { throw EnvironmentError.launchFailed }
        if !noLaunchObservation {
            instances[specification.association.environmentID] = Self.instance(nextLaunchGeneration)
            nextLaunchGeneration += 1
        }
    }
    var effects: [String] { events.filter { ["quit", "wait", "launch", "activate", "pidActivate"].contains($0) } }
}

extension OpeningSystem {
    func configurePID(_ scope: PIDActivationScope?, refuses: Bool = false, wrongForeground: Bool = false) {
        pidScope = scope; pidRefuses = refuses; pidWrongForeground = wrongForeground
    }
    func permitsPIDActivation(_ a: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async -> Bool {
        pidScope?.permits(a, revision: revision, instance: instance) == true
    }
    func activatePIDEnvironment(_ a: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async throws {
        guard !pidConsumed, pidScope?.permits(a, revision: revision, instance: instance) == true else { throw EnvironmentOpeningError.unavailable }
        pidConsumed = true; events.append("pidActivate")
        if pidRefuses { throw SwitchingError.activationFailed }
        pidForeground = pidWrongForeground ? Self.instance(50) : instance
    }
    func verifyPIDForeground(_ instance: DesktopInstance) async throws {
        guard pidForeground == instance else { throw SwitchingError.activationFailed }
    }
}

actor OpeningVerifier: DesktopAccountVerifying {
    var calls = 0, readinessCalls = 0
    var blocked = false, readiness = true, mismatch = false
    func configure(blocked: Bool = false, readiness: Bool = true, mismatch: Bool = false) {
        self.blocked = blocked; self.readiness = readiness; self.mismatch = mismatch
    }
    func validateLaunchReadiness(_ association: EnvironmentAssociation) throws {
        readinessCalls += 1
        if !readiness { throw AccountOpeningError.identityUnverified }
    }
    func verify(_ a: EnvironmentAssociation, instance: DesktopInstance) -> AccountVerification {
        calls += 1
        if mismatch { return .identityMismatch }
        return FixtureAccountVerifier(unavailable: blocked).verify(a, instance: instance)
    }
}
actor OpeningActivity: CodexActivityChecking {
    var status: CodexActivityStatus = .idle
    var scopedPIDs: [Int32] = []
    func set(_ value: CodexActivityStatus) { status = value }
    func checkActivity() throws -> CodexActivityStatus { throw CheckFailure(description: "Global status cannot prove scoped activity") }
    func checkActivity(for instance: DesktopInstance) -> CodexActivityStatus { scopedPIDs.append(instance.main.pid); return status }
}
actor OpeningConsent {
    var values: [AccountCloseConfirmation] = []
    func accept(_ value: AccountCloseConfirmation) -> AccountCloseDecision { values.append(value); return .confirm(allowPrimary: true) }
}

@MainActor
struct OpeningFixture {
    let f: AssociationFixture, system: OpeningSystem, verifier: OpeningVerifier, activity: OpeningActivity
    let driver: DesktopSwitchingDriver, coordinator: AccountSwitchingCoordinator
    var target: AccountProfile { f.profiles[1] }
    static func make(_ root: URL, targetRunning: Bool = true, primary: Bool = false, primaryAllowed: Bool = false) async throws -> Self {
        var f = try await AssociationFixture.make(root)
        if primary {
            _ = try await f.store.disconnectEnvironment(profileID: f.profiles[0].id)
            let home = f.userHome.appendingPathComponent(".codex"), electron = f.userHome.appendingPathComponent("Library/Application Support/Codex")
            try AssociationFixture.directory(home); try AssociationFixture.directory(electron)
            let a = try f.validator.link(profileID: f.profiles[0].id, environmentID: f.profiles[0].id,
                kind: .standardExternal, home: home.path, electron: electron.path)
            _ = try await f.store.linkEnvironment(a, validator: f.validator)
            f = AssociationFixture(root: f.root, userHome: f.userHome, store: f.store, validator: f.validator,
                profiles: f.profiles, associations: [a, f.associations[1]])
        }
        // Synthetic catalog only: exercise the current revision without any live metadata access.
        var catalog = try await f.store.inspectAssociations(); catalog.revision = 3
        try AtomicMetadataWriter().write(JSONEncoder().encode(catalog), to: f.validator.managedRoot.appendingPathComponent("environments.json"))
        let system = OpeningSystem(primaryAllowed: primaryAllowed), verifier = OpeningVerifier(), activity = OpeningActivity()
        await system.seed(f.associations, targetRunning: targetRunning)
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: verifier)
        return Self(f: f, system: system, verifier: verifier, activity: activity, driver: driver,
            coordinator: AccountSwitchingCoordinator(driver: driver, activityChecker: activity))
    }
    func open(_ mode: AccountOpeningMode = .openSeparately,
              consent: @Sendable (AccountCloseConfirmation) async -> AccountCloseDecision = { _ in .confirm(allowPrimary: false) }) async throws {
        try await coordinator.openAccount(to: target, mode: mode, confirmClose: consent)
    }
}

@MainActor
func openingError(_ expected: SwitchingError, _ body: () async throws -> Void) async throws {
    do { try await body(); throw CheckFailure(description: "Expected opening rejection \(expected)") }
    catch let error as SwitchingError { try expect(error == expected, "Expected \(expected), got \(error)") }
}

extension CoreChecks {
    @MainActor
    static func openingChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func scenario(_ name: String, running: Bool = true, primary: Bool = false, approved: Bool = false,
                      _ body: @escaping @MainActor (OpeningFixture) async throws -> Void) async {
            await run("Opening: " + name) {
                let f = try await OpeningFixture.make(base.appendingPathComponent("opening-" + UUID().uuidString),
                    targetRunning: running, primary: primary, primaryAllowed: approved)
                try await body(f)
            }
        }
        await scenario("existing target activates twice without duplicate, quit, inventory or activity") { f in
            try await f.open(); try await f.open()
            try expect(await f.system.effects == ["activate", "activate"], "Repeat selection revalidates existing instance")
            try expect(await !f.system.events.contains("inventory"), "Other instances are not involved")
            try expect(await f.activity.scopedPIDs.isEmpty, "No interruption query")
            try expect(await f.coordinator.openingResult == .activatedExisting(f.target.id), "Verified activation result")
        }
        await scenario("absent target launches once with other instance preserved", running: false) { f in
            let before = await f.system.instances[f.f.associations[0].environmentID]
            try await f.open()
            try expect(await f.system.effects == ["launch"], "Exactly one mock launch")
            try expect(await f.system.instances[f.f.associations[0].environmentID] == before, "Other account untouched")
            try expect(await f.coordinator.openingResult == .launched(f.target.id), "Verified launched result")
        }
        await scenario("launch failure consumes attempt and blocks repeat without rollback", running: false) { f in
            await f.system.configure(launch: true)
            try await openingError(.opening(.launchFailure)) { try await f.open() }
            try await openingError(.opening(.recoveryRequired)) { try await f.open() }
            try expect(await f.system.effects == ["launch"], "No retry/rollback")
            try expect(await f.coordinator.openingResult == nil, "No success")
        }
        for (name, permissions, window, expected) in [
            ("window ambiguity", true, false, AccountOpeningError.windowUnavailable),
            ("missing Accessibility permission", false, true, .missingPermissions)
        ] {
            await scenario(name) { f in
                await f.system.configure(permissions: permissions, window: window)
                try await openingError(.opening(expected)) { try await f.open() }
                try expect(await f.system.effects.isEmpty, "No random activation or launch fallback")
            }
        }
        await scenario("wrong account proof blocks dispatch") { f in
            await f.verifier.configure(mismatch: true)
            try await openingError(.environment(.accountMismatch)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "Account mismatch cannot pass")
        }
        await scenario("unverified account proof blocks dispatch") { f in
            await f.verifier.configure(blocked: true)
            try await openingError(.opening(.identityUnverified)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "No action")
        }
        await scenario("absent target needs identity readiness before closing anything", running: false) { f in
            await f.verifier.configure(readiness: false)
            try await openingError(.opening(.identityUnverified)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects.isEmpty, "No speculative launch or interruption")
        }
        await scenario("unlinked target reports typed rejection") { f in
            _ = try await f.f.store.disconnectEnvironment(profileID: f.target.id)
            try await openingError(.opening(.targetNotLinked)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "No action")
        }
        await scenario("foreign profile UUID is rejected") { f in
            do { try await f.coordinator.openAccount(to: AccountProfile(name: "Other"), mode: .openSeparately); throw CheckFailure(description: "Foreign profile accepted") }
            catch SwitchingError.validationFailed {}
            try expect(await f.system.effects.isEmpty, "No action")
        }
        await scenario("two known instances close other and activate target") { f in
            let consent = OpeningConsent()
            try await f.open(.closeOthersAndOpen) { await consent.accept($0) }
            try expect(await f.system.effects == ["quit", "wait", "activate"], "Normal addressed quit then activation")
            let values = await consent.values
            try expect(values.count == 1 && values[0].affected.count == 1 && values[0].target.id == f.target.id, "Explicit exact list")
            try expect(await f.activity.scopedPIDs.allSatisfy { $0 == 180_000 }, "Activity scoped to affected process")
        }
        await scenario("closed target is preflighted then launched", running: false) { f in
            try await f.open(.closeOthersAndOpen)
            try expect(await f.system.effects == ["quit", "wait", "launch"], "Launch last after validated exit")
        }
        await scenario("third unbound A blocks entire close operation") { f in
            await f.system.configure(unknown: 1)
            try await openingError(.opening(.unknownInstances)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects.isEmpty, "Retained A is neither ignored nor terminated")
        }
        for status in [CodexActivityStatus.unknown(.incompleteCoverage), .assess(operations: [.init(location: .local, kind: .runningTurn)], coverageComplete: true, fresh: true)] {
            await scenario("non-idle activity requires explicit confirmation: \(status)") { f in
                await f.activity.set(status)
                let consent = OpeningConsent()
                try await f.open(.closeOthersAndOpen) { await consent.accept($0) }
                try expect(await consent.values.first?.activities == [status], "Unknown/Busy is visible and not treated as Idle")
            }
        }
        await scenario("Cancel leaves all instances unchanged") { f in
            try await openingError(.opening(.userCancelled)) { try await f.open(.closeOthersAndOpen) { _ in .cancel } }
            try expect(await f.system.effects.isEmpty, "No close on simple selection")
            try expect(await f.coordinator.state == .cancelled, "Cancellation state")
            try await f.open() // Cancel did not consume an external action.
        }
        await scenario("ambiguous process blocks all operations") { f in
            await f.system.configure(ambiguous: true)
            try await openingError(.opening(.ambiguousInstance)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects.isEmpty, "No PID/bundle-only dispatch")
        }
        await scenario("normal termination failure stops before activation") { f in
            await f.system.configure(quit: true)
            try await openingError(.quitFailed) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects == ["quit"], "No force quit, retry or launch")
            try expect(await f.coordinator.openingDisposition == .recoveryRequired, "Possibly delivered action retained")
        }
        await scenario("exit timeout stops before activation") { f in
            await f.system.configure(timeout: true)
            try await openingError(.opening(.terminationTimeout)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects == ["quit", "wait"], "No force termination")
        }
        await scenario("launch failure after confirmed close exposes partial completion", running: false) { f in
            await f.system.configure(launch: true)
            try await openingError(.opening(.launchFailure)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.coordinator.openingDisposition == .partialCompletion, "Partial result separate from precise cause")
            try expect(await f.coordinator.openingProgress.closedProfileIDs == [f.f.profiles[0].id], "Exact confirmed closure recorded")
            try expect(await f.system.effects == ["quit", "wait", "launch"], "No automatic restoration")
        }
        await scenario("process generation changes after confirmation") { f in
            try await openingError(.opening(.processChanged)) {
                try await f.open(.closeOthersAndOpen) { _ in
                    await f.system.replace(f.f.associations[0]); return .confirm(allowPrimary: false)
                }
            }
            try expect(await f.system.effects.isEmpty, "Fresh generation check before first quit")
        }
        await scenario("window identity changes after confirmation") { f in
            try await openingError(.opening(.windowUnavailable)) {
                try await f.open(.closeOthersAndOpen) { _ in await f.system.changeWindow(); return .confirm(allowPrimary: false) }
            }
            try expect(await f.system.effects.isEmpty, "No other instance closed for an unusable target window")
        }
        await scenario("inventory recheck failure stops before quit") { f in
            try await openingError(.processInspectionFailed) {
                try await f.open(.closeOthersAndOpen) { _ in await f.system.configure(inventory: true); return .confirm(allowPrimary: false) }
            }
            try expect(await f.system.effects.isEmpty, "Failed inventory is not empty inventory")
        }
        await scenario("primary adapter gate blocks even with confirmation", primary: true) { f in
            try await openingError(.opening(.primaryConsentRequired)) { try await f.open(.closeOthersAndOpen) { _ in .confirm(allowPrimary: true) } }
            try expect(await f.system.effects.isEmpty, "Independent primary release gate")
        }
        await scenario("approved mock primary still requires explicit primary consent", primary: true, approved: true) { f in
            try await openingError(.opening(.primaryConsentRequired)) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.system.effects.isEmpty, "General confirmation is insufficient")
        }
        await scenario("approved mock primary with explicit consent can close", primary: true, approved: true) { f in
            try await f.open(.closeOthersAndOpen) { _ in .confirm(allowPrimary: true) }
            try expect(await f.system.effects == ["quit", "wait", "activate"], "Two independent mock approvals")
        }
        await scenario("primary existing target can activate without primary lifecycle approval", primary: true) { f in
            try await f.coordinator.openAccount(to: f.f.profiles[0], mode: .openSeparately)
            try expect(await f.system.effects == ["activate"], "Primary activation is separate from primary restart")
        }
        await scenario("recheck activity after consent requires renewed confirmation") { f in
            let consent = OpeningConsent()
            try await f.open(.closeOthersAndOpen) { value in
                let decision = await consent.accept(value)
                await f.activity.set(.unknown(.staleEvidence))
                return decision
            }
            try expect(await consent.values.count == 2, "Changed activity reconsented")
            try expect(await f.system.effects == ["quit", "wait", "activate"], "Only after stable consent")
        }
        await scenario("shared busy gate rejects overlapping choice") { f in
            try await f.open(.closeOthersAndOpen) { _ in
                do { try await f.open(); throw CheckFailure(description: "Concurrent choice accepted") }
                catch SwitchingError.opening(.busy) {}
                catch { return .cancel }
                return .confirm(allowPrimary: false)
            }
            try expect(await f.system.effects == ["quit", "wait", "activate"], "Only first choice dispatches")
        }
        await scenario("profiles UUID revision3 bindings and data survive both modes") { f in
            let profiles = try await f.f.store.inspect(), associations = try await f.f.store.inspectAssociations()
            let sentinel = f.f.userHome.appendingPathComponent("user-data.fixture")
            try AssociationFixture.directory(f.f.userHome)
            try Data("synthetic user data".utf8).write(to: sentinel)
            let urls = ["profiles.json", "environments.json", "environments.backup.json"].map { f.f.validator.managedRoot.appendingPathComponent($0) }
            let bytes = try urls.map { try Data(contentsOf: $0) }
            try await f.open(); try await f.open(.closeOthersAndOpen)
            try expect(try await ProfileStore(root: f.f.validator.managedRoot).inspect() == profiles, "Exact profiles and UUIDs reload")
            try expect(try await f.f.store.inspectAssociations() == associations && associations.revision == 3, "Exact revision3 bindings")
            try expect(try urls.map { try Data(contentsOf: $0) } == bytes, "Metadata byte equality")
            try expect(try Data(contentsOf: sentinel) == Data("synthetic user data".utf8), "User data retained")
        }
        await scenario("second quit failure preserves exact partial progress") { f in
            let third = try await f.f.store.create(name: "Synthetic third").profiles[2]
            let a = try await f.f.store.prepareManagedEnvironment(profileID: third.id)
            _ = try await f.f.store.linkEnvironment(a, validator: f.f.validator)
            await f.system.seed(f.f.associations + [a]); await f.system.rejectSecondQuit()
            try await openingError(.quitFailed) { try await f.open(.closeOthersAndOpen) }
            try expect(await f.coordinator.openingProgress.closedProfileIDs == [f.f.profiles[0].id], "Only confirmed exit counted")
            try expect(await f.coordinator.openingDisposition == .partialCompletion, "Partial multi-close explicitly exposed")
            try expect(await f.system.effects == ["quit", "wait", "quit"], "No target dispatch, retries or restoration")
        }
        await scenario("target PID changes after plan prevents activation") { f in
            let plan = try await f.driver.planOpening(profile: f.target, mode: .openSeparately)
            await f.system.replace(f.f.associations[1])
            do { try await f.driver.recheckOpening(plan, remaining: []); throw CheckFailure(description: "Changed PID accepted") }
            catch AccountOpeningError.processChanged {}
            try expect(await f.system.effects.isEmpty, "No activation or replacement launch")
        }
        await scenario("concurrent metadata change after confirmation is retained and blocks quit") { f in
            try await openingError(.opening(.processChanged)) {
                try await f.open(.closeOthersAndOpen) { _ in
                    do { _ = try await f.f.store.rename(id: f.f.profiles[0].id, name: "Changed fixture") }
                    catch { return .cancel }
                    return .confirm(allowPrimary: false)
                }
            }
            try expect(await f.system.effects.isEmpty, "No action under stale catalog")
            try expect(try await f.f.store.inspect().profiles[0].name == "Changed fixture", "Concurrent edit not rolled back")
        }
        await scenario("post-activation failure never reports success or launches fallback") { f in
            await f.system.configure(activation: true)
            try await openingError(.opening(.windowUnavailable)) { try await f.open() }
            try expect(await f.system.effects == ["activate"], "Only attempted activation")
            try expect(await f.coordinator.openingResult == nil, "No false success")
            try expect(await f.coordinator.openingDisposition == .recoveryRequired, "Action requires review")
        }
        await scenario("overlapping child attribution blocks full inventory") { f in
            let generation = OpeningSystem.instance(0)
            let other = OpeningSystem.instance(1)
            let overlapping = DesktopInstance(main: other.main, related: [other.main, generation.main], nativeLaunchDate: other.nativeLaunchDate)
            let inventory = DesktopInstanceInventory(entries: [
                .init(association: f.f.associations[0], instance: generation), .init(association: f.f.associations[1], instance: overlapping)
            ], unknownCount: 0)
            do { try inventory.validate(); throw CheckFailure(description: "Shared helper accepted") }
            catch AccountOpeningError.ambiguousInstance {}
        }
        await scenario("production native inventory and launch readiness remain gated") { f in
            let native = NativeDesktopSystem()
            try expect(!DesktopIntegrationPolicy.lifecycleEnabled && !DesktopIntegrationPolicy.primaryLifecycleEnabled, "No runtime unlock")
            try await environmentError(.releaseGateClosed) { _ = try await native.instanceInventory(associations: f.f.associations) }
            do { try await AccountIdentityVerifier().validateLaunchReadiness(f.f.associations[1]); throw CheckFailure(description: "Unsupported readiness accepted") }
            catch AccountOpeningError.identityUnverified {}
            try expect(ConnectionPresentation.state(association: f.f.associations[1]) == .verificationRequired, "Linked is not verified")
        }
    }
}

extension OpeningSystem {
    func authorizeEnvironmentOperation(_ scope: EnvironmentOperationScope, allowPrimary: Bool) throws {
        guard operationScope == nil else { throw AccountOpeningError.busy }
        try scope.validate()
        guard allowPrimary || !scope.others.contains(where: { $0.association.kind == .standardExternal }) else { throw AccountOpeningError.primaryConsentRequired }
        operationScope = scope; operationHistory.append(scope.id)
        operationActivated = false; operationLaunched = false; operationQuit = []
    }
    func scriptLaunchReadiness(_ samples: [Result<DesktopObservation, EnvironmentError>]) { launchReadinessSamples = samples }
    func nextLaunchSample(_ association: EnvironmentAssociation, timeout: Duration) throws -> DesktopObservation {
        precondition(timeout > .zero)
        guard var samples = launchReadinessSamples, !samples.isEmpty else { throw EnvironmentError.launchFailed }
        let sample = samples.count > 1 ? samples.removeFirst() : samples[0]
        launchReadinessSamples = samples
        let observation = try sample.get()
        if let instance = try observation.unique() { instances[association.environmentID] = instance }
        return observation
    }
    func requireScope(_ scope: EnvironmentOperationScope) throws {
        try scope.validate()
        guard operationScope == scope else { throw EnvironmentOpeningError.confirmationRequired }
    }
    func activateScopedEnvironment(_ scope: EnvironmentOperationScope, instance: DesktopInstance) throws {
        try requireScope(scope)
        guard !operationActivated, instances[scope.target.environmentID] == instance else { throw AccountOpeningError.processChanged }
        if beforeDispatchFailure == "activate" { throw AccountOpeningError.processChanged }
        dispatchLedger.mark(scope.id, effect: .activation(instance))
        operationActivated = true; events.append("pidActivate")
        if failActivation { throw SwitchingError.activationFailed }
        pidForeground = pidWrongForeground ? Self.instance(50) : instance
        if replaceAfterActivation { instances[scope.target.environmentID] = Self.instance(91) }
    }
    func launchScopedEnvironment(_ scope: EnvironmentOperationScope) async throws -> DesktopInstance {
        try requireScope(scope)
        guard !operationLaunched, scope.targetInstance == nil, instances[scope.target.environmentID] == nil else { throw AccountOpeningError.processChanged }
        if beforeDispatchFailure == "launch" { throw AccountOpeningError.processChanged }
        dispatchLedger.mark(scope.id, effect: .launch)
        operationLaunched = true
        let specification = try DesktopLaunchSpecification(association: scope.target, allowStandardExternal: true)
        scopedLaunchSpecifications.append(specification)
        try launch(specification)
        if launchReadinessSamples != nil {
            return try await DesktopReadiness.wait(timeout: .milliseconds(100), interval: .milliseconds(1)) {
                try await self.nextLaunchSample(scope.target, timeout: $0)
            }
        }
        guard let instance = instances[scope.target.environmentID] else { throw EnvironmentError.launchFailed }
        return instance
    }
    func quitScopedEnvironment(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) throws {
        try requireScope(scope)
        guard scope.mode == .closeOthersAndOpen, scope.others.contains(item),
              operationQuit.insert(item.association.environmentID).inserted else { throw EnvironmentOpeningError.stalePlan }
        if beforeDispatchFailure == "quit" { throw AccountOpeningError.processChanged }
        dispatchLedger.mark(scope.id, effect: .normalQuit(item.instance))
        try requestNormalQuit(item.instance, association: item.association)
    }
    func environmentEffectDisposition(_ id: UUID) -> EnvironmentEffectDisposition {
        preciseDispatch ? dispatchLedger.disposition(for: id) : .unknown
    }
    func configureUnsettled(launcher: Bool = false, orphans: Set<Int32> = []) {
        launcherStillRunning = launcher; orphanPIDs = orphans
    }
    func confirmEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, inventoryAssociations: [EnvironmentAssociation]) async throws {
        guard preciseDispatch, operationScope == nil else { throw AccountOpeningError.recoveryRequired }
        let inventory = try await environmentInstanceInventory(associations: inventoryAssociations)
        let live = Set(instances.values.flatMap { $0.related.map(\.pid) }).union(orphanPIDs)
        try EnvironmentRecoveryProof.validate(scope: scope, effects: dispatchLedger.effects(for: scope.id),
            inventory: inventory, livePIDs: live, launcherRunning: launcherStillRunning)
    }
    func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect], inventoryAssociations: [EnvironmentAssociation]) async throws {
        guard preciseDispatch, operationScope == nil else { throw AccountOpeningError.recoveryRequired }
        let inventory = try await environmentInstanceInventory(associations: inventoryAssociations)
        let live = Set(instances.values.flatMap { $0.related.map(\.pid) }).union(orphanPIDs)
        try EnvironmentRecoveryProof.validate(scope: scope, effects: effects,
            inventory: inventory, livePIDs: live, launcherRunning: launcherStillRunning)
    }
    func waitForScopedExit(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) throws {
        try requireScope(scope)
        guard operationQuit.contains(item.association.environmentID) else { throw EnvironmentOpeningError.stalePlan }
        try waitForExit(item.instance, association: item.association, timeout: .seconds(10))
    }
    func finishEnvironmentOperation(_ id: UUID) {
        guard operationScope?.id == id else { return }
        operationScope = nil
    }
}
