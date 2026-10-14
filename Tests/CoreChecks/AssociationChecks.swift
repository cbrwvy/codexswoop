import Foundation
import Darwin
import CodexSwoopCore

@MainActor
func environmentError(_ expected: EnvironmentError, _ body: () async throws -> Void) async throws {
    do { try await body(); throw CheckFailure(description: "Expected environment rejection: \(expected)") }
    catch let error as EnvironmentError { try expect(error == expected, "Wrong environment error: \(error)") }
}

/// Entirely synthetic lifecycle. No Process/NSRunningApplication/authentication calls.
actor FixtureDesktopSystem: DesktopSystem {
    nonisolated let lifecycleAllowed = true
    var instances: [UUID: DesktopInstance] = [:]
    var events: [String] = []
    var incompatible = false, launchFails = false, exitTimeout = false
    func configure(incompatible: Bool = false, launchFails: Bool = false, exitTimeout: Bool = false) {
        self.incompatible = incompatible; self.launchFails = launchFails; self.exitTimeout = exitTimeout
    }
    func set(_ association: EnvironmentAssociation, _ instance: DesktopInstance) { instances[association.environmentID] = instance }
    func setUnrelated(_ environmentID: UUID, _ instance: DesktopInstance) { instances[environmentID] = instance }
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint {
        OpeningBuildFingerprint(version: "synthetic", build: "fixture", signingRequirement: "synthetic-only",
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: "c", count: 64))
    }
    func validateInstallation() throws { events.append("build"); if incompatible { throw EnvironmentError.incompatibleBuild } }
    func observe(_ association: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        events.append("observe")
        return DesktopObservation(matching: instances[association.environmentID].map { [$0] } ?? [], ambiguous: false)
    }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) {
        events.append("quit:\(instance.main.pid)")
        if !exitTimeout { instances.removeValue(forKey: association.environmentID) }
    }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) throws {
        events.append("wait")
        try expect(timeout == .seconds(10), "Bounded deadline")
        if exitTimeout { throw SwitchingError.exitTimedOut }
    }
    func launch(_ specification: DesktopLaunchSpecification) throws {
        events.append("launch")
        if launchFails { throw EnvironmentError.launchFailed }
        let generation = DesktopGeneration(pid: 120_001, uid: getuid(), started: "fixture target generation")
        instances[specification.association.environmentID] = DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date().addingTimeInterval(-1))
    }
}
struct FixtureAccountVerifier: DesktopAccountVerifying {
    let unavailable: Bool
    init(unavailable: Bool = false) { self.unavailable = unavailable }
    func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) -> AccountVerification {
        if unavailable { return .unavailable }
        return .verified(profileID: association.profileID, environmentID: association.environmentID,
                         generation: instance.main, checkedAt: Date(), expiresAt: Date().addingTimeInterval(2))
    }
}

/// Simulates an asynchronous verifier which returns a proof even after its caller was cancelled.
actor HeldProofVerifier: DesktopAccountVerifying {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) async -> AccountVerification {
        calls += 1
        if calls == 2 { await withCheckedContinuation { continuation = $0 } }
        return FixtureAccountVerifier().verify(association, instance: instance)
    }
}

@MainActor
struct AssociationFixture {
    let root: URL, userHome: URL, store: ProfileStore, validator: EnvironmentValidator
    let profiles: [AccountProfile], associations: [EnvironmentAssociation]
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func make(_ root: URL, linked: Bool = true) async throws -> AssociationFixture {
        let store = ProfileStore(root: root.appendingPathComponent("store")), home = root.appendingPathComponent("user")
        let validator = EnvironmentValidator(userHome: home, managedRoot: root.appendingPathComponent("store"))
        _ = try await store.create(name: "Основной")
        let profiles = try await store.create(name: "Рабочий").profiles
        var associations: [EnvironmentAssociation] = []
        for profile in profiles {
            let base = validator.managedRoot.appendingPathComponent("Profiles/\(profile.directoryIdentifier)")
            let h = base.appendingPathComponent("codex-home"), e = base.appendingPathComponent("electron-user-data")
            try directory(h); try directory(e)
            let value = try validator.link(profileID: profile.id, environmentID: profile.id, kind: .managed, home: h.path, electron: e.path)
            if linked { _ = try await store.linkEnvironment(value, validator: validator) }
            associations.append(value)
        }
        return AssociationFixture(root: root, userHome: home, store: store, validator: validator, profiles: profiles, associations: associations)
    }
    func driver(_ system: FixtureDesktopSystem, source: Bool = false, verified: Bool = true) -> DesktopSwitchingDriver {
        DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: store, validator: validator, system: system,
            verifier: FixtureAccountVerifier(unavailable: !verified), source: source ? associations[0] : nil)
    }
    var sourceInstance: DesktopInstance {
        let generation = DesktopGeneration(pid: 120_000, uid: getuid(), started: "fixture source generation")
        return DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date().addingTimeInterval(-10))
    }
}

extension CoreChecks {
    @MainActor
    static func associationChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        func root(_ name: String) -> URL { base.appendingPathComponent("bindings-" + name) }

        await run("Process metadata: padded ps columns preserve exact official executable and generation") {
            let path = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            for padding in [" ", "     ", "\t\t "] {
                let row = try DesktopProcessMetadata.parse("  131234     1   501 Fri Oct  9 11:53:32 2026" + padding + path)
                try expect(row.pid == 131234 && row.parent == 1 && row.uid == 501
                    && row.started == "Fri Oct 9 11:53:32 2026" && row.executable == path, "Padding cannot hide a running official instance")
            }
        }
        await run("Process metadata: executable paths retain internal and trailing spaces") {
            let path = "/Applications/Example App.app/Contents/MacOS/Example App "
            let row = try DesktopProcessMetadata.parse("42\t1\t501\tMon\tOct\t12\t00:00:00\t2026\t  " + path)
            try expect(row.executable == path, "Only leading column delimiters may be removed")
        }
        await run("Process metadata: signed Darwin UID spelling matches the unsigned uid_t value") {
            let signed = try DesktopProcessMetadata.parse("42 1 -2 Mon Oct 12 00:00:00 2026 /system/process")
            let unsigned = try DesktopProcessMetadata.parse("42 1 4294967294 Mon Oct 12 00:00:00 2026 /system/process")
            try expect(signed == unsigned && signed.uid == 4_294_967_294 && signed.uid != getuid(), "A system UID must not invalidate the current-user inventory or be mistaken for it")
        }
        await run("Process metadata: malformed observations reject instead of disappearing") {
            for line in ["", "42 1 501 Mon Oct 12 00:00:00 2026", "42 1 501 Mon Oct 12 00:00:00 2026     ",
                         "bad 1 501 Mon Oct 12 00:00:00 2026 /app", "42 -1 501 Mon Oct 12 00:00:00 2026 /app",
                         "42 1 -4294967297 Mon Oct 12 00:00:00 2026 /app"] {
                try await environmentError(.ambiguousInstance) { _ = try DesktopProcessMetadata.parse(line) }
            }
        }

        await run("Bindings: schema-1 profiles, Unicode names and UUIDs survive linking and restart byte-for-byte") {
            let f = try await AssociationFixture.make(root("legacy"), linked: false)
            let url = f.validator.managedRoot.appendingPathComponent("profiles.json"), bytes = try Data(contentsOf: url)
            for value in f.associations { _ = try await f.store.linkEnvironment(value, validator: f.validator) }
            let reopened = ProfileStore(root: f.validator.managedRoot)
            try expect(try Data(contentsOf: url) == bytes, "Legacy catalog never migrated by linking")
            try expect(try await reopened.inspect().profiles == f.profiles, "Names, IDs and dates retained")
            try expect(try await reopened.inspectAssociations().associations == f.associations, "Separate schema persists")
        }
        await run("Bindings: unlinked legacy profiles remain Not connected without creating sidecar") {
            let f = try await AssociationFixture.make(root("not-connected"), linked: false)
            try expect(try await f.store.inspectAssociations().associations.isEmpty, "No inferred account binding")
            try expect(!fm.fileExists(atPath: f.validator.managedRoot.appendingPathComponent("environments.json").path), "Read does not enroll")
            try expect(ConnectionPresentation.state(association: nil) == .notConnected, "Honest status")
        }
        await run("Bindings: standard external reference validates metadata without reading application files") {
            let f = try await AssociationFixture.make(root("standard"), linked: false)
            let h = f.userHome.appendingPathComponent(".codex"), e = f.userHome.appendingPathComponent("Library/Application Support/Codex")
            try AssociationFixture.directory(h); try AssociationFixture.directory(e)
            let value = try f.validator.link(profileID: f.profiles[0].id, environmentID: UUID(), kind: .standardExternal, home: h.path, electron: e.path)
            _ = try await f.store.linkEnvironment(value, validator: f.validator)
            try expect(value.origin == .currentDefaults && value.requiresIdentityVerification, "Reference is not identity")
            try expect(ConnectionPresentation.state(association: value) == .verificationRequired, "No false Connected")
            try expect(try fm.contentsOfDirectory(atPath: h.path).isEmpty, "No auth or enrollment files created")
        }
        await run("Bindings: isolated external UUID environment links to existing profile without duplicate profile") {
            let f = try await AssociationFixture.make(root("external"), linked: false)
            let id = UUID(), dir = f.userHome.appendingPathComponent("environments/\(id.uuidString.lowercased())")
            let h = dir.appendingPathComponent("codex-home"), e = dir.appendingPathComponent("electron-user-data")
            try AssociationFixture.directory(dir); try AssociationFixture.directory(h); try AssociationFixture.directory(e)
            let value = try f.validator.link(profileID: f.profiles[1].id, environmentID: id, kind: .isolatedExternal, home: h.path, electron: e.path)
            _ = try await f.store.linkEnvironment(value, validator: f.validator)
            try expect(try await f.store.inspect().profiles.count == 2, "Exactly existing profiles")
        }
        await run("Bindings: guarded temporary environment retains original canonical paths and explicit temporary kind") {
            let f = try await AssociationFixture.make(root("temporary"), linked: false)
            let runID = UUID(), id = UUID(), lab = URL(fileURLWithPath: "/private/tmp/codexswoop-lab-\(runID.uuidString.lowercased())")
            defer { try? fm.removeItem(at: lab) } // This test's generated empty fixture only.
            let profiles = lab.appendingPathComponent("Profiles"), dir = profiles.appendingPathComponent(id.uuidString.lowercased())
            let h = dir.appendingPathComponent("codex-home"), e = dir.appendingPathComponent("electron-user-data")
            for url in [lab, profiles, dir, h, e] { try AssociationFixture.directory(url) }
            let marker: [String: Any] = ["schema": 1, "mode": "guarded", "owner_uid": getuid(), "protected_uid": getuid(),
                "run_id": runID.uuidString, "profiles": ["A": id.uuidString, "B": UUID().uuidString]]
            let markerURL = lab.appendingPathComponent("lab.json")
            try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            let value = try f.validator.link(profileID: f.profiles[1].id, environmentID: id, kind: .temporaryResearch, home: h.path, electron: e.path)
            _ = try await f.store.linkEnvironment(value, validator: f.validator)
            try expect(value.isTemporary && value.codexHome == h.path, "No relocation")
            try validatorMarkerRejected(f, markerURL: markerURL, value: value)
        }
        await run("Bindings: same profile, same environment and overlapping paths cannot be linked twice") {
            let f = try await AssociationFixture.make(root("duplicate"))
            try await environmentError(.duplicateAssociation) { _ = try await f.store.linkEnvironment(f.associations[0], validator: f.validator) }
            _ = try await f.store.disconnectEnvironment(profileID: f.profiles[0].id)
            _ = try await f.store.disconnectEnvironment(profileID: f.profiles[1].id)
            let h = f.userHome.appendingPathComponent(".codex"), e = f.userHome.appendingPathComponent("Library/Application Support/Codex")
            try AssociationFixture.directory(h); try AssociationFixture.directory(e)
            let id = UUID()
            for profile in f.profiles {
                let value = try f.validator.link(profileID: profile.id, environmentID: id, kind: .standardExternal, home: h.path, electron: e.path)
                if profile.id == f.profiles[0].id { _ = try await f.store.linkEnvironment(value, validator: f.validator) }
                else { try await environmentError(.duplicateAssociation) { _ = try await f.store.linkEnvironment(value, validator: f.validator) } }
            }
            let nestedID = UUID(), nested = h.appendingPathComponent("nested/\(nestedID.uuidString.lowercased())")
            let nh = nested.appendingPathComponent("codex-home"), ne = nested.appendingPathComponent("electron-user-data")
            try AssociationFixture.directory(nested); try AssociationFixture.directory(nh); try AssociationFixture.directory(ne)
            let overlap = try f.validator.link(profileID: f.profiles[1].id, environmentID: nestedID, kind: .isolatedExternal, home: nh.path, electron: ne.path)
            try await environmentError(.duplicateAssociation) { _ = try await f.store.linkEnvironment(overlap, validator: f.validator) }
        }
        await run("Bindings: missing directory never recreated or signed in") {
            let f = try await AssociationFixture.make(root("missing"))
            try fm.removeItem(atPath: f.associations[1].codexHome)
            try await environmentError(.missingDirectory) { try f.validator.revalidate(f.associations[1]) }
            try expect(!fm.fileExists(atPath: f.associations[1].codexHome), "No implicit repair")
        }
        await run("Bindings: malformed, traversal and nested paths rejected") {
            let f = try await AssociationFixture.make(root("invalid"))
            for path in ["relative", "/private/tmp/../tmp/x", "/private//tmp/x", "/", "/private/tmp/x\n"] {
                try await environmentError(.invalidPath) {
                    _ = try f.validator.link(profileID: f.profiles[0].id, environmentID: UUID(), kind: .isolatedExternal, home: path, electron: path + "/nested")
                }
            }
        }
        await run("Bindings: symlink escape fails without touching destination") {
            let f = try await AssociationFixture.make(root("symlink"))
            let value = f.associations[1], outside = root("outside")
            try AssociationFixture.directory(outside)
            try fm.removeItem(atPath: value.codexHome)
            try fm.createSymbolicLink(atPath: value.codexHome, withDestinationPath: outside.path)
            try await environmentError(.unsafeDirectory) { try f.validator.revalidate(value) }
            try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Destination retained untouched")
        }
        await run("Bindings: changed inode after validation fails closed even at identical path") {
            let f = try await AssociationFixture.make(root("replacement")), value = f.associations[1]
            let original = URL(fileURLWithPath: value.codexHome), moved = original.appendingPathExtension("retained")
            try fm.moveItem(at: original, to: moved); try AssociationFixture.directory(original)
            try await environmentError(.changedDirectory) { try f.validator.revalidate(value) }
        }
        await run("Bindings: loose permissions are rejected without chmod repair") {
            let f = try await AssociationFixture.make(root("mode")), value = f.associations[1]
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: value.electronData)
            try await environmentError(.unsafeDirectory) { try f.validator.revalidate(value) }
            try expect((try fm.attributesOfItem(atPath: value.electronData)[.posixPermissions] as? NSNumber)?.intValue == 0o755, "No permission mutation")
        }
        await run("Bindings: connected profile removal retains directories and the other profile") {
            let f = try await AssociationFixture.make(root("disconnect")), value = f.associations[1]
            _ = try await f.store.removeRecord(id: value.profileID)
            try expect(fm.fileExists(atPath: value.codexHome) && fm.fileExists(atPath: value.electronData), "Environment retained")
            try expect(try await f.store.inspect().profiles == [f.profiles[0]], "Only selected profile removed")
            try expect(try await f.store.inspectAssociations().associations == [f.associations[0]], "Only selected active link removed")
        }
        await run("Bindings: failed atomic sidecar commit restores unchanged old metadata") {
            let f = try await AssociationFixture.make(root("atomic"))
            let file = f.validator.managedRoot.appendingPathComponent("environments.json"), original = try Data(contentsOf: file)
            let faulty = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "environments.json" { throw ProfileError.storageUnavailable }
            })
            try await expectError(.storageUnavailable) { _ = try await faulty.disconnectEnvironment(profileID: f.profiles[0].id) }
            try expect(try Data(contentsOf: file) == original, "Committed metadata unchanged")
            try expect(try await f.store.inspectAssociations().associations == f.associations, "Rollback needs no app restart")
        }
        await run("Bindings: corrupt sidecar blocks writes; explicit backup recovery retains damaged bytes") {
            let f = try await AssociationFixture.make(root("corrupt")), file = f.validator.managedRoot.appendingPathComponent("environments.json")
            let damaged = Data("damaged fixture".utf8); try damaged.write(to: file)
            try await environmentError(.invalidMetadata) { _ = try await f.store.disconnectEnvironment(profileID: f.profiles[0].id) }
            let recovered = try await f.store.recoverAssociationsBackup()
            try expect(recovered.associations == [f.associations[0]], "Previous snapshot")
            let retained = try fm.contentsOfDirectory(at: f.validator.managedRoot, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("environments-damaged-") }
            try expect(try retained.map { try Data(contentsOf: $0) } == damaged, "Damaged bytes retained")
            try expect(try await f.store.inspect().profiles == f.profiles, "Profiles survive recovery")
        }
        await run("Bindings: newer schema cannot be edited or overwritten by backup recovery") {
            let f = try await AssociationFixture.make(root("future")), file = f.validator.managedRoot.appendingPathComponent("environments.json")
            var catalog = try await f.store.inspectAssociations(); catalog.schemaVersion = 999
            let bytes = try JSONEncoder().encode(catalog); try bytes.write(to: file)
            try await environmentError(.unsupportedSchema) { _ = try await f.store.inspectAssociations() }
            try await environmentError(.unsupportedSchema) { _ = try await f.store.recoverAssociationsBackup() }
            try expect(try Data(contentsOf: file) == bytes, "Future data retained")
        }
        await run("Bindings: missing sidecar with backup never becomes unlinked silently") {
            let f = try await AssociationFixture.make(root("missing-sidecar"))
            try fm.removeItem(at: f.validator.managedRoot.appendingPathComponent("environments.json"))
            try await environmentError(.invalidMetadata) { _ = try await f.store.inspectAssociations() }
        }
        await run("Bindings: legacy recovery cannot resurrect a reference to a deleted profile") {
            let f = try await AssociationFixture.make(root("orphan"))
            let original = try await f.store.inspectAssociations()
            _ = try await f.store.removeRecord(id: f.profiles[1].id)
            try AtomicMetadataWriter().write(JSONEncoder().encode(original), to: f.validator.managedRoot.appendingPathComponent("environments.backup.json"))
            try Data("damaged fixture".utf8).write(to: f.validator.managedRoot.appendingPathComponent("environments.json"))
            do { _ = try await f.store.recoverAssociationsBackup(); throw CheckFailure(description: "Dangling recovery accepted") }
            catch AccountSetupError.conflict {}
            try expect(try await f.store.inspect().profiles == [f.profiles[0]], "Deleted profile not restored")
        }
        await run("Bindings: identity unavailable, expired, wrong profile and wrong generation never become Connected") {
            let f = try await AssociationFixture.make(root("identity")), value = f.associations[1], instance = f.sourceInstance, now = Date()
            let results: [AccountVerification] = [.unavailable,
                .verified(profileID: value.profileID, environmentID: value.environmentID, generation: instance.main, checkedAt: now.addingTimeInterval(-6), expiresAt: now.addingTimeInterval(10)),
                .verified(profileID: value.profileID, environmentID: value.environmentID, generation: instance.main, checkedAt: now, expiresAt: now.addingTimeInterval(-1)),
                .verified(profileID: UUID(), environmentID: value.environmentID, generation: instance.main, checkedAt: now, expiresAt: now.addingTimeInterval(10)),
                .verified(profileID: value.profileID, environmentID: value.environmentID, generation: DesktopGeneration(pid: instance.main.pid, uid: getuid(), started: "reused PID"), checkedAt: now, expiresAt: now.addingTimeInterval(10))]
            for result in results {
                try expect(ConnectionPresentation.state(association: value, verification: result, instance: instance, selected: true, now: now) == .verificationRequired, "No false Active")
            }
            try expect(ConnectionPresentation.state(association: value, verification: .signedOut) == .reauthenticationRequired, "Signed out separate from unknown")
        }
        await run("Bindings: fresh matching test proof enables Connected and Active only at runtime") {
            let f = try await AssociationFixture.make(root("proof")), value = f.associations[1], instance = f.sourceInstance
            let proof = FixtureAccountVerifier().verify(value, instance: instance)
            try expect(ConnectionPresentation.state(association: value, verification: proof, instance: instance) == .connected, "Verified runtime proof")
            try expect(ConnectionPresentation.state(association: value, verification: proof, instance: instance, selected: true) == .active, "Selected matching proof")
            try expect(ConnectionPresentation.state(association: value) == .verificationRequired, "Relaunch loses runtime proof")
        }
        await ownershipChecks(run: run)
        await run("Driver: production lifecycle entry points all reject before touching official processes") {
            let f = try await AssociationFixture.make(root("gate")), native = NativeDesktopSystem(validator: f.validator)
            try expect(!DesktopIntegrationPolicy.lifecycleEnabled && !native.lifecycleAllowed, "Hard gate closed")
            try await environmentError(.releaseGateClosed) { try await native.requestNormalQuit(f.sourceInstance, association: f.associations[0]) }
            try await environmentError(.releaseGateClosed) { try await native.waitForExit(f.sourceInstance, association: f.associations[0], timeout: .seconds(10)) }
            try await environmentError(.releaseGateClosed) { try await native.launch(DesktopLaunchSpecification(association: f.associations[1])) }
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: native)
            do { try await driver.validate(profile: f.profiles[1]); throw CheckFailure(description: "Native gate open") }
            catch SwitchingError.unavailable {}
        }
        await run("Driver: launch specification preserves original UUID roots and contains no shell or credentials") {
            let f = try await AssociationFixture.make(root("arguments")), value = f.associations[1], spec = try DesktopLaunchSpecification(association: value)
            try expect(spec.arguments.contains("CODEX_HOME=" + value.codexHome) && spec.arguments.contains("CODEX_ELECTRON_USER_DATA_PATH=" + value.electronData), "Both roots passed explicitly")
            try expect(spec.arguments.first == "-n" && spec.environment == ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], "Single Launch Services request, clean launcher environment")
        }
        await run("Driver: one synthetic target launch reaches verified active without touching metadata") {
            let f = try await AssociationFixture.make(root("success")), system = FixtureDesktopSystem()
            let metadata = try await f.store.inspectAssociations(), driver = f.driver(system)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle]))
            try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true)
            try expect(await coordinator.state == .active(f.profiles[1].id), "Mock proof accepted")
            try expect(await system.events.filter { $0 == "launch" }.count == 1, "One launch")
            try expect(try await f.store.inspectAssociations() == metadata, "No switching metadata commit")
            try await environmentError(.recoveryRequired) { try await driver.validate(profile: f.profiles[1]) }
        }
        await run("Driver: unavailable identity after synthetic launch requires manual recovery, no false success") {
            let f = try await AssociationFixture.make(root("unverified")), system = FixtureDesktopSystem()
            let coordinator = AccountSwitchingCoordinator(driver: f.driver(system, verified: false), activityChecker: ScenarioActivityChecker([.idle]))
            do { try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true); throw CheckFailure(description: "Identity accepted") }
            catch SwitchingError.environment(.identityUnverified) {}
            try expect(await coordinator.state == .recoveryRequired, "No pretend restoration")
            try expect(await coordinator.rollbackFailed, "External restoration cannot be guaranteed")
            try expect(await system.events.filter { $0 == "launch" }.count == 1, "No recovery launch")
        }
        await run("Driver: launch failure is consumed once and preserves both profile records") {
            let f = try await AssociationFixture.make(root("launch-fail")), system = FixtureDesktopSystem()
            await system.configure(launchFails: true)
            let coordinator = AccountSwitchingCoordinator(driver: f.driver(system), activityChecker: ScenarioActivityChecker([.idle]))
            do { try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true); throw CheckFailure(description: "Failure ignored") }
            catch SwitchingError.environment(.launchFailed) {}
            try expect(await coordinator.state == .recoveryRequired, "Review required; no automatic retry")
            try expect(try await f.store.inspect().profiles == f.profiles, "Profiles unchanged")
        }
        await run("Driver: selected synthetic source quits once; unrelated instance remains") {
            let f = try await AssociationFixture.make(root("source")), system = FixtureDesktopSystem()
            let unrelatedID = UUID(), unrelatedGeneration = DesktopGeneration(pid: 120_002, uid: getuid(), started: "unrelated fixture")
            let unrelated = DesktopInstance(main: unrelatedGeneration, related: [unrelatedGeneration], nativeLaunchDate: Date().addingTimeInterval(-1))
            await system.setUnrelated(unrelatedID, unrelated)
            await system.set(f.associations[0], f.sourceInstance)
            let coordinator = AccountSwitchingCoordinator(driver: f.driver(system, source: true), activityChecker: ScenarioActivityChecker([.idle]))
            try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true)
            try expect(await system.events.filter { $0.hasPrefix("quit:") } == ["quit:120000"], "Only captured source")
            try expect(await system.instances[unrelatedID] == unrelated, "Unrelated fixture unchanged")
        }
        await run("Driver: source exit timeout prevents launch and automatic restoration") {
            let f = try await AssociationFixture.make(root("timeout")), system = FixtureDesktopSystem()
            await system.configure(exitTimeout: true); await system.set(f.associations[0], f.sourceInstance)
            let coordinator = AccountSwitchingCoordinator(driver: f.driver(system, source: true), activityChecker: ScenarioActivityChecker([.idle]))
            do { try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true); throw CheckFailure(description: "Timeout ignored") }
            catch SwitchingError.exitTimedOut {}
            try expect(await !system.events.contains("launch"), "No launch after timeout")
            try expect(await coordinator.state == .recoveryRequired, "Source state uncertain")
        }
        await run("Driver: generation change immediately before quit blocks native dispatch") {
            let f = try await AssociationFixture.make(root("changed-process")), system = FixtureDesktopSystem(), driver = f.driver(system, source: true)
            await system.set(f.associations[0], f.sourceInstance)
            try await driver.validate(profile: f.profiles[1]); try expect(try await driver.processIsRunning(), "Source captured")
            let changed = DesktopGeneration(pid: 120_000, uid: getuid(), started: "different generation")
            await system.set(f.associations[0], DesktopInstance(main: changed, related: [changed], nativeLaunchDate: Date().addingTimeInterval(-1)))
            try await environmentError(.processChanged) { try await driver.requestGracefulQuit() }
            try expect(await !system.events.contains(where: { $0.hasPrefix("quit:") }), "No quit after PID reuse")
        }
        await run("Driver: missing identity on source prevents any interruption") {
            let f = try await AssociationFixture.make(root("source-unknown")), system = FixtureDesktopSystem(), driver = f.driver(system, source: true, verified: false)
            await system.set(f.associations[0], f.sourceInstance)
            try await driver.validate(profile: f.profiles[1])
            try await environmentError(.identityUnverified) { _ = try await driver.processIsRunning() }
            try expect(await !system.events.contains("launch"), "Fail before lifecycle")
        }
        await run("Driver: target directory lost after preparation prevents source quit") {
            let f = try await AssociationFixture.make(root("target-lost")), system = FixtureDesktopSystem(), driver = f.driver(system, source: true)
            await system.set(f.associations[0], f.sourceInstance)
            try await driver.validate(profile: f.profiles[1]); _ = try await driver.processIsRunning()
            try await driver.prepare(profile: f.profiles[1])
            try fm.removeItem(atPath: f.associations[1].electronData)
            try await environmentError(.missingDirectory) { try await driver.requestGracefulQuit() }
            try expect(await !system.events.contains(where: { $0.hasPrefix("quit:") }), "Source retained after target failure")
        }
        await run("Driver: cancellation while final identity check is pending prevents quit dispatch") {
            let f = try await AssociationFixture.make(root("late-cancel")), system = FixtureDesktopSystem(), verifier = HeldProofVerifier()
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: system, verifier: verifier, source: f.associations[0])
            await system.set(f.associations[0], f.sourceInstance)
            try await driver.validate(profile: f.profiles[1]); _ = try await driver.processIsRunning()
            try await driver.prepare(profile: f.profiles[1])
            let attempt = Task { try await driver.requestGracefulQuit() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await !verifier.waiting {
                guard ContinuousClock.now < deadline else { attempt.cancel(); throw CheckFailure(description: "Fixture verifier did not pause") }
                await Task.yield()
            }
            attempt.cancel(); await verifier.release()
            do { try await attempt.value; throw CheckFailure(description: "Cancelled quit dispatched") }
            catch is CancellationError {}
            try expect(await !system.events.contains(where: { $0.hasPrefix("quit:") }), "No lifecycle side effect after cancellation")
            try await driver.rollback()
        }
        await run("Driver: incompatible official build blocks before source inspection or lifecycle") {
            let f = try await AssociationFixture.make(root("incompatible")), system = FixtureDesktopSystem()
            await system.configure(incompatible: true)
            try await environmentError(.incompatibleBuild) { try await f.driver(system).validate(profile: f.profiles[1]) }
            try expect(await system.events == ["build"], "Version gate first")
        }
        let busy = CodexActivityStatus.assess(operations: [.init(location: .local, kind: .waitingForApproval)], coverageComplete: true, fresh: true)
        for (name, status) in [("Busy", busy), ("Unknown", CodexActivityStatus.unknown(.desktopConnectionUnverified))] {
            await run("Driver: \(name) Cancel leaves lifecycle and metadata untouched") {
                let f = try await AssociationFixture.make(root("cancel-" + name)), system = FixtureDesktopSystem(), original = try await f.store.inspectAssociations()
                let coordinator = AccountSwitchingCoordinator(driver: f.driver(system), activityChecker: ScenarioActivityChecker([status]))
                do { try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true, confirmActivity: { _ in false }); throw CheckFailure(description: "Cancel ignored") }
                catch SwitchingError.cancelled {}
                try expect(await !system.events.contains("launch"), "No launch")
                try expect(try await f.store.inspectAssociations() == original, "No metadata change")
            }
            await run("Driver: \(name) consent is followed by fresh rechecks before one synthetic launch") {
                let f = try await AssociationFixture.make(root("confirm-" + name)), system = FixtureDesktopSystem(), checks = ScenarioActivityChecker([status])
                let coordinator = AccountSwitchingCoordinator(driver: f.driver(system), activityChecker: checks)
                try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true, confirmActivity: { _ in true })
                try expect(await checks.checks == 3, "Initial, post-confirmation and pre-launch checks")
                try expect(await system.events.filter { $0 == "launch" }.count == 1, "One confirmed mock launch")
            }
        }
        await run("Driver: Idle to Busy change during preparation needs consent; Cancel prevents source quit") {
            let f = try await AssociationFixture.make(root("activity-change")), system = FixtureDesktopSystem()
            await system.set(f.associations[0], f.sourceInstance)
            let coordinator = AccountSwitchingCoordinator(driver: f.driver(system, source: true), activityChecker: ScenarioActivityChecker([.idle, busy]))
            do { try await coordinator.switchAccount(to: f.profiles[1], workInterruptionConfirmed: true, confirmActivity: { _ in false }); throw CheckFailure(description: "Changed activity ignored") }
            catch SwitchingError.cancelled {}
            try expect(await !system.events.contains(where: { $0.hasPrefix("quit:") || $0 == "launch" }), "Stopped before interruption")
            try expect(await !coordinator.rollbackFailed, "Metadata-only rollback completes")
        }
    }

    @MainActor
    static func validatorMarkerRejected(_ f: AssociationFixture, markerURL: URL, value: EnvironmentAssociation) throws {
        try Data("invalid fixture marker".utf8).write(to: markerURL)
        do { try f.validator.revalidate(value); throw CheckFailure(description: "Invalid marker accepted") }
        catch EnvironmentError.invalidMetadata {}
    }

    @MainActor
    static func ownershipChecks(run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func row(_ pid: Int32, _ parent: Int32, _ role: DesktopProcessEvidence.Role, _ home: Int = 0, _ electron: Int = 0,
                 defaults: Int = 0, uid: UInt32 = getuid(), started: String = "fixture") -> DesktopProcessEvidence {
            DesktopProcessEvidence(generation: DesktopGeneration(pid: pid, uid: uid, started: started), parent: parent,
                role: role, homeDescriptors: home, electronDescriptors: electron, defaultDescriptors: defaults)
        }
        let good = [row(10, 1, .main, 2, 3), row(11, 10, .backend, 2), row(12, 10, .helper, 0, 1), row(13, 11, .external)]
        await run("Ownership: two instances are distinguishable by roots; external child stays associated") {
            let sample = good + [row(20, 1, .main), row(21, 20, .backend)]
            try expect(try DesktopOwnership.resolve(before: sample, after: sample, standard: false).first?.map(\.pid) == [10, 11, 12, 13], "Positive roots and ancestry, unrelated main excluded")
        }
        for (name, sample) in [
            ("new PID/window alone", [row(10, 1, .main, 1), row(11, 10, .backend, 1)]),
            ("backend belongs to another main", [row(10, 1, .main, 1, 1), row(11, 20, .backend, 1)]),
            ("wrong owner UID", [row(10, 1, .main, 1, 1, uid: getuid() + 1), row(11, 10, .backend, 1)]),
            ("default roots mixed into isolated lineage", [row(10, 1, .main, 1, 1, defaults: 1), row(11, 10, .backend, 1)]),
            ("unattributed directory use", good + [row(30, 1, .backend, 1)]),
            ("two matching instances", good + [row(20, 1, .main, 1, 1), row(21, 20, .backend, 1)])
        ] {
            await run("Ownership: rejects \(name)") {
                try await environmentError(.ambiguousInstance) { _ = try DesktopOwnership.resolve(before: sample, after: sample, standard: false) }
            }
        }
        await run("Ownership: PID reuse and changed parent between samples invalidate ownership") {
            let changed = [row(10, 1, .main, 2, 3, started: "new generation")] + Array(good.dropFirst())
            try await environmentError(.processChanged) { _ = try DesktopOwnership.resolve(before: good, after: changed, standard: false) }
            let reparented = Array(good.dropLast()) + [row(13, 1, .external)]
            try await environmentError(.ambiguousInstance) { _ = try DesktopOwnership.resolve(before: good, after: reparented, standard: false) }
        }
        await run("Ownership: stale, duplicate and wrong-UID handles cannot identify a native target") {
            let gen = DesktopGeneration(pid: 99, uid: getuid(), started: "fixture"), instance = DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-1))
            try await environmentError(.ambiguousInstance) { _ = try DesktopObservation(matching: [instance, instance], ambiguous: false).unique() }
            try await environmentError(.ambiguousInstance) { _ = try DesktopObservation(matching: [instance], ambiguous: false, observedAt: Date().addingTimeInterval(-6)).unique() }
            let wrong = DesktopGeneration(pid: 99, uid: getuid() + 1, started: "fixture")
            try await environmentError(.processChanged) {
                _ = try DesktopObservation(matching: [DesktopInstance(main: wrong, related: [wrong], nativeLaunchDate: instance.nativeLaunchDate)], ambiguous: false).unique()
            }
        }
    }
}
