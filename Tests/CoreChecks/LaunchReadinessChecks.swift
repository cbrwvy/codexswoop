import Foundation
import Darwin
import CodexSwoopCore

private actor ReadinessScript {
    var samples: [Result<DesktopObservation, EnvironmentError>]
    var calls = 0
    init(_ samples: [Result<DesktopObservation, EnvironmentError>]) { self.samples = samples }
    func observe(_ timeout: Duration) throws -> DesktopObservation {
        calls += 1
        precondition(timeout > .zero && timeout <= .seconds(5))
        let value = samples.count > 1 ? samples.removeFirst() : samples[0]
        return try value.get()
    }
}

extension CoreChecks {
    @MainActor static func launchReadinessChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let first = OpeningSystem.instance(1), replacement = OpeningSystem.instance(2)
        func ready(_ instance: DesktopInstance) -> Result<DesktopObservation, EnvironmentError> {
            .success(DesktopObservation(matching: [instance], ambiguous: false))
        }
        let pending: Result<DesktopObservation, EnvironmentError> = .success(DesktopObservation(matching: [], ambiguous: false))
        for (name, samples, expected) in [
            ("GUI before backend / initial postflight ambiguity", [pending, .failure(.ambiguousInstance), ready(first), ready(first)], first),
            ("backend generation stabilizes", [.failure(.processChanged), ready(first), ready(replacement), ready(replacement)], replacement),
            ("first completed sample is insufficient", [ready(first), .failure(.processChanged), ready(replacement), ready(replacement)], replacement)
        ] {
            await run("Readiness: " + name) {
                let script = ReadinessScript(samples)
                let instance = try await DesktopReadiness.wait(timeout: .seconds(1), interval: .milliseconds(1)) { try await script.observe($0) }
                let calls = await script.calls
                try expect(instance == expected && calls >= 4, "Only stable strict snapshots accepted")
            }
        }
        for (name, value) in [("no process", pending), ("ambiguous mains", .failure(.ambiguousInstance)), ("unstable PID", .failure(.processChanged))] {
            await run("Readiness: bounded timeout for " + name) {
                let script = ReadinessScript([value])
                do {
                    _ = try await DesktopReadiness.wait(timeout: .milliseconds(15), interval: .milliseconds(2)) { try await script.observe($0) }
                    throw CheckFailure(description: "Unconfirmed readiness accepted")
                } catch EnvironmentError.readinessTimedOut {}
                try expect(await script.calls < 30, "Bounded read-only observations")
            }
        }
        for error in [EnvironmentError.incompatibleBuild, .unsafeDirectory, .changedDirectory, .invalidPath, .launchFailed] {
            await run("Readiness: security/fatal error never becomes readiness: \(error)") {
                let script = ReadinessScript([.failure(error), ready(first), ready(first)])
                do {
                    _ = try await DesktopReadiness.wait(timeout: .seconds(1), interval: .milliseconds(1)) { try await script.observe($0) }
                    throw CheckFailure(description: "Security failure ignored")
                } catch let actual as EnvironmentError { try expect(actual == error, "Exact fatal failure") }
                try expect(await script.calls == 1, "No retry after security rejection")
            }
        }
        await run("Readiness: cancellation stops observations") {
            let script = ReadinessScript([pending])
            let task = Task { try await DesktopReadiness.wait(timeout: .seconds(1)) { try await script.observe($0) } }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(description: "Cancelled readiness succeeded") } catch is CancellationError {}
        }
        await run("Readiness: strict GUI/backend/root ownership cannot be bypassed") {
            let main = DesktopProcessEvidence(generation: first.main, parent: 1, role: .main, homeDescriptors: 2, electronDescriptors: 2)
            let backend = DesktopProcessEvidence(generation: replacement.main, parent: first.main.pid, role: .backend, homeDescriptors: 1)
            do { _ = try DesktopOwnership.resolve(before: [main], after: [main], standard: false); throw CheckFailure(description: "GUI alone accepted") }
            catch EnvironmentError.ambiguousInstance {}
            try expect(try DesktopOwnership.resolve(before: [main, backend], after: [main, backend], standard: false).count == 1, "Both roots and backend required")
        }
        for standard in [false, true] {
            await run("Readiness integration: all closed, \(standard ? "Standard External" : "Managed"), saved inactive environment, delayed backend and PID replacement") {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString), running: false)
                await f.system.setInstance(nil, for: f.f.associations[0])
                let store = f.f.store
                let new = try await store.previewNewAccount(name: "Fictional retained inactive", managed: true, validator: f.f.validator)
                _ = try await store.commitAccountSetup(new)
                let saved = try await store.inspect().profiles.last!
                let removal = try await store.previewProfileRemoval(id: saved.id)
                _ = try await store.commitAccountSetup(removal)
                let before = try await store.inspectAssociations()
                let metadata = try await store.inspect()
                let retained = try await store.inspectAccountSetup().retained
                await f.system.scriptLaunchReadiness([pending, .failure(.ambiguousInstance), ready(first),
                    .failure(.processChanged), ready(replacement), ready(replacement)])
                let selected = standard ? f.f.profiles[0] : f.target
                try await f.coordinator.openAccount(to: selected, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
                try expect(await f.system.effects == ["launch", "pidActivate"], "Exactly one launch followed by verified activation")
                try expect(await f.coordinator.state == .environmentOpened(selected.id), "No false recovery latch after bounded readiness")
                let afterAssociations = try await store.inspectAssociations(), afterMetadata = try await store.inspect()
                try expect(afterAssociations == before && afterMetadata == metadata, "Metadata and revision unchanged by opening")
                try expect(try await store.inspectAccountSetup().retained == retained, "Saved inactive environment preserved")
                try await f.coordinator.openAccount(to: selected, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
                try expect(await f.system.effects == ["launch", "pidActivate", "pidActivate"], "Repeat cannot duplicate an instance")
                let identityCalls = await f.verifier.calls, axCalls = await f.system.axCalls
                try expect(identityCalls == 0 && axCalls == 0, "No identity API or AX requirement")
            }
        }
        await run("Review: concurrent metadata change keeps recovery latch and performs no lifecycle effect") {
            let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString), running: false)
            await f.system.configurePreciseDispatch()
            await f.system.configure(activation: true)
            do { try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true }) } catch {}
            let store = f.f.store, id = f.target.id
            let before = await f.system.effects
            await f.system.mutateNextInventory { _ = try await store.rename(id: id, name: "Changed during read-only review") }
            do { try await f.coordinator.acknowledgeOpeningRecovery(userReviewed: true); throw CheckFailure(description: "Stale review accepted") }
            catch OpeningJournalError.conflict {}
            try expect(await f.coordinator.state == .recoveryRequired, "Pending journal prevents concurrent metadata mutation")
            try expect(await f.system.effects == before, "No launch, activation or close during review")
        }
        for unknown in [false, true] {
            await run("Review: read-only reconciliation \(unknown ? "retains unknown latch" : "resolves confirmed launch")") {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString), running: false)
                await f.system.configurePreciseDispatch()
            await f.system.configure(activation: true)
                do {
                    try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
                    throw CheckFailure(description: "Activation failure expected")
                } catch {}
                let before = await f.system.effects
                if unknown { await f.system.configure(unknown: 1) }
                if unknown {
                    do { try await f.coordinator.acknowledgeOpeningRecovery(userReviewed: true); throw CheckFailure(description: "Unknown dismissed") }
                    catch AccountOpeningError.unknownInstances {}
                    try expect(await f.coordinator.state == .recoveryRequired, "Latch retained")
                } else {
                    try await f.coordinator.acknowledgeOpeningRecovery(userReviewed: true)
                    try expect(await f.coordinator.state == .idle, "Verified result unlatches")
                }
                try expect(await f.system.effects == before, "Review never launches, activates or closes")
            }
        }
    }
}
