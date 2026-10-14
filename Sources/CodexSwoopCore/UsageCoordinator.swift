import Foundation

/// Lifecycle-owned service. Constructing a SwiftUI view never starts polling or account I/O.
@MainActor
public final class UsageCoordinator {
    public struct Policy: Sendable {
        public var freshness: TimeInterval = 300
        public var timeout: Duration = .seconds(10)
        public var polling: Duration = .seconds(420)
        public var retryBase: TimeInterval = 30
        public init() {}
    }
    private let provider: any AccountUsageProvider
    private let verifier: AccountIdentityVerifier
    private let policy: Policy
    private let now: @Sendable () -> Date
    private var contexts: [UUID: UsageContext] = [:]
    private var associations: [UUID: EnvironmentAssociation] = [:]
    private var cache = UsageCache()
    private var states: [UUID: UsageViewState] = [:]
    private struct Attempt {
        let token: UUID
        let work: Task<Void, Never>
        let deadline: Task<Void, Never>
    }
    private var attempts: [UUID: Attempt] = [:]
    private var failures: [UUID: Int] = [:]
    private var retryAt: [UUID: Date] = [:]
    private var halted: Set<UUID> = []
    private var pollingTask: Task<Void, Never>?
    public var onChange: (@MainActor () -> Void)?
    public init(provider: any AccountUsageProvider = BlockedAccountUsageProvider(),
                verifier: AccountIdentityVerifier = AccountIdentityVerifier(), policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider; self.verifier = verifier; self.policy = policy; self.now = now
    }
    deinit { pollingTask?.cancel(); for attempt in attempts.values { attempt.work.cancel(); attempt.deadline.cancel() } }

    /// Metadata-only synchronization. Missing technical identity never produces a context.
    public func synchronize(_ values: [EnvironmentAssociation]) {
        let fresh = Dictionary(values.map { ($0.profileID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(associations.keys).union(fresh.keys) where associations[id] != fresh[id] {
            invalidate(id); associations[id] = fresh[id]
        }
    }
    public func bind(_ context: UsageContext) {
        if contexts[context.profileID] != context {
            invalidate(context.profileID); contexts[context.profileID] = context
            associations[context.profileID] = context.association
        }
    }
    /// Call on account/updated, transport loss, ownership uncertainty or protocol/build change.
    /// No response-derived identity is promoted into an expected identity.
    public func invalidate(_ id: UUID) {
        cancel(id); contexts.removeValue(forKey: id); cache.clear(id); states.removeValue(forKey: id)
        failures.removeValue(forKey: id); retryAt.removeValue(forKey: id); halted.remove(id); onChange?()
    }
    public func clearCache() {
        for id in Array(contexts.keys) { cancel(id) }
        cache.clearAll(); states.removeAll(); onChange?()
    }
    public func state(for id: UUID) -> UsageViewState {
        guard provider.permitsSyntheticRequests else {
            return UsageViewState(status: associations[id] == nil ? .unavailable : .verificationRequired,
                                  explanation: UsageIntegrationPolicy.blockedReason)
        }
        guard let context = contexts[id] else {
            return UsageViewState(status: .verificationRequired, explanation: L10n.text("message.dc95ee0080"))
        }
        let refreshable = attempts[id] == nil && (retryAt[id].map { now() >= $0 } ?? true) && !halted.contains(id)
        let snapshot = cache.snapshot(for: context)
        if let state = states[id], state.status != .available && state.status != .stale {
            let visible = snapshot?.isFresh(at: now(), ttl: policy.freshness) == true ? snapshot : nil
            return UsageViewState(status: state.status, snapshot: visible, explanation: state.explanation, canRefresh: refreshable, lastSuccessfulUpdate: snapshot?.updatedAt)
        }
        if let snapshot {
            let fresh = snapshot.isFresh(at: now(), ttl: policy.freshness)
            return UsageViewState(status: fresh ? .available : .stale, snapshot: snapshot,
                                  explanation: fresh ? L10n.text("message.e567a39ada") : L10n.text("message.dcd161ced4"), canRefresh: refreshable)
        }
        return UsageViewState(status: .unavailable, explanation: L10n.text("message.da7db9f601"), canRefresh: refreshable)
    }
    /// Starts one request. Duplicate clicks share its state; no queued duplicate or automatic retry.
    public func refresh(_ id: UUID) {
        guard provider.permitsSyntheticRequests, let context = contexts[id], attempts[id] == nil,
              !halted.contains(id), retryAt[id].map({ now() >= $0 }) ?? true else { return }
        guard context.protocolVersion == UsageIntegrationPolicy.reviewedProtocol else {
            fail(id, .unsupportedProtocol); return
        }
        states[id] = UsageViewState(status: cache.snapshot(for: context) == nil ? .loading : .refreshing, explanation: L10n.text("message.ec5942ca5b"))
        let token = UUID()
        let work = Task<Void, Never> { [weak self] in
            guard let self else { return }; await self.perform(context, token: token)
        }
        let deadline = Task { [weak self, policy] in
            do { try await Task.sleep(for: policy.timeout) } catch { return }
            guard let self, self.attempts[id]?.token == token else { return }
            self.cancel(id); self.fail(id, .timeout)
        }
        // Tasks inherit MainActor and cannot run until the current synchronous turn completes.
        attempts[id] = Attempt(token: token, work: work, deadline: deadline)
        onChange?()
    }
    public func cancel(_ id: UUID) {
        if let attempt = attempts.removeValue(forKey: id) {
            attempt.work.cancel(); attempt.deadline.cancel()
            states.removeValue(forKey: id); onChange?()
        }
    }
    private func current(_ context: UsageContext, token: UUID) -> Bool {
        attempts[context.profileID]?.token == token && contexts[context.profileID] == context && !Task.isCancelled
    }
    private func validate(_ evidence: UsageSourceEvidence, context: UsageContext) throws {
        guard evidence.scope == .desktopBackend, evidence.context == context,
              evidence.checkedAt <= now(), now().timeIntervalSince(evidence.checkedAt) <= 5 else { throw UsageFailure.verificationRequired }
        guard (try? DesktopObservation(matching: [context.instance], ambiguous: false, observedAt: evidence.checkedAt).unique(now: now())) == context.instance else {
            throw UsageFailure.verificationRequired
        }
    }
    private func prove(_ context: UsageContext) async throws {
        try Task.checkCancellation()
        guard verifier.expects(context.accountIdentity, for: context.association) else { throw UsageFailure.verificationRequired }
        try await checkSource(context)
        let result = try await verifier.assess(AccountIdentityRequest(association: context.association, instance: context.instance))
        guard result.state == .verified else {
            if result.state == .authenticationRequired { throw UsageFailure.authenticationRequired }
            throw UsageFailure.verificationRequired
        }
        guard verifier.expects(context.accountIdentity, for: context.association) else { throw UsageFailure.verificationRequired }
        // Verifier anchors are independent of transport responses and caller labels.
        guard result.proof.confirms(context.association, instance: context.instance, now: now()) else { throw UsageFailure.verificationRequired }
        try await checkSource(context)
        guard result.proof.confirms(context.association, instance: context.instance, now: now()) else { throw UsageFailure.verificationRequired }
    }
    private func checkSource(_ context: UsageContext) async throws {
        do { try validate(try await provider.proveSource(context), context: context) }
        catch is CancellationError { throw CancellationError() }
        catch { throw UsageFailure.verificationRequired }
    }
    private func perform(_ context: UsageContext, token: UUID) async {
        let id = context.profileID
        do {
            try await prove(context)
            guard current(context, token: token) else { return }
            let reply = try await provider.read(context)
            guard current(context, token: token) else { return }
            try validate(reply.source, context: context)
            guard reply.accountScope == context.accountScope else { throw UsageFailure.verificationRequired }
            guard reply.capturedAt <= now(), now().timeIntervalSince(reply.capturedAt) <= policy.freshness,
                  cache.snapshot(for: context).map({ reply.capturedAt >= $0.updatedAt }) ?? true else { throw UsageFailure.invalidData }
            let decoded: DecodedUsage
            switch reply.kind {
            case .initial:
                decoded = try UsageDecoder.initial(reply.payload, at: reply.capturedAt)
                guard decoded.accountScope == context.accountScope else { throw UsageFailure.verificationRequired }
            case .rolling:
                guard let previous = cache.snapshot(for: context) else { throw UsageFailure.unavailable }
                decoded = try UsageDecoder.rolling(reply.payload, previous: previous.data, at: reply.capturedAt)
            }
            try await prove(context)
            guard current(context, token: token) else { return }
            // Do not extend freshness of retained sparse windows; no invented reset recovery.
            let snapshot = AccountUsageSnapshot(context: context, data: decoded, updatedAt: reply.capturedAt)
            finish(id); cache.store(snapshot); failures[id] = 0; retryAt[id] = nil
            states[id] = UsageViewState(status: decoded.buckets.flatMap(\.windows).isEmpty ? .unavailable : .available,
                                        explanation: L10n.text("message.6527e566f5"))
            onChange?()
        } catch {
            guard current(context, token: token) else { return }
            finish(id)
            if error is CancellationError { states.removeValue(forKey: id); onChange?(); return }
            fail(id, (error as? UsageFailure) ?? .networkUnavailable)
        }
    }
    private func finish(_ id: UUID) { attempts.removeValue(forKey: id)?.deadline.cancel() }
    private func fail(_ id: UUID, _ error: UsageFailure) {
        let count = min(6, (failures[id] ?? 0) + 1); failures[id] = count
        var delay = min(900, max(0, policy.retryBase) * pow(2, Double(count - 1)))
        if case .rateLimited(let requested) = error, requested.isFinite { delay = max(delay, min(900, max(0, requested))) }
        retryAt[id] = now().addingTimeInterval(delay)
        switch error {
        case .verificationRequired, .authenticationRequired, .unsupportedProtocol:
            cache.clear(id); halted.insert(id)
        default: break
        }
        states[id] = UsageViewState(status: error.status, explanation: error.explanation)
        onChange?()
    }
    /// Explicit application-lifecycle opt-in for synthetic integration tests only in this stage.
    /// After three failures automatic refresh stops per profile; manual refresh honors backoff.
    public func startAutomaticRefresh() {
        guard provider.permitsSyntheticRequests, pollingTask == nil else { return }
        pollingTask = Task { [weak self, policy] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: policy.polling) } catch { return }
                guard let self else { return }
                self.automaticTick()
            }
        }
    }
    public func automaticTick() {
        guard provider.permitsSyntheticRequests else { return }
        for id in contexts.keys where (failures[id] ?? 0) < 3 { refresh(id) }
        onChange?()
    }
    public func stopAutomaticRefresh() { pollingTask?.cancel(); pollingTask = nil }
}
