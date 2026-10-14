import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Darwin
import Security

/// Parses the fixed ps metadata columns without losing spaces inside executable paths.
public struct DesktopProcessMetadata: Equatable, Sendable {
    public let pid: Int32, parent: Int32, uid: UInt32
    public let started: String, executable: String

    public static func parse(_ line: String) throws -> Self {
        let parts = line.split(maxSplits: 8, omittingEmptySubsequences: true,
                               whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 9, let pid = Int32(parts[0]), pid >= 0,
              let parent = Int32(parts[1]), parent >= 0, let rawUID = Int64(parts[2]),
              rawUID >= Int64(Int32.min), rawUID <= Int64(UInt32.max) else {
            throw EnvironmentError.ambiguousInstance
        }
        // Darwin ps may render uid_t as signed (for example nobody is -2).
        // Normalize its 32-bit representation before filtering by the current UID.
        let uid = rawUID < 0 ? UInt32(bitPattern: Int32(rawUID)) : UInt32(rawUID)
        // maxSplits leaves delimiter padding in the remainder. Remove only that padding,
        // preserving internal and trailing executable-name characters for exact matching.
        let executable = String(parts[8].drop(while: { $0 == " " || $0 == "\t" }))
        guard !executable.isEmpty else { throw EnvironmentError.ambiguousInstance }
        return Self(pid: pid, parent: parent, uid: uid,
                    started: parts[3...7].joined(separator: " "), executable: executable)
    }
    /// ps lstart has only second precision. Bind its metadata to libproc's microsecond start time.
    public func preciseGeneration() throws -> DesktopGeneration {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_ppid == UInt32(parent), info.pbi_uid == uid,
              info.pbi_start_tvsec > 0, info.pbi_start_tvsec < UInt64.max / 1_000_000,
              info.pbi_start_tvusec < 1_000_000 else { throw EnvironmentError.processChanged }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) == executable else {
            throw EnvironmentError.processChanged
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard formatter.string(from: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))) == started else { throw EnvironmentError.processChanged }
        return DesktopGeneration(pid: pid, uid: uid, started: started,
            startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

}

/// Version-specific adapter. Legacy effects remain closed; environment effects require one exact confirmed scope.
public actor NativeDesktopSystem: DesktopSystem {
    public nonisolated var lifecycleAllowed: Bool { DesktopIntegrationPolicy.lifecycleEnabled }
    public nonisolated var standardLifecycleAllowed: Bool { DesktopIntegrationPolicy.primaryLifecycleEnabled }
    public nonisolated var environmentActivationAllowed: Bool { EnvironmentOpeningPolicy.nativeActivationEnabled }
    private var retainedWindows: [UUID: NativeWindowIdentity] = [:]
    private let validator: EnvironmentValidator
    private let app = URL(fileURLWithPath: ReviewedCodexBuild.path)
    private let pidActivationScope: PIDActivationScope?
    private var pidActivationConsumed = false
    private var operationScope: EnvironmentOperationScope?
    private var scopeClosed = Set<UUID>()
    private var scopeQuit = Set<UUID>()
    private var scopeActivated = false, scopeLaunched = false
    private var scopeLaunchedInstance: DesktopInstance?
    private var validatedInstallation: InstallationValidationSnapshot?
    private let dispatchLedger = EnvironmentDispatchLedger()
    private var submittedLauncher: (id: UUID, process: Process)?
    public init(validator: EnvironmentValidator = EnvironmentValidator(), pidActivationScope: PIDActivationScope? = nil) {
        self.validator = validator; self.pidActivationScope = pidActivationScope
    }

    public func permitsPIDActivation(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async -> Bool {
        pidActivationScope?.permits(association, revision: revision, instance: instance) == true
    }

    /// Select only by PID. No AX, launch, quit, URL opening or bundle-ID selection.
    public func activatePIDEnvironment(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async throws {
        guard !pidActivationConsumed, pidActivationScope?.permits(association, revision: revision, instance: instance) == true else {
            throw EnvironmentOpeningError.unavailable
        }
        try validator.revalidate(association)
        try await validateInstallation()
        guard try await observe(association).unique() == instance else { throw EnvironmentError.processChanged }
        let catalog = try await ProfileStore(root: validator.managedRoot).inspectAssociations()
        guard catalog.revision == revision, catalog.associations.contains(association) else { throw EnvironmentOpeningError.stalePlan }
        try validator.revalidate(association)
        try Self.validateLiveSignature(instance.main.pid)
        try Task.checkCancellation()
        guard !pidActivationConsumed, pidActivationScope?.permits(association, revision: revision, instance: instance) == true else {
            throw EnvironmentOpeningError.unavailable
        }
        pidActivationConsumed = true
        try await dispatchPIDActivation(association, instance: instance)
    }

    private func dispatchPIDActivation(_ association: EnvironmentAssociation, instance: DesktopInstance, scope: EnvironmentOperationScope? = nil) async throws {
        if let scope { try await checkDispatchCatalogs(scope) }
        try validator.revalidate(association)
        try Self.validateLiveSignature(instance.main.pid)
        let ledger = dispatchLedger
        try await MainActor.run {
            guard let target = NSRunningApplication(processIdentifier: instance.main.pid), !target.isTerminated,
                  target.processIdentifier == instance.main.pid, target.launchDate == instance.nativeLaunchDate,
                  target.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                  target.bundleIdentifier == "com.openai.codex" else { throw EnvironmentError.processChanged }
            try Task.checkCancellation()
            if let scope { ledger.mark(scope.id, effect: .activation(instance)) }
            guard target.activate(options: []) else { throw SwitchingError.activationFailed }
        }
        // activate() only acknowledges dispatch. Allow the main run loop to observe foreground change.
        // This is a bounded observation wait, not another activation request.
        for attempt in 0...20 {
            try Task.checkCancellation()
            if await Self.pidIsForeground(instance) {
                guard try await observe(association).unique() == instance else { throw EnvironmentError.processChanged }
                return
            }
            if attempt < 20 { try await Task.sleep(for: .milliseconds(50)) }
        }
        throw SwitchingError.activationFailed
    }

    @MainActor private static func pidIsForeground(_ instance: DesktopInstance) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == instance.main.pid && !front.isTerminated
            && front.launchDate == instance.nativeLaunchDate && front.bundleIdentifier == "com.openai.codex"
            && front.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    }
    public func verifyPIDForeground(_ instance: DesktopInstance) async throws {
        guard await Self.pidIsForeground(instance) else { throw SwitchingError.activationFailed }
    }

    public func validateInstallation() async throws {
        guard FileManager.default.fileExists(atPath: app.path) else { throw EnvironmentError.codexNotInstalled }
        guard app.resolvingSymlinksInPath() == app, let installation = CodexBundleInspector.inspect(app),
              ReviewedCodexBuild.matches(installation) else { throw EnvironmentError.incompatibleBuild }
        let snapshot = try InstallationValidationSnapshot.capture(app)
        if validatedInstallation == snapshot { return }
        validatedInstallation = nil
        let requirement = "-R=" + ReviewedCodexBuild.signingRequirement
        let result = try await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", requirement, app.path])
        guard result.status == 0 else { throw EnvironmentError.incompatibleBuild }
        let archive = try FileHandle(forReadingFrom: app.appendingPathComponent("Contents/Resources/app.asar"))
        defer { try? archive.close() }
        var hash = SHA256()
        while let bytes = try archive.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == ReviewedCodexBuild.archiveSHA256 else {
            throw EnvironmentError.incompatibleBuild
        }
        guard try InstallationValidationSnapshot.capture(app) == snapshot else { throw EnvironmentError.incompatibleBuild }
        validatedInstallation = snapshot
    }

    public func openingBuildFingerprint() async throws -> OpeningBuildFingerprint {
        try await validateInstallation()
        guard let snapshot = validatedInstallation else { throw EnvironmentError.incompatibleBuild }
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw EnvironmentError.incompatibleBuild }
        let value = OpeningBuildFingerprint(version: ReviewedCodexBuild.version, build: ReviewedCodexBuild.build,
            signingRequirement: ReviewedCodexBuild.signingRequirement, archiveSHA256: ReviewedCodexBuild.archiveSHA256,
            codeDirectoryHash: hash.map { String(format: "%02x", $0) }.joined(), bundleGenerationSHA256: try snapshot.fingerprint)
        try value.validate()
        guard try InstallationValidationSnapshot.capture(app) == snapshot else { throw EnvironmentError.incompatibleBuild }
        return value
    }

    private struct Row: Equatable {
        let generation: DesktopGeneration
        let parent: Int32
        let inBundle: Bool
        let main: Bool
        let backend: Bool
    }
    private func inventory(deadline: ContinuousClock.Instant? = nil,
        preflight: InstallationPreflightSession? = nil) async throws -> [Int32: Row] {
        let columns = (preflight == nil ? "" : "stat=,") + "pid=,ppid=,uid=,lstart=,comm="
        let result = try await command("/bin/ps", ["-ww", "-axo", columns], deadline: deadline)
        guard result.status == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnvironmentError.ambiguousInstance
        }
        var rows: [Int32: Row] = [:]
        var metadataByPID: [Int32: DesktopProcessMetadata] = [:]
        var psStates: [Int32: String] = [:], observedParents = Set<Int32>()
        for line in result.output.split(separator: "\n") {
            let stateAndMetadata = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard preflight == nil || stateAndMetadata.count == 2 else { throw EnvironmentError.ambiguousInstance }
            let metadata = try DesktopProcessMetadata.parse(preflight == nil ? String(line) : String(stateAndMetadata[1]))
            observedParents.insert(metadata.parent)
            if preflight != nil { psStates[metadata.pid] = String(stateAndMetadata[0]) }
            let pid = metadata.pid, parent = metadata.parent, uid = metadata.uid
            guard pid > 0, uid == getuid() else { continue }
            // Executable paths stay in RAM for classification; never command arguments/environment.
            let executable = metadata.executable
            guard rows[pid] == nil else { throw EnvironmentError.ambiguousInstance }
            metadataByPID[pid] = metadata
            rows[pid] = Row(generation: DesktopGeneration(pid: pid, uid: uid, started: metadata.started),
                            parent: parent, inBundle: executable.hasPrefix(app.path + "/"),
                            main: executable == app.path + "/Contents/MacOS/ChatGPT",
                            backend: executable == app.path + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        }
        var precisePIDs = Set(rows.values.filter(\.inBundle).map { $0.generation.pid })
        while true {
            let expanded = precisePIDs.union(rows.values.filter { precisePIDs.contains($0.parent) }.map { $0.generation.pid })
            if expanded == precisePIDs { break }; precisePIDs = expanded
        }
        var witnesses: [Int32: InstallationZombieWitness] = [:]
        for pid in precisePIDs {
            guard let row = rows[pid], let metadata = metadataByPID[pid] else { throw EnvironmentError.processChanged }
            let generation: DesktopGeneration
            if preflight != nil {
                let sample = try InstallationProcessSample.read(metadata: metadata,
                    psStatus: psStates[pid] ?? "", hasChildren: observedParents.contains(pid), parent: {
                        guard precisePIDs.contains(metadata.parent), psStates[metadata.parent]?.first != "Z",
                              let parentMetadata = metadataByPID[metadata.parent] else { throw EnvironmentError.processChanged }
                        return try parentMetadata.preciseGeneration()
                    })
                switch sample {
                case .active(let value): generation = value
                case .zombie(let witness):
                    witnesses[pid] = witness; rows.removeValue(forKey: pid); continue
                }
            } else { generation = try metadata.preciseGeneration() }
            rows[pid] = Row(generation: generation, parent: row.parent,
                inBundle: row.inBundle, main: row.main, backend: row.backend)
        }
        if let preflight {
            guard witnesses.values.allSatisfy({ rows[$0.parent.pid]?.generation == $0.parent }) else {
                throw EnvironmentError.processChanged
            }
            // Tombstones remain in the session, never in an active ownership inventory.
            try preflight.check(witnesses)
        }
        return rows
    }
    private struct Counts { var home = 0; var electron = 0; var defaults = 0 }
    private func descriptorCounts(_ rows: [Int32: Row], association: EnvironmentAssociation, deadline: ContinuousClock.Instant) async throws -> [Int32: Counts] {
        let pids = rows.values.filter(\.inBundle).map { $0.generation.pid }.sorted()
        if pids.isEmpty { return [:] }
        let result = try await command("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"], deadline: deadline)
        guard result.status == 0 else { throw EnvironmentError.ambiguousInstance }
        var counts = Dictionary(uniqueKeysWithValues: pids.map { ($0, Counts()) })
        let defaults = [validator.userHome.appendingPathComponent(".codex").path,
                        validator.userHome.appendingPathComponent("Library/Application Support/Codex").path]
        var current: Int32?
        for line in result.output.split(separator: "\n") {
            if line.first == "p" { current = Int32(line.dropFirst()) }
            else if line.first == "n", let pid = current, counts[pid] != nil {
                let name = String(line.dropFirst())
                func matches(_ path: String) -> Bool { name == path || EnvironmentValidator.beneath(name, path) }
                if matches(association.codexHome) { counts[pid]!.home += 1 }
                else if matches(association.electronData) { counts[pid]!.electron += 1 }
                else if defaults.contains(where: matches) { counts[pid]!.defaults += 1 }
            }
        }
        return counts // Raw names are discarded, never opened/stat'ed or logged.
    }

    public func observe(_ association: EnvironmentAssociation, timeout: Duration) async throws -> DesktopObservation {
        try await observeUntil(association, deadline: ContinuousClock.now.advanced(by: min(timeout, .seconds(5))))
    }
    private func observeUntil(_ association: EnvironmentAssociation, deadline: ContinuousClock.Instant,
        preflight: InstallationPreflightSession? = nil) async throws -> DesktopObservation {
        guard ContinuousClock.now < deadline else { throw EnvironmentError.ambiguousInstance }
        try validator.revalidate(association)
        let before = try await inventory(deadline: deadline, preflight: preflight)
        let counts = try await descriptorCounts(before, association: association, deadline: deadline)
        let after = try await inventory(deadline: deadline, preflight: preflight)
        func normalized(_ rows: [Int32: Row]) -> [DesktopProcessEvidence] {
            rows.values.map { row in
                let count = counts[row.generation.pid, default: Counts()]
                return DesktopProcessEvidence(generation: row.generation, parent: row.parent,
                    role: row.main ? .main : row.backend ? .backend : row.inBundle ? .helper : .external,
                    homeDescriptors: count.home, electronDescriptors: count.electron, defaultDescriptors: count.defaults)
            }
        }
        let beforeEvidence = normalized(before), afterEvidence = normalized(after)
        let candidates = try DesktopOwnership.resolve(before: beforeEvidence, after: afterEvidence, standard: association.kind == .standardExternal)
        var matched: [DesktopInstance] = []
        for members in candidates {
            guard let main = members.first(where: { before[$0.pid]?.main == true }) else { throw EnvironmentError.ambiguousInstance }
            let pid = main.pid
            let date: Date? = await MainActor.run {
                guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
                      running.bundleIdentifier == CodexBundleInspector.bundleIdentifier,
                      running.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" else { return nil }
                return running.launchDate
            }
            guard let date else { throw EnvironmentError.processChanged }
            try Self.validateLiveSignature(pid)
            matched.append(DesktopInstance(main: main, related: members, nativeLaunchDate: date))
        }
        guard ContinuousClock.now < deadline else { throw EnvironmentError.ambiguousInstance }
        let observation = DesktopObservation(matching: matched, ambiguous: false)
        if let preflight {
            preflight.observations.append(InstallationReferenceObservation(association: association,
                instance: try observation.unique(), before: beforeEvidence, after: afterEvidence))
        }
        return observation
    }

    public func activationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        return try await captureActivationEvidence(association, instance: instance)
    }

    public func environmentActivationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        guard environmentActivationAllowed else { throw EnvironmentOpeningError.unavailable }
        guard !association.isTemporary else { throw EnvironmentOpeningError.unavailable }
        return try await captureActivationEvidence(association, instance: instance)
    }

    /// Explicit read-only preflight. Retains the existing AX adapter's ownership checks and never
    /// requests permissions or dispatches an action. Its evidence cannot unlock either effect gate.
    public func inspectEnvironmentWindow(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        guard !association.isTemporary else { throw EnvironmentOpeningError.unavailable }
        return try await captureActivationEvidence(association, instance: instance)
    }

    private func captureActivationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        try validator.revalidate(association)
        try await validateInstallation()
        guard try await observe(association).unique() == instance else { throw EnvironmentError.processChanged }
        let previous = retainedWindows[association.environmentID]
        let handle = try await NativeWindowIdentity.capture(instance, previous: previous)
        retainedWindows[association.environmentID] = handle
        let evidence = DesktopActivationEvidence(association: association, instance: instance,
            windowIDs: handle.windowIDs, windowOwners: [instance.main], ownershipConfirmed: true, windowToken: handle.token)
        guard try await observe(association).unique() == instance else { throw EnvironmentError.processChanged }
        try evidence.validate(association: association, instance: instance)
        return evidence
    }

    public func activate(_ evidence: DesktopActivationEvidence) async throws {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        try await raiseRetainedWindow(evidence)
    }

    public func activateEnvironment(_ evidence: DesktopActivationEvidence) async throws {
        guard environmentActivationAllowed else { throw EnvironmentOpeningError.unavailable }
        guard !evidence.association.isTemporary else { throw EnvironmentOpeningError.unavailable }
        try await raiseRetainedWindow(evidence)
    }

    private func raiseRetainedWindow(_ evidence: DesktopActivationEvidence) async throws {
        try evidence.validate(association: evidence.association, instance: evidence.instance)
        let fresh = try await captureActivationEvidence(evidence.association, instance: evidence.instance)
        guard fresh.windowIDs == evidence.windowIDs, fresh.windowToken == evidence.windowToken,
              let handle = retainedWindows[evidence.association.environmentID] else { throw EnvironmentError.activationUnavailable }
        try Task.checkCancellation()
        try await handle.raiseAndConfirm()
        guard try await observe(evidence.association).unique() == evidence.instance else { throw EnvironmentError.processChanged }
        // No open/launch, terminate, authentication or fallback path exists in this method.
    }

    public func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) async throws {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        guard association.kind != .standardExternal || standardLifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        try await dispatchNormalQuit(instance, association: association)
    }
    private func dispatchNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation, scope: EnvironmentOperationScope? = nil) async throws {
        try validator.revalidate(association)
        try await validateInstallation()
        guard try await observe(association).unique() == instance else { throw EnvironmentError.processChanged }
        try Self.validateLiveSignature(instance.main.pid)
        if let scope { try await checkDispatchCatalogs(scope) }
        try validator.revalidate(association)
        try Task.checkCancellation()
        let ledger = dispatchLedger
        let sent = await MainActor.run {
            guard !Task.isCancelled, let target = NSRunningApplication(processIdentifier: instance.main.pid), !target.isTerminated,
                  target.launchDate == instance.nativeLaunchDate,
                  target.bundleIdentifier == CodexBundleInspector.bundleIdentifier,
                  target.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                  let fresh = NSRunningApplication(processIdentifier: instance.main.pid), fresh.isEqual(target) else { return false }
            if let scope { ledger.mark(scope.id, effect: .normalQuit(instance)) }
            return target.terminate()
        }
        guard sent else { throw EnvironmentError.processChanged }
    }
    public func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) async throws {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        try await confirmNormalExit(instance, association: association, timeout: timeout)
    }
    private func confirmNormalExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(10)))
        repeat {
            try Task.checkCancellation()
            let rows: [Int32: Row]
            do { rows = try await inventory(deadline: deadline) }
            catch { if ContinuousClock.now >= deadline { throw SwitchingError.exitTimedOut }; throw error }
            for generation in instance.related {
                if let current = rows[generation.pid], current.generation != generation { throw EnvironmentError.processChanged }
            }
            if instance.related.allSatisfy({ rows[$0.pid] == nil }) {
                guard try await observeUntil(association, deadline: deadline).unique() == nil else { throw EnvironmentError.ambiguousInstance }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw SwitchingError.exitTimedOut
    }
    public func launch(_ specification: DesktopLaunchSpecification) async throws {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        guard try DesktopLaunchSpecification(association: specification.association, allowStandardExternal: standardLifecycleAllowed) == specification else { throw EnvironmentError.invalidPath }
        try await dispatchLaunch(specification)
    }
    private func dispatchLaunch(_ specification: DesktopLaunchSpecification, scope: EnvironmentOperationScope? = nil) async throws {
        try validator.revalidate(specification.association)
        try await validateInstallation()
        guard try await observe(specification.association).unique() == nil else { throw EnvironmentError.ambiguousInstance }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = specification.arguments; process.environment = specification.environment
        process.currentDirectoryURL = specification.workingDirectory
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        if let scope { try await checkDispatchCatalogs(scope) }
        try validator.revalidate(specification.association)
        try Task.checkCancellation()
        if let scope {
            submittedLauncher = (scope.id, process)
            dispatchLedger.mark(scope.id, effect: .launch)
        }
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning, process.terminationStatus == 0 else { throw EnvironmentError.launchFailed }
        // Request delivery only. Driver separately verifies roots, generation and identity.
    }

    public func instanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory {
        guard lifecycleAllowed else { throw EnvironmentError.releaseGateClosed }
        return try await environmentInstanceInventory(associations: associations)
    }
    public func environmentInstanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory {
        try await collectInstanceInventory(associations: associations)
    }

    /// Read-only installation diagnosis only. Never feeds lifecycle plans or recovery.
    public func inspectInstallationProcesses() async throws -> InstallationProcessPreflightReport {
        let store = ProfileStore(root: validator.managedRoot)
        func references() async throws -> InstallationAssociationReferences {
            guard try await store.inspectPendingAccountSetup() == nil else { throw AccountSetupError.recoveryRequired }
            return try await InstallationAssociationReferences(state: store.inspectAccountSetup(),
                research: store.inspectRetainedResearchEnvironments())
        }
        let original = try await references()
        let session = InstallationPreflightSession()
        let first = try await collectInstallationGroups(references: original, session: session)
        guard try await references() == original else { throw EnvironmentError.processChanged }
        let second = try await collectInstallationGroups(references: original, session: session)
        guard try await references() == original else { throw EnvironmentError.processChanged }
        return try InstallationProcessPreflightReport(first: first, second: second)
    }

    private func collectInstallationGroups(references: InstallationAssociationReferences,
        session: InstallationPreflightSession) async throws -> InstallationGroupingSnapshot {
        let build = try await openingBuildFingerprint()
        try references.revalidate(using: validator)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let nativeBefore = await Self.nativeMainPIDs()
        let before = try await inventory(deadline: deadline, preflight: session)
        session.observations = []
        for reference in references.values {
            _ = try await observeUntil(reference.association, deadline: deadline, preflight: session).unique()
        }
        let after = try await inventory(deadline: deadline, preflight: session)
        let nativeAfter = await Self.nativeMainPIDs()
        func selected(_ rows: [Int32: Row]) -> [Int32: Row] {
            var members = Set(rows.values.filter(\.inBundle).map { $0.generation.pid })
            while true {
                let expanded = members.union(rows.values.filter { members.contains($0.parent) }.map { $0.generation.pid })
                if expanded == members { break }; members = expanded
            }
            return rows.filter { members.contains($0.key) }
        }
        guard selected(before) == selected(after), nativeBefore == nativeAfter,
              ContinuousClock.now < deadline else { throw EnvironmentError.processChanged }
        try references.revalidate(using: validator)
        guard try await openingBuildFingerprint() == build else { throw EnvironmentError.incompatibleBuild }
        return try InstallationGroupingSnapshot(references: references, observations: session.observations,
            mains: Set(before.values.filter(\.main).map(\.generation)), nativePIDs: nativeAfter,
            witnesses: session.witnesses ?? [:], build: build)
    }

    private func collectInstanceInventory(associations: [EnvironmentAssociation],
        preflight: InstallationPreflightSession? = nil) async throws -> DesktopInstanceInventory {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let nativeBefore = await Self.nativeMainPIDs()
        let before = try await inventory(deadline: deadline, preflight: preflight)
        var entries: [DesktopInventoryEntry] = []
        for association in associations {
            if let instance = try await observeUntil(association, deadline: deadline, preflight: preflight).unique() {
                entries.append(DesktopInventoryEntry(association: association, instance: instance))
            }
        }
        let after = try await inventory(deadline: deadline, preflight: preflight)
        let nativeAfter = await Self.nativeMainPIDs()
        let mains = before.values.filter(\.main).map(\.generation)
        guard Set(mains) == Set(after.values.filter(\.main).map(\.generation)),
              nativeBefore == nativeAfter, Set(mains.map(\.pid)).isSubset(of: nativeAfter),
              Set(entries.map { $0.instance.main }).count == entries.count,
              entries.allSatisfy({ mains.contains($0.instance.main) }), ContinuousClock.now < deadline else { throw EnvironmentError.processChanged }
        // A currently unlinked research main is counted as unknown and blocks Close Others.
        return DesktopInstanceInventory(entries: entries, unknownCount: nativeAfter.count - entries.count)
    }
    @MainActor private static func nativeMainPIDs() -> Set<Int32> {
        // Include other official copies with the same bundle ID instead of silently ignoring their path.
        Set(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier == CodexBundleInspector.bundleIdentifier
                || $0.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        }.map(\.processIdentifier))
    }
    public func authorizeEnvironmentOperation(_ scope: EnvironmentOperationScope, allowPrimary: Bool) async throws {
        guard operationScope == nil else { throw AccountOpeningError.busy }
        try scope.validate()
        guard allowPrimary || !scope.others.contains(where: { $0.association.kind == .standardExternal }) else { throw AccountOpeningError.primaryConsentRequired }
        try await checkScopeMetadata(scope)
        try await checkScopeInventory(scope, closed: [], launched: nil)
        // Reentrancy cannot replace an operation while its checks are suspended.
        guard operationScope == nil else { throw AccountOpeningError.busy }
        operationScope = scope; scopeClosed = []; scopeQuit = []
        scopeActivated = false; scopeLaunched = false; scopeLaunchedInstance = nil
    }
    private func checkDispatchCatalogs(_ scope: EnvironmentOperationScope) async throws {
        guard operationScope == scope else { throw EnvironmentOpeningError.confirmationRequired }
        try await checkScopeCatalogs(scope)
        guard operationScope == scope else { throw EnvironmentOpeningError.stalePlan }
    }
    private func checkScopeMetadata(_ scope: EnvironmentOperationScope) async throws {
        try await checkScopeCatalogs(scope)
        try await validateInstallation()
    }
    private func checkScopeCatalogs(_ scope: EnvironmentOperationScope) async throws {
        try Task.checkCancellation(); try scope.validate()
        let store = ProfileStore(root: validator.managedRoot)
        guard try await store.inspect() == scope.profiles,
              try await store.inspectAssociations() == scope.associations,
              try await store.inspectManagedEnvironments() == scope.managed else { throw EnvironmentOpeningError.stalePlan }
        if scope.mode == .closeOthersAndOpen {
            guard try await store.inspectRetainedResearchEnvironments() == scope.retainedResearch else { throw EnvironmentOpeningError.stalePlan }
        }
        try validator.revalidate(scope.target)
        for item in scope.others { try validator.revalidate(item.association) }
    }
    private func checkScopeInventory(_ scope: EnvironmentOperationScope, closed: Set<UUID>, launched: DesktopInstance?) async throws {
        let target = try await observe(scope.target).unique()
        guard target == (launched ?? scope.targetInstance) else { throw AccountOpeningError.processChanged }
        if scope.mode == .closeOthersAndOpen {
            let inventory = try await environmentInstanceInventory(associations: scope.associations.associations + scope.retainedResearch)
            try inventory.validate()
            let expected = scope.others.filter { !closed.contains($0.association.environmentID) }
                + (target.map { [DesktopInventoryEntry(association: scope.target, instance: $0)] } ?? [])
            guard inventory.entries.count == expected.count, expected.allSatisfy(inventory.entries.contains) else { throw AccountOpeningError.processChanged }
        }
    }
    private func recheckScope(_ scope: EnvironmentOperationScope) async throws {
        guard operationScope == scope else { throw EnvironmentOpeningError.confirmationRequired }
        try await checkScopeMetadata(scope)
        try await checkScopeInventory(scope, closed: scopeClosed, launched: scopeLaunchedInstance)
        guard operationScope == scope else { throw EnvironmentOpeningError.stalePlan }
        try Task.checkCancellation()
    }
    public func activateScopedEnvironment(_ scope: EnvironmentOperationScope, instance: DesktopInstance) async throws {
        try await recheckScope(scope)
        guard !scopeActivated, instance == (scopeLaunchedInstance ?? scope.targetInstance),
              scope.mode == .openSeparately || scopeClosed.count == scope.others.count else { throw EnvironmentOpeningError.stalePlan }
        try Self.validateLiveSignature(instance.main.pid)
        scopeActivated = true
        try await dispatchPIDActivation(scope.target, instance: instance, scope: scope)
    }
    public func launchScopedEnvironment(_ scope: EnvironmentOperationScope) async throws -> DesktopInstance {
        try await recheckScope(scope)
        guard !scopeLaunched, scope.targetInstance == nil,
              scope.mode == .openSeparately || scopeClosed.count == scope.others.count else { throw EnvironmentOpeningError.stalePlan }
        let specification = try DesktopLaunchSpecification(association: scope.target, allowStandardExternal: true)
        scopeLaunched = true
        try await dispatchLaunch(specification, scope: scope)
        let instance = try await DesktopReadiness.wait { timeout in
            try await self.observe(scope.target, timeout: timeout)
        }
        guard operationScope == scope else { throw EnvironmentOpeningError.stalePlan }
        try await checkScopeMetadata(scope)
        scopeLaunchedInstance = instance
        return instance
    }

    public func quitScopedEnvironment(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws {
        try await recheckScope(scope)
        guard scope.mode == .closeOthersAndOpen, scope.others.contains(item),
              !scopeQuit.contains(item.association.environmentID), item.association != scope.target else { throw EnvironmentOpeningError.stalePlan }
        scopeQuit.insert(item.association.environmentID)
        try await dispatchNormalQuit(item.instance, association: item.association, scope: scope)
    }
    public func waitForScopedExit(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws {
        guard operationScope == scope, scope.others.contains(item), scopeQuit.contains(item.association.environmentID),
              !scopeClosed.contains(item.association.environmentID) else { throw EnvironmentOpeningError.stalePlan }
        try await confirmNormalExit(item.instance, association: item.association, timeout: .seconds(10))
        guard operationScope == scope else { throw EnvironmentOpeningError.stalePlan }
        scopeClosed.insert(item.association.environmentID)
    }
    public func environmentEffectDisposition(_ id: UUID) -> EnvironmentEffectDisposition {
        dispatchLedger.disposition(for: id)
    }
    public func confirmEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, inventoryAssociations: [EnvironmentAssociation]) async throws {
        guard operationScope == nil else { throw AccountOpeningError.busy }
        let effects = dispatchLedger.effects(for: scope.id)
        let launcherRunning = effects.contains(.launch)
            && (submittedLauncher?.id != scope.id || submittedLauncher?.process.isRunning != false)
        try await validateInstallation()
        for association in [scope.target] + scope.others.map(\.association) { try validator.revalidate(association) }
        let first = try await environmentInstanceInventory(associations: inventoryAssociations)
        let live = try await inventory()
        try EnvironmentRecoveryProof.validate(scope: scope, effects: effects, inventory: first,
            livePIDs: Set(live.keys), launcherRunning: launcherRunning)
        let second = try await environmentInstanceInventory(associations: inventoryAssociations)
        guard first.entries == second.entries, first.unknownCount == second.unknownCount else {
            throw EnvironmentError.processChanged
        }
        try EnvironmentRecoveryProof.validate(scope: scope, effects: effects, inventory: second,
            livePIDs: Set(try await inventory().keys), launcherRunning: launcherRunning)
        try Task.checkCancellation()
    }
    public func finishEnvironmentOperation(_ id: UUID) {
        guard operationScope?.id == id else { return }
        operationScope = nil; scopeClosed = []; scopeQuit = []; scopeLaunchedInstance = nil
        scopeActivated = false; scopeLaunched = false
    }

    /// Restored journal data is observation evidence only; never assign it to operationScope.
    public func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope,
        effects: [EnvironmentSubmittedEffect], inventoryAssociations: [EnvironmentAssociation]) async throws {
        guard operationScope == nil else { throw AccountOpeningError.busy }
        let captured = scope.others.map(\.instance) + (scope.targetInstance.map { [$0] } ?? [])
            + effects.compactMap { effect -> DesktopInstance? in
                if case let .activation(instance) = effect { return instance }; return nil
            }
        guard captured.flatMap(\.related).allSatisfy({ $0.startTimeMicroseconds != nil }) else { throw AccountOpeningError.recoveryRequired }
        // A launcher handle is lost on restart. Without a captured owned result, dispatch may
        // still be pending; presence of some target or disappearance of old processes is insufficient.
        if effects.contains(.launch), submittedLauncher?.id != scope.id,
           !effects.contains(where: { if case .activation = $0 { return true }; return false }) {
            throw AccountOpeningError.recoveryRequired
        }
        if submittedLauncher?.id == scope.id, submittedLauncher?.process.isRunning == true {
            throw AccountOpeningError.recoveryRequired
        }
        try await validateInstallation()
        for association in inventoryAssociations { try validator.revalidate(association) }
        let first = try await environmentInstanceInventory(associations: inventoryAssociations)
        try EnvironmentRecoveryProof.validate(scope: scope, effects: effects, inventory: first,
            livePIDs: Set(try await inventory().keys), launcherRunning: false)
        let second = try await environmentInstanceInventory(associations: inventoryAssociations)
        guard first.entries == second.entries, first.unknownCount == second.unknownCount else { throw EnvironmentError.processChanged }
        try EnvironmentRecoveryProof.validate(scope: scope, effects: effects, inventory: second,
            livePIDs: Set(try await inventory().keys), launcherRunning: false)
        try Task.checkCancellation()
    }

    private static func validateLiveSignature(_ pid: Int32) throws {
        var guest: SecCode?, requirement: SecRequirement?, liveStatic: SecStaticCode?, diskStatic: SecStaticCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let rule = "identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &liveStatic) == errSecSuccess, let liveStatic,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Applications/ChatGPT.app") as CFURL, [], &diskStatic) == errSecSuccess, let diskStatic else {
            throw EnvironmentError.incompatibleBuild
        }
        var liveInfo: CFDictionary?, diskInfo: CFDictionary?
        guard SecCodeCopySigningInformation(liveStatic, [], &liveInfo) == errSecSuccess,
              SecCodeCopySigningInformation(diskStatic, [], &diskInfo) == errSecSuccess,
              let liveHash = (liveInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let diskHash = (diskInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              liveHash == diskHash else { throw EnvironmentError.incompatibleBuild }
    }

    private func command(_ executable: String, _ arguments: [String], deadline outerDeadline: ContinuousClock.Instant? = nil) async throws -> (status: Int32, output: String) {
        guard ["/bin/ps", "/usr/sbin/lsof", "/usr/bin/codesign"].contains(executable) else { throw EnvironmentError.ambiguousInstance }
        let deadline = min(ContinuousClock.now.advanced(by: .seconds(5)), outerDeadline ?? ContinuousClock.now.advanced(by: .seconds(5)))
        guard ContinuousClock.now < deadline else { throw EnvironmentError.ambiguousInstance }
        let process = Process(), pipe = Pipe(), buffer = CommandBuffer()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin", "LANG": "C", "LC_ALL": "C", "TZ": "UTC"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in buffer.read(handle) }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        try Task.checkCancellation()
        try process.run()
        while process.isRunning && ContinuousClock.now < deadline {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else { throw EnvironmentError.ambiguousInstance } // Never signal a timed-out child.
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.finish(pipe.fileHandleForReading)
        return (process.terminationStatus, try buffer.text())
    }
}

private final class CommandBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    private func append(_ data: Data) {
        if bytes.count + data.count > 8_388_608 { overflow = true }
        else { bytes.append(data) }
    }
    func read(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        append(handle.availableData)
    }
    func finish(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        append(handle.readDataToEndOfFile())
    }
    func text() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, let value = String(data: bytes, encoding: .utf8) else { throw EnvironmentError.ambiguousInstance }
        return value
    }
}
