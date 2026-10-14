import Foundation
import Darwin
import CodexSwoopCore

@MainActor
struct EnvironmentOpeningFixture {
    let f: AssociationFixture
    let system: OpeningSystem
    let verifier: OpeningVerifier
    let activity: OpeningActivity
    let driver: DesktopSwitchingDriver
    let coordinator: AccountSwitchingCoordinator
    var target: AccountProfile { f.profiles[1] }
    var association: EnvironmentAssociation { f.associations[1] }
    static func make(_ root: URL, running: Bool = true, lifecycle: Bool = false, allowed: Bool = true) async throws -> Self {
        let original = try await OpeningFixture.make(root, targetRunning: running, primary: true)
        let system = OpeningSystem(lifecycle: lifecycle, environmentActivation: allowed)
        await system.seed(original.f.associations, targetRunning: running)
        await original.verifier.configure(blocked: true)
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: original.f.store, validator: original.f.validator,
            system: system, verifier: original.verifier)
        return Self(f: original.f, system: system, verifier: original.verifier, activity: original.activity,
            driver: driver, coordinator: AccountSwitchingCoordinator(driver: driver, activityChecker: original.activity))
    }
    func open(manual: ManualAccountConfirmation? = nil,
              confirm: @Sendable (EnvironmentOpeningPlan) async -> Bool = { _ in true }) async throws {
        try await coordinator.openEnvironment(to: target, manual: manual, confirm: confirm)
    }
}

extension CoreChecks {
    @MainActor static func environmentOpeningChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func scenario(_ name: String, running: Bool = true, lifecycle: Bool = false, allowed: Bool = true,
                      _ body: @escaping @MainActor (EnvironmentOpeningFixture) async throws -> Void) async {
            await run("Environment opening: " + name) {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString),
                    running: running, lifecycle: lifecycle, allowed: allowed)
                try await body(f)
                try expect(await f.verifier.readinessCalls == 0, "No prelaunch identity call")
            }
        }
        await scenario("five guarantees remain independent; no account/read dependency") { f in
            let other = await f.system.instances[f.f.associations[0].environmentID]
            try await f.open(manual: ManualAccountConfirmation(association: f.association))
            guard let result = await f.coordinator.environmentOpeningResult else { throw CheckFailure(description: "Missing environment result") }
            let g = result.guarantees
            try expect(g.environmentOwnershipVerified && g.processOwnershipVerified && g.windowOwnershipVerified, "All ownership proofs")
            try expect(g.accountIdentityUserConfirmed && !g.accountIdentityTechnicallyVerified, "Manual never becomes technical")
            try expect(await f.verifier.calls == 0, "Unavailable verifier never queried")
            try expect(await f.system.effects == ["activate"], "Exactly one mock activation")
            try expect(await f.system.instances[f.f.associations[0].environmentID] == other, "Standard instance retained")
            try expect(await f.coordinator.state == .environmentOpened(f.target.id), "Environment result, not account Active")
            try expect(await f.coordinator.openingResult == nil, "No verified account result")
            try expect(await f.activity.scopedPIDs.isEmpty, "No interruption query")
            try expect(await !f.system.events.contains("inventory"), "No global inventory")
            try expect(ConnectionPresentation.state(association: f.association, instance: result.evidence.instance) == .verificationRequired, "No Account Verified status")
        }
        await scenario("explicit environment purpose consent works without visual account note") { f in
            try await f.open()
            try expect(await f.coordinator.environmentOpeningResult?.guarantees.accountIdentityUserConfirmed == false, "Purpose consent is not account confirmation")
            try expect(await f.verifier.calls == 0, "No implicit identity check")
            try await f.open()
            try expect(await f.system.effects == ["activate", "activate"], "Fresh explicit repeat")
        }
        await scenario("foreign manual confirmation is informational only") { f in
            try await f.open(manual: ManualAccountConfirmation(association: f.f.associations[0]))
            try expect(await f.coordinator.environmentOpeningResult?.guarantees.accountIdentityUserConfirmed == false, "Other profile note cannot transfer")
        }
        await scenario("same profile and environment UUIDs cannot reuse an old directory confirmation") { f in
            let old = f.association
            let changed = try f.f.validator.link(profileID: old.profileID, environmentID: old.environmentID,
                kind: old.kind, home: old.codexHome, electron: old.electronData, now: old.checkedAt.addingTimeInterval(-1))
            try await f.open(manual: ManualAccountConfirmation(association: changed))
            try expect(await f.coordinator.environmentOpeningResult?.guarantees.accountIdentityUserConfirmed == false, "Full association scope")
        }
        await scenario("Standard External activates only its own existing window without lifecycle or account identity") { f in
            try await f.coordinator.openEnvironment(to: f.f.profiles[0]) { _ in true }
            try expect(await f.system.activatedEvidence.map(\.association) == [f.f.associations[0]], "Exact selected environment")
            try expect(await f.system.effects == ["activate"], "No Standard launch/quit")
            try expect(await f.verifier.calls == 0, "No account request")
        }
        await scenario("time spent confirming requires newly captured evidence") { f in
            try await f.open { _ in
                try? await Task.sleep(for: .seconds(6))
                return true
            }
            let evidence = await f.system.activatedEvidence
            try expect(evidence.count == 1 && Date().timeIntervalSince(evidence[0].observedAt) < 5, "Dispatch uses fresh evidence")
        }
        await scenario("cancel leaves processes and proof untouched") { f in
            try await openingError(.opening(.userCancelled)) { try await f.open { _ in false } }
            try expect(await f.system.effects.isEmpty, "No effect")
            try expect(await f.verifier.calls == 0, "No account call")
            try expect(await f.coordinator.state == .cancelled, "Cancelled")
            try await f.open()
        }
        await scenario("default confirmation denies action") { f in
            try await openingError(.opening(.userCancelled)) { try await f.coordinator.openEnvironment(to: f.target) }
            try expect(await f.system.effects.isEmpty, "No silent consent")
        }
        await scenario("inactive target never launches", running: false) { f in
            try await openingError(.environmentOpening(.targetNotRunning)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "No launch fallback")
            try expect(await f.verifier.calls == 0, "No account call")
        }
        for (name, permission, window, expected) in [
            ("ambiguous window", true, false, EnvironmentError.activationUnavailable),
            ("insufficient AX permission", false, true, .missingPermissions)
        ] {
            await scenario(name) { f in
                await f.system.configure(permissions: permission, window: window)
                try await openingError(.environment(expected)) { try await f.open() }
                try expect(await f.system.effects.isEmpty, "No permission prompt or fallback")
            }
        }
        await scenario("ambiguous process ownership") { f in
            await f.system.configure(ambiguous: true)
            try await openingError(.environment(.ambiguousInstance)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "No guessed target")
        }
        for kind in ["multiple windows", "missing AX token", "foreign owner", "stale window evidence", "foreign association"] {
            await scenario("reject " + kind) { f in
                let instance = await f.system.instances[f.association.environmentID]!
                let evidence = DesktopActivationEvidence(
                    association: kind == "foreign association" ? f.f.associations[0] : f.association, instance: instance,
                    windowIDs: kind == "multiple windows" ? [1, 2] : [1],
                    windowOwners: kind == "foreign owner" ? [OpeningSystem.instance(8).main] : [instance.main],
                    ownershipConfirmed: true, observedAt: Date().addingTimeInterval(kind == "stale window evidence" ? -6 : 0),
                    windowToken: kind == "missing AX token" ? nil : UUID())
                await f.system.overrideEvidence(evidence)
                try await openingError(.environment(.activationUnavailable)) { try await f.open() }
                try expect(await f.system.effects.isEmpty, "Exact fresh owned window required")
            }
        }
        await scenario("task cancellation while awaiting user consent") { f in
            let task = Task { try await f.open { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            } }
            try await openingError(.opening(.userCancelled)) { try await task.value }
            try expect(await f.system.effects.isEmpty, "Cancellation before dispatch")
        }
        await scenario("PID changes during user confirmation") { f in
            try await openingError(.environment(.processChanged)) {
                try await f.open { _ in await f.system.replace(f.association); return true }
            }
            try expect(await f.system.effects.isEmpty, "No activation of replacement")
        }
        await scenario("same PID with new generation is rejected") { f in
            try await openingError(.environment(.processChanged)) {
                try await f.open { plan in
                    let old = plan.evidence.instance
                    let generation = DesktopGeneration(pid: old.main.pid, uid: getuid(), started: "reused PID")
                    await f.system.setInstance(DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date()), for: f.association)
                    return true
                }
            }
            try expect(await f.system.effects.isEmpty, "PID alone insufficient")
        }
        await scenario("AX window token changes during consent") { f in
            try await openingError(.environment(.activationUnavailable)) {
                try await f.open { _ in await f.system.changeWindow(); return true }
            }
            try expect(await f.system.effects.isEmpty, "No alternative window")
        }
        await scenario("target exits during consent") { f in
            try await openingError(.environment(.processChanged)) {
                try await f.open { _ in await f.system.setInstance(nil, for: f.association); return true }
            }
            try expect(await f.system.effects.isEmpty, "No activation-to-launch fallback")
        }
        await scenario("directory permissions change after planning") { f in
            try await openingError(.environment(.unsafeDirectory)) {
                try await f.open { plan in
                    chmod(plan.association.codexHome, 0o777)
                    return true
                }
            }
            try expect(await f.system.effects.isEmpty, "Directory proof rechecked")
        }
        await scenario("environment binding changes after planning") { f in
            try await openingError(.environmentOpening(.stalePlan)) {
                try await f.open { _ in
                    _ = try? await f.f.store.disconnectEnvironment(profileID: f.target.id)
                    return true
                }
            }
            try expect(await f.system.effects.isEmpty, "Full catalog equality required")
        }
        await scenario("changed profile catalog blocks action") { f in
            try await openingError(.environmentOpening(.stalePlan)) {
                try await f.open { _ in
                    _ = try? await f.f.store.rename(id: f.target.id, name: "Changed fixture")
                    return true
                }
            }
            try expect(await f.system.effects.isEmpty, "No stale label/intent")
        }
        await scenario("different profile cannot consume retained plan") { f in
            let plan = try await f.driver.planEnvironmentOpening(profile: f.target, manual: nil)
            do {
                _ = try await f.driver.planEnvironmentOpening(profile: f.f.profiles[0], manual: nil)
                throw CheckFailure(description: "Plan overwritten")
            } catch AccountOpeningError.recoveryRequired {}
            do {
                try await f.driver.activateEnvironment(plan, confirmedPlanID: UUID())
                throw CheckFailure(description: "Foreign confirmation accepted")
            } catch EnvironmentOpeningError.confirmationRequired {}
            try expect(await f.system.effects.isEmpty, "Plan-specific consent")
            await f.driver.finishEnvironmentOpening(plan, success: false)
        }
        await scenario("foreign profile UUID rejected") { f in
            try await openingError(.validationFailed) {
                try await f.coordinator.openEnvironment(to: AccountProfile(name: "Foreign")) { _ in true }
            }
            try expect(await f.system.effects.isEmpty, "Only catalog profiles")
        }
        await scenario("unlinked target rejected") { f in
            _ = try await f.f.store.disconnectEnvironment(profileID: f.target.id)
            try await openingError(.environment(.missingAssociation)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "Existing association required")
        }
        await scenario("Usage remains inaccessible after manual note and activation") { f in
            let provider = UsageFixtureProvider()
            let usage = UsageCoordinator(provider: provider)
            usage.synchronize(f.f.associations)
            try await f.open(manual: ManualAccountConfirmation(association: f.association))
            usage.refresh(f.target.id); usage.automaticTick()
            try expect(usage.state(for: f.target.id).status == .verificationRequired, "No usage context from activation")
            try expect(await provider.calls == 0, "No account API from manual consent")
            try expect(await provider.proofs == 0, "No usage source access")
            try expect(!UsageIntegrationPolicy.liveEnabled, "Live Usage gate unchanged")
        }
        await scenario("Close Others still needs lifecycle authorization") { f in
            try await f.open()
            try await openingError(.unavailable) { try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen) }
            try expect(await f.system.effects == ["activate"], "No close/launch authorization propagated")
        }
        await scenario("Close Others still needs technical identity even with mock lifecycle gate", lifecycle: true) { f in
            try await f.open(manual: ManualAccountConfirmation(association: f.association))
            try await openingError(.opening(.identityUnverified)) { try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen) }
            try expect(await f.system.effects == ["activate"], "Manual note cannot authorize close")
            try expect(await f.verifier.calls == 1, "Strict old identity path retained")
        }
        await scenario("same coordinator busy guard covers all operations") { f in
            try await f.open { _ in
                do { try await f.open(); return false } catch SwitchingError.opening(.busy) {} catch { return false }
                do { try await f.coordinator.switchAccount(to: f.target, workInterruptionConfirmed: true); return false }
                catch SwitchingError.busy {} catch { return false }
                do { try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen); return false }
                catch SwitchingError.opening(.busy) {} catch { return false }
                return true
            }
            try expect(await f.system.effects == ["activate"], "Only one operation")
        }
        await scenario("post-dispatch failure requires review across all paths") { f in
            await f.system.configure(activation: true)
            try await openingError(.environment(.activationUnavailable)) { try await f.open() }
            try await openingError(.opening(.recoveryRequired)) { try await f.open() }
            try await openingError(.opening(.recoveryRequired)) { try await f.coordinator.switchAccount(to: f.target, workInterruptionConfirmed: true) }
            try expect(await f.coordinator.environmentOpeningResult == nil, "No success")
            try expect(await f.system.effects == ["activate"], "No retry/recovery launch")
        }
        await scenario("process churn after dispatch never produces environment success") { f in
            await f.system.changeProcessAfterActivation()
            try await openingError(.environment(.processChanged)) { try await f.open() }
            try expect(await f.system.effects == ["activate"], "No recovery launch")
            try expect(await f.coordinator.environmentOpeningResult == nil, "No false result")
            try expect(await f.coordinator.state == .recoveryRequired, "Review required")
        }
        await scenario("separate environment policy denies even with lifecycle allowed", lifecycle: true, allowed: false) { f in
            try await openingError(.environmentOpening(.unavailable)) { try await f.open() }
            try expect(await f.system.effects.isEmpty, "Independent policy")
        }
        await scenario("native gates reject before any process/window/API access") { f in
            let native = NativeDesktopSystem(validator: f.f.validator)
            try expect(!EnvironmentOpeningPolicy.nativeActivationEnabled && !DesktopIntegrationPolicy.lifecycleEnabled
                && !DesktopIntegrationPolicy.primaryLifecycleEnabled, "All native effect gates remain closed")
            let instance = OpeningSystem.instance(1)
            do { _ = try await native.environmentActivationEvidence(f.association, instance: instance); throw CheckFailure(description: "Native evidence ungated") }
            catch EnvironmentOpeningError.unavailable {}
            let evidence = DesktopActivationEvidence(association: f.association, instance: instance, windowIDs: [1],
                windowOwners: [instance.main], ownershipConfirmed: true, windowToken: UUID())
            do { try await native.activateEnvironment(evidence); throw CheckFailure(description: "Native activation ungated") }
            catch EnvironmentOpeningError.unavailable {}
        }
        await scenario("revision3 catalogs and synthetic reserve A retained byte-for-byte") { f in
            let files = ["profiles.json", "environments.json", "environments.backup.json"].map { f.f.validator.managedRoot.appendingPathComponent($0) }
            let bytes = try files.map { try Data(contentsOf: $0) }
            let reserve = f.f.userHome.appendingPathComponent("reserve-A.fixture")
            try Data("synthetic retained A".utf8).write(to: reserve)
            try await f.open()
            try expect(try files.map { try Data(contentsOf: $0) } == bytes, "No profile/reference/revision writes")
            try expect(try await f.f.store.inspectAssociations().revision == 3, "Revision retained")
            try expect(try Data(contentsOf: reserve) == Data("synthetic retained A".utf8), "Reserve retained")
        }
    }
}

extension OpeningSystem {
    func changeProcessAfterActivation() { replaceAfterActivation = true }
    func overrideEvidence(_ evidence: DesktopActivationEvidence) { evidenceOverride = evidence }
    func setInstance(_ value: DesktopInstance?, for association: EnvironmentAssociation) { instances[association.environmentID] = value }
}
