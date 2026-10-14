import Foundation
import Darwin
import CodexSwoopCore

actor FixtureIdentityReader: AccountIdentityReading {
    enum Behavior: Sendable {
        case account(AccountIdentityKey?), signedOut, expired, failure, unavailable
        case routed(RoutedAccountIdentity)
    }
    let behavior: Behavior
    var calls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    func read(_ request: AccountIdentityRequest) throws -> IdentityReadResult {
        calls += 1
        switch behavior {
        case let .account(key): return .response(RoutedAccountIdentity(request: request, key: key, authenticated: true))
        case .signedOut: return .response(RoutedAccountIdentity(request: request, key: nil, authenticated: false))
        case .expired: throw IdentityReadError.authenticationExpired
        case .failure: throw CheckFailure(description: "Sensitive transport detail must not escape")
        case .unavailable: return .unavailable
        case let .routed(response): return .response(response)
        }
    }
}

actor FixtureActivationSystem: DesktopSystem {
    nonisolated let lifecycleAllowed = true
    enum Mode: Sendable { case confirmed, ambiguous, wrongOwner, unconfirmed, noWindows, stale, failure }
    var mode: Mode = .confirmed
    var instances: [UUID: DesktopInstance] = [:]
    var events: [String] = []
    func set(_ association: EnvironmentAssociation, _ instance: DesktopInstance?) { instances[association.environmentID] = instance }
    func configure(_ mode: Mode) { self.mode = mode }
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint {
        OpeningBuildFingerprint(version: "synthetic", build: "fixture", signingRequirement: "synthetic-only",
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: "c", count: 64))
    }
    func validateInstallation() { events.append("build") }
    func observe(_ association: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        events.append("observe")
        let instances = instances[association.environmentID].map { [$0] } ?? []
        return DesktopObservation(matching: mode == .ambiguous ? instances + instances : instances, ambiguous: mode == .ambiguous)
    }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) { events.append("quit") }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) { events.append("wait") }
    func launch(_ specification: DesktopLaunchSpecification) { events.append("launch") }
    func activationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) -> DesktopActivationEvidence {
        events.append("windows")
        let wrong = DesktopGeneration(pid: instance.main.pid + 1, uid: getuid(), started: "other fixture")
        return DesktopActivationEvidence(association: association, instance: instance,
            windowIDs: mode == .noWindows ? [] : [1, 2],
            windowOwners: mode == .wrongOwner ? [wrong] : [instance.main], ownershipConfirmed: mode != .unconfirmed,
            observedAt: Date().addingTimeInterval(mode == .stale ? -10 : 0))
    }
    func activate(_ evidence: DesktopActivationEvidence) throws {
        events.append("activate")
        if mode == .failure { throw EnvironmentError.activationUnavailable }
    }
}
struct FixtureFixedProof: DesktopAccountVerifying {
    let proof: AccountVerification
    func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) -> AccountVerification { proof }
}
actor CountingUnknownChecker: CodexActivityChecking {
    var calls = 0
    func checkActivity() -> CodexActivityStatus { calls += 1; return .unknown(.desktopConnectionUnverified) }
}

extension CoreChecks {
    @MainActor
    static func readinessChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        func root(_ name: String) -> URL { base.appendingPathComponent("readiness-" + name) }
        func key(_ subject: String = "fixture-subject") throws -> AccountIdentityKey { try AccountIdentityKey(namespace: "synthetic-subject-v1", subject: subject) }
        func fresh(_ name: String, writer: AtomicMetadataWriter = AtomicMetadataWriter()) async throws -> (ProfileStore, AccountProfile, URL) {
            let path = root(name), store = ProfileStore(root: path, writer: writer)
            let profile = try await store.create(name: "Fixture Work").profiles[0]
            return (store, profile, path)
        }
        await run("Identity: routed matching subject yields a fresh generation-bound proof") {
            let f = try await AssociationFixture.make(root("identity-success")), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
            let verifier = AccountIdentityVerifier(reader: FixtureIdentityReader(.account(try key())),
                expected: [ExpectedAccountIdentity(association: request.association, key: try key())])
            let result = try await verifier.assess(request)
            try expect(result.state == .verified && result.proof.confirms(request.association, instance: request.instance), "Verified only with independent expected subject and routing")
            try expect(String(describing: try key()) == "<account identity>", "No raw subject in diagnostics")
        }
        for (name, behavior, state) in [
            ("missing subject", FixtureIdentityReader.Behavior.account(nil), AccountIdentityState.unverified),
            ("transport failure", .failure, .verificationError), ("expired authorization", .expired, .authenticationRequired),
            ("signed out", .signedOut, .authenticationRequired), ("unavailable mechanism", .unavailable, .verificationUnavailable)
        ] {
            await run("Identity: " + name) {
                let f = try await AssociationFixture.make(root("identity-" + state.rawValue + name)), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
                let result = try await AccountIdentityVerifier(reader: FixtureIdentityReader(behavior)).assess(request)
                try expect(result.state == state && !result.proof.confirms(request.association, instance: request.instance), "No false verified result")
            }
        }
        await run("Identity: subject mismatch differs from missing independent anchor") {
            let f = try await AssociationFixture.make(root("identity-mismatch")), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
            let reader = FixtureIdentityReader(.account(try key("wrong")))
            let verifier = AccountIdentityVerifier(reader: reader, expected: [ExpectedAccountIdentity(association: request.association, key: try key())])
            try expect(try await verifier.assess(request).state == .identityMismatch, "Mismatch explicit")
            try expect(try await AccountIdentityVerifier(reader: reader).assess(request).state == .unverified, "Never self-enroll a received subject")
        }
        await run("Identity: another profile's correctly authenticated response is rejected") {
            let f = try await AssociationFixture.make(root("identity-cross-profile")), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
            let other = AccountIdentityRequest(association: f.associations[1], instance: f.sourceInstance)
            let reader = FixtureIdentityReader(.routed(RoutedAccountIdentity(request: other, key: try key(), authenticated: true)))
            let verifier = AccountIdentityVerifier(reader: reader, expected: [ExpectedAccountIdentity(association: request.association, key: try key())])
            try expect(try await verifier.assess(request).state == .verificationError, "Cross-profile routing cannot be trusted")
        }
        await run("Identity: stale and future responses fail even when subjects match") {
            let f = try await AssociationFixture.make(root("identity-stale")), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
            for offset in [-10.0, 10.0] {
                let reader = FixtureIdentityReader(.routed(RoutedAccountIdentity(request: request, key: try key(), authenticated: true,
                    checkedAt: Date().addingTimeInterval(offset), expiresAt: Date().addingTimeInterval(20))))
                try expect(try await AccountIdentityVerifier(reader: reader).assess(request).state == .verificationError, "Freshness required")
            }
        }
        await run("Identity: manual confirmation and default bridge cannot enable Connected") {
            let f = try await AssociationFixture.make(root("identity-manual")), association = f.associations[0]
            let manual = ManualAccountConfirmation(association: association)
            try expect(manual.profileID == association.profileID && manual.environmentID == association.environmentID, "Informational note scoped")
            try expect(try await AccountIdentityVerifier().assess(AccountIdentityRequest(association: association, instance: f.sourceInstance)).state == .verificationUnavailable, "Production no I/O bridge")
            try expect(ConnectionPresentation.state(association: association, instance: f.sourceInstance) == .verificationRequired, "No manual proof")
        }
        await run("Identity: cancellation prevents even a synthetic reader call") {
            let f = try await AssociationFixture.make(root("identity-cancel")), reader = FixtureIdentityReader(.unavailable)
            let attempt = Task { @MainActor in
                while !Task.isCancelled { await Task.yield() }
                return try await AccountIdentityVerifier(reader: reader).assess(AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance))
            }
            attempt.cancel()
            do { _ = try await attempt.value; throw CheckFailure(description: "Cancellation ignored") }
            catch is CancellationError {}
            try expect(await reader.calls == 0, "No request after cancellation")
        }
        await run("Managed: private UUID storage persists without changing profile bytes or binding") {
            let (store, profile, path) = try await fresh("managed-create")
            let bytes = try Data(contentsOf: path.appendingPathComponent("profiles.json"))
            let value = try await store.prepareManagedEnvironment(profileID: profile.id)
            try EnvironmentValidator(managedRoot: path).revalidate(value)
            try expect(value.kind == .managed && value.environmentID == profile.id, "Immutable UUID path")
            try expect(value.homeIdentity.permissions == 0o700 && value.electronIdentity.owner == getuid(), "Private owned pair")
            try expect(try Data(contentsOf: path.appendingPathComponent("profiles.json")) == bytes, "Legacy bytes unchanged")
            try expect(try await store.inspectAssociations().associations.isEmpty, "Preparation does not bind")
            try expect(try await ProfileStore(root: path).inspectManagedEnvironments().prepared == [value], "Persistent marker reloads")
            _ = try await store.removeRecord(id: profile.id)
            try expect(try await store.inspect().profiles.isEmpty, "Prepared profile removed; directories retained")
        }
        await run("Managed: repeat creation never overwrites populated or empty storage") {
            let (store, profile, _) = try await fresh("managed-repeat"), value = try await store.prepareManagedEnvironment(profileID: profile.id)
            let sentinel = URL(fileURLWithPath: value.codexHome).appendingPathComponent("benign-fixture")
            try Data("retain".utf8).write(to: sentinel)
            try await environmentError(.environmentPrepared) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try String(contentsOf: sentinel, encoding: .utf8) == "retain", "No cleanup or overwrite")
        }
        await run("Managed: missing directory is rejected on recheck and never recreated") {
            let (store, profile, path) = try await fresh("managed-missing"), value = try await store.prepareManagedEnvironment(profileID: profile.id)
            try fm.removeItem(atPath: value.electronData)
            try await environmentError(.missingDirectory) { try EnvironmentValidator(managedRoot: path).revalidate(value) }
            try await environmentError(.environmentPrepared) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(!fm.fileExists(atPath: value.electronData), "No implicit repair")
        }
        await run("Managed: unsafe store root is refused without permission repair") {
            let (store, profile, path) = try await fresh("managed-root-mode")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            try await environmentError(.unsafeDirectory) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try EnvironmentValidator().directory(path.path, privateOnly: false).permissions == 0o755, "Store preflight never repairs permissions")
        }
        await run("Managed: unsafe reserved directory mode is rejected without repair") {
            let (store, profile, path) = try await fresh("managed-mode"), directory = path.appendingPathComponent("Profiles/\(profile.directoryIdentifier)")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try await environmentError(.unsafeDirectory) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try EnvironmentValidator().directory(directory.path, privateOnly: false).permissions == 0o755, "No permission rewrite")
        }
        await run("Managed: symlink outside reservation rejects before creating either child") {
            let (store, profile, path) = try await fresh("managed-symlink"), directory = path.appendingPathComponent("Profiles/\(profile.directoryIdentifier)")
            let outside = root("outside"); try AssociationFixture.directory(outside)
            try fm.removeItem(at: directory); try fm.createSymbolicLink(at: directory, withDestinationURL: outside)
            try await environmentError(.unsafeDirectory) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "No symlink escape")
        }
        await run("Managed: concurrent actors allow at most one successful preparation") {
            let (store, profile, path) = try await fresh("managed-race"), other = ProfileStore(root: path)
            let attempts = [Task { try await store.prepareManagedEnvironment(profileID: profile.id) }, Task { try await other.prepareManagedEnvironment(profileID: profile.id) }]
            var successes = 0
            for attempt in attempts {
                do { _ = try await attempt.value; successes += 1 }
                catch ProfileError.storeBusy {} catch EnvironmentError.environmentPrepared {}
            }
            let retained = try await store.inspectManagedEnvironments()
            try expect(successes == 1 && retained.prepared.count == 1, "Cooperating writers serialize with flock")
        }
        await run("Managed: cancellation before preparation leaves metadata and children absent") {
            let (store, profile, path) = try await fresh("managed-cancel")
            let attempt = Task { @MainActor in
                while !Task.isCancelled { await Task.yield() }
                return try await store.prepareManagedEnvironment(profileID: profile.id)
            }
            attempt.cancel()
            do { _ = try await attempt.value; throw CheckFailure(description: "Cancellation ignored") } catch is CancellationError {}
            try expect(!fm.fileExists(atPath: path.appendingPathComponent("managed-environments.json").path), "No metadata commit")
            try expect(!fm.fileExists(atPath: path.appendingPathComponent("Profiles/\(profile.directoryIdentifier)/codex-home").path), "No directory creation")
        }
        await run("Managed: atomic metadata failure retains empty storage without a false record") {
            let (store, profile, path) = try await fresh("managed-io")
            let fault = ProfileStore(root: path, writer: AtomicMetadataWriter(beforeReplace: { destination in
                if destination.lastPathComponent == "managed-environments.json" { throw ProfileError.storageUnavailable }
            }))
            try await expectError(.storageUnavailable) { _ = try await fault.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try await store.inspectManagedEnvironments().prepared.isEmpty, "Failed commit not visible")
            _ = try await store.removeRecord(id: profile.id)
            try expect(try await store.inspect().profiles.isEmpty, "Prepared profile removed; directories retained")
            try await expectError(.missingProfile) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
        }
        await run("Managed: corrupt metadata explicit recovery retains directories and old UUIDs") {
            let (store, first, path) = try await fresh("managed-recover")
            _ = try await store.prepareManagedEnvironment(profileID: first.id)
            let second = try await store.create(name: "Fixture Second").profiles[1]
            let value = try await store.prepareManagedEnvironment(profileID: second.id)
            let metadata = path.appendingPathComponent("managed-environments.json")
            try Data("invalid".utf8).write(to: metadata)
            try await environmentError(.invalidMetadata) { _ = try await store.inspectManagedEnvironments() }
            try expect(try await store.recoverManagedEnvironmentBackup().prepared.map(\.profileID) == [first.id], "Previous snapshot restored")
            try expect(fm.fileExists(atPath: value.codexHome), "Recovered metadata does not erase prepared data")
            _ = try await store.removeRecord(id: second.id)
            try expect(fm.fileExists(atPath: value.codexHome), "Unregistered retained data survives removal")
        }
        await run("Managed: unsupported schema and corrupt recovery backup fail closed") {
            let (store, profile, path) = try await fresh("managed-future")
            _ = try await store.prepareManagedEnvironment(profileID: profile.id)
            let metadata = path.appendingPathComponent("managed-environments.json")
            try Data("{\"schemaVersion\":99}".utf8).write(to: metadata)
            try await environmentError(.unsupportedSchema) { _ = try await store.recoverManagedEnvironmentBackup() }
            try Data("invalid".utf8).write(to: metadata)
            let backup = path.appendingPathComponent("managed-environments.backup.json")
            try Data("invalid".utf8).write(to: backup); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try await environmentError(.invalidMetadata) { _ = try await store.recoverManagedEnvironmentBackup() }
        }
        await run("Managed: filesystem child collision retains all existing files") {
            let (store, profile, path) = try await fresh("managed-file")
            let file = path.appendingPathComponent("Profiles/\(profile.directoryIdentifier)/electron-user-data")
            try Data("fixture".utf8).write(to: file)
            try await environmentError(.environmentPrepared) { _ = try await store.prepareManagedEnvironment(profileID: profile.id) }
            try expect(try Data(contentsOf: file) == Data("fixture".utf8), "Existing reservation not overwritten")
        }
        await run("Activation: A to B to A has no quit, launch, activity query or interruption warning") {
            let f = try await AssociationFixture.make(root("activation-roundtrip")), system = FixtureActivationSystem(), checker = CountingUnknownChecker()
            for (i, association) in f.associations.enumerated() {
                let gen = DesktopGeneration(pid: 130_000 + Int32(i), uid: getuid(), started: "fixture \(i)")
                await system.set(association, DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-10)))
            }
            let before = try await f.store.inspectAssociations()
            for profile in [f.profiles[1], f.profiles[0]] {
                let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
                let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: checker)
                try await coordinator.switchAccount(to: profile, workInterruptionConfirmed: false)
                try expect(await coordinator.state == .active(profile.id), "Matching existing instance verified after activation")
            }
            try expect(await system.events.filter { $0 == "activate" }.count == 2, "Two mock activations")
            try expect(await !system.events.contains(where: { ["launch", "quit", "wait"].contains($0) }), "Activation branch cannot enter restart branch")
            try expect(await checker.calls == 0, "No potentially interrupting operation")
            try expect(try await f.store.inspectAssociations() == before, "References unchanged")
        }
        for (name, mode, expected) in [
            ("multiple instances", FixtureActivationSystem.Mode.ambiguous, EnvironmentError.ambiguousInstance),
            ("wrong window owner", .wrongOwner, .activationUnavailable), ("unconfirmed window", .unconfirmed, .activationUnavailable),
            ("no windows", .noWindows, .activationUnavailable), ("stale window evidence", .stale, .activationUnavailable)
        ] {
            await run("Activation: " + name + " blocks before dispatch") {
                let f = try await AssociationFixture.make(root("activation-" + name)), system = FixtureActivationSystem()
                await system.set(f.associations[0], f.sourceInstance); await system.configure(mode)
                let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
                try await environmentError(expected) { try await driver.validate(profile: f.profiles[0]) }
                try expect(await !system.events.contains("activate"), "No action on ambiguous ownership")
            }
        }
        await run("Activation: target absent chooses launch strategy and never invents a window") {
            let f = try await AssociationFixture.make(root("activation-missing")), system = FixtureActivationSystem()
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system)
            try await driver.validate(profile: f.profiles[0])
            try expect(try await driver.strategy() == .launch, "Missing managed target is separate from activation")
            try await environmentError(.activationUnavailable) { try await driver.activate(profile: f.profiles[0]) }
            try expect(await !system.events.contains("activate"), "No fallback activation")
        }
        await run("Activation: process generation change between validation and action prevents dispatch") {
            let f = try await AssociationFixture.make(root("activation-pid-change")), system = FixtureActivationSystem()
            await system.set(f.associations[0], f.sourceInstance)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
            try await driver.validate(profile: f.profiles[0])
            let gen = DesktopGeneration(pid: 140_001, uid: getuid(), started: "replacement")
            await system.set(f.associations[0], DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-1)))
            try await environmentError(.processChanged) { try await driver.activate(profile: f.profiles[0]) }
            try expect(await !system.events.contains("activate"), "No PID-only activation")
        }
        await run("Activation: wrong profile evidence cannot pass a matching process check") {
            let f = try await AssociationFixture.make(root("activation-wrong-profile")), instance = f.sourceInstance
            let evidence = DesktopActivationEvidence(association: f.associations[1], instance: instance, windowIDs: [1], windowOwners: [instance.main], ownershipConfirmed: true)
            try await environmentError(.activationUnavailable) { try evidence.validate(association: f.associations[0], instance: instance) }
        }
        for (name, proof, error) in [("signed out", AccountVerification.signedOut, EnvironmentError.authenticationRequired),
                                     ("account mismatch", .identityMismatch, .accountMismatch)] {
            await run("Switching: typed " + name + " stops before lifecycle or activation") {
                let f = try await AssociationFixture.make(root("typed-" + name)), system = FixtureActivationSystem()
                await system.set(f.associations[0], f.sourceInstance)
                let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureFixedProof(proof: proof))
                let coordinator = AccountSwitchingCoordinator(driver: driver)
                do { try await coordinator.switchAccount(to: f.profiles[0], workInterruptionConfirmed: true); throw CheckFailure(description: "Error ignored") }
                catch SwitchingError.environment(let actual) { try expect(actual == error, "Specific error retained") }
                try expect(await coordinator.lastError == .environment(error), "UI can retain exact failure")
                let events = await system.events
                try expect(!events.contains("activate") && !events.contains("quit"), "No dispatch")
            }
        }
        await run("Activation: failure reports recovery required without restart fallback") {
            let f = try await AssociationFixture.make(root("activation-failure")), system = FixtureActivationSystem()
            await system.set(f.associations[0], f.sourceInstance); await system.configure(.failure)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            do { try await coordinator.switchAccount(to: f.profiles[0], workInterruptionConfirmed: false); throw CheckFailure(description: "Failure ignored") }
            catch SwitchingError.environment(.activationUnavailable) {}
            try expect(await coordinator.state == .recoveryRequired, "Cannot claim foreground rollback")
            let events = await system.events
            try expect(!events.contains("launch") && !events.contains("quit"), "No fallback")
        }
        await run("Activation: cancellation during fresh identity check never activates or quits") {
            let f = try await AssociationFixture.make(root("activation-cancel")), system = FixtureActivationSystem(), verifier = HeldProofVerifier()
            await system.set(f.associations[0], f.sourceInstance)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: verifier)
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            let attempt = Task { try await coordinator.switchAccount(to: f.profiles[0], workInterruptionConfirmed: false) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await !verifier.waiting && ContinuousClock.now < deadline { await Task.yield() }
            try expect(await verifier.waiting, "Paused in final identity check")
            attempt.cancel(); await verifier.release()
            do { try await attempt.value; throw CheckFailure(description: "Cancellation ignored") } catch SwitchingError.cancelled {}
            let events = await system.events
            try expect(!events.contains("activate") && !events.contains("quit"), "No dispatch after cancellation")
            try expect(await coordinator.state == .cancelled, "Cancellation retained after memory rollback")
        }
        await run("Activation: standard external can activate a verified instance but cannot launch when absent") {
            let f = try await AssociationFixture.make(root("activation-standard")), system = FixtureActivationSystem(), profile = f.profiles[0]
            _ = try await f.store.disconnectEnvironment(profileID: profile.id)
            let home = f.userHome.appendingPathComponent(".codex"), electron = f.userHome.appendingPathComponent("Library/Application Support/Codex")
            try AssociationFixture.directory(home); try AssociationFixture.directory(electron)
            let association = try f.validator.link(profileID: profile.id, environmentID: profile.id, kind: .standardExternal, home: home.path, electron: electron.path)
            _ = try await f.store.linkEnvironment(association, validator: f.validator)
            await system.set(association, f.sourceInstance)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            try await coordinator.switchAccount(to: profile, workInterruptionConfirmed: false)
            await system.set(association, nil)
            let missing = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier())
            try await environmentError(.releaseGateClosed) { try await missing.validate(profile: profile) }
            let events = await system.events
            try expect(!events.contains("quit") && !events.contains("launch"), "Protected primary never restarted")
        }
        await run("Switching: restart mock B to A reuses the same coordinator contract") {
            let f = try await AssociationFixture.make(root("restart-reverse")), system = FixtureDesktopSystem()
            await system.set(f.associations[1], f.sourceInstance)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: FixtureAccountVerifier(), source: f.associations[1])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            try await coordinator.switchAccount(to: f.profiles[0], workInterruptionConfirmed: true)
            try expect(await coordinator.state == .active(f.profiles[0].id), "Reverse mock restart verified")
            let events = await system.events
            try expect(events.filter { $0.hasPrefix("quit:") }.count == 1 && events.filter { $0 == "launch" }.count == 1, "Exactly one dispatch each")
        }
        await run("Managed: wrong metadata mode blocks preparation without adding directories") {
            let (store, first, path) = try await fresh("managed-metadata-mode")
            _ = try await store.prepareManagedEnvironment(profileID: first.id)
            let second = try await store.create(name: "Fixture Second").profiles[1]
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.appendingPathComponent("managed-environments.json").path)
            try await environmentError(.invalidMetadata) { _ = try await store.prepareManagedEnvironment(profileID: second.id) }
            try expect(!fm.fileExists(atPath: path.appendingPathComponent("Profiles/\(second.directoryIdentifier)/codex-home").path), "No mutation on corrupt registry")
        }
        await run("Managed: failed second commit preserves prior catalog and recoverable backup") {
            let (store, first, path) = try await fresh("managed-second-fault")
            _ = try await store.prepareManagedEnvironment(profileID: first.id)
            let second = try await store.create(name: "Fixture Second").profiles[1]
            let before = try Data(contentsOf: path.appendingPathComponent("managed-environments.json"))
            let fault = ProfileStore(root: path, writer: AtomicMetadataWriter(beforeReplace: { destination in
                if destination.lastPathComponent == "managed-environments.json" { throw ProfileError.storageUnavailable }
            }))
            try await expectError(.storageUnavailable) { _ = try await fault.prepareManagedEnvironment(profileID: second.id) }
            try expect(try Data(contentsOf: path.appendingPathComponent("managed-environments.json")) == before, "Previous metadata retained")
            try expect(try Data(contentsOf: path.appendingPathComponent("managed-environments.backup.json")) == before, "Valid rollback snapshot")
        }
        await run("Identity: a response from a replaced process generation is not accepted") {
            let f = try await AssociationFixture.make(root("identity-generation")), request = AccountIdentityRequest(association: f.associations[0], instance: f.sourceInstance)
            let gen = DesktopGeneration(pid: f.sourceInstance.main.pid, uid: getuid(), started: "reused fixture PID")
            let changed = AccountIdentityRequest(association: request.association, instance: DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-1)))
            let reader = FixtureIdentityReader(.routed(RoutedAccountIdentity(request: changed, key: try key(), authenticated: true)))
            try expect(try await AccountIdentityVerifier(reader: reader).assess(request).state == .verificationError, "Generation routing mismatch")
        }
        await run("Activation: production bridge refuses window inspection and activation without I/O") {
            let f = try await AssociationFixture.make(root("activation-native-gate")), native = NativeDesktopSystem()
            try await environmentError(.releaseGateClosed) { _ = try await native.activationEvidence(f.associations[0], instance: f.sourceInstance) }
            let evidence = DesktopActivationEvidence(association: f.associations[0], instance: f.sourceInstance, windowIDs: [1], windowOwners: [f.sourceInstance.main], ownershipConfirmed: true)
            try await environmentError(.releaseGateClosed) { try await native.activate(evidence) }
        }
    }
}

extension CoreChecks {
    @MainActor static func preparePersistentFixture() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/research/stage26/persistent-fixture-" + UUID().uuidString.lowercased())
        let store = ProfileStore(root: root), validator = EnvironmentValidator(managedRoot: root)
        _ = try await store.create(name: "Fixture Primary")
        let profiles = try await store.create(name: "Fixture Work").profiles
        for profile in profiles {
            let association = try await store.prepareManagedEnvironment(profileID: profile.id)
            try validator.revalidate(association)
            try expect(try FileManager.default.contentsOfDirectory(atPath: association.codexHome).isEmpty, "Empty test home")
            try expect(try FileManager.default.contentsOfDirectory(atPath: association.electronData).isEmpty, "Empty test Electron root")
        }
        try expect(try await ProfileStore(root: root).inspectManagedEnvironments().prepared.count == 2, "Reload prepared registry")
        print("PASS two empty persistent fixture environments retained: \(root.path)")
    }
}
