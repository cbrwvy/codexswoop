import Foundation

public enum OpeningRecoveryResolution: Equatable, Sendable { case safeForNewOperation }

public enum SwitchingState: Equatable, Sendable {
    case idle, validating, awaitingConfirmation, inspectingProcess, checkingActivity, awaitingActivityConfirmation
    case preparing, quitting, waitingForExit, launching, activating, verifying
    case active(UUID), environmentOpened(UUID), unavailable, cancelled, failed, recoveryRequired
}

public enum SwitchingError: Error, LocalizedError, Equatable, Sendable {
    case unavailable, busy, confirmationRequired, identityUnconfirmed, cancelled
    case validationFailed, processInspectionFailed, preparationFailed, quitFailed, exitWaitFailed, exitTimedOut
    case launchFailed, verificationFailed, activityUnstable
    case environment(EnvironmentError), activationFailed, opening(AccountOpeningError), environmentOpening(EnvironmentOpeningError)
    public var errorDescription: String? {
        switch self {
        case let .environment(error): error.errorDescription
        case let .opening(error): error.errorDescription
        case let .environmentOpening(error): error.errorDescription
        case .unavailable: L10n.text("message.daf4974f13")
        case .busy: L10n.text("message.86d7fe1e18")
        case .confirmationRequired: L10n.text("message.ea89d4c0ad")
        case .identityUnconfirmed: L10n.text("message.be04b80336")
        case .cancelled: L10n.text("message.abb4a62b3a")
        case .exitTimedOut: L10n.text("message.732ecec0b2")
        case .activityUnstable: L10n.text("message.410984c2e3")
        case .quitFailed: L10n.text("message.2f22292713")
        case .launchFailed: L10n.text("message.faf2e32a37")
        case .activationFailed: L10n.text("message.7280996b1a")
        default: L10n.text("message.85bed1aa51")
        }
    }
}

/// Preparation completes before any live process is interrupted. Native lifecycle is separately release-gated.
public protocol AccountSwitchingDriver: Sendable {
    func validate(profile: AccountProfile) async throws
    func strategy() async throws -> AccountSwitchingStrategy
    func activate(profile: AccountProfile) async throws
    func processIsRunning() async throws -> Bool
    func prepare(profile: AccountProfile) async throws
    /// Request normal application termination. Never escalate to SIGKILL automatically.
    func requestGracefulQuit() async throws
    /// Implementations must enforce this finite deadline and throw SwitchingError.exitTimedOut.
    func waitForExit(timeout: Duration) async throws
    func launch(profile: AccountProfile) async throws
    func authenticatedProfileID() async throws -> UUID?
    /// Cleanup must work even when the initiating task was cancelled.
    func rollback() async throws
    func planOpening(profile: AccountProfile, mode: AccountOpeningMode) async throws -> AccountOpeningPlan
    func recheckOpening(_ plan: AccountOpeningPlan, remaining: [OpeningInstance]) async throws
    func quitOpeningInstance(_ item: OpeningInstance, plan: AccountOpeningPlan, allowPrimary: Bool) async throws
    func waitForOpeningExit(_ item: OpeningInstance, timeout: Duration) async throws
    func finishOpening(_ plan: AccountOpeningPlan, success: Bool) async
    func restoreOpeningRecovery() async throws -> Bool
    func completeOpeningJournal() async throws
    func persistOpeningFailure(_ error: SwitchingError) async throws
    func restoredOpeningFailure() async throws -> SwitchingError?
}
public extension AccountSwitchingDriver {
    func restoreOpeningRecovery() async throws -> Bool { false }
    func completeOpeningJournal() async throws {}
    func persistOpeningFailure(_ error: SwitchingError) async throws {}
    func restoredOpeningFailure() async throws -> SwitchingError? { nil }
    func strategy() async throws -> AccountSwitchingStrategy { .restart }
    func activate(profile: AccountProfile) async throws { throw EnvironmentError.activationUnavailable }
}

public actor AccountSwitchingCoordinator {
    public private(set) var state: SwitchingState = .idle
    public private(set) var lastError: SwitchingError?
    public private(set) var rollbackFailed = false
    public private(set) var openingRecoveryResolution: OpeningRecoveryResolution?
    public private(set) var openingResult: AccountOpeningResult?
    public private(set) var openingDisposition: AccountOpeningError?
    public private(set) var openingProgress = AccountOpeningProgress()
    public private(set) var environmentOpeningResult: EnvironmentOpeningPlan?
    public private(set) var pidEnvironmentOpeningResult: PIDEnvironmentOpeningPlan?
    private var busy = false
    private var environmentRecoveryRequired = false
    private let driver: (any AccountSwitchingDriver)?
    private let activityChecker: any CodexActivityChecking

    /// Fails closed by default: cannot terminate or launch any process.
    public init(driver: (any AccountSwitchingDriver)? = nil,
                activityChecker: any CodexActivityChecking = ConservativeActivityChecker()) {
        self.driver = driver; self.activityChecker = activityChecker
    }

    public func switchAccount(to profile: AccountProfile, workInterruptionConfirmed: Bool,
                              confirmActivity: @Sendable (CodexActivityStatus) async -> Bool = { _ in false }) async throws {
        try await refreshOpeningRecovery()
        guard !busy else { throw SwitchingError.busy }
        guard !environmentRecoveryRequired else { throw SwitchingError.opening(.recoveryRequired) }
        guard let driver else { state = .unavailable; lastError = .unavailable; throw SwitchingError.unavailable }
        busy = true
        environmentOpeningResult = nil
        lastError = nil
        rollbackFailed = false
        defer { busy = false }
        var needsRollback = false
        do {
            state = .validating
            try Task.checkCancellation()
            try await driver.validate(profile: profile)
            try Task.checkCancellation()
            let strategy = try await driver.strategy()
            if strategy == .activate {
                // The activation-only interface cannot dispatch lifecycle operations. No work-interruption
                // consent is needed; native identity/window ownership remain mandatory and release-gated.
                state = .preparing; needsRollback = true
                try await driver.prepare(profile: profile)
                try Task.checkCancellation()
                state = .activating
                try await driver.activate(profile: profile)
                try Task.checkCancellation()
                state = .verifying
                guard try await driver.authenticatedProfileID() == profile.id else { throw SwitchingError.identityUnconfirmed }
                try Task.checkCancellation()
                try await driver.completeOpeningJournal()
                state = .active(profile.id)
                return
            }
            state = .awaitingConfirmation
            guard workInterruptionConfirmed else { throw SwitchingError.confirmationRequired }
            state = .inspectingProcess
            let running = try await driver.processIsRunning()
            try Task.checkCancellation()
            let accepted = try await activityConsent(accepted: nil, confirm: confirmActivity)
            state = .preparing
            needsRollback = true
            try await driver.prepare(profile: profile)
            try Task.checkCancellation()
            // Preparation and an open warning can take time. Recheck immediately before quit/launch.
            _ = try await activityConsent(accepted: accepted, confirm: confirmActivity)
            if running {
                state = .quitting
                try await driver.requestGracefulQuit()
                try Task.checkCancellation()
                state = .waitingForExit
                try await driver.waitForExit(timeout: .seconds(10))
                try Task.checkCancellation()
            }
            state = .launching
            try await driver.launch(profile: profile)
            try Task.checkCancellation()
            state = .verifying
            guard try await driver.authenticatedProfileID() == profile.id else { throw SwitchingError.identityUnconfirmed }
            try Task.checkCancellation()
            try await driver.completeOpeningJournal()
            state = .active(profile.id)
        } catch {
            let failure = normalized(error)
            lastError = failure
            state = failure == .cancelled ? .cancelled : .failed
            if needsRollback {
                // An unstructured cleanup task does not inherit the caller's cancellation flag.
                let cleanup = Task { try await driver.rollback() }
                do { try await cleanup.value }
                catch { rollbackFailed = true; state = .recoveryRequired }
            }
            throw failure
        }
    }

    private func activityConsent(accepted: CodexActivityStatus?,
                                 confirm: @Sendable (CodexActivityStatus) async -> Bool) async throws -> CodexActivityStatus {
        var accepted = accepted
        for attempt in 0...3 {
            state = .checkingActivity
            try Task.checkCancellation()
            let status: CodexActivityStatus
            do { status = try await activityChecker.checkActivity() }
            catch is CancellationError { throw CancellationError() }
            catch { status = .unknown(.checkFailed) }
            try Task.checkCancellation()
            if status == .idle || status == accepted { return status }
            guard attempt < 3 else { throw SwitchingError.activityUnstable }
            state = .awaitingActivityConfirmation
            let confirmed = await confirm(status)
            try Task.checkCancellation()
            guard confirmed else { throw SwitchingError.cancelled }
            accepted = status
            // Every confirmation is followed by a fresh check. A changed non-idle result needs consent again.
        }
        throw SwitchingError.activityUnstable
    }

    private func normalized(_ error: Error) -> SwitchingError {
        if error is CancellationError { return .cancelled }
        if error as? SwitchingError == .cancelled { return .cancelled }
        if error as? SwitchingError == .activityUnstable { return .activityUnstable }
        if let environment = error as? EnvironmentError { return .environment(environment) }
        if let switching = error as? SwitchingError { return switching }
        if state == .awaitingConfirmation { return .confirmationRequired }
        if state == .waitingForExit, error as? SwitchingError == .exitTimedOut { return .exitTimedOut }
        if state == .verifying, error as? SwitchingError == .identityUnconfirmed { return .identityUnconfirmed }
        switch state {
        case .validating: return .validationFailed
        case .inspectingProcess: return .processInspectionFailed
        case .preparing: return .preparationFailed
        case .quitting: return .quitFailed
        case .waitingForExit: return .exitWaitFailed
        case .launching: return .launchFailed
        case .activating: return .activationFailed
        default: return .verificationFailed
        }
    }
}

extension AccountSwitchingCoordinator {
    /// Invoked at startup and before every action; an empty new journal never clears a live latch.
    @discardableResult public func refreshOpeningRecovery() async throws -> Bool {
        guard !busy else { throw SwitchingError.busy }
        busy = true; defer { busy = false }
        do {
            if try await driver?.restoreOpeningRecovery() == true {
                environmentRecoveryRequired = true; state = .recoveryRequired; openingRecoveryResolution = nil
                if let restored = try await driver?.restoredOpeningFailure() { lastError = restored }
                if openingDisposition == nil { openingDisposition = .recoveryRequired }
            }
        } catch OpeningJournalError.busy {
            // Lock contention alone is not evidence of an unfinished operation. No action can
            // proceed until a fresh read succeeds; don't strand a latch with no durable record.
            throw SwitchingError.busy
        } catch {
            environmentRecoveryRequired = true; state = .recoveryRequired; openingDisposition = .recoveryRequired
            openingRecoveryResolution = nil
            throw error
        }
        return environmentRecoveryRequired || state == .recoveryRequired
    }
    /// Read-only settlement of known submitted requests. No manual identity claim or OS retry.
    public func reconcileOpeningRecovery() async throws {
        guard !busy else { throw SwitchingError.busy }
        guard state == .recoveryRequired, let driver = driver as? any ScopedEnvironmentOpeningDriver else {
            throw AccountOpeningError.recoveryRequired
        }
        busy = true; defer { busy = false }
        try await driver.reconcileEnvironmentRecovery()
        clearOpeningRecovery()
        openingRecoveryResolution = .safeForNewOperation
    }
    /// PID-scoped Open Separately uses the same serialization and recovery latch, with its own capability.
    public func openPIDEnvironment(to profile: AccountProfile, manual: ManualAccountConfirmation? = nil,
        confirm: @Sendable (PIDEnvironmentOpeningPlan) async -> Bool = { _ in false }) async throws {
        guard !busy else { throw SwitchingError.opening(.busy) }
        try await refreshOpeningRecovery()
        guard !busy else { throw SwitchingError.opening(.busy) }
        guard state != .recoveryRequired, !environmentRecoveryRequired else { throw SwitchingError.opening(.recoveryRequired) }
        guard let pidDriver = driver as? any PIDEnvironmentOpeningDriver else { throw SwitchingError.environmentOpening(.unavailable) }
        busy = true; openingRecoveryResolution = nil; lastError = nil; openingResult = nil; environmentOpeningResult = nil; pidEnvironmentOpeningResult = nil
        openingDisposition = nil; openingProgress = AccountOpeningProgress(); rollbackFailed = false
        defer { busy = false }
        var plan: PIDEnvironmentOpeningPlan?
        do {
            state = .validating; try Task.checkCancellation()
            let prepared = try await pidDriver.planPIDEnvironmentOpening(profile: profile, manual: manual)
            plan = prepared
            state = .awaitingConfirmation
            let accepted = await confirm(prepared)
            try Task.checkCancellation()
            guard accepted else { throw AccountOpeningError.userCancelled }
            state = .preparing
            try await pidDriver.recheckPIDEnvironmentOpening(prepared)
            try Task.checkCancellation()
            state = .activating; openingProgress.actionMayHaveOccurred = true
            try await pidDriver.activatePIDEnvironment(prepared, confirmedPlanID: prepared.id)
            state = .verifying
            try await pidDriver.verifyPIDEnvironmentOpening(prepared)
            try Task.checkCancellation()
            try await driver?.completeOpeningJournal()
            await pidDriver.finishPIDEnvironmentOpening(prepared)
            pidEnvironmentOpeningResult = prepared
            state = .environmentOpened(profile.id)
        } catch {
            let failure: SwitchingError
            if error is CancellationError { failure = .opening(.userCancelled) }
            else if let error = error as? EnvironmentOpeningError { failure = .environmentOpening(error) }
            else if let error = error as? EnvironmentError { failure = .environment(error) }
            else if let error = error as? AccountOpeningError { failure = .opening(error) }
            else { failure = normalized(error) }
            lastError = failure
            if let scoped = driver as? any ScopedEnvironmentOpeningDriver,
               await scoped.openingEffectDisposition() == .notDispatched { openingProgress.actionMayHaveOccurred = false }
            if openingProgress.actionMayHaveOccurred {
                environmentRecoveryRequired = true; state = .recoveryRequired; openingDisposition = .recoveryRequired
            } else { state = failure == .opening(.userCancelled) ? .cancelled : .failed }
            if let plan { await pidDriver.finishPIDEnvironmentOpening(plan) }
            if (try? await driver?.restoreOpeningRecovery()) != false {
                environmentRecoveryRequired = true; state = .recoveryRequired; openingDisposition = .recoveryRequired
            }
            throw failure
        }
    }

    /// Explicit, environment-scoped Open Separately. Never falls through to account opening or launch.
    public func openEnvironment(to profile: AccountProfile, manual: ManualAccountConfirmation? = nil,
        confirm: @Sendable (EnvironmentOpeningPlan) async -> Bool = { _ in false }) async throws {
        guard !busy else { throw SwitchingError.opening(.busy) }
        try await refreshOpeningRecovery()
        guard !busy else { throw SwitchingError.opening(.busy) }
        guard state != .recoveryRequired else { throw SwitchingError.opening(.recoveryRequired) }
        guard let environmentDriver = driver as? any EnvironmentOpeningDriver else {
            throw SwitchingError.environmentOpening(.unavailable)
        }
        busy = true; openingRecoveryResolution = nil; lastError = nil; openingResult = nil; environmentOpeningResult = nil
        openingDisposition = nil; openingProgress = AccountOpeningProgress(); rollbackFailed = false
        defer { busy = false }
        var plan: EnvironmentOpeningPlan?
        do {
            state = .validating; try Task.checkCancellation()
            let prepared = try await environmentDriver.planEnvironmentOpening(profile: profile, manual: manual)
            plan = prepared
            state = .awaitingConfirmation
            let accepted = await confirm(prepared)
            try Task.checkCancellation()
            guard accepted else { throw AccountOpeningError.userCancelled }
            state = .preparing
            try await environmentDriver.recheckEnvironmentOpening(prepared)
            try Task.checkCancellation()
            state = .activating
            openingProgress.actionMayHaveOccurred = true
            try await environmentDriver.activateEnvironment(prepared, confirmedPlanID: prepared.id)
            state = .verifying
            try await environmentDriver.recheckEnvironmentOpening(prepared)
            try Task.checkCancellation()
            try await driver?.completeOpeningJournal()
            await environmentDriver.finishEnvironmentOpening(prepared, success: true)
            environmentOpeningResult = prepared
            state = .environmentOpened(profile.id) // Does not mean authenticatedProfileID or Account Verified.
        } catch {
            let failure: SwitchingError
            if error is CancellationError { failure = .opening(.userCancelled) }
            else if let error = error as? EnvironmentOpeningError { failure = .environmentOpening(error) }
            else if let error = error as? EnvironmentError { failure = .environment(error) }
            else if let error = error as? AccountOpeningError { failure = .opening(error) }
            else { failure = normalized(error) }
            lastError = failure
            if let scoped = driver as? any ScopedEnvironmentOpeningDriver,
               await scoped.openingEffectDisposition() == .notDispatched { openingProgress.actionMayHaveOccurred = false }
            if openingProgress.actionMayHaveOccurred {
                environmentRecoveryRequired = true
                state = .recoveryRequired; openingDisposition = .recoveryRequired
            } else { state = failure == .opening(.userCancelled) ? .cancelled : .failed }
            if let plan { await environmentDriver.finishEnvironmentOpening(plan, success: false) }
            if (try? await driver?.restoreOpeningRecovery()) != false {
                environmentRecoveryRequired = true; state = .recoveryRequired; openingDisposition = .recoveryRequired
            }
            throw failure
        }
    }

    /// Both public actions share this coordinator's busy state, activity policy and typed outcomes.
    /// No rollback is invoked: closing several external apps is not an atomic or reversible transaction.
    public func openAccount(to profile: AccountProfile, mode: AccountOpeningMode, environmentScoped: Bool = false,
        confirmOpen: @Sendable (AccountOpeningPlan) async -> Bool = { _ in false },
        confirmClose: @Sendable (AccountCloseConfirmation) async -> AccountCloseDecision = { _ in .cancel }) async throws {
        guard !busy else { throw SwitchingError.opening(.busy) }
        try await refreshOpeningRecovery()
        guard !busy else { throw SwitchingError.opening(.busy) }
        guard state != .recoveryRequired else { throw SwitchingError.opening(.recoveryRequired) }
        guard let driver else { state = .unavailable; throw SwitchingError.unavailable }
        busy = true; openingRecoveryResolution = nil; lastError = nil; openingResult = nil; environmentOpeningResult = nil; openingDisposition = nil; openingProgress = AccountOpeningProgress(); rollbackFailed = false
        defer { busy = false }
        var plan: AccountOpeningPlan?
        do {
            state = .validating; try Task.checkCancellation()
            let scopedDriver = environmentScoped ? driver as? any ScopedEnvironmentOpeningDriver : nil
            guard !environmentScoped || scopedDriver != nil else { throw EnvironmentOpeningError.unavailable }
            let prepared: AccountOpeningPlan
            if let scopedDriver { prepared = try await scopedDriver.planEnvironmentAccount(profile: profile, mode: mode) }
            else { prepared = try await driver.planOpening(profile: profile, mode: mode) }
            plan = prepared
            state = .preparing
            if !environmentScoped { try await driver.prepare(profile: profile) }
            try await driver.recheckOpening(prepared, remaining: prepared.others)
            var remaining = prepared.others
            if environmentScoped && mode == .openSeparately {
                state = .awaitingConfirmation
                let accepted = await confirmOpen(prepared)
                try Task.checkCancellation()
                guard accepted else { throw AccountOpeningError.userCancelled }
                try await driver.recheckOpening(prepared, remaining: [])
                try await scopedDriver?.authorizeEnvironmentAccount(prepared, allowPrimary: false)
            }
            if mode == .closeOthersAndOpen {
                // Consent is mandatory even if activity is Idle or there are zero others.
                var accepted: [CodexActivityStatus]?
                var allowPrimary = false
                for attempt in 0...3 {
                    let activities = try await openingActivities(remaining)
                    state = .awaitingActivityConfirmation
                    let decision = await confirmClose(AccountCloseConfirmation(target: profile, affected: remaining,
                        activities: activities, unknownInstanceCount: 0, targetEnvironment: environmentScoped ? prepared.association : nil))
                    try Task.checkCancellation()
                    guard case let .confirm(primary) = decision else { throw AccountOpeningError.userCancelled }
                    guard !remaining.contains(where: \.isPrimary) || primary else { throw AccountOpeningError.primaryConsentRequired }
                    allowPrimary = primary
                    try await driver.recheckOpening(prepared, remaining: remaining)
                    let fresh = try await openingActivities(remaining)
                    if fresh == activities { accepted = fresh; break }
                    guard attempt < 3 else { throw SwitchingError.activityUnstable }
                }
                guard let accepted else { throw SwitchingError.activityUnstable }
                if let scopedDriver { try await scopedDriver.authorizeEnvironmentAccount(prepared, allowPrimary: allowPrimary) }
                for item in prepared.others {
                    try Task.checkCancellation()
                    try await driver.recheckOpening(prepared, remaining: remaining)
                    // Recheck scoped activity immediately before EACH normal quit. A changed result needs new consent.
                    let statuses = try await openingActivities(remaining)
                    let expected = remaining.compactMap { entry in prepared.others.firstIndex(of: entry).map { accepted[$0] } }
                    if statuses != expected {
                        state = .awaitingActivityConfirmation
                        let decision = await confirmClose(AccountCloseConfirmation(target: profile, affected: remaining,
                            activities: statuses, unknownInstanceCount: 0, targetEnvironment: environmentScoped ? prepared.association : nil))
                        try Task.checkCancellation()
                        guard case let .confirm(primary) = decision else { throw AccountOpeningError.userCancelled }
                        guard !remaining.contains(where: \.isPrimary) || primary else { throw AccountOpeningError.primaryConsentRequired }
                        allowPrimary = primary
                        try await driver.recheckOpening(prepared, remaining: remaining)
                        guard try await openingActivities(remaining) == statuses else { throw SwitchingError.activityUnstable }
                    }
                    state = .quitting
                    openingProgress.actionMayHaveOccurred = true
                    try await driver.quitOpeningInstance(item, plan: prepared, allowPrimary: allowPrimary)
                    try Task.checkCancellation(); state = .waitingForExit
                    try await driver.waitForOpeningExit(item, timeout: .seconds(10))
                    openingProgress.closedProfileIDs.append(item.operationID)
                    openingProgress.closedInstanceNames.append(item.displayName)
                    remaining.removeAll { $0 == item }
                    try await driver.recheckOpening(prepared, remaining: remaining)
                }
            }
            try Task.checkCancellation()
            try await driver.recheckOpening(prepared, remaining: remaining)
            if prepared.targetInstance != nil {
                state = .activating; openingProgress.actionMayHaveOccurred = true
                try await driver.activate(profile: profile)
            } else {
                state = .launching; openingProgress.actionMayHaveOccurred = true
                try await driver.launch(profile: profile)
            }
            try Task.checkCancellation(); state = .verifying
            if let scopedDriver { try await scopedDriver.verifyEnvironmentAccount(prepared) }
            else { guard try await driver.authenticatedProfileID() == profile.id else { throw AccountOpeningError.identityUnverified } }
            try await driver.recheckOpening(prepared, remaining: remaining)
            if let scopedDriver { try await scopedDriver.verifyEnvironmentAccount(prepared) }
            try Task.checkCancellation()
            try await driver.completeOpeningJournal()
            openingResult = prepared.targetInstance == nil ? .launched(profile.id) : .activatedExisting(profile.id)
            await driver.finishOpening(prepared, success: true)
            state = environmentScoped ? .environmentOpened(profile.id) : .active(profile.id)
        } catch {
            let failure: SwitchingError
            if let error = error as? EnvironmentOpeningError { failure = .environmentOpening(error) }
            else if let opening = error as? AccountOpeningError { failure = .opening(opening) }
            else if let environment = error as? EnvironmentError {
                switch environment {
                case .missingAssociation: failure = .opening(.targetNotLinked)
                case .identityUnverified: failure = .opening(.identityUnverified)
                case .activationUnavailable: failure = .opening(.windowUnavailable)
                case .ambiguousInstance: failure = .opening(.ambiguousInstance)
                case .processChanged: failure = .opening(.processChanged)
                case .launchFailed: failure = .opening(.launchFailure)
                case .missingPermissions: failure = .opening(.missingPermissions)
                default: failure = .environment(environment)
                }
            } else if error is CancellationError { failure = .opening(.userCancelled) }
            else if error as? SwitchingError == .exitTimedOut { failure = .opening(.terminationTimeout) }
            else { failure = normalized(error) }
            lastError = failure
            if environmentScoped, openingProgress.closedProfileIDs.isEmpty,
               let scopedDriver = driver as? any ScopedEnvironmentOpeningDriver,
               await scopedDriver.openingEffectDisposition() == .notDispatched {
                openingProgress.actionMayHaveOccurred = false
            }
            if openingProgress.actionMayHaveOccurred {
                environmentRecoveryRequired = true
                state = .recoveryRequired
                openingDisposition = openingProgress.closedProfileIDs.isEmpty ? .recoveryRequired : .partialCompletion
                // Preserve the precise cause in lastError; expose partial state separately from success.
                openingResult = nil
            } else { state = failure == .opening(.userCancelled) ? .cancelled : .failed }
            do { try await driver.persistOpeningFailure(failure) }
            catch { lastError = failure } // A failed diagnostic write never clears pending or hides its cause.
            if let plan { await driver.finishOpening(plan, success: false) }
            if (try? await driver.restoreOpeningRecovery()) != false {
                environmentRecoveryRequired = true; state = .recoveryRequired
                if openingDisposition == nil { openingDisposition = .recoveryRequired }
            }
            throw failure
        }
    }
    private func openingActivities(_ instances: [OpeningInstance]) async throws -> [CodexActivityStatus] {
        state = .checkingActivity
        var statuses: [CodexActivityStatus] = []
        for instance in instances {
            try Task.checkCancellation()
            do { statuses.append(try await activityChecker.checkActivity(for: instance.instance)) }
            catch is CancellationError { throw CancellationError() }
            catch { statuses.append(.unknown(.checkFailed)) }
        }
        try Task.checkCancellation()
        return statuses
    }
}

extension AccountSwitchingCoordinator {
    /// Called only after the user reviews an uncertain/partial result. Revokes old authority;
    /// the next operation still needs new checks and explicit consent.
    public func acknowledgeOpeningRecovery(userReviewed: Bool) async throws {
        guard !busy else { throw SwitchingError.busy }
        guard userReviewed, state == .recoveryRequired,
              let driver = driver as? any ScopedEnvironmentOpeningDriver else { throw AccountOpeningError.recoveryRequired }
        busy = true; defer { busy = false }
        try await driver.reconcileEnvironmentRecovery()
        clearOpeningRecovery()
        openingRecoveryResolution = .safeForNewOperation
    }
    private func clearOpeningRecovery() {
        environmentRecoveryRequired = false; state = .idle; lastError = nil; openingDisposition = nil
        openingResult = nil; openingProgress = AccountOpeningProgress()
    }
}
