import CryptoKit
import Darwin
import Foundation
@testable import CodexSwoopCore

private enum Failure: Error { case assertion(String), injected }
private final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ stage: String) { lock.lock(); defer { lock.unlock() }; items.append(stage) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@main @MainActor struct EpochRecoveryChecks {
    static var count = 0
    static var context = "initial"
    static func require(_ value: Bool, _ text: String) throws {
        guard value else { throw Failure.assertion(text) }; count += 1
    }
    nonisolated static func precise(_ pid: Int32) -> DesktopInstance {
        let g = DesktopGeneration(pid: pid, uid: getuid(), started: "synthetic-\(pid)", startTimeMicroseconds: UInt64(pid) * 1_000_000 + 123)
        let child = DesktopGeneration(pid: pid + 1_000, uid: getuid(), started: "synthetic-child-\(pid)", startTimeMicroseconds: UInt64(pid) * 1_000_000 + 124)
        return DesktopInstance(main: g, related: [g, child], nativeLaunchDate: Date(timeIntervalSince1970: 1_700_000_000),
            signingIdentity: CodexSigningIdentity(identifier: CodexBundleInspector.bundleIdentifier,
                teamIdentifier: OfficialCodexPolicy.teamIdentifier, codeDirectoryHash: String(repeating: "b", count: 40)))
    }
    static func make(launched: Bool = false) async throws -> (ReleaseFixture, PendingOpeningOperation) {
        let base = URL(fileURLWithPath: "/private/tmp/codexswoop-epoch-qa-\(UUID().uuidString)")
        let f = try await ReleaseFixture.make(root: base)
        for (i, a) in f.associations.enumerated() { await f.system.setSyntheticInstance(a.environmentID, precise(210_000 + Int32(i))) }
        if launched { await f.system.removeSyntheticInstance(f.associations[1].environmentID) }
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
        let plan = try await driver.planEnvironmentAccount(profile: f.profiles[1], mode: .openSeparately)
        let record = try await PendingOpeningOperation(scope: EnvironmentOperationScope(plan: plan, managed: f.store.inspectManagedEnvironments()),
            bootSession: "synthetic-boot", buildFingerprint: f.system.openingBuildFingerprint())
        let j = OpeningOperationJournal(root: f.validator.managedRoot)
        try j.begin(record)
        if launched {
            try j.append(.launch, operation: record.id)
            try j.append(.activation(precise(210_001)), operation: record.id)
        } else { try j.append(.activation(record.targetInstance!), operation: record.id) }
        j.abandon()
        for (i, a) in f.associations.enumerated() { await f.system.setSyntheticInstance(a.environmentID, precise(240_000 + Int32(i))) }
        return (f, record)
    }
    static func engine(_ root: URL, record: PendingOpeningOperation) -> OpeningEpochEngine {
        OpeningEpochEngine(root: root, sample: { references, _ in
            OpeningEpochObservation(boot: record.bootSession, build: record.buildFingerprint,
                inventory: DesktopInstanceInventory(entries: references.enumerated().map { i, a in
                    DesktopInventoryEntry(association: a, instance: precise(240_000 + Int32(i)))
                }, unknownCount: 0), originalPIDsAbsent: true, swoopRunning: false)
        })
    }
    static func pair(_ root: URL) throws -> [Data] {
        try OpeningEpochEngine.pair.map { try Data(contentsOf: root.appendingPathComponent($0)) }
    }
    static func validate(_ f: ReleaseFixture, original: [Data], token: String) async throws {
        let root = f.validator.managedRoot
        let active = try pair(root)
        let e = try OpeningOperationJournal.decodePair(active[0], active[1])
        try require(e.schemaVersion == 3 && e.pending == nil && e.settled == nil && e.revision == 0, "fresh epoch without historical settlement")
        let archive = root.appendingPathComponent(OpeningEpochEngine.archiveName)
        for (i, name) in OpeningEpochEngine.pair.enumerated() {
            try require(Data(contentsOf: archive.appendingPathComponent(name)) == original[i], "original pair retained exactly")
        }
        let m = try JSONDecoder().decode(OpeningEpochManifest.self, from: Data(contentsOf: archive.appendingPathComponent("manifest.json")))
        try require(m.historicalOutcome == "unknown" && m.authorization == token, "manifest binds consent and unknown outcome")
        for name in OpeningEpochEngine.catalogs {
            let live = try ReplacementFileSnapshot.read(root.appendingPathComponent(name), optional: true)
            let saved = try ReplacementFileSnapshot.read(archive.appendingPathComponent(name), optional: true)
            try require(live.bytes == saved.bytes, "catalog untouched and archived: \(name)")
        }
        try require(OpeningOperationJournal(root: root).pending() == nil, "startup accepts verified epoch")
        let after = try await f.store.inspectAccountSetup()
        try require(after.profiles.profiles.count == 2 && after.associations.associations.count == 2, "both profiles and bindings survive")
    }
    static func worker(_ args: [String]) async throws {
        guard args.count == 4, args[1] == "--worker", args[2].hasPrefix("/private/tmp/codexswoop-epoch-qa-"),
              !args[2].split(separator: "/").contains("..") else { exit(2) }
        let root = URL(fileURLWithPath: args[2])
        let pending: PendingOpeningOperation
        if let live = try? OpeningOperationJournal(root: root).pending() { pending = live }
        else {
            let archive = root.appendingPathComponent(OpeningEpochEngine.archiveName)
            pending = try OpeningOperationJournal.decodePair(Data(contentsOf: archive.appendingPathComponent("opening-journal.json")),
                Data(contentsOf: archive.appendingPathComponent("opening-journal-watermark.json"))).pending!
        }
        var tool = engine(root, record: pending)
        let review = try await tool.run(consent: nil)
        let stop = args[3]
        tool.fault = { stage in if stage == stop { _exit(73) } }
        _ = try await tool.run(consent: review.consent)
        exit(9) // requested crash hook must have been reached
    }
    static func launchedReceiverSupersession() async throws {
        let (f, record) = try await make(launched: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let root = f.validator.managedRoot, original = try pair(root)
        let envelope = try OpeningOperationJournal.decodePair(original[0], original[1])
        try require(envelope.revision == 3 && envelope.pending?.targetInstance == nil
            && envelope.pending?.effects == [.launch, .activation(precise(210_001))], "real-store launch/activation shape is reproduced synthetically")
        var tool = engine(root, record: record)
        let probe = tool.sample
        tool.sample = { references, originals in
            guard originals == Set<Int32>([210_001, 211_001]) else { throw Failure.assertion("activation-result PID generations missing from launch recovery proof") }
            return try await probe(references, originals)
        }
        let consent = try await tool.run(consent: nil).consent
        _ = try await tool.run(consent: consent)
        try await validate(f, original: original, token: consent)
        try require(await f.system.effects.isEmpty, "archiving launch evidence never replays a process effect")
    }
    static func profileOpeningAfterSupersession() async throws {
        let (f, old) = try await make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let root = f.validator.managedRoot, original = try pair(root)
        let before = try await f.store.inspectAccountSetup()
        let tool = engine(root, record: old), consent = try await tool.run(consent: nil).consent
        _ = try await tool.run(consent: consent)
        let coordinator = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(bootSession: { "synthetic-boot" },
            store: ProfileStore(root: root), validator: f.validator, system: f.system))
        let review = try await coordinator.refreshOpeningRecovery()
        try require(!review, "committed epoch restores normal coordinator readiness")
        for profile in f.profiles {
            try await coordinator.openAccount(to: profile, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
        }
        try require(await f.system.effects == ["activate", "activate"], "both existing profiles open through the normal synthetic coordinator")
        try require(await f.system.instances.count == 2, "open separately preserves both environments")
        try require(await f.store.inspectAccountSetup() == before, "normal opening after supersession preserves all catalogs")
        let active = try pair(root), current = try OpeningOperationJournal.decodePair(active[0], active[1])
        try require(current.schemaVersion == 3 && current.pending == nil && current.settled != nil && current.settled?.id != old.id,
            "normal postflight settles only the new operation and retains epoch provenance")
        let archived = root.appendingPathComponent(OpeningEpochEngine.archiveName)
        try require(pair(archived) == original, "normal opening never reinterprets old unresolved evidence")
        let repeated = try await tool.run(consent: consent)
        try require(repeated.alreadyApplied && (try pair(root)) == active, "supersession cannot erase later normal results")
    }
    static func negativeChecks() async throws {
        for mode in ["running", "boot", "build", "signature", "unknown", "reuse", "generation", "inventory-drift", "catalog-replaced", "setup", "lock", "corrupt", "future", "missing-precision", "orphan-backup", "oversized-pair", "metadata-lock", "permissions", "environment-directory-replaced", "after-archive-inventory-drift", "after-archive-running", "cancelled"] {
            context = "negative: " + mode
            let (f, record) = try await make()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let root = f.validator.managedRoot
            var tool = engine(root, record: record)
            var token = try await tool.run(consent: nil).consent
            let calls = Stages()
            tool.sample = { references, originals in
                calls.add("sample")
                if mode == "signature" { throw EnvironmentError.incompatibleBuild }
                if mode == "reuse" { throw OpeningEpochError.originalPIDAbsenceUnproven(originals.sorted().last!) }
                if mode == "environment-directory-replaced" {
                    let path = URL(fileURLWithPath: references[0].codexHome)
                    try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("displaced"))
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                if mode == "catalog-replaced" {
                    let path = root.appendingPathComponent("profiles.json")
                    try AtomicMetadataWriter().write(Data(contentsOf: path), to: path)
                }
                let build = mode == "build" ? OpeningBuildFingerprint(version: "changed", build: record.buildFingerprint.build,
                    signingRequirement: record.buildFingerprint.signingRequirement, archiveSHA256: record.buildFingerprint.archiveSHA256,
                    codeDirectoryHash: record.buildFingerprint.codeDirectoryHash, bundleGenerationSHA256: record.buildFingerprint.bundleGenerationSHA256) : record.buildFingerprint
                return OpeningEpochObservation(boot: mode == "boot" ? "other-boot" : record.bootSession, build: build,
                    inventory: DesktopInstanceInventory(entries: references.enumerated().map { i, a in
                        let pid = 240_000 + Int32(i) + ((mode == "inventory-drift" || (mode == "after-archive-inventory-drift" && calls.values.count >= 3)) ? Int32(calls.values.count) * 10 : 0)
                        let instance = mode == "generation" ? DesktopInstance(main: DesktopGeneration(pid: pid, uid: getuid(), started: "synthetic"), related: [], nativeLaunchDate: Date()) : precise(pid)
                        return DesktopInventoryEntry(association: a, instance: instance)
                    }, unknownCount: mode == "unknown" ? 1 : 0), originalPIDsAbsent: true, swoopRunning: mode == "running" || (mode == "after-archive-running" && calls.values.count >= 3))
            }
            var lockFD: Int32 = -1
            defer { if lockFD >= 0 { close(lockFD) } }
            if mode == "lock" || mode == "metadata-lock" {
                lockFD = Darwin.open(root.appendingPathComponent(mode == "lock" ? "opening-operation.lock" : "metadata.lock").path, O_RDONLY)
                guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.assertion("QA lock") }
            }
            if mode == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("profiles.json").path) }
            if mode == "orphan-backup" {
                let active = root.appendingPathComponent("retained-environments.json")
                if FileManager.default.fileExists(atPath: active.path) { try FileManager.default.removeItem(at: active) }
                try AtomicMetadataWriter().write(JSONEncoder().encode(RetainedEnvironmentCatalog()), to: root.appendingPathComponent("retained-environments.backup.json"))
            }
            if mode == "setup" { try AtomicMetadataWriter().write(Data("{}".utf8), to: root.appendingPathComponent("setup-journal.json")) }
            if mode == "corrupt" { try AtomicMetadataWriter().write(Data("{}".utf8), to: root.appendingPathComponent("opening-journal.json")) }
            if mode == "oversized-pair" {
                let data = try pair(root)
                let changed = data[0] + Data(repeating: 32, count: 262_145 - data[0].count)
                var marker = try JSONSerialization.jsonObject(with: data[1]) as! [String: Any]
                marker["journalSHA256"] = OpeningEpochEngine.hash(changed)
                let old = try JSONSerialization.jsonObject(with: data[0]) as! [String: Any]
                token = "supersede-unresolved:\(old["storeID"]!):\(record.id.uuidString):\(OpeningEpochEngine.hash(changed))"
                try AtomicMetadataWriter().write(changed, to: root.appendingPathComponent("opening-journal.json"))
                try AtomicMetadataWriter().write(JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]), to: root.appendingPathComponent("opening-journal-watermark.json"))
            }
            if mode == "future" || mode == "missing-precision" {
                let data = try pair(root)
                var value = try JSONSerialization.jsonObject(with: data[0]) as! [String: Any]
                if mode == "future" { value["schemaVersion"] = 100 }
                else {
                    func strip(_ x: Any) -> Any {
                        if var d = x as? [String: Any] { d.removeValue(forKey: "startTimeMicroseconds"); return d.mapValues(strip) }
                        if let a = x as? [Any] { return a.map(strip) }; return x
                    }
                    value = strip(value) as! [String: Any]
                }
                let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                var marker = try JSONSerialization.jsonObject(with: data[1]) as! [String: Any]
                marker["journalSHA256"] = OpeningEpochEngine.hash(changed)
                if mode == "missing-precision" { token = "supersede-unresolved:\(value["storeID"]!):\(record.id.uuidString):\(OpeningEpochEngine.hash(changed))" }
                try AtomicMetadataWriter().write(changed, to: root.appendingPathComponent("opening-journal.json"))
                try AtomicMetadataWriter().write(JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]), to: root.appendingPathComponent("opening-journal-watermark.json"))
            }
            let before = try pair(root)
            do {
                if mode == "cancelled" {
                    let readyTool = tool, readyToken = token
                    let task = Task { try await Task.sleep(for: .milliseconds(50)); return try await readyTool.run(consent: readyToken) }
                    task.cancel(); _ = try await task.value
                } else { _ = try await tool.run(consent: token) }
                throw Failure.assertion("unsafe predicate accepted: \(mode)")
            } catch is Failure { throw Failure.assertion("unsafe predicate accepted: \(mode)") }
            catch {
                if mode == "oversized-pair" { try require(error as? OpeningJournalError == .invalid, "existing journal size cap retained") }
                count += 1
            }
            try require(pair(root) == before, "failed \(mode) left active evidence unchanged")
            try require(FileManager.default.fileExists(atPath: root.appendingPathComponent(OpeningEpochEngine.archiveName).path) == mode.hasPrefix("after-archive"), "failed \(mode) preserves the expected archive state")
        }
        let (f, record) = try await make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = engine(f.validator.managedRoot, record: record)
        let consent = try await tool.run(consent: nil).consent
        _ = try await tool.run(consent: consent)
        let archive = f.validator.managedRoot.appendingPathComponent(OpeningEpochEngine.archiveName)
        try AtomicMetadataWriter().write(Data("tampered".utf8), to: archive.appendingPathComponent("manifest.json"))
        do { _ = try OpeningOperationJournal(root: f.validator.managedRoot).pending(); throw Failure.assertion("damaged archive ignored by startup") }
        catch is Failure { throw Failure.assertion("damaged archive ignored by startup") }
        catch { count += 1 }
        do { _ = try await tool.run(consent: consent); throw Failure.assertion("damaged archive repaired") }
        catch is Failure { throw Failure.assertion("damaged archive repaired") }
        catch { count += 1 }
    }
    static func main() async {
        do {
            if CommandLine.arguments.count > 1 { try await worker(CommandLine.arguments); return }
            let swoopID = "io.github.cbrwvy.codexswoop"
            try require(!OpeningEpochRecovery.requiresSwoopShutdown(pid: 100, bundleID: swoopID, executable: "codexswoop-recovery", terminated: false, inspectorPID: 100), "own nested helper is not the Swoop GUI")
            try require(OpeningEpochRecovery.requiresSwoopShutdown(pid: 101, bundleID: swoopID, executable: "codexswoop-recovery", terminated: false, inspectorPID: 100), "another helper cannot be ignored")
            try require(OpeningEpochRecovery.requiresSwoopShutdown(pid: 100, bundleID: swoopID, executable: "CodexSwoop", terminated: false, inspectorPID: 100), "GUI cannot exclude itself")
            try require(OpeningEpochRecovery.requiresSwoopShutdown(pid: 101, bundleID: nil, executable: "CodexSwoop", terminated: false, inspectorPID: 100), "executable identifies an unregistered Swoop")
            try require(OpeningEpochRecovery.requiresSwoopShutdown(pid: 101, bundleID: swoopID, executable: nil, terminated: false, inspectorPID: 100), "ambiguous matching bundle blocks")
            try require(!OpeningEpochRecovery.requiresSwoopShutdown(pid: 101, bundleID: swoopID, executable: "CodexSwoop", terminated: true, inspectorPID: 100), "terminated application does not block")
            try require(!OpeningEpochRecovery.requiresSwoopShutdown(pid: 101, bundleID: "synthetic.official", executable: "ChatGPT", terminated: false, inspectorPID: 100), "official Codex is never a shutdown target")
            try await launchedReceiverSupersession()
            try await profileOpeningAfterSupersession()
            try await negativeChecks()
            let (f, record) = try await make(); defer { try? FileManager.default.removeItem(at: f.root) }
            let original = try pair(f.validator.managedRoot), tool = engine(f.validator.managedRoot, record: record)
            let review = try await tool.run(consent: nil)
            try require(pair(f.validator.managedRoot) == original, "read-only inspection changed nothing")
            let stages = Stages()
            var successful = tool; successful.fault = { stages.add($0) }
            _ = try await successful.run(consent: review.consent)
            try await validate(f, original: original, token: review.consent)
            let committed = try pair(f.validator.managedRoot)
            let repeated = try await successful.run(consent: review.consent)
            try require(repeated.alreadyApplied && (try pair(f.validator.managedRoot)) == committed, "successful rerun is read-only and idempotent")
            // Future new-epoch operations retain provenance; another supersession is prohibited.
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.store, validator: f.validator, system: f.system)
            let plan = try await driver.planEnvironmentAccount(profile: f.profiles[1], mode: .openSeparately)
            let next = try await PendingOpeningOperation(scope: EnvironmentOperationScope(plan: plan, managed: f.store.inspectManagedEnvironments()),
                bootSession: "synthetic-boot", buildFingerprint: f.system.openingBuildFingerprint())
            let j = OpeningOperationJournal(root: f.validator.managedRoot)
            try j.begin(next); j.abandon()
            let pendingNew = try pair(f.validator.managedRoot)
            let noRepeat = try await successful.run(consent: review.consent)
            try require(noRepeat.alreadyApplied && (try pair(f.validator.managedRoot)) == pendingNew, "new pending is never discarded by repeat migration")
            let normalHooks = Set(stages.values)
            let (resumeFixture, resumeRecord) = try await make()
            defer { try? FileManager.default.removeItem(at: resumeFixture.root) }
            var resumeTool = engine(resumeFixture.validator.managedRoot, record: resumeRecord)
            let resumeConsent = try await resumeTool.run(consent: nil).consent
            resumeTool.fault = { if $0 == "before-write-archive-epoch-commit.json" { throw Failure.injected } }
            do { _ = try await resumeTool.run(consent: resumeConsent) } catch Failure.injected { }
            resumeTool.fault = { stages.add($0) }
            _ = try await resumeTool.run(consent: resumeConsent)
            let (partialFixture, partialRecord) = try await make()
            defer { try? FileManager.default.removeItem(at: partialFixture.root) }
            var partialTool = engine(partialFixture.validator.managedRoot, record: partialRecord)
            let partialConsent = try await partialTool.run(consent: nil).consent
            partialTool.fault = { if $0 == "before-write-archive-manifest.json" { throw Failure.injected } }
            do { _ = try await partialTool.run(consent: partialConsent) } catch Failure.injected { }
            partialTool.fault = { stages.add($0) }
            _ = try await partialTool.run(consent: partialConsent)
            let hooks = Array(Set(stages.values)).sorted()
            for hook in hooks {
                for abrupt in [false, true] {
                    context = "fault \(hook) abrupt=\(abrupt)"
                    let (fixture, oldRecord) = try await make()
                    defer { try? FileManager.default.removeItem(at: fixture.root) }
                    let root = fixture.validator.managedRoot, oldBytes = try pair(root)
                    var candidate = engine(root, record: oldRecord)
                    let consent = try await candidate.run(consent: nil).consent
                    if !normalHooks.contains(hook) {
                        let seed = hook.contains("resume-prepared-pair") ? "before-write-archive-epoch-commit.json" : "before-write-archive-manifest.json"
                        candidate.fault = { if $0 == seed { throw Failure.injected } }
                        do { _ = try await candidate.run(consent: consent) } catch Failure.injected { }
                    }
                    if abrupt {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                        p.arguments = ["--worker", root.path, hook]
                        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                        try p.run(); p.waitUntilExit()
                        try require(p.terminationStatus == 73, "abrupt QA worker reached \(hook)")
                    } else {
                        candidate.fault = { stage in if stage == hook { throw Failure.injected } }
                        do { _ = try await candidate.run(consent: consent); throw Failure.assertion("fault not reached: \(hook)") }
                        catch Failure.injected { count += 1 }
                    }
                    let interruptedBytes = try pair(root)
                    if let current = try? OpeningOperationJournal.decodePair(interruptedBytes[0], interruptedBytes[1]), current.schemaVersion == 3, FileManager.default.fileExists(atPath: root.appendingPathComponent(OpeningEpochEngine.archiveName + "/epoch-commit.json").path) {
                        try await validate(fixture, original: oldBytes, token: consent)
                    } else {
                        do {
                            let current = try OpeningOperationJournal(root: root).pending()
                            try require(current?.id == oldRecord.id, "old pending retained before commit")
                        } catch is OpeningJournalError { count += 1 } // watermark-first torn pair: blocked
                        catch is OpeningEpochError { count += 1 } // prepared pair without durable commit: blocked
                        do { try await fixture.coordinator.reconcileOpeningRecovery(); throw Failure.assertion("Check Again bypassed supersession") }
                        catch is Failure { throw Failure.assertion("Check Again bypassed supersession") }
                        catch { count += 1 }
                        try require(pair(root) == interruptedBytes, "Check Again never performs or resumes supersession")
                    }
                    let retry = engine(root, record: oldRecord)
                    _ = try await retry.run(consent: nil)
                    try require(pair(root) == interruptedBytes, "inspection never resumes an interrupted transition")
                    do { _ = try await retry.run(consent: "wrong-store-and-operation"); throw Failure.assertion("wrong consent") }
                    catch OpeningEpochError.consentRequired { count += 1 }
                    _ = try await retry.run(consent: consent)
                    try await validate(fixture, original: oldBytes, token: consent)
                    let bytes = try pair(root)
                    let result = try await retry.run(consent: consent)
                    try require(result.alreadyApplied && (try pair(root)) == bytes, "rerun cannot republish another epoch")
                    try require(await fixture.system.effects.isEmpty, "synthetic process effects remain empty")
                }
            }
            print("PASS epoch recovery: \(hooks.count) fault stages, thrown I/O faults and abrupt QA-process exits, \(count) assertions")
        } catch { print("FAIL epoch recovery at \(context): \(error)"); exit(1) }
    }
}
