import Foundation
import Darwin
import CodexSwoopCore

extension CoreChecks {
    @MainActor static func scopedOpeningChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func scenario(_ name: String, running: Bool = true,
                      _ body: @escaping @MainActor (EnvironmentOpeningFixture) async throws -> Void) async {
            await run("Reusable opening: " + name) {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString), running: running)
                let metadata = f.f.validator.managedRoot.appendingPathComponent("environments.json")
                let before = try Data(contentsOf: metadata)
                try await body(f)
                try expect(try Data(contentsOf: metadata) == before, "Revision 3 and associations retained")
                let calls = await f.verifier.calls, readiness = await f.verifier.readinessCalls
                try expect(calls == 0 && readiness == 0, "Environment opening never grants technical identity")
                try expect(await f.system.axCalls == 0, "No Accessibility dependency")
            }
        }
        @MainActor @Sendable func open(_ f: EnvironmentOpeningFixture, profile: AccountProfile? = nil, mode: AccountOpeningMode = .openSeparately) async throws {
            try await f.coordinator.openAccount(to: profile ?? f.target, mode: mode, environmentScoped: true,
                confirmOpen: { _ in true }, confirmClose: { _ in .confirm(allowPrimary: true) })
        }
        for action in ["activate", "launch", "quit"] {
            await scenario("known no-dispatch failure does not require manual recovery: " + action, running: action != "launch") { f in
                await f.system.configurePreciseDispatch(failBefore: action)
                let mode: AccountOpeningMode = action == "quit" ? .closeOthersAndOpen : .openSeparately
                try await openingError(.opening(.processChanged)) { try await open(f, mode: mode) }
                let state = await f.coordinator.state, progress = await f.coordinator.openingProgress
                try expect(state == .failed && !progress.actionMayHaveOccurred, "Receiver preflight rejection is not an uncertain OS effect")
                let effects = await f.system.effects, scope = await f.system.operationScope
                try expect(effects.isEmpty && scope == nil, "No dispatch and old authority revoked")
                await f.system.configurePreciseDispatch()
                try await open(f, mode: mode)
                let history = await f.system.operationHistory
                try expect(history.count == 2 && Set(history).count == 2, "Next manual choice obtains a fresh scope, never retries old authority")
            }
        }
        await scenario("submitted activation failure still requires manual recovery") { f in
            await f.system.configurePreciseDispatch()
            await f.system.configure(activation: true)
            try await openingError(.activationFailed) { try await open(f) }
            try expect(await f.coordinator.state == .recoveryRequired, "Submitted uncertain effect retains safety latch")
            try await openingError(.opening(.recoveryRequired)) { try await open(f) }
            try expect(await f.system.effects == ["pidActivate"], "No automatic retry")
        }
        await scenario("settled activation reconciles read-only before a fresh manual choice") { f in
            await f.system.configurePreciseDispatch()
            await f.system.configure(activation: true)
            try await openingError(.activationFailed) { try await open(f) }
            try await f.coordinator.reconcileOpeningRecovery()
            try expect(await f.coordinator.state == .idle, "Fresh strict ownership can resolve an old foreground failure")
            let result = await f.coordinator.openingResult, effects = await f.system.effects
            try expect(result == nil && effects == ["pidActivate"], "Reconciliation neither retries nor claims opening success")
            await f.system.configure(activation: false)
            try await open(f)
            try expect(await f.system.operationHistory.count == 2, "Next selection obtains fresh authority")
        }
        await scenario("first-to-second postflight failure can reconcile and return to closed first") { f in
            await f.system.configurePreciseDispatch()
            await f.system.configurePID(nil, wrongForeground: true)
            try await openingError(.activationFailed) { try await open(f, mode: .closeOthersAndOpen) }
            try expect(await f.system.effects == ["quit", "wait", "pidActivate"], "First closed, second still running after uncertain foreground")
            try await f.coordinator.reconcileOpeningRecovery()
            await f.system.configurePID(nil, wrongForeground: false)
            try await open(f, profile: f.f.profiles[0], mode: .closeOthersAndOpen)
            try expect(await f.system.effects == ["quit", "wait", "pidActivate", "quit", "wait", "launch", "pidActivate"], "Return closes second and launches absent first under fresh consent")
            try expect(await f.coordinator.state == .environmentOpened(f.f.profiles[0].id), "Reverse path is no longer blocked by settled old postflight")
        }
        for change in ["absent target", "replacement target", "unknown inventory", "changed metadata"] {
            await scenario("automatic reconciliation refuses " + change) { f in
                await f.system.configurePreciseDispatch()
                await f.system.configure(activation: true)
                try await openingError(.activationFailed) { try await open(f) }
                switch change {
                case "absent target": await f.system.setInstance(nil, for: f.association)
                case "replacement target": await f.system.replace(f.association)
                case "unknown inventory": await f.system.configure(unknown: 1)
                default:
                    do { _ = try await f.f.store.rename(id: f.target.id, name: "Changed"); throw CheckFailure(description: "Pending metadata mutation accepted") }
                    catch OpeningJournalError.conflict {}
                    // Simulate out-of-band drift in disposable storage; the public writer is blocked.
                    var changed = try await f.f.store.inspect(); changed.revision += 1
                    try JSONEncoder().encode(changed).write(to: f.f.validator.managedRoot.appendingPathComponent("profiles.json"))
                }
                do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Unsafe reconciliation accepted") }
                catch is AccountOpeningError {} catch is EnvironmentOpeningError {} catch is OpeningJournalError {}
                try expect(await f.coordinator.state == .recoveryRequired, "Unresolved outcome remains guarded")
                try expect(await f.system.effects == ["pidActivate"], "No reconciliation actuator")
            }
        }
        await scenario("submitted launch is pending until launcher finished and target identified", running: false) { f in
            await f.system.configurePreciseDispatch()
            await f.system.configure(launch: true)
            try await openingError(.opening(.launchFailure)) { try await open(f) }
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Absent target accepted") }
            catch AccountOpeningError.recoveryRequired {}
            await f.system.setInstance(OpeningSystem.instance(20), for: f.association)
            await f.system.configureUnsettled(launcher: true)
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Running launcher accepted") }
            catch AccountOpeningError.recoveryRequired {}
            await f.system.configureUnsettled()
            try await f.coordinator.reconcileOpeningRecovery()
            try expect(await f.system.effects == ["launch"], "No duplicate launch or automatic activation")
        }
        await scenario("submitted quit must lose the entire captured group before reconciliation") { f in
            await f.system.configurePreciseDispatch()
            await f.system.configure(quit: true)
            try await openingError(.quitFailed) { try await open(f, mode: .closeOthersAndOpen) }
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Running quit receiver accepted") }
            catch AccountOpeningError.recoveryRequired {}
            let original = await f.system.instances[f.f.associations[0].environmentID]!
            await f.system.setInstance(nil, for: f.f.associations[0])
            await f.system.configureUnsettled(orphans: [original.related.last!.pid])
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Surviving child accepted") }
            catch AccountOpeningError.recoveryRequired {}
            await f.system.configureUnsettled()
            try await f.coordinator.reconcileOpeningRecovery()
            try expect(await f.system.effects == ["quit"], "No second termination or target activation")
        }
        await scenario("unknown dispatch adapters cannot reconcile automatically") { f in
            await f.system.configure(activation: true)
            try await openingError(.activationFailed) { try await open(f) }
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Unknown adapter accepted") }
            catch AccountOpeningError.recoveryRequired {}
            try expect(await f.coordinator.state == .recoveryRequired, "Legacy uncertainty remains explicit")
        }
        await scenario("metadata change during read-only reconciliation remains guarded") { f in
            await f.system.configurePreciseDispatch()
            await f.system.configure(activation: true)
            try await openingError(.activationFailed) { try await open(f) }
            await f.system.mutateNextInventory { _ = try await f.f.store.rename(id: f.target.id, name: "Changed during proof") }
            do { try await f.coordinator.reconcileOpeningRecovery(); throw CheckFailure(description: "Racing metadata accepted") }
            catch OpeningJournalError.conflict {}
            try expect(await f.coordinator.state == .recoveryRequired, "Metadata mutation is rejected while evidence is checked")
            try expect(await f.system.effects == ["pidActivate"], "No native effect during reconciliation")
        }
        await scenario("successful close followed by target preflight failure remains partial") { f in
            await f.system.configurePreciseDispatch(failBefore: "activate")
            try await openingError(.opening(.processChanged)) { try await open(f, profile: f.f.profiles[0], mode: .closeOthersAndOpen) }
            try expect(await f.coordinator.state == .recoveryRequired, "A completed quit cannot be downgraded to no-dispatch")
            try expect(await f.system.effects == ["quit", "wait"], "Only the explicitly confirmed other instance was closed")
        }
        await scenario("reverse close Work then launch absent Standard External") { f in
            await f.system.configurePreciseDispatch()
            await f.system.setInstance(nil, for: f.f.associations[0])
            try await open(f, profile: f.f.profiles[0], mode: .closeOthersAndOpen)
            try expect(await f.system.effects == ["quit", "wait", "launch", "pidActivate"], "Reverse path launches primary only after Work exit")
            try expect(await f.coordinator.state == .environmentOpened(f.f.profiles[0].id), "Verified reverse result")
        }
        for bothInitiallyRunning in [false, true] {
            await scenario("30 consecutive alternating close-and-open operations; initially both running: \(bothInitiallyRunning)", running: bothInitiallyRunning) { f in
                await f.system.configurePreciseDispatch()
                await f.activity.set(.unknown(.incompleteCoverage))
                var previous: DesktopGeneration?, observed = Set<DesktopGeneration>()
                for index in 0..<30 {
                    let profile = index.isMultiple(of: 2) ? f.target : f.f.profiles[0]
                    let association = index.isMultiple(of: 2) ? f.association : f.f.associations[0]
                    try await open(f, profile: profile, mode: .closeOthersAndOpen)
                    let instances = await f.system.instances
                    guard let current = instances[association.environmentID] else { throw CheckFailure(description: "Missing target at cycle \(index)") }
                    try expect(instances.count == 1 && current.main != previous, "Only fresh target survives cycle \(index)")
                    try expect(observed.insert(current.main).inserted, "Restarted instances never reuse synthetic generations")
                    previous = current.main
                    try expect(await f.coordinator.state == .environmentOpened(profile.id), "Coordinator reusable after cycle \(index)")
                    try expect(await f.system.operationScope == nil, "Old scope revoked at cycle \(index)")
                }
                let history = await f.system.operationHistory, effects = await f.system.effects
                try expect(history.count == 30 && Set(history).count == 30, "Thirty fresh explicit scopes")
                try expect(effects.filter { $0 == "quit" }.count == 30 && effects.filter { $0 == "wait" }.count == 30,
                    "Exactly one confirmed quit and wait per transition")
                try expect(effects.filter { $0 == "launch" }.count == (bothInitiallyRunning ? 29 : 30)
                    && effects.filter { $0 == "pidActivate" }.count == 30, "No duplicate launches or activations")
            }
        }
        await scenario("activate Work, Primary, Work; fresh authority every time") { f in
            let before = await f.system.instances
            try await open(f); try await open(f, profile: f.f.profiles[0]); try await open(f)
            try expect(await f.system.effects == ["pidActivate", "pidActivate", "pidActivate"], "Repeat and return without launch/quit")
            try expect(await f.system.instances == before, "Same generations")
            let ids = await f.system.operationHistory
            try expect(ids.count == 3 && Set(ids).count == 3 && f.system.lifecycleAllowed == false, "No global gate")
            try expect(await f.coordinator.state == .environmentOpened(f.target.id), "No Account Verified state")
            try expect(await f.system.operationScope == nil, "Authority revoked on completion")
        }
        await scenario("launch closed Managed once, then activate without duplicate", running: false) { f in
            try await open(f); try await open(f)
            try expect(await f.system.effects == ["launch", "pidActivate", "pidActivate"], "One launch only")
            let specs = await f.system.scopedLaunchSpecifications
            let paths = DesktopLaunchPaths(association: f.association)
            try expect(specs.count == 1 && specs[0].arguments.contains("CODEX_HOME=" + paths.home)
                && specs[0].arguments.contains("CODEX_ELECTRON_USER_DATA_PATH=" + paths.electron)
                && specs[0].arguments.contains("--user-data-dir=" + paths.electron), "Paired identity-bound launch roots")
            try expect(specs[0].environment == ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], "No inherited credentials/environment")
        }
        await scenario("launch closed Standard External; preserve Work") { f in
            let primary = f.f.associations[0], work = await f.system.instances[f.association.environmentID]
            await f.system.setInstance(nil, for: primary)
            try await open(f, profile: f.f.profiles[0])
            try expect(await f.system.scopedLaunchSpecifications.first?.association == primary, "Explicit standard roots")
            try expect(await f.system.instances[f.association.environmentID] == work, "Other account retained")
        }
        for status in [CodexActivityStatus.idle, .unknown(.incompleteCoverage),
                       .assess(operations: [.init(location: .local, kind: .runningTurn)], coverageComplete: true, fresh: true)] {
            await scenario("close Primary with explicit Idle/Busy/Unknown consent: \(status)") { f in
                await f.activity.set(status)
                let consent = OpeningConsent()
                try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen, environmentScoped: true,
                    confirmClose: { await consent.accept($0) })
                let values = await consent.values
                try expect(values.count == 1 && values[0].affected.map(\.profile.id) == [f.f.profiles[0].id]
                    && values[0].activities == [status] && values[0].requiresPrimaryConsent, "Exact close list and scoped activity")
                try expect(await f.system.effects == ["quit", "wait", "pidActivate"], "Normal quit, confirmed exit, activation")
                try await open(f, profile: f.f.profiles[0])
                try expect(await f.system.instances.count == 2, "Return by launching the closed account")
            }
        }
        await scenario("close Work and keep Standard External") { f in
            try await open(f, profile: f.f.profiles[0], mode: .closeOthersAndOpen)
            try expect(await f.system.instances[f.association.environmentID] == nil, "Work exited")
            try expect(await f.coordinator.state == .environmentOpened(f.f.profiles[0].id), "Primary retained")
        }
        await scenario("close before launching missing target", running: false) { f in
            try await open(f, mode: .closeOthersAndOpen)
            try expect(await f.system.effects == ["quit", "wait", "launch", "pidActivate"], "Launch only after exits")
        }
        for mode in AccountOpeningMode.allCases {
            await scenario("Cancel is default: \(mode)") { f in
                try await openingError(.opening(.userCancelled)) {
                    try await f.coordinator.openAccount(to: f.target, mode: mode, environmentScoped: true)
                }
                let effects = await f.system.effects, history = await f.system.operationHistory
                try expect(effects.isEmpty && history.isEmpty, "No authority or effects")
                try await open(f)
            }
        }
        await scenario("unknown reserve A blocks closing; separate opening still works") { f in
            await f.system.configure(unknown: 1)
            try await openingError(.opening(.unknownInstances)) { try await open(f, mode: .closeOthersAndOpen) }
            try expect(await f.system.effects.isEmpty, "Unknown never ignored or closed")
            try await open(f)
        }
        await scenario("missing primary checkbox cannot grant closing authority") { f in
            try await openingError(.opening(.primaryConsentRequired)) {
                try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen, environmentScoped: true,
                    confirmClose: { _ in .confirm(allowPrimary: false) })
            }
            let effects = await f.system.effects, scope = await f.system.operationScope
            try expect(effects.isEmpty && scope == nil, "No authorization")
        }
        for change in ["PID", "launchDate", "UID", "started"] {
            await scenario("reject changed \(change) after consent") { f in
                try await openingError(.opening(.processChanged)) {
                    try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true,
                        confirmOpen: { plan in
                            let old = plan.targetInstance!
                            let g = DesktopGeneration(pid: old.main.pid + (change == "PID" ? 1 : 0),
                                uid: old.main.uid + (change == "UID" ? 1 : 0), started: change == "started" ? "replacement" : old.main.started)
                            await f.system.setInstance(DesktopInstance(main: g, related: [g], nativeLaunchDate:
                                change == "launchDate" ? old.nativeLaunchDate.addingTimeInterval(-1) : old.nativeLaunchDate), for: f.association)
                            return true
                        })
                }
                try expect(await f.system.effects.isEmpty, "Stale consent cannot dispatch")
            }
        }
        await scenario("target becomes running during launch confirmation", running: false) { f in
            try await openingError(.opening(.processChanged)) {
                try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in
                    await f.system.replace(f.association); return true
                })
            }
            try expect(await f.system.effects.isEmpty, "No duplicate")
        }
        await scenario("ambiguous / wrong-root observation blocks") { f in
            await f.system.configure(ambiguous: true)
            try await openingError(.opening(.ambiguousInstance)) { try await open(f) }
            try expect(await f.system.effects.isEmpty, "No guessed owner")
        }
        await scenario("directory identity changes during confirmation") { f in
            try await openingError(.environment(.unsafeDirectory)) {
                try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { plan in
                    chmod(plan.association.electronData, 0o777); return true
                })
            }
            try expect(await f.system.effects.isEmpty, "No unsafe environment effect")
        }
        await scenario("installation signature/build rejection") { f in
            await f.system.rejectInstallation()
            try await openingError(.environment(.incompatibleBuild)) { try await open(f) }
            try expect(await f.system.effects.isEmpty, "Unreviewed app blocked")
        }
        await scenario("another operation while confirming is Busy") { f in
            try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in
                do { try await open(f); return false }
                catch SwitchingError.opening(.busy) { return true } catch { return false }
            })
        }
        await scenario("task cancellation before effects permits fresh retry") { f in
            let task = Task { try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return true
            }) }
            try await openingError(.opening(.userCancelled)) { try await task.value }
            try expect(await f.system.effects.isEmpty, "No cancelled dispatch")
            try await open(f)
        }
        for kind in ["launch", "quit", "timeout", "foreground", "generation", "missing observation"] {
            await scenario("failure/manual review cannot waive unknown proof: " + kind, running: kind != "launch" && kind != "missing observation") { f in
                await f.system.configure(launch: kind == "launch", quit: kind == "quit", timeout: kind == "timeout")
                if kind == "foreground" { await f.system.configurePID(nil, wrongForeground: true) }
                if kind == "generation" { await f.system.configureReplacementAfterActivation() }
                if kind == "missing observation" { await f.system.suppressLaunchedInstance() }
                do { try await open(f, mode: kind == "quit" || kind == "timeout" ? .closeOthersAndOpen : .openSeparately)
                    throw CheckFailure(description: "Failure not reported")
                } catch is SwitchingError {}
                let state = await f.coordinator.state, result = await f.coordinator.openingResult
                try expect(state == .recoveryRequired && result == nil, "Uncertain effects require review")
                try expect(await f.system.operationScope == nil, "Old authority revoked")
                try await openingError(.opening(.recoveryRequired)) { try await open(f) }
                try await openingError(.opening(.recoveryRequired)) { try await f.coordinator.switchAccount(to: f.target, workInterruptionConfirmed: true) }
                do { try await f.coordinator.acknowledgeOpeningRecovery(userReviewed: false); throw CheckFailure(description: "Implicit review") }
                catch AccountOpeningError.recoveryRequired {}
                let before = await f.system.effects
                do { try await f.coordinator.acknowledgeOpeningRecovery(userReviewed: true); throw CheckFailure(description: "User claim waived missing proof") }
                catch AccountOpeningError.recoveryRequired {}
                try expect(await f.coordinator.state == .recoveryRequired, "Manual review cannot bypass read-only proof")
                try expect(await f.system.effects == before, "No retry or recovery actuator")
            }
        }
        await scenario("post-close launch failure reports partial completion", running: false) { f in
            await f.system.configure(launch: true)
            try await openingError(.opening(.launchFailure)) { try await open(f, mode: .closeOthersAndOpen) }
            let disposition = await f.coordinator.openingDisposition, progress = await f.coordinator.openingProgress
            try expect(disposition == .partialCompletion && progress.closedProfileIDs == [f.f.profiles[0].id], "Precise confirmed closure list")
            try expect(await f.system.effects == ["quit", "wait", "launch"], "No recovery launch")
        }
        for variant in ["success", "second quit failure", "changed marker", "backup drift"] {
            await run("Reusable opening: retained Reserve A " + variant) {
                let r = try await ReplacementFixture.make(base.appendingPathComponent(UUID().uuidString))
                defer { try? FileManager.default.removeItem(at: r.lab) }
                let preview = try await r.preview()
                _ = try await r.store.replaceEnvironmentAssociation(profileID: r.profile.id, preview: preview, validator: r.validator)
                let current = try await r.store.inspectAssociations()
                let backup = try Data(contentsOf: r.url("environments.backup.json"))
                let system = OpeningSystem(lifecycle: false), activity = OpeningActivity()
                await system.seed(current.associations + [r.old])
                let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: r.store, validator: r.validator, system: system)
                let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: activity)
                if variant == "second quit failure" { await system.rejectSecondQuit() }
                if variant == "changed marker" { chmod(r.lab.appendingPathComponent("lab.json").path, 0o644) }
                do {
                    try await coordinator.openAccount(to: r.profile, mode: .closeOthersAndOpen, environmentScoped: true,
                        confirmClose: { confirmation in
                            let reserve = confirmation.affected.filter { $0.association.isTemporary }
                            guard reserve.count == 1, reserve[0].displayName.contains("Reserve A"),
                                  reserve[0].operationID == r.old.environmentID else { return .cancel }
                            if variant == "backup drift" {
                                var catalog = try! await r.store.inspectAssociations()
                                catalog.revision = 4
                                let url = r.validator.managedRoot.appendingPathComponent("environments.backup.json")
                                try! AtomicMetadataWriter().write(JSONEncoder().encode(catalog), to: url)
                            }
                            return .confirm(allowPrimary: true)
                        })
                    try expect(variant == "success", "Injected failure reported")
                    try expect(await system.effects == ["quit", "wait", "quit", "wait", "pidActivate"], "A separately confirmed and closed normally")
                    try expect(await coordinator.openingProgress.closedInstanceNames.contains(where: { $0.contains("Reserve A") }), "A separate in result")
                } catch is SwitchingError {
                    try expect(variant != "success", "Expected safe result")
                    if variant == "changed marker" || variant == "backup drift" {
                        try expect(await system.effects.isEmpty, "Invalid A proof prevents all effects")
                    } else {
                        try expect(await coordinator.openingDisposition == .partialCompletion, "Partial multi-quit reported")
                        try expect(await system.effects == ["quit", "wait", "quit"], "No activation after second quit failure")
                    }
                }
                if variant != "backup drift" { try expect(try Data(contentsOf: r.url("environments.backup.json")) == backup, "Reserve reference unchanged") }
                try expect(FileManager.default.fileExists(atPath: r.old.codexHome) && FileManager.default.fileExists(atPath: r.old.electronData), "Reserve A directories preserved")
            }
        }
        await run("Reusable opening: reconcile separate activation while known Reserve A remains open") {
            let r = try await ReplacementFixture.make(base.appendingPathComponent(UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: r.lab) }
            _ = try await r.store.replaceEnvironmentAssociation(profileID: r.profile.id, preview: r.preview(), validator: r.validator)
            let current = try await r.store.inspectAssociations()
            let system = OpeningSystem(lifecycle: false)
            await system.seed(current.associations + [r.old])
            await system.configurePreciseDispatch()
            await system.configure(activation: true)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: r.store, validator: r.validator, system: system)
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            try await openingError(.activationFailed) {
                try await coordinator.openAccount(to: r.profile, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
            }
            try await coordinator.reconcileOpeningRecovery()
            try expect(await coordinator.state == .idle, "Fresh inventory includes known retained references even for separate opening")
            try expect(await system.effects == ["pidActivate"], "Reserve A is not closed by reconciliation")
        }
        await scenario("native addressed methods deny unconfirmed scope before OS effects") { f in
            let plan = try await f.driver.planEnvironmentAccount(profile: f.target, mode: .openSeparately)
            let scope = EnvironmentOperationScope(plan: plan, managed: try await f.f.store.inspectManagedEnvironments())
            let native = NativeDesktopSystem(validator: f.f.validator)
            do { try await native.activateScopedEnvironment(scope, instance: plan.targetInstance!); throw CheckFailure(description: "Ungated activation") }
            catch EnvironmentOpeningError.confirmationRequired {}
            do { _ = try await native.launchScopedEnvironment(scope); throw CheckFailure(description: "Ungated launch") }
            catch EnvironmentOpeningError.confirmationRequired {}
            do { try await native.quitScopedEnvironment(scope, item: DesktopInventoryEntry(association: f.association, instance: plan.targetInstance!)); throw CheckFailure(description: "Ungated quit") }
            catch EnvironmentOpeningError.confirmationRequired {}
            let expired = EnvironmentOperationScope(plan: plan, managed: scope.managed, expiresAt: Date().addingTimeInterval(-1))
            do { try expired.validate(); throw CheckFailure(description: "Expired scope accepted") }
            catch EnvironmentOpeningError.stalePlan {}
            await f.driver.finishOpening(plan, success: false)
            try expect(!native.lifecycleAllowed && !native.standardLifecycleAllowed && !UsageIntegrationPolicy.liveEnabled, "Global gates closed")
        }
        await scenario("metadata and user sentinel data retained across launch/close/return") { f in
            let paths = f.f.associations.flatMap { [$0.codexHome, $0.electronData] }.map { URL(fileURLWithPath: $0).appendingPathComponent("user-sentinel.txt") }
            for path in paths { try Data("private fixture user data".utf8).write(to: path) }
            let profiles = try await f.f.store.inspect()
            try await open(f, mode: .closeOthersAndOpen); try await open(f, profile: f.f.profiles[0])
            for path in paths { try expect(try Data(contentsOf: path) == Data("private fixture user data".utf8), "User data retained") }
            try expect(try await f.f.store.inspect() == profiles, "Profile UUID/name/dates unchanged")
            let usage = UsageCoordinator(provider: UsageFixtureProvider()); usage.synchronize(f.f.associations); usage.refresh(f.target.id)
            try expect(usage.state(for: f.target.id).status == .verificationRequired, "Usage still requires technical identity")
        }
    }
}
