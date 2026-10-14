import Foundation
import Darwin
import CodexSwoopCore

extension CoreChecks {
    @MainActor static func pidOpeningChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func scenario(_ name: String, _ body: @escaping @MainActor (EnvironmentOpeningFixture) async throws -> Void) async {
            await run("PID opening: " + name) {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString))
                let instance = await f.system.instances[f.association.environmentID]!
                let scope = try PIDActivationScope(association: f.association, revision: 3, instance: instance)
                await f.system.configurePID(scope)
                try await body(f)
                try expect(await f.system.axCalls == 0, "No AX calls/fallback")
                let verifierCalls = await f.verifier.calls, readinessCalls = await f.verifier.readinessCalls
                try expect(verifierCalls == 0 && readinessCalls == 0, "No account verifier or launch identity access")
                try expect(await f.system.effects.allSatisfy { $0 == "pidActivate" }, "No lifecycle fallback")
            }
        }
        await scenario("success without AX, preserves other instance and metadata; identity/Usage/Close Others stay gated") { f in
            await f.system.configure(permissions: false, window: false)
            let other = await f.system.instances[f.f.associations[0].environmentID]
            let metadata = f.f.validator.managedRoot.appendingPathComponent("environments.json")
            let before = try Data(contentsOf: metadata)
            try await f.coordinator.openPIDEnvironment(to: f.target, manual: ManualAccountConfirmation(association: f.association)) { _ in true }
            guard let result = await f.coordinator.pidEnvironmentOpeningResult else { throw CheckFailure(description: "Missing result") }
            try expect(result.guarantees.environmentOwnershipVerified && result.guarantees.processOwnershipVerified
                && !result.guarantees.windowOwnershipVerified && result.guarantees.accountIdentityUserConfirmed
                && !result.guarantees.accountIdentityTechnicallyVerified, "Independent guarantees")
            try expect(await f.system.effects == ["pidActivate"], "Exactly one dispatch")
            try expect(await f.system.instances[f.f.associations[0].environmentID] == other, "Other instance retained")
            try expect(try Data(contentsOf: metadata) == before, "No binding writes")
            let provider = UsageFixtureProvider()
            let checkedUsage = UsageCoordinator(provider: provider)
            checkedUsage.synchronize(f.f.associations)
            checkedUsage.refresh(f.target.id); checkedUsage.automaticTick()
            try expect(checkedUsage.state(for: f.target.id).status == .verificationRequired, "Usage still unverified")
            let calls = await provider.calls, proofs = await provider.proofs
            try expect(calls == 0 && proofs == 0, "No Usage API")
            try await openingError(.unavailable) { try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen) }
            try await openingError(.opening(.recoveryRequired)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
            try expect(await f.system.effects == ["pidActivate"], "Trial cannot be reused")
        }
        await scenario("no scoped capability") { f in
            await f.system.configurePID(nil)
            try await openingError(.environmentOpening(.unavailable)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
            try expect(await f.system.effects.isEmpty, "Closed by default")
        }
        await scenario("scope revision mismatch") { f in
            let instance = await f.system.instances[f.association.environmentID]!
            await f.system.configurePID(try PIDActivationScope(association: f.association, revision: 4, instance: instance))
            try await openingError(.environmentOpening(.unavailable)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
            try expect(await f.system.effects.isEmpty, "Revision-scoped capability")
        }
        await scenario("scope expires while awaiting consent") { f in
            let instance = await f.system.instances[f.association.environmentID]!
            await f.system.configurePID(try PIDActivationScope(association: f.association, revision: 3, instance: instance,
                expiresAt: Date().addingTimeInterval(0.05)))
            try await openingError(.environmentOpening(.unavailable)) {
                try await f.coordinator.openPIDEnvironment(to: f.target) { _ in
                    try? await Task.sleep(for: .milliseconds(80)); return true
                }
            }
            try expect(await f.system.effects.isEmpty, "Expired consent scope cannot dispatch")
        }
        await scenario("consent defaults to cancellation") { f in
            try await openingError(.opening(.userCancelled)) { try await f.coordinator.openPIDEnvironment(to: f.target) }
            try expect(await f.system.effects.isEmpty, "No effect")
        }
        await scenario("cannot activate Primary with Work scope") { f in
            try await openingError(.environmentOpening(.unavailable)) { try await f.coordinator.openPIDEnvironment(to: f.f.profiles[0]) { _ in true } }
            try expect(await f.system.effects.isEmpty, "Profile isolated")
        }
        await scenario("target not running; no launch") { f in
            await f.system.setInstance(nil, for: f.association)
            try await openingError(.environmentOpening(.targetNotRunning)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
        }
        await scenario("ambiguous process rejected") { f in
            await f.system.configure(ambiguous: true)
            try await openingError(.environment(.ambiguousInstance)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
        }
        for change in ["PID", "generation", "launchDate", "UID"] {
            await scenario("changed " + change + " during consent") { f in
                try await openingError(.environment(.processChanged)) {
                    try await f.coordinator.openPIDEnvironment(to: f.target) { plan in
                        let old = plan.instance
                        let generation = DesktopGeneration(pid: old.main.pid + (change == "PID" ? 1 : 0),
                            uid: old.main.uid + (change == "UID" ? 1 : 0),
                            started: change == "generation" ? "replacement generation" : old.main.started)
                        await f.system.setInstance(DesktopInstance(main: generation, related: [generation],
                            nativeLaunchDate: change == "launchDate" ? old.nativeLaunchDate.addingTimeInterval(-1) : old.nativeLaunchDate), for: f.association)
                        return true
                    }
                }
                try expect(await f.system.effects.isEmpty, "No stale dispatch")
            }
        }
        await scenario("association change during consent") { f in
            try await openingError(.environmentOpening(.stalePlan)) {
                try await f.coordinator.openPIDEnvironment(to: f.target) { _ in
                    _ = try? await f.f.store.disconnectEnvironment(profileID: f.target.id); return true
                }
            }
            try expect(await f.system.effects.isEmpty, "Binding rechecked")
        }
        await scenario("revision change during consent") { f in
            try await openingError(.environmentOpening(.stalePlan)) {
                try await f.coordinator.openPIDEnvironment(to: f.target) { _ in
                    if var catalog = try? await f.f.store.inspectAssociations() {
                        catalog.revision += 1
                        try? AtomicMetadataWriter().write(JSONEncoder().encode(catalog), to: f.f.validator.managedRoot.appendingPathComponent("environments.json"))
                    }
                    return true
                }
            }
        }
        await scenario("unsafe directory during consent") { f in
            try await openingError(.environment(.unsafeDirectory)) {
                try await f.coordinator.openPIDEnvironment(to: f.target) { plan in chmod(plan.association.codexHome, 0o777); return true }
            }
        }
        for refusal in [true, false] {
            await scenario(refusal ? "request refused, no retry" : "wrong foreground PID, no false success") { f in
                let instance = await f.system.instances[f.association.environmentID]!
                await f.system.configurePID(try PIDActivationScope(association: f.association, revision: 3, instance: instance),
                    refuses: refusal, wrongForeground: !refusal)
                try await openingError(.activationFailed) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
                try expect(await f.coordinator.pidEnvironmentOpeningResult == nil, "No success")
                try expect(await f.coordinator.state == .recoveryRequired, "Possible dispatch requires review")
                try await openingError(.opening(.recoveryRequired)) { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
                try await openingError(.opening(.recoveryRequired)) { try await f.coordinator.switchAccount(to: f.target, workInterruptionConfirmed: true) }
                try expect(await f.system.effects == ["pidActivate"], "Single attempt")
            }
        }
        await scenario("wrong confirmation ID and overlapping operations") { f in
            let plan = try await f.driver.planPIDEnvironmentOpening(profile: f.target, manual: nil)
            do { try await f.driver.activatePIDEnvironment(plan, confirmedPlanID: UUID()); throw CheckFailure(description: "Wrong confirmation accepted") }
            catch EnvironmentOpeningError.confirmationRequired {}
            do { _ = try await f.driver.planEnvironmentOpening(profile: f.target, manual: nil); throw CheckFailure(description: "Overlapping plan accepted") }
            catch AccountOpeningError.recoveryRequired {}
            await f.driver.finishPIDEnvironmentOpening(plan)
            try await f.coordinator.openPIDEnvironment(to: f.target) { _ in
                do { try await f.coordinator.openPIDEnvironment(to: f.target); return false }
                catch SwitchingError.opening(.busy) {} catch { return false }
                return true
            }
        }
        await scenario("task cancellation before dispatch") { f in
            let task = Task { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return true
            } }
            try await openingError(.opening(.userCancelled)) { try await task.value }
            try expect(await f.system.effects.isEmpty, "Cancelled before dispatch")
        }
        await scenario("native branch closed before OS access; legacy gates unchanged") { f in
            let native = NativeDesktopSystem(validator: f.f.validator), instance = OpeningSystem.instance(1)
            try expect(await !native.permitsPIDActivation(f.association, revision: 3, instance: instance), "No runtime scope by default")
            do { try await native.activatePIDEnvironment(f.association, revision: 3, instance: instance); throw CheckFailure(description: "Ungated native dispatch") }
            catch EnvironmentOpeningError.unavailable {}
            try expect(!EnvironmentOpeningPolicy.nativeActivationEnabled && !DesktopIntegrationPolicy.lifecycleEnabled
                && !DesktopIntegrationPolicy.primaryLifecycleEnabled && !UsageIntegrationPolicy.liveEnabled, "Global gates unchanged")
        }
    }
}
