import CryptoKit
import CodexSwoopCore
import Darwin
import Foundation

extension CoreChecks {
    /// Disposable child exits without cleanup to reproduce Swoop death, never Codex death.
    static func openingJournalWorker() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 4, args[2].hasPrefix("/private/tmp/codexswoop-checks-"),
              !args[2].split(separator: "/").contains("..") else { exit(2) }
        let root = URL(fileURLWithPath: args[2])
        let mode = args[3], counter = JournalCrashCounter()
        if mode == "metadata-probe" {
            do { _ = try await ProfileStore(root: root).create(name: "Concurrent probe"); exit(9) }
            catch ProfileError.storeBusy { exit(0) }
        }
        let stage = mode.hasSuffix("effect") ? 2 : (mode.hasSuffix("complete") ? 3 : 1)
        let writer = AtomicMetadataWriter { path in
            let name = path.lastPathComponent
            let occurrence = counter.next(name)
            if mode.hasPrefix("bootstrap-before-") && occurrence == 1,
               name == (mode.hasSuffix("marker") ? "opening-journal-watermark.json" : "opening-journal.json") { _exit(0) }
            if mode.hasPrefix("crash-before-"), occurrence == stage,
               name == (mode.contains("-marker-") ? "opening-journal-watermark.json" : "opening-journal.json") { _exit(0) }
        }
        let journal = OpeningOperationJournal(root: root, writer: writer)
        if mode.hasPrefix("bootstrap-") { try journal.initializeFreshStore(); _exit(0) }
        let record = try JSONDecoder().decode(PendingOpeningOperation.self,
            from: Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("synthetic-opening-intent.json")))
        do { try journal.begin(record) } catch OpeningJournalError.busy { exit(7) }
        if mode == "crash-after-intent" { _exit(0) }
        if mode.hasPrefix("crash-") {
            if !mode.hasSuffix("intent") { try journal.append(.activation(record.targetInstance!), operation: record.id) }
            if mode.hasSuffix("complete") { try journal.complete(record.id) }
            _exit(0)
        }
        if args[3] == "activation", let instance = record.targetInstance {
            try journal.append(.activation(instance), operation: record.id)
        } else if args[3] == "partial", let item = record.others.first {
            try journal.append(.normalQuit(item.instance), operation: record.id)
        } else if args[3] == "hold" {
            try Data().write(to: root.deletingLastPathComponent().appendingPathComponent("opening-worker-ready"))
            _ = try FileHandle.standardInput.read(upToCount: 1)
        }
        _exit(0) // No deinit/finish/postflight; OS releases the lease.
    }

    @MainActor static func openingJournalChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func scenario(_ title: String, running: Bool = true,
            _ body: @escaping @MainActor (EnvironmentOpeningFixture) async throws -> Void) async {
            await run("Durable opening: " + title) {
                let f = try await EnvironmentOpeningFixture.make(base.appendingPathComponent(UUID().uuidString), running: running)
                await f.system.configurePreciseDispatch()
                try await body(f)
            }
        }
        func record(_ f: EnvironmentOpeningFixture, mode: AccountOpeningMode = .openSeparately,
            boot: String = "synthetic-boot") async throws -> PendingOpeningOperation {
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.f.store,
                validator: f.f.validator, system: f.system)
            let plan = try await driver.planEnvironmentAccount(profile: f.target, mode: mode)
            let managed = try await f.f.store.inspectManagedEnvironments()
            let retained = mode == .closeOthersAndOpen ? try await f.f.store.inspectRetainedResearchEnvironments() : []
            return try PendingOpeningOperation(scope: EnvironmentOperationScope(plan: plan,
                managed: managed, retainedResearch: retained), bootSession: boot, buildFingerprint: try await f.system.openingBuildFingerprint())
        }
        func restarted(_ f: EnvironmentOpeningFixture) -> AccountSwitchingCoordinator {
            AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
                store: ProfileStore(root: f.f.validator.managedRoot), validator: f.f.validator, system: f.system))
        }
        func child(_ f: EnvironmentOpeningFixture, _ intent: PendingOpeningOperation, mode: String,
            input: Pipe? = nil) throws -> Process {
            try JSONEncoder().encode(intent).write(to: f.f.root.appendingPathComponent("synthetic-opening-intent.json"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            process.arguments = ["--opening-journal-worker", f.f.validator.managedRoot.path, mode]
            if let input { process.standardInput = input } else { process.standardInput = FileHandle.nullDevice }
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        func open(_ f: EnvironmentOpeningFixture) async throws {
            try await f.coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
        }
        for preserved in [false, true] {
            await run("Durable opening: fresh store, two profiles, restart; preserved directories=\(preserved)") {
                let root = base.appendingPathComponent(UUID().uuidString)
                let environment = root.appendingPathComponent("Profiles/unused-environment")
                let sentinel = environment.appendingPathComponent("preserved.txt")
                if preserved {
                    try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    try Data("Synthetic preserved environment".utf8).write(to: sentinel)
                }
                let store = ProfileStore(root: root)
                _ = try await store.load()
                let path = root.appendingPathComponent("opening-journal.json")
                let watermark = root.appendingPathComponent("opening-journal-watermark.json")
                let before = try Data(contentsOf: path), beforeMarker = try Data(contentsOf: watermark)
                let envelope = try JSONSerialization.jsonObject(with: before) as! [String: Any]
                let marker = try JSONSerialization.jsonObject(with: beforeMarker) as! [String: Any]
                try expect(envelope["storeID"] as? String == marker["storeID"] as? String,
                    "Fresh store ID matches")
                try expect(envelope["revision"] as? Int == 0 && marker["revision"] as? Int == 0,
                    "Fresh revision is zero")
                try expect(marker["journalSHA256"] as? String == SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(),
                    "Watermark binds exact journal bytes")
                _ = try await store.create(name: "Fixture One")
                let expected = try await store.create(name: "Fixture Two")
                let restarted = ProfileStore(root: root)
                try expect(try await restarted.load() == expected, "Both profiles survive restart")
                try expect(try OpeningOperationJournal(root: root).pending() == nil, "No invented pending operation")
                try expect(try Data(contentsOf: path) == before && Data(contentsOf: watermark) == beforeMarker,
                    "Profile creation and startup retain the consistent idle pair")
                if preserved { try expect(try Data(contentsOf: sentinel) == Data("Synthetic preserved environment".utf8),
                    "Unreferenced environment contents retained") }
            }
        }
        await scenario("launched receiver replaced before recovery retains exact evidence", running: false) { f in
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot)
            let intent = try await record(f)
            let original = OpeningSystem.instance(70)
            try journal.begin(intent); try journal.append(.launch, operation: intent.id)
            try journal.append(.activation(original), operation: intent.id); journal.abandon()
            await f.system.setInstance(OpeningSystem.instance(71), for: f.association)
            let root = f.f.validator.managedRoot
            let before = try Data(contentsOf: root.appendingPathComponent("opening-journal.json"))
            let marker = try Data(contentsOf: root.appendingPathComponent("opening-journal-watermark.json"))
            let recovered = restarted(f)
            try expect(try await recovered.refreshOpeningRecovery(), "Recorded effects restore real recovery")
            do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Replacement accepted as historical proof") }
            catch AccountOpeningError.recoveryTargetChanged {}
            try expect(await recovered.state == .recoveryRequired, "Unknown historical result stays blocked")
            try expect(try Data(contentsOf: root.appendingPathComponent("opening-journal.json")) == before
                && Data(contentsOf: root.appendingPathComponent("opening-journal-watermark.json")) == marker,
                "Both original evidence files remain byte-identical")
            try expect(await f.system.effects.isEmpty, "Reconciliation has no lifecycle effects")
        }
        await scenario("successful postflight leaves versioned idle record and permits fresh consent") { f in
            try await open(f)
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot)
            try expect(try journal.pending() == nil, "Verified operation settled")
            try expect(try await restarted(f).refreshOpeningRecovery() == false, "Restart without invented recovery")
            try expect(await f.system.effects == ["pidActivate"], "Recovery never repeats an effect")
        }
        await scenario("failure before intent creates no pending record") { f in
            await f.system.configure(unknown: 1)
            do {
                try await f.coordinator.openAccount(to: f.target, mode: .closeOthersAndOpen, environmentScoped: true)
                throw CheckFailure(description: "Unknown process accepted")
            } catch SwitchingError.opening(.unknownInstances) {}
            try expect(try OpeningOperationJournal(root: f.f.validator.managedRoot).pending() == nil, "No action, no intent")
        }
        for mode in ["intent", "activation", "partial"] {
            await scenario("child exits before postflight: " + mode) { f in
                let intent = try await record(f, mode: mode == "partial" ? .closeOthersAndOpen : .openSeparately)
                let process = try child(f, intent, mode: mode)
                try await waitUntil { !process.isRunning }
                try expect(process.terminationStatus == 0, "Synthetic worker exited without cleanup")
                let recovered = restarted(f)
                try expect(try await recovered.refreshOpeningRecovery(), "Needs Review restored")
                try await openingError(.opening(.recoveryRequired)) {
                    try await recovered.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true)
                }
                if mode == "activation" {
                    try await recovered.reconcileOpeningRecovery()
                    try expect(await recovered.state == .idle, "Exact original receiver is sufficient")
                } else if mode == "partial" {
                    let other = f.f.associations[0]
                    await f.system.setInstance(nil, for: other) // Synthetic already-closed outcome.
                    try await recovered.reconcileOpeningRecovery()
                    try expect(await recovered.state == .idle, "Partial close resolved with living exact target")
                } else {
                    do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Intent alone settled") }
                    catch AccountOpeningError.recoveryRequired {}
                    try expect(await recovered.state == .recoveryRequired, "Unobserved intent cannot be replayed or timed out")
                }
                try expect(await f.system.effects.isEmpty, "Restart and Check Again performed no lifecycle action")
            }
        }
        await scenario("two OS processes serialize, and recovery cannot steal a live lease") { f in
            let intent = try await record(f), pipe = Pipe()
            let first = try child(f, intent, mode: "hold", input: pipe)
            try await waitUntil { FileManager.default.fileExists(atPath: f.f.root.appendingPathComponent("opening-worker-ready").path) }
            let second = try child(f, intent, mode: "intent")
            try await waitUntil { !second.isRunning }
            try expect(second.terminationStatus == 7, "Second Swoop cannot dispatch")
            let recovered = restarted(f)
            _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Live owner stolen") }
            catch OpeningJournalError.busy {}
            try pipe.fileHandleForWriting.write(contentsOf: Data([1]))
            try await waitUntil { !first.isRunning }
            try expect(try OpeningOperationJournal(root: f.f.validator.managedRoot).pending()?.id == intent.id, "Original intent retained")
        }
        for change in ["malformed", "future schema", "contradiction", "changed generation", "unknown process", "new boot", "absent after boot"] {
            await scenario("Check Again refuses " + change) { f in
                let journal = OpeningOperationJournal(root: f.f.validator.managedRoot)
                let intent = try await record(f, boot: change.contains("boot") ? "different-boot" : "synthetic-boot")
                try journal.begin(intent)
                try journal.append(.activation(intent.targetInstance!), operation: intent.id)
                journal.abandon()
                let path = f.f.validator.managedRoot.appendingPathComponent("opening-journal.json")
                switch change {
                case "malformed": try Data("{".utf8).write(to: path)
                case "future schema", "contradiction":
                    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                    if change == "future schema" { json["schemaVersion"] = 99 } else { json["state"] = "idle" }
                    let data = try JSONSerialization.data(withJSONObject: json)
                    try data.write(to: path)
                    if change == "future schema" {
                        // Keep the pair consistent to test schema rejection, not only hash mismatch.
                        let markerPath = f.f.validator.managedRoot.appendingPathComponent("opening-journal-watermark.json")
                        var marker = try JSONSerialization.jsonObject(with: Data(contentsOf: markerPath)) as! [String: Any]
                        marker["journalSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        try JSONSerialization.data(withJSONObject: marker).write(to: markerPath)
                    }
                case "changed generation": await f.system.replace(f.association)
                case "unknown process": await f.system.configure(unknown: 1)
                case "absent after boot": await f.system.setInstance(nil, for: f.association)
                default: break
                }
                let before = try Data(contentsOf: path), recovered = restarted(f)
                do { _ = try await recovered.refreshOpeningRecovery() } catch { /* Invalid records still latch review. */ }
                do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Unsafe journal settled") }
                catch is OpeningJournalError {} catch is AccountOpeningError {}
                try expect(await recovered.state == .recoveryRequired, "Blocking warning retained")
                try expect(try Data(contentsOf: path) == before, "Failed observation never rewrites the record")
                try expect(await f.system.effects.isEmpty, "No replay")
            }
        }
        await scenario("intent write failure prevents every OS effect") { f in
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot, writer: AtomicMetadataWriter { _ in throw OpeningJournalError.unavailable })
            let coordinator = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
                store: f.f.store, validator: f.f.validator, system: f.system, openingJournal: journal))
            do {
                try await coordinator.openAccount(to: f.target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
                throw CheckFailure(description: "Failed journal write accepted")
            } catch is SwitchingError {}
            try expect(await f.system.effects.isEmpty, "Atomic intent barrier precedes OS calls")
            try expect(try journal.pending() == nil, "Failed pre-rename save left no pending intent")
        }
        await scenario("pending journal blocks metadata changes and manual acknowledgement cannot bypass proof") { f in
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot), intent = try await record(f)
            try journal.begin(intent); journal.abandon()
            do { _ = try await f.f.store.rename(id: f.target.id, name: "Blocked"); throw CheckFailure(description: "Metadata changed") }
            catch OpeningJournalError.conflict {}
            let recovered = restarted(f); _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.acknowledgeOpeningRecovery(userReviewed: true); throw CheckFailure(description: "Manual review bypassed proof") }
            catch AccountOpeningError.recoveryRequired {}
        }
        for point in ["before-marker-intent", "before-journal-intent", "after-intent",
                      "before-marker-effect", "before-journal-effect", "after-effect",
                      "before-marker-complete", "before-journal-complete", "after-complete"] {
            await scenario("process death at durable boundary " + point) { f in
                let intent = try await record(f), process = try child(f, intent, mode: "crash-" + point)
                try await waitUntil { !process.isRunning }
                try expect(process.terminationStatus == 0, "Worker exited at selected durable boundary")
                let journal = OpeningOperationJournal(root: f.f.validator.managedRoot)
                if point.contains("before-journal") {
                    do { _ = try journal.pending(); throw CheckFailure(description: "Torn pair accepted") }
                    catch OpeningJournalError.invalid {}
                } else if point == "before-marker-intent" || point == "after-complete" {
                    try expect(try journal.pending() == nil, "Only untouched idle or durably completed operation is clean")
                } else {
                    try expect(try journal.pending()?.id == intent.id, "Intent survives process exit")
                }
                try expect(await f.system.effects.isEmpty, "QA crash worker never invoked any Desktop adapter")
            }
        }
        for point in ["before-marker", "before-journal", "after"] {
            await run("Durable opening: bootstrap crash " + point) {
                let root = base.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try AtomicMetadataWriter().write(Data(), to: root.appendingPathComponent("metadata.lock"))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                process.arguments = ["--opening-journal-worker", root.path, "bootstrap-" + point]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); try await waitUntil { !process.isRunning }
                try expect(process.terminationStatus == 0, "Bootstrap worker exited without cleanup")
                let journal = OpeningOperationJournal(root: root)
                if point == "before-journal" {
                    do { try journal.initializeFreshStore(); throw CheckFailure(description: "Torn bootstrap silently repaired") }
                    catch OpeningJournalError.invalid {}
                } else {
                    try journal.initializeFreshStore()
                    try expect(try journal.pending() == nil, "Fresh bootstrap is safe before any intent or account metadata")
                }
            }
        }
        for loss in ["journal", "watermark", "both", "journal rollback", "watermark rollback"] {
            await scenario("missing or rolled back initialized journal: " + loss) { f in
                let root = f.f.validator.managedRoot
                let path = root.appendingPathComponent("opening-journal.json"), watermark = root.appendingPathComponent("opening-journal-watermark.json")
                let oldJournal = try Data(contentsOf: path), oldMarker = try Data(contentsOf: watermark)
                let journal = OpeningOperationJournal(root: root), intent = try await record(f)
                try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
                switch loss {
                case "journal": try FileManager.default.removeItem(at: path)
                case "watermark": try FileManager.default.removeItem(at: watermark)
                case "both": try FileManager.default.removeItem(at: path); try FileManager.default.removeItem(at: watermark)
                case "journal rollback": try oldJournal.write(to: path)
                default: try oldMarker.write(to: watermark)
                }
                let recovered = restarted(f)
                do { _ = try await recovered.refreshOpeningRecovery(); throw CheckFailure(description: "Lost journal interpreted as clean") }
                catch is OpeningJournalError {}
                try expect(await recovered.state == .recoveryRequired, "Missing/rolled-back data blocks after restart")
                do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Lost journal reconciled") }
                catch is OpeningJournalError {}
                try expect(await f.system.effects.isEmpty, "No initialization or replay during recovery")
            }
        }
        for pid in [false, true] {
            await scenario("snapshot change immediately before " + (pid ? "PID" : "window") + " intent blocks dispatch") { f in
                if pid {
                    let instance = await f.system.instances[f.association.environmentID]!
                    let revision = try await f.f.store.inspectAssociations().revision
                    await f.system.configurePID(try PIDActivationScope(association: f.association, revision: revision, instance: instance))
                }
                await f.system.mutateNextFingerprint {
                    _ = try await f.f.store.rename(id: f.target.id, name: "Concurrent metadata change")
                }
                do {
                    if pid { try await f.coordinator.openPIDEnvironment(to: f.target) { _ in true } }
                    else { try await f.coordinator.openEnvironment(to: f.target) { _ in true } }
                    throw CheckFailure(description: "Stale intent dispatched")
                } catch is SwitchingError {}
                try expect(await f.system.effects.isEmpty, "Snapshot comparison under lock precedes native dispatch")
                try expect(try OpeningOperationJournal(root: f.f.validator.managedRoot).pending() == nil, "Rejected snapshot has no pending intent")
                try expect(await f.coordinator.state == .failed, "Known pre-dispatch refusal is not an uncertain operation")
            }
        }
        await scenario("another OS process cannot mutate metadata during intent publication") { f in
            let root = f.f.validator.managedRoot, intent = try await record(f)
            let executable = ProcessInfo.processInfo.arguments[0]
            let journal = OpeningOperationJournal(root: root, writer: AtomicMetadataWriter { path in
                guard path.lastPathComponent == "opening-journal-watermark.json" else { return }
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["--opening-journal-worker", root.path, "metadata-probe"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CheckFailure(description: "Concurrent metadata write escaped lock") }
            })
            try journal.begin(intent); journal.abandon()
            try expect(try journal.pending()?.id == intent.id, "Intent published under the same lock as snapshot validation")
        }
        await scenario("changed Codex build rejects recovery without rewriting evidence") { f in
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot), intent = try await record(f)
            try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id); journal.abandon()
            await f.system.changeBuild()
            let recovered = restarted(f); _ = try await recovered.refreshOpeningRecovery()
            do { try await recovered.reconcileOpeningRecovery(); throw CheckFailure(description: "Changed official build reinterpreted old intent") }
            catch EnvironmentError.incompatibleBuild {}
            try expect(try journal.pending()?.buildFingerprint == intent.buildFingerprint, "Original build evidence retained")
            try expect(await f.system.effects.isEmpty, "Read-only reconciliation performed no lifecycle effect")
        }
        await scenario("another Swoop's completion can be rechecked using exact settled evidence") { f in
            let journal = OpeningOperationJournal(root: f.f.validator.managedRoot), intent = try await record(f)
            try journal.begin(intent); try journal.append(.activation(intent.targetInstance!), operation: intent.id)
            let observer = restarted(f); _ = try await observer.refreshOpeningRecovery()
            try journal.complete(intent.id)
            try await observer.reconcileOpeningRecovery()
            try expect(await observer.state == .idle, "Completed owner does not strand another Swoop's warning")
            try expect(await observer.openingRecoveryResolution == .safeForNewOperation, "Safety, not previous activation success")
            let result = await observer.openingResult, effects = await f.system.effects
            try expect(result == nil && effects.isEmpty, "No success claim or replay")
        }
        await scenario("legacy bootstrap requires separate review and matching metadata snapshot") { f in
            let root = f.f.validator.managedRoot
            try FileManager.default.removeItem(at: root.appendingPathComponent("opening-journal.json"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("opening-journal-watermark.json"))
            let journal = OpeningOperationJournal(root: root)
            do { try journal.initializeFreshStore(); throw CheckFailure(description: "Legacy store auto-initialized") }
            catch OpeningJournalError.legacyUninitialized {}
            let intent = try await record(f, mode: .closeOthersAndOpen)
            do { try journal.initializeAfterLegacyRecoveryReview(expectedCatalogDigest: "stale"); throw CheckFailure(description: "Stale migration review accepted") }
            catch OpeningJournalError.conflict {}
            // Synthetic approval only. Production migration requires the old live result to be resolved.
            try journal.initializeAfterLegacyRecoveryReview(expectedCatalogDigest: intent.catalogDigest)
            try expect(try journal.pending() == nil, "Separately reviewed synthetic bootstrap succeeded")
        }
        await scenario("pending setup created in the pre-intent gap blocks activation") { f in
            let setup = f.f.validator.managedRoot.appendingPathComponent("setup-journal.json")
            await f.system.mutateNextFingerprint { try AtomicMetadataWriter().write(Data("synthetic pending setup".utf8), to: setup) }
            do { try await f.coordinator.openEnvironment(to: f.target) { _ in true }; throw CheckFailure(description: "Pending setup ignored") }
            catch is SwitchingError {}
            try expect(await f.system.effects.isEmpty, "Setup journal is checked under the intent publication lock")
            try expect(try OpeningOperationJournal(root: f.f.validator.managedRoot).pending() == nil, "No opening intent was published")
        }
        await run("Durable opening: precise libproc generation for the synthetic QA process") {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-ww", "-p", String(getpid()), "-o", "pid=,ppid=,uid=,lstart=,comm="]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TZ": "UTC"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CheckFailure(description: "Synthetic self metadata unavailable") }
            let raw = try DesktopProcessMetadata.parse(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            // swift run can use a relative argv[0]. Native official-process classification requires
            // an exact absolute bundle path and must reject that untrusted relative selector.
            if !raw.executable.hasPrefix("/") {
                do { _ = try raw.preciseGeneration(); throw CheckFailure(description: "Relative selector accepted") }
                catch EnvironmentError.processChanged {}
            }
            // The fixture checkout can live beneath macOS /tmp aliases. Obtain this QA
            // process's kernel path rather than guessing how ps/argv spelling was canonicalized.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
                throw CheckFailure(description: "Synthetic self executable unavailable")
            }
            let executable = String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let metadata = try DesktopProcessMetadata.parse("\(raw.pid) \(raw.parent) \(raw.uid) \(raw.started) \(executable)")
            let first = try metadata.preciseGeneration(), second = try metadata.preciseGeneration()
            try expect(first == second && first.startTimeMicroseconds != nil, "Microsecond generation is stable for the exact QA process")
        }
    }
}


private final class JournalCrashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[name, default: 0] += 1; return counts[name]!

    }
}
