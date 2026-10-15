import Foundation
import Darwin

/// This release has no verified live identity bridge or two-account acceptance result.
public enum DesktopIntegrationPolicy {
    public static let lifecycleEnabled = false
    public static let primaryLifecycleEnabled = false
    public static var blockedReason: String { L10n.text("opening.blocked") }
}

public struct DesktopGeneration: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let started: String
    public let startTimeMicroseconds: UInt64?
    public init(pid: Int32, uid: UInt32, started: String, startTimeMicroseconds: UInt64? = nil) {
        self.pid = pid; self.uid = uid; self.started = started; self.startTimeMicroseconds = startTimeMicroseconds
    }
}
public struct DesktopInstance: Codable, Equatable, Sendable {
    public let main: DesktopGeneration
    public let related: [DesktopGeneration]
    public let nativeLaunchDate: Date
    public let signingIdentity: CodexSigningIdentity?
    public init(main: DesktopGeneration, related: [DesktopGeneration], nativeLaunchDate: Date, signingIdentity: CodexSigningIdentity? = nil) {
        self.main = main; self.related = related; self.nativeLaunchDate = nativeLaunchDate; self.signingIdentity = signingIdentity
    }
}
public struct DesktopObservation: Sendable {
    public let matching: [DesktopInstance]
    public let ambiguous: Bool
    public let observedAt: Date
    public init(matching: [DesktopInstance], ambiguous: Bool, observedAt: Date = Date()) {
        self.matching = matching; self.ambiguous = ambiguous; self.observedAt = observedAt
    }
    public func unique(now: Date = Date()) throws -> DesktopInstance? {
        guard !ambiguous, matching.count <= 1, observedAt <= now, now.timeIntervalSince(observedAt) <= 5 else {
            throw EnvironmentError.ambiguousInstance
        }
        if let instance = matching.first {
            try instance.signingIdentity?.validate()
            guard instance.main.pid > 0, instance.main.uid == getuid(), !instance.main.started.isEmpty,
                  instance.nativeLaunchDate <= now, instance.related.contains(instance.main),
                  Set(instance.related.map(\.pid)).count == instance.related.count,
                  instance.related.allSatisfy({ $0.pid > 0 && $0.uid == getuid() && !$0.started.isEmpty }) else {
                throw EnvironmentError.processChanged
            }
        }
        return matching.first
    }
}

/// Runtime-only, supplied by a future supported verifier. Never decoded from profile metadata.
public enum AccountVerification: Equatable, Sendable {
    case unavailable, signedOut, identityMismatch
    case verified(profileID: UUID, environmentID: UUID, generation: DesktopGeneration, checkedAt: Date, expiresAt: Date)
    public func confirms(_ association: EnvironmentAssociation, instance: DesktopInstance, now: Date = Date()) -> Bool {
        guard case let .verified(profile, environment, generation, checked, expires) = self else { return false }
        return profile == association.profileID && environment == association.environmentID && generation == instance.main
            && checked <= now && now.timeIntervalSince(checked) <= 5 && expires > now
    }
}
public enum ConnectionPresentation {
    public static func state(association: EnvironmentAssociation?, verification: AccountVerification = .unavailable,
                             instance: DesktopInstance? = nil, selected: Bool = false, failed: Bool = false,
                             now: Date = Date()) -> ProfileConnectionState {
        guard let association else { return .notConnected }
        if failed { return .error }
        if verification == .signedOut { return .reauthenticationRequired }
        if verification == .identityMismatch { return .accountMismatch }
        guard let instance, verification.confirms(association, instance: instance, now: now) else { return .verificationRequired }
        return selected ? .active : .connected
    }
}

public struct DesktopLaunchSpecification: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public init(association: EnvironmentAssociation, allowStandardExternal: Bool = false) throws {
        guard association.kind != .standardExternal || allowStandardExternal else { throw EnvironmentError.releaseGateClosed }
        self.association = association
        let paths = DesktopLaunchPaths(association: association)
        arguments = ["-n", "-g", "--env", "CODEX_HOME=" + paths.home,
                     "--env", "CODEX_ELECTRON_USER_DATA_PATH=" + paths.electron,
                     "--env", "PATH=/usr/bin:/bin", "--env", "LANG=en_US.UTF-8",
                     "/Applications/ChatGPT.app", "--args", "--user-data-dir=" + paths.electron]
        environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let base = URL(fileURLWithPath: association.codexHome).deletingLastPathComponent()
        workingDirectory = association.isTemporary ? base.deletingLastPathComponent().deletingLastPathComponent() : base
    }
}

public protocol DesktopSystem: Sendable {
    func environmentInstanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory
    func authorizeEnvironmentOperation(_ scope: EnvironmentOperationScope, allowPrimary: Bool) async throws
    func activateScopedEnvironment(_ scope: EnvironmentOperationScope, instance: DesktopInstance) async throws
    func launchScopedEnvironment(_ scope: EnvironmentOperationScope) async throws -> DesktopInstance
    func launchScopedEnvironment(_ scope: EnvironmentOperationScope,
        recordReceiver: @Sendable (DesktopInstance) throws -> Void) async throws -> DesktopInstance
    func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope,
        effects: [EnvironmentSubmittedEffect], launchReceiver: DesktopInstance?, inventoryAssociations: [EnvironmentAssociation]) async throws
    func quitScopedEnvironment(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws
    func waitForScopedExit(_ scope: EnvironmentOperationScope, item: DesktopInventoryEntry) async throws
    func finishEnvironmentOperation(_ id: UUID) async
    func environmentOpeningFailureStage() async -> OpeningFailureRecord.Stage?
    func environmentEffectDisposition(_ id: UUID) async -> EnvironmentEffectDisposition
    func confirmEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, inventoryAssociations: [EnvironmentAssociation]) async throws
    func confirmPersistedEnvironmentOperationSettled(_ scope: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect], inventoryAssociations: [EnvironmentAssociation]) async throws
    func permitsPIDActivation(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async -> Bool
    func activatePIDEnvironment(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async throws
    func verifyPIDForeground(_ instance: DesktopInstance) async throws
    var lifecycleAllowed: Bool { get }
    var standardLifecycleAllowed: Bool { get }
    var environmentActivationAllowed: Bool { get }
    func environmentActivationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence
    func activateEnvironment(_ evidence: DesktopActivationEvidence) async throws
    func instanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory
    func validateInstallation() async throws
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint
    func observe(_ association: EnvironmentAssociation, timeout: Duration) async throws -> DesktopObservation
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) async throws
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) async throws
    func launch(_ specification: DesktopLaunchSpecification) async throws
    func activationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence
    /// Strict activation-only contract: no launch, quit, reopen URL, authentication or fallback.
    func activate(_ evidence: DesktopActivationEvidence) async throws
}
public extension DesktopSystem {
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint { throw OpeningJournalError.unavailable }
    func permitsPIDActivation(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async -> Bool { false }
    func activatePIDEnvironment(_ association: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) async throws { throw EnvironmentOpeningError.unavailable }
    func verifyPIDForeground(_ instance: DesktopInstance) async throws { throw SwitchingError.activationFailed }
    var environmentActivationAllowed: Bool { false }
    func environmentActivationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        throw EnvironmentOpeningError.unavailable
    }
    func activateEnvironment(_ evidence: DesktopActivationEvidence) async throws { throw EnvironmentOpeningError.unavailable }
    var standardLifecycleAllowed: Bool { false }
    func instanceInventory(associations: [EnvironmentAssociation]) async throws -> DesktopInstanceInventory { throw AccountOpeningError.ambiguousInstance }
    func observe(_ association: EnvironmentAssociation) async throws -> DesktopObservation {
        try await observe(association, timeout: .seconds(5))
    }
    func activationEvidence(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> DesktopActivationEvidence {
        throw EnvironmentError.activationUnavailable
    }
    func activate(_ evidence: DesktopActivationEvidence) async throws { throw EnvironmentError.activationUnavailable }
}
public protocol DesktopAccountVerifying: Sendable {
    func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> AccountVerification
    /// A supported prelaunch routing/identity capability and independent enrollment anchor are required.
    func validateLaunchReadiness(_ association: EnvironmentAssociation) async throws
}
public extension DesktopAccountVerifying {
    func validateLaunchReadiness(_ association: EnvironmentAssociation) async throws { throw AccountOpeningError.identityUnverified }
}
public struct UnavailableDesktopAccountVerifier: DesktopAccountVerifying {
    public init() {}
    public func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> AccountVerification { .unavailable }
}

/// Reuses the existing coordinator's serialization, tri-state consent, rechecks and cancellation.
/// The native system's release gate is closed. Tests inject only synthetic systems/verifiers.
public actor DesktopSwitchingDriver: AccountSwitchingDriver {
    private let store: ProfileStore
    private let validator: EnvironmentValidator
    private let system: any DesktopSystem
    private let verifier: any DesktopAccountVerifying
    private let source: EnvironmentAssociation?
    private var target: EnvironmentAssociation?
    private var selectedStrategy: AccountSwitchingStrategy = .restart
    private var activation: DesktopActivationEvidence?
    private var capturedSource: DesktopInstance?
    private var launched: DesktopInstance?
    private var quitRequested = false
    private var launchSubmitted = false
    private var activationSubmitted = false
    private var environmentPlan: EnvironmentOpeningPlan?
    private var pidPlan: PIDEnvironmentOpeningPlan?
    private var scopedOpening = false
    private var scopedRetainedResearch: [EnvironmentAssociation] = []
    private var scopedManaged: ManagedEnvironmentCatalog?
    private var operationScope: EnvironmentOperationScope?
    private var recoveryScope: EnvironmentOperationScope?
    private let bootSessionProvider: @Sendable () throws -> String
    private let openingJournal: OpeningOperationJournal
    public let independentOpeningAllowed: Bool
    private var openingStage: OpeningFailureRecord.Stage?
    private var journalID: UUID?
    private var journalBuild: OpeningBuildFingerprint?
    private var observedRecoveryID: UUID?
    private var durablePlan: AccountOpeningPlan?
    private var openingToken: UUID?
    private var openingQuitGenerations = Set<DesktopGeneration>()

    public init(bootSession: @escaping @Sendable () throws -> String = OpeningOperationJournal.bootSession,
                store: ProfileStore, validator: EnvironmentValidator, system: any DesktopSystem,
                verifier: any DesktopAccountVerifying = AccountIdentityVerifier(), source: EnvironmentAssociation? = nil,
                openingJournal: OpeningOperationJournal? = nil, independentOpeningAllowed: Bool = false) {
        self.store = store; self.validator = validator; self.system = system; self.verifier = verifier; self.source = source
        self.bootSessionProvider = bootSession
        self.independentOpeningAllowed = independentOpeningAllowed
        self.openingJournal = openingJournal ?? OpeningOperationJournal(root: store.root)
    }
    public func validate(profile: AccountProfile) async throws {
        guard system.lifecycleAllowed else { throw SwitchingError.unavailable }
        guard pidPlan == nil, environmentPlan == nil, !launchSubmitted, !quitRequested, !activationSubmitted else { throw EnvironmentError.recoveryRequired }
        target = nil; activation = nil; capturedSource = nil; launched = nil
        guard let association = try await store.inspectAssociations().associations.first(where: { $0.profileID == profile.id }) else {
            throw EnvironmentError.missingAssociation
        }
        try validator.revalidate(association)
        try await system.validateInstallation()
        if let instance = try await system.observe(association).unique() {
            // Prefer an already-running instance, including a protected standard external reference.
            // A real native window-ownership bridge is still blocked; bundle ID/PID alone cannot pass.
            guard !association.isTemporary else { throw EnvironmentError.releaseGateClosed }
            try await requireIdentity(association, instance: instance)
            let evidence = try await system.activationEvidence(association, instance: instance)
            try evidence.validate(association: association, instance: instance)
            activation = evidence; selectedStrategy = .activate
        } else {
            guard association.kind == .managed, source == nil || source?.kind == .managed else {
                throw EnvironmentError.releaseGateClosed
            }
            selectedStrategy = source == nil ? .launch : .restart
        }
        target = association
    }
    public func strategy() async throws -> AccountSwitchingStrategy { selectedStrategy }
    public func processIsRunning() async throws -> Bool {
        guard let source else { return false }
        try validator.revalidate(source)
        guard let instance = try await system.observe(source).unique() else { throw EnvironmentError.processChanged }
        try await requireIdentity(source, instance: instance)
        capturedSource = instance
        return true
    }
    public func prepare(profile: AccountProfile) async throws {
        guard let target, target.profileID == profile.id else { throw EnvironmentError.missingAssociation }
        try await retainedAssociation(target)
        try validator.revalidate(target)
        // No enrollment, auth, persistent selection or environment writes.
    }
    public func requestGracefulQuit() async throws {
        guard selectedStrategy == .restart, system.lifecycleAllowed, !quitRequested, let source, let capturedSource, let target else { throw EnvironmentError.processChanged }
        try await retainedAssociation(target)
        try validator.revalidate(target)
        guard try await system.observe(target).unique() == nil else { throw EnvironmentError.ambiguousInstance }
        try await retainedAssociation(source)
        try validator.revalidate(source)
        try await system.validateInstallation()
        guard try await system.observe(source).unique() == capturedSource else {
            throw EnvironmentError.processChanged
        }
        try await requireIdentity(source, instance: capturedSource)
        try Task.checkCancellation()
        try await beginLegacyOpeningJournal()
        try await recordOpeningEffect(.normalQuit(capturedSource))
        quitRequested = true // Consumed before dispatch; errors never grant a retry.
        try await system.requestNormalQuit(capturedSource, association: source)
    }
    public func waitForExit(timeout: Duration) async throws {
        guard quitRequested, let source, let capturedSource else { throw EnvironmentError.processChanged }
        try await system.waitForExit(capturedSource, association: source, timeout: timeout)
        // The system contract confirms all captured processes and any replacement root use within this deadline.
    }
    public func launch(profile: AccountProfile) async throws {
        if scopedOpening {
            guard !launchSubmitted, let scope = operationScope, scope.target.profileID == profile.id else { throw AccountOpeningError.processChanged }
            try await recordOpeningEffect(.launch)
            launchSubmitted = true
            let journal = openingJournal
            let persistReceiver = !independentOpeningAllowed || scope.mode != .openSeparately
            openingStage = .launch
            launched = try await system.launchScopedEnvironment(scope, recordReceiver: {
                if persistReceiver { try journal.captureLaunchReceiver($0, operation: scope.id) }
            })
            try await recordOpeningEffect(.activation(launched!))
            activationSubmitted = true
            openingStage = .activation
            do { try await system.activateScopedEnvironment(scope, instance: launched!) }
            catch { openingStage = await system.environmentOpeningFailureStage() ?? openingStage; throw error }
            return
        }
        guard selectedStrategy != .activate, system.lifecycleAllowed, !launchSubmitted, let target, target.profileID == profile.id else { throw EnvironmentError.launchFailed }
        try Task.checkCancellation()
        try await retainedAssociation(target)
        try validator.revalidate(target)
        try await system.validateInstallation()
        if openingToken == nil, let source, quitRequested, try await system.observe(source).unique() != nil { throw SwitchingError.exitTimedOut }
        guard try await system.observe(target).unique() == nil else { throw EnvironmentError.ambiguousInstance }
        let specification = try DesktopLaunchSpecification(association: target, allowStandardExternal: system.standardLifecycleAllowed && openingToken != nil)
        try Task.checkCancellation()
        try await beginLegacyOpeningJournal()
        try await recordOpeningEffect(.launch)
        launchSubmitted = true
        try await system.launch(specification)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            try Task.checkCancellation()
            try validator.revalidate(target)
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw EnvironmentError.launchFailed }
            if let instance = try await system.observe(target, timeout: remaining).unique() { launched = instance; return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw EnvironmentError.launchFailed
    }
    public func authenticatedProfileID() async throws -> UUID? {
        guard let target, let launched else { return nil }
        try await retainedAssociation(target)
        try validator.revalidate(target)
        try await system.validateInstallation()
        guard try await system.observe(target).unique() == launched else { throw EnvironmentError.processChanged }
        try await requireIdentity(target, instance: launched)
        return target.profileID
    }
    public func activate(profile: AccountProfile) async throws {
        if scopedOpening {
            guard !activationSubmitted, let scope = operationScope, scope.target.profileID == profile.id,
                  let instance = scope.targetInstance else { throw AccountOpeningError.processChanged }
            try await recordOpeningEffect(.activation(instance))
            activationSubmitted = true
            openingStage = .activation
            do { try await system.activateScopedEnvironment(scope, instance: instance) }
            catch { openingStage = await system.environmentOpeningFailureStage() ?? openingStage; throw error }
            return
        }
        guard system.lifecycleAllowed, selectedStrategy == .activate, !activationSubmitted,
              let target, target.profileID == profile.id, let activation else { throw EnvironmentError.activationUnavailable }
        try await retainedAssociation(target)
        try validator.revalidate(target)
        try await system.validateInstallation()
        guard try await system.observe(target).unique() == activation.instance else { throw EnvironmentError.processChanged }
        try await requireIdentity(target, instance: activation.instance)
        let fresh = try await system.activationEvidence(target, instance: activation.instance)
        try fresh.validate(association: target, instance: activation.instance)
        guard fresh.windowIDs == activation.windowIDs, fresh.windowToken == activation.windowToken else { throw EnvironmentError.activationUnavailable }
        try Task.checkCancellation()
        try await beginLegacyOpeningJournal()
        try await recordOpeningEffect(.activation(activation.instance))
        activationSubmitted = true
        try await system.activate(fresh)
        launched = activation.instance // Same running generation; not a launch operation.
    }
    public func rollback() async throws {
        openingJournal.abandon(); journalID = nil
        target = nil; launched = nil; activation = nil
        // Metadata was not committed. External process/auth changes cannot be transactionally undone.
        if quitRequested || launchSubmitted || activationSubmitted { throw EnvironmentError.recoveryRequired }
    }
    private func requireIdentity(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws {
        let proof = try await verifier.verify(association, instance: instance)
        if proof == .signedOut { throw EnvironmentError.authenticationRequired }
        if proof == .identityMismatch { throw EnvironmentError.accountMismatch }
        guard proof.confirms(association, instance: instance) else { throw EnvironmentError.identityUnverified }
    }
    private func retainedAssociation(_ association: EnvironmentAssociation) async throws {
        guard try await store.inspectAssociations().associations.contains(association) else { throw EnvironmentError.changedDirectory }
    }
}

extension DesktopSwitchingDriver {
    public func planOpening(profile: AccountProfile, mode: AccountOpeningMode) async throws -> AccountOpeningPlan {
        try await buildOpeningPlan(profile: profile, mode: mode, environmentScoped: false)
    }
    private func buildOpeningPlan(profile: AccountProfile, mode: AccountOpeningMode, environmentScoped: Bool) async throws -> AccountOpeningPlan {
        guard environmentScoped || system.lifecycleAllowed else { throw SwitchingError.unavailable }
        guard pidPlan == nil, !quitRequested, !launchSubmitted, !activationSubmitted, openingToken == nil, environmentPlan == nil else { throw AccountOpeningError.recoveryRequired }
        let profiles = try await store.inspect()
        guard profiles.profiles.contains(profile) else { throw ProfileError.missingProfile }
        let associations = try await store.inspectAssociations()
        guard let association = associations.associations.first(where: { $0.profileID == profile.id }) else { throw AccountOpeningError.targetNotLinked }
        try validator.revalidate(association)
        guard !association.isTemporary else { throw EnvironmentError.releaseGateClosed }
        if environmentScoped {
            guard association.kind == .managed || association.kind == .standardExternal else { throw EnvironmentOpeningError.unavailable }
        }
        let managed = try await store.inspectManagedEnvironments()
        try await system.validateInstallation()
        let instance: DesktopInstance?
        do { instance = try await system.observe(association).unique() }
        catch let error as EnvironmentError where environmentScoped
            && (error == .ambiguousInstance || error == .processChanged || error == .backendNotReady) {
            instance = try await DesktopReadiness.wait(timeout: .seconds(5), preserveReason: true) {
                try await self.system.observe(association, timeout: $0)
            }
        }
        var evidence: DesktopActivationEvidence?
        if let instance, !environmentScoped {
            try await requireIdentity(association, instance: instance)
            evidence = try await system.activationEvidence(association, instance: instance)
            try evidence?.validate(association: association, instance: instance)
        } else if instance == nil && !environmentScoped {
            guard association.kind == .managed || (association.kind == .standardExternal && system.standardLifecycleAllowed) else {
                throw AccountOpeningError.primaryConsentRequired
            }
            // No speculative launch to discover which account owns the environment.
            try await verifier.validateLaunchReadiness(association)
            _ = try DesktopLaunchSpecification(association: association, allowStandardExternal: system.standardLifecycleAllowed)
        }
        let retained = environmentScoped && mode == .closeOthersAndOpen ? try await store.inspectRetainedResearchEnvironments() : []
        let inventoryAssociations = associations.associations + retained
        var others: [OpeningInstance] = []
        if mode == .closeOthersAndOpen {
            // The backup is only an ownership candidate. observe() checks its guarded marker,
            // current private directory identities, live signature and both roots before mapping A.
            for candidate in retained { try validator.revalidate(candidate) }
            let inventory = try await environmentScoped ? system.environmentInstanceInventory(associations: inventoryAssociations) : system.instanceInventory(associations: inventoryAssociations)
            try inventory.validate()
            guard DesktopOpeningTarget.matches(inventory.entries.first(where: { $0.association == association })?.instance,
                expected: instance, newlyLaunched: false, allowChildChanges: environmentScoped) else { throw AccountOpeningError.processChanged }
            for entry in inventory.entries where entry.association != association {
                guard inventoryAssociations.contains(entry.association),
                      let owner = profiles.profiles.first(where: { $0.id == entry.association.profileID }) else { throw AccountOpeningError.unknownInstances }
                try validator.revalidate(entry.association)
                if !environmentScoped { try await requireIdentity(entry.association, instance: entry.instance) }
                guard environmentScoped || entry.association.kind != .standardExternal || system.standardLifecycleAllowed else {
                    throw AccountOpeningError.primaryConsentRequired
                }
                others.append(OpeningInstance(profile: owner, association: entry.association, instance: entry.instance))
            }
        }
        let token = UUID()
        target = association; activation = evidence; launched = nil; capturedSource = nil
        selectedStrategy = instance == nil ? .launch : .activate
        openingToken = token; scopedOpening = environmentScoped; scopedRetainedResearch = retained; scopedManaged = environmentScoped ? managed : nil
        let plan = AccountOpeningPlan(id: token, mode: mode, target: profile, association: association, targetInstance: instance,
                                  others: others.sorted { $0.instance.main.pid < $1.instance.main.pid }, profiles: profiles, associations: associations)
        durablePlan = plan
        return plan
    }

    public func recheckOpening(_ plan: AccountOpeningPlan, remaining: [OpeningInstance]) async throws {
        try Task.checkCancellation()
        guard scopedOpening || system.lifecycleAllowed else { throw SwitchingError.unavailable }
        guard openingToken == plan.id, target == plan.association,
              try await store.inspect() == plan.profiles, try await store.inspectAssociations() == plan.associations else {
            throw AccountOpeningError.processChanged
        }
        if scopedOpening {
            guard try await store.inspectManagedEnvironments() == scopedManaged else { throw EnvironmentOpeningError.stalePlan }
            if plan.mode == .closeOthersAndOpen {
                guard try await store.inspectRetainedResearchEnvironments() == scopedRetainedResearch else { throw EnvironmentOpeningError.stalePlan }
            }
        }
        try validator.revalidate(plan.association)
        try await system.validateInstallation()
        openingStage = .driverPostflightTarget
        let currentTarget = try await system.observeOpeningTarget(plan.association, launchedReceiver: scopedOpening ? launched : nil,
            expectedReceiver: scopedOpening ? plan.targetInstance : nil)
        guard DesktopOpeningTarget.matches(currentTarget, expected: launched ?? plan.targetInstance,
            newlyLaunched: scopedOpening && launched != nil, allowChildChanges: scopedOpening) else { throw AccountOpeningError.processChanged }
        if let currentTarget, !scopedOpening {
            try await requireIdentity(plan.association, instance: currentTarget)
            if let activation {
                let fresh = try await system.activationEvidence(plan.association, instance: currentTarget)
                try fresh.validate(association: plan.association, instance: currentTarget)
                guard fresh.windowIDs == activation.windowIDs, fresh.windowToken == activation.windowToken else {
                    throw AccountOpeningError.windowUnavailable
                }
            }
        }
        else if !scopedOpening { try await verifier.validateLaunchReadiness(plan.association) }
        if plan.mode == .closeOthersAndOpen {
            openingStage = .driverPostflightInventory
            let expected = remaining.map { DesktopInventoryEntry(association: $0.association, instance: $0.instance) }
                + (currentTarget.map { [DesktopInventoryEntry(association: plan.association, instance: $0)] } ?? [])
            let launchedTarget = scopedOpening && launched != nil ? currentTarget.map { DesktopInventoryEntry(association: plan.association, instance: $0) } : nil
            let inventory = try await scopedOpening ? system.environmentInstanceInventory(associations: plan.associations.associations + scopedRetainedResearch)
                : system.instanceInventory(associations: plan.associations.associations)
            try inventory.validate()
            openingStage = .driverInventoryComparison
            guard DesktopOpeningTarget.confirms(inventory, expected: expected, launchedTarget: launchedTarget,
                allowChildChanges: scopedOpening) else { throw AccountOpeningError.processChanged }
            for item in remaining {
                try validator.revalidate(item.association)
                if !scopedOpening { try await requireIdentity(item.association, instance: item.instance) }
            }
        }
    }
    public func quitOpeningInstance(_ item: OpeningInstance, plan: AccountOpeningPlan, allowPrimary: Bool) async throws {
        guard scopedOpening || system.lifecycleAllowed else { throw SwitchingError.unavailable }
        guard openingToken == plan.id, plan.mode == .closeOthersAndOpen,
              plan.others.contains(item), item.association != plan.association, !openingQuitGenerations.contains(item.instance.main) else { throw AccountOpeningError.processChanged }
        guard !item.isPrimary || (allowPrimary && (scopedOpening || system.standardLifecycleAllowed)) else { throw AccountOpeningError.primaryConsentRequired }
        if scopedOpening && item.association.isTemporary {
            guard try await store.inspectRetainedResearchEnvironments() == scopedRetainedResearch,
                  scopedRetainedResearch.contains(item.association) else { throw EnvironmentOpeningError.stalePlan }
        } else { try await retainedAssociation(item.association) }
        try validator.revalidate(item.association)
        try await system.validateInstallation()
        guard DesktopOpeningTarget.matches(try await system.observe(item.association).unique(), expected: item.instance,
            newlyLaunched: false, allowChildChanges: scopedOpening) else { throw AccountOpeningError.processChanged }
        if !scopedOpening { try await requireIdentity(item.association, instance: item.instance) }
        try Task.checkCancellation()
        if !scopedOpening { try await beginLegacyOpeningJournal() }
        try await recordOpeningEffect(.normalQuit(item.instance))
        openingQuitGenerations.insert(item.instance.main)
        quitRequested = true // Never retry a possibly delivered normal-quit request.
        if scopedOpening {
            guard let scope = operationScope else { throw EnvironmentOpeningError.confirmationRequired }
            openingStage = .quitDispatch
            try await system.quitScopedEnvironment(scope, item: DesktopInventoryEntry(association: item.association, instance: item.instance))
        } else { try await system.requestNormalQuit(item.instance, association: item.association) }
    }
    public func waitForOpeningExit(_ item: OpeningInstance, timeout: Duration) async throws {
        guard openingToken != nil, quitRequested else { throw AccountOpeningError.processChanged }
        if scopedOpening {
            guard let scope = operationScope else { throw EnvironmentOpeningError.confirmationRequired }
            openingStage = .exitWait
            try await system.waitForScopedExit(scope, item: DesktopInventoryEntry(association: item.association, instance: item.instance))
        } else { try await system.waitForExit(item.instance, association: item.association, timeout: min(timeout, .seconds(10))) }
    }
    public func finishOpening(_ plan: AccountOpeningPlan, success: Bool) async {
        guard openingToken == plan.id else { return }
        let disposition = await system.environmentEffectDisposition(plan.id)
        let noDispatch = scopedOpening && disposition == .notDispatched
        let independent = scopedOpening && independentOpeningAllowed && plan.mode == .openSeparately
        if scopedOpening, !success, !noDispatch, !independent { recoveryScope = operationScope }
        if !success, noDispatch, journalID == plan.id {
            do { try openingJournal.complete(plan.id) } catch { /* Preserve an uncertain journal transition. */ }
        }
        openingJournal.abandon(); journalID = nil; durablePlan = nil
        await system.finishEnvironmentOperation(plan.id)
        scopedOpening = false; scopedManaged = nil; scopedRetainedResearch = []; operationScope = nil
        openingToken = nil
        target = nil; activation = nil; launched = nil; capturedSource = nil
        if success || noDispatch || independent { openingQuitGenerations = []; quitRequested = false; launchSubmitted = false; activationSubmitted = false }
        // Failure retains consumed effect flags. No launch, quit, metadata change or automatic rollback.
    }
}

extension DesktopSwitchingDriver: EnvironmentOpeningDriver {
    public func planEnvironmentOpening(profile: AccountProfile, manual: ManualAccountConfirmation?) async throws -> EnvironmentOpeningPlan {
        guard system.environmentActivationAllowed else { throw EnvironmentOpeningError.unavailable }
        guard pidPlan == nil, openingToken == nil, environmentPlan == nil, !quitRequested, !launchSubmitted, !activationSubmitted else {
            throw AccountOpeningError.recoveryRequired
        }
        try Task.checkCancellation()
        let profiles = try await store.inspect(), associations = try await store.inspectAssociations()
        guard profiles.profiles.contains(profile) else { throw ProfileError.missingProfile }
        guard let association = associations.associations.first(where: { $0.profileID == profile.id }) else {
            throw EnvironmentError.missingAssociation
        }
        guard !association.isTemporary, association.lastCheck == .directoryMetadataVerified else { throw EnvironmentOpeningError.unavailable }
        try validator.revalidate(association)
        try await system.validateInstallation()
        guard let instance = try await system.observe(association).unique() else { throw EnvironmentOpeningError.targetNotRunning }
        let evidence = try await system.environmentActivationEvidence(association, instance: instance)
        try evidence.validate(association: association, instance: instance)
        guard evidence.windowToken != nil, evidence.windowIDs.count == 1 else { throw EnvironmentError.activationUnavailable }
        let plan = EnvironmentOpeningPlan(id: UUID(), profile: profile, association: association, evidence: evidence,
            guarantees: EnvironmentOpeningGuarantees(environmentOwnershipVerified: true, processOwnershipVerified: true,
                windowOwnershipVerified: true, accountIdentityUserConfirmed: manual?.association == association
                    && (manual?.confirmedAt ?? .distantFuture) <= Date()),
            profiles: profiles, associations: associations)
        environmentPlan = plan
        return plan
    }

    public func recheckEnvironmentOpening(_ plan: EnvironmentOpeningPlan) async throws {
        try Task.checkCancellation()
        guard system.environmentActivationAllowed, environmentPlan == plan,
              try await store.inspect() == plan.profiles, try await store.inspectAssociations() == plan.associations else {
            throw EnvironmentOpeningError.stalePlan
        }
        try validator.revalidate(plan.association)
        try await system.validateInstallation()
        guard try await system.observe(plan.association).unique() == plan.evidence.instance else { throw EnvironmentError.processChanged }
        let fresh = try await system.environmentActivationEvidence(plan.association, instance: plan.evidence.instance)
        try fresh.validate(association: plan.association, instance: plan.evidence.instance)
        guard fresh.windowToken == plan.evidence.windowToken, fresh.windowIDs == plan.evidence.windowIDs else {
            throw EnvironmentError.activationUnavailable
        }
        try Task.checkCancellation()
    }

    public func activateEnvironment(_ plan: EnvironmentOpeningPlan, confirmedPlanID: UUID) async throws {
        guard confirmedPlanID == plan.id else { throw EnvironmentOpeningError.confirmationRequired }
        guard !activationSubmitted, !quitRequested, !launchSubmitted else { throw AccountOpeningError.recoveryRequired }
        try await recheckEnvironmentOpening(plan)
        let fresh = try await system.environmentActivationEvidence(plan.association, instance: plan.evidence.instance)
        try fresh.validate(association: plan.association, instance: plan.evidence.instance)
        guard fresh.windowToken == plan.evidence.windowToken, fresh.windowIDs == plan.evidence.windowIDs else {
            throw EnvironmentError.activationUnavailable
        }
        try Task.checkCancellation()
        try await beginActivationJournal(id: plan.id, profile: plan.profile, association: plan.association,
            instance: plan.evidence.instance, profiles: plan.profiles, associations: plan.associations)
        try await recordOpeningEffect(.activation(plan.evidence.instance))
        activationSubmitted = true // One-shot before dispatch; failure cannot grant a retry.
        try await system.activateEnvironment(fresh)
    }

    public func finishEnvironmentOpening(_ plan: EnvironmentOpeningPlan, success: Bool) {
        guard environmentPlan == plan else { return }
        environmentPlan = nil
        settleUndispatchedActivationJournal()
        openingJournal.abandon(); journalID = nil
        if success { activationSubmitted = false }
        // No metadata writes, auth, rollback or automatic foreground restoration.
    }
}

extension DesktopSwitchingDriver: PIDEnvironmentOpeningDriver {
    public func planPIDEnvironmentOpening(profile: AccountProfile, manual: ManualAccountConfirmation?) async throws -> PIDEnvironmentOpeningPlan {
        guard pidPlan == nil, environmentPlan == nil, openingToken == nil,
              !activationSubmitted, !launchSubmitted, !quitRequested else { throw AccountOpeningError.recoveryRequired }
        try Task.checkCancellation()
        let profiles = try await store.inspect(), associations = try await store.inspectAssociations()
        let managed = try await store.inspectManagedEnvironments()
        guard profiles.profiles.contains(profile) else { throw ProfileError.missingProfile }
        guard let association = associations.associations.first(where: { $0.profileID == profile.id }),
              association.kind == .managed, !association.isTemporary,
              association.lastCheck == .directoryMetadataVerified else { throw EnvironmentOpeningError.unavailable }
        try validator.revalidate(association)
        try await system.validateInstallation()
        guard let instance = try await system.observe(association).unique() else { throw EnvironmentOpeningError.targetNotRunning }
        guard await system.permitsPIDActivation(association, revision: associations.revision, instance: instance) else {
            throw EnvironmentOpeningError.unavailable
        }
        let plan = PIDEnvironmentOpeningPlan(id: UUID(), profile: profile, association: association, instance: instance,
            guarantees: EnvironmentOpeningGuarantees(environmentOwnershipVerified: true, processOwnershipVerified: true,
                windowOwnershipVerified: false, accountIdentityUserConfirmed: manual?.association == association
                    && (manual?.confirmedAt ?? .distantFuture) <= Date()),
            profiles: profiles, associations: associations, managed: managed)
        guard pidPlan == nil, environmentPlan == nil, openingToken == nil, !activationSubmitted else { throw AccountOpeningError.recoveryRequired }
        pidPlan = plan
        return plan
    }
    public func recheckPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) async throws {
        try Task.checkCancellation()
        guard pidPlan == plan, try await store.inspect() == plan.profiles,
              try await store.inspectAssociations() == plan.associations,
              try await store.inspectManagedEnvironments() == plan.managed else { throw EnvironmentOpeningError.stalePlan }
        try validator.revalidate(plan.association)
        try await system.validateInstallation()
        guard try await system.observe(plan.association).unique() == plan.instance else { throw EnvironmentError.processChanged }
        guard await system.permitsPIDActivation(plan.association, revision: plan.associations.revision, instance: plan.instance) else {
            throw EnvironmentOpeningError.unavailable
        }
        try Task.checkCancellation()
    }
    public func activatePIDEnvironment(_ plan: PIDEnvironmentOpeningPlan, confirmedPlanID: UUID) async throws {
        guard confirmedPlanID == plan.id else { throw EnvironmentOpeningError.confirmationRequired }
        guard !activationSubmitted, !launchSubmitted, !quitRequested else { throw AccountOpeningError.recoveryRequired }
        try await recheckPIDEnvironmentOpening(plan)
        guard !activationSubmitted else { throw AccountOpeningError.recoveryRequired }
        try await beginActivationJournal(id: plan.id, profile: plan.profile, association: plan.association,
            instance: plan.instance, profiles: plan.profiles, associations: plan.associations)
        try await recordOpeningEffect(.activation(plan.instance))
        activationSubmitted = true // Consume before dispatch, including failed/uncertain requests.
        try await system.activatePIDEnvironment(plan.association, revision: plan.associations.revision, instance: plan.instance)
    }
    public func verifyPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) async throws {
        try await recheckPIDEnvironmentOpening(plan)
        try await system.verifyPIDForeground(plan.instance)
    }
    public func finishPIDEnvironmentOpening(_ plan: PIDEnvironmentOpeningPlan) {
        if pidPlan == plan { pidPlan = nil }
        settleUndispatchedActivationJournal()
        openingJournal.abandon(); journalID = nil
        // Retain activationSubmitted after any dispatch. A trial cannot be reused or retried.
    }
}

extension DesktopSwitchingDriver: ScopedEnvironmentOpeningDriver {
    public func restoreOpeningRecovery() throws -> Bool {
        if let pending = try openingJournal.pending() { observedRecoveryID = pending.id }
        return observedRecoveryID != nil
    }
    public func persistOpeningFailure(_ error: SwitchingError) throws {
        if let journalID { try openingJournal.recordFailure(OpeningFailureRecord(error, stage: openingStage), operation: journalID) }
    }
    public func restoredOpeningFailure() throws -> SwitchingError? { try openingJournal.pending()?.failure?.error }
    public func completeOpeningJournal() async throws {
        openingStage = .journalCompletion
        if let journalID {
            guard try await system.openingBuildFingerprint() == journalBuild else { throw EnvironmentError.incompatibleBuild }
            try openingJournal.complete(journalID); self.journalID = nil; journalBuild = nil
        }
    }
    public func reconcileEnvironmentRecovery() async throws {
        guard openingToken == nil, environmentPlan == nil, pidPlan == nil else { throw AccountOpeningError.busy }
        let record = try openingJournal.acquireRecovery(expectedOperation: observedRecoveryID)
        defer { openingJournal.abandon() }
        guard record.bootSession == (try bootSessionProvider()) else { throw AccountOpeningError.recoveryBootChanged }
        guard try await system.openingBuildFingerprint() == record.buildFingerprint else { throw EnvironmentError.incompatibleBuild }
        let scope = try await recoveredScope(record)
        try await validateRecoveryCatalogs(scope)
        let retained = try await store.inspectRetainedResearchEnvironments()
        try await system.confirmPersistedEnvironmentOperationSettled(scope, effects: record.effects, launchReceiver: record.launchReceiver,
            inventoryAssociations: scope.associations.associations + retained)
        try await validateRecoveryCatalogs(scope)
        guard try await store.inspectRetainedResearchEnvironments() == retained else { throw EnvironmentOpeningError.stalePlan }
        // This checks fresh metadata and inventory only. It grants no account identity or authority.
        try await validateEnvironmentRecovery()
        guard try await system.openingBuildFingerprint() == record.buildFingerprint else { throw EnvironmentError.incompatibleBuild }
        try openingJournal.complete(record.id)
        observedRecoveryID = nil
        openingQuitGenerations = []; quitRequested = false; launchSubmitted = false; activationSubmitted = false
        recoveryScope = nil
    }
    private func recoveredScope(_ record: PendingOpeningOperation) async throws -> EnvironmentOperationScope {
        let profiles = try await store.inspect(), associations = try await store.inspectAssociations()
        let managed = try await store.inspectManagedEnvironments()
        let retained = record.mode == .closeOthersAndOpen ? try await store.inspectRetainedResearchEnvironments() : []
        guard record.catalogDigest == (try PendingOpeningOperation.digest(profiles: profiles, associations: associations,
                managed: managed, retained: retained)),
              let target = associations.associations.first(where: { $0.environmentID == record.targetEnvironmentID }),
              let profile = profiles.profiles.first(where: { $0.id == target.profileID }) else { throw OpeningJournalError.conflict }
        let others = try record.others.map { receiver -> OpeningInstance in
            guard let association = (associations.associations + retained).first(where: { $0.environmentID == receiver.environmentID }),
                  let owner = profiles.profiles.first(where: { $0.id == association.profileID }) else { throw OpeningJournalError.conflict }
            return OpeningInstance(profile: owner, association: association, instance: receiver.instance)
        }
        let plan = AccountOpeningPlan(id: record.id, mode: record.mode, target: profile, association: target,
            targetInstance: record.targetInstance, others: others, profiles: profiles, associations: associations)
        // Expired forever: this reconstructed value is evidence, never valid dispatch authority.
        return EnvironmentOperationScope(plan: plan, managed: managed, retainedResearch: retained, expiresAt: .distantPast, buildFingerprint: record.buildFingerprint)
    }
    private func validateRecoveryCatalogs(_ scope: EnvironmentOperationScope) async throws {
        guard try await store.inspect() == scope.profiles,
              try await store.inspectAssociations() == scope.associations,
              try await store.inspectManagedEnvironments() == scope.managed,
              try await store.inspectPendingAccountSetup() == nil else { throw EnvironmentOpeningError.stalePlan }
        if scope.mode == .closeOthersAndOpen {
            guard try await store.inspectRetainedResearchEnvironments() == scope.retainedResearch else { throw EnvironmentOpeningError.stalePlan }
        }
    }
    public func openingEffectDisposition() async -> EnvironmentEffectDisposition {
        if !activationSubmitted && !launchSubmitted && !quitRequested { return .notDispatched }
        guard scopedOpening, let id = openingToken else { return .unknown }
        return await system.environmentEffectDisposition(id)
    }
    public func planEnvironmentAccount(profile: AccountProfile, mode: AccountOpeningMode) async throws -> AccountOpeningPlan {
        try await buildOpeningPlan(profile: profile, mode: mode, environmentScoped: true)
    }
    public func authorizeEnvironmentAccount(_ plan: AccountOpeningPlan, allowPrimary: Bool) async throws {
        guard scopedOpening, operationScope == nil, let managed = scopedManaged else { throw EnvironmentOpeningError.stalePlan }
        try await recheckOpening(plan, remaining: plan.others)
        let build = try await system.openingBuildFingerprint()
        let scope = EnvironmentOperationScope(plan: plan, managed: managed, retainedResearch: scopedRetainedResearch, buildFingerprint: build)
        try scope.validate()
        if independentOpeningAllowed && plan.mode == .openSeparately {
            try openingJournal.acquireOperationLease()
        } else { try await beginOpeningJournal(scope) }
        try await system.authorizeEnvironmentOperation(scope, allowPrimary: allowPrimary)
        operationScope = scope
    }
    public func verifyEnvironmentAccount(_ plan: AccountOpeningPlan) async throws {
        guard scopedOpening, operationScope?.id == plan.id, let instance = launched ?? plan.targetInstance else { throw AccountOpeningError.processChanged }
        try validator.revalidate(plan.association)
        openingStage = .driverPostflightTarget
        let fresh = try await system.observeOpeningTarget(plan.association, launchedReceiver: launched,
            expectedReceiver: plan.targetInstance)
        guard DesktopOpeningTarget.matches(fresh, expected: instance, newlyLaunched: launched != nil, allowChildChanges: true) else { throw AccountOpeningError.processChanged }
        openingStage = .driverForeground
        try await system.verifyPIDForeground(instance)
    }
    public func acknowledgeEnvironmentRecovery() async throws { try await reconcileEnvironmentRecovery() }
    private func validateEnvironmentRecovery() async throws {
        guard openingToken == nil, environmentPlan == nil, pidPlan == nil else { throw AccountOpeningError.busy }
        guard try await store.inspectPendingAccountSetup() == nil else { throw AccountSetupError.recoveryRequired }
        let profiles = try await store.inspect(), associations = try await store.inspectAssociations()
        let managed = try await store.inspectManagedEnvironments()
        try await system.validateInstallation()
        let retained = try await store.inspectRetainedResearchEnvironments()
        for association in associations.associations + retained { try validator.revalidate(association) }
        let inventory = try await system.environmentInstanceInventory(associations: associations.associations + retained)
        try inventory.validate() // Unknown GUI instances cannot be dismissed as an absent target.
        guard try await store.inspect() == profiles,
              try await store.inspectAssociations() == associations,
              try await store.inspectManagedEnvironments() == managed,
              try await store.inspectRetainedResearchEnvironments() == retained,
              try await store.inspectPendingAccountSetup() == nil else { throw EnvironmentOpeningError.stalePlan }
        for association in associations.associations + retained { try validator.revalidate(association) }
        try Task.checkCancellation()
    }
}


extension DesktopSwitchingDriver {
    private func settleUndispatchedActivationJournal() {
        if !activationSubmitted && !launchSubmitted && !quitRequested, let journalID {
            do { try openingJournal.complete(journalID) } catch { /* A torn pair remains blocked. */ }
        }
    }
    private func beginOpeningJournal(_ scope: EnvironmentOperationScope) async throws {
        let build = try await system.openingBuildFingerprint()
        guard scope.buildFingerprint == nil || scope.buildFingerprint == build else { throw EnvironmentError.incompatibleBuild }
        try openingJournal.begin(PendingOpeningOperation(scope: scope, bootSession: bootSessionProvider(), buildFingerprint: build))
        journalID = scope.id; journalBuild = build
    }
    private func recordOpeningEffect(_ effect: EnvironmentSubmittedEffect) async throws {
        if independentOpeningAllowed, scopedOpening, operationScope?.mode == .openSeparately { return }
        guard try await system.openingBuildFingerprint() == journalBuild else { throw EnvironmentError.incompatibleBuild }
        guard let journalID else { throw OpeningJournalError.conflict }
        try openingJournal.append(effect, operation: journalID)
    }
    private func beginActivationJournal(id: UUID, profile: AccountProfile, association: EnvironmentAssociation,
        instance: DesktopInstance, profiles: ProfileCatalog, associations: AssociationCatalog) async throws {
        let managed = try await store.inspectManagedEnvironments()
        let plan = AccountOpeningPlan(id: id, mode: .openSeparately, target: profile, association: association,
            targetInstance: instance, others: [], profiles: profiles, associations: associations)
        try await beginOpeningJournal(EnvironmentOperationScope(plan: plan, managed: managed))
    }
    private func beginLegacyOpeningJournal() async throws {
        guard journalID == nil else { return }
        let managed = try await store.inspectManagedEnvironments()
        if let durablePlan {
            try await beginOpeningJournal(EnvironmentOperationScope(plan: durablePlan, managed: managed))
            return
        }
        guard let target else { throw OpeningJournalError.conflict }
        let profiles = try await store.inspect(), associations = try await store.inspectAssociations()
        guard let profile = profiles.profiles.first(where: { $0.id == target.profileID }) else { throw OpeningJournalError.conflict }
        var others: [OpeningInstance] = []
        if let source, let capturedSource, let owner = profiles.profiles.first(where: { $0.id == source.profileID }) {
            others = [OpeningInstance(profile: owner, association: source, instance: capturedSource)]
        }
        let plan = AccountOpeningPlan(id: UUID(), mode: others.isEmpty ? .openSeparately : .closeOthersAndOpen,
            target: profile, association: target, targetInstance: activation?.instance, others: others,
            profiles: profiles, associations: associations)
        try await beginOpeningJournal(EnvironmentOperationScope(plan: plan, managed: managed))
    }
}
