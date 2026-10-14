import Foundation
import Darwin
import CodexSwoopCore

// Fictional values only. No process launch, native account transport or credential access.
func fictionalUsage(_ id: String = "fictional-plus-scope", used: Double = 28, weekly: Bool = true) -> Data {
    let primary: [String: Any] = ["usedPercent": used, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]
    var bucket: [String: Any] = ["limitId": "codex", "primary": primary, "planType": "plus"]
    if weekly { bucket["secondary"] = ["usedPercent": 59, "windowDurationMins": 10080] }
    return try! JSONSerialization.data(withJSONObject: ["accountId": id, "rateLimits": bucket])
}
actor UsageFixtureReader: AccountIdentityReading {
    let keys: [UUID: AccountIdentityKey]
    var wrong = false, signedOut = false, changeAfterRead = false, shortExpiry = false
    var calls = 0
    init(_ keys: [UUID: AccountIdentityKey]) { self.keys = keys }
    func configure(wrong: Bool = false, signedOut: Bool = false, changeAfterRead: Bool = false, shortExpiry: Bool = false) {
        self.wrong = wrong; self.signedOut = signedOut; self.changeAfterRead = changeAfterRead; self.shortExpiry = shortExpiry
    }
    func read(_ request: AccountIdentityRequest) throws -> IdentityReadResult {
        calls += 1
        if signedOut || (changeAfterRead && calls > 1) { throw IdentityReadError.authenticationExpired }
        let key = wrong ? try AccountIdentityKey(namespace: "fictional-user", subject: "intruder") : keys[request.association.profileID]
        return .response(RoutedAccountIdentity(request: request, key: key, authenticated: true, expiresAt: Date().addingTimeInterval(shortExpiry ? 0.1 : 5)))
    }
}
actor UsageFixtureProvider: AccountUsageProvider {
    nonisolated let permitsSyntheticRequests: Bool
    var calls = 0, proofs = 0
    var held = false, wrongSource = false, missingScope = false, wrongScope = false, proofFailure = false, ownedSource = false
    var error: UsageFailure?, data: Data?, age: TimeInterval = 0
    var kind: UsageReply.Kind = .initial
    var slowFinalProof = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(allowed: Bool = true) { permitsSyntheticRequests = allowed }
    func configure(held: Bool = false, wrongSource: Bool = false, missingScope: Bool = false,
                   wrongScope: Bool = false, error: UsageFailure? = nil, data: Data? = nil,
                   age: TimeInterval = 0, kind: UsageReply.Kind = .initial, proofFailure: Bool = false, slowFinalProof: Bool = false,
                   ownedSource: Bool = false) {
        self.ownedSource = ownedSource
        self.held = held; self.wrongSource = wrongSource; self.missingScope = missingScope
        self.wrongScope = wrongScope; self.error = error; self.data = data; self.age = age; self.kind = kind; self.proofFailure = proofFailure; self.slowFinalProof = slowFinalProof
    }
    func release() { held = false; let waits = pending; pending.removeAll(); for wait in waits { wait.resume() } }
    func proveSource(_ context: UsageContext) async throws -> UsageSourceEvidence {
        proofs += 1
        if proofFailure { throw EnvironmentError.changedDirectory }
        if slowFinalProof && proofs == 2 { try await Task.sleep(for: .milliseconds(200)) }
        return UsageSourceEvidence(context: context, checkedAt: Date().addingTimeInterval(wrongSource ? -10 : 0),
                                   scope: ownedSource ? .ownedAppServer : .desktopBackend)
    }
    func read(_ context: UsageContext) async throws -> UsageReply {
        calls += 1
        let raw = data ?? fictionalUsage(context.association.kind == .managed && context.instance.main.pid == 120_001 ? "fictional-free-scope" : "fictional-plus-scope", used: context.instance.main.pid == 120_001 ? 14 : 28)
        let captured = Date().addingTimeInterval(-age)
        if held { await withCheckedContinuation { pending.append($0) } } // Deliberately ignores cancellation.
        if let error { throw error }
        let scope = missingScope ? nil : (wrongScope ? try AccountIdentityKey(namespace: UsageIntegrationPolicy.accountScopeNamespace, subject: "fictional-other-scope") : context.accountScope)
        return UsageReply(source: UsageSourceEvidence(context: context), accountScope: scope, payload: raw, capturedAt: captured, kind: kind)
    }
}
@MainActor
struct UsageLab {
    let fixture: AssociationFixture, provider: UsageFixtureProvider, reader: UsageFixtureReader
    let contexts: [UsageContext], service: UsageCoordinator
    static func make(_ root: URL, allowed: Bool = true, timeout: Duration = .seconds(2), retryBase: TimeInterval = 30) async throws -> UsageLab {
        let f = try await AssociationFixture.make(root), provider = UsageFixtureProvider(allowed: allowed)
        var contexts: [UsageContext] = [], anchors: [ExpectedAccountIdentity] = []
        for i in 0..<2 {
            let user = try AccountIdentityKey(namespace: "fictional-user", subject: "fictional-subject-\(i)")
            let scope = try AccountIdentityKey(namespace: UsageIntegrationPolicy.accountScopeNamespace, subject: i == 0 ? "fictional-plus-scope" : "fictional-free-scope")
            let gen = DesktopGeneration(pid: Int32(120_000 + i), uid: getuid(), started: "fictional-\(i)")
            let instance = DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date().addingTimeInterval(-10))
            contexts.append(UsageContext(association: f.associations[i], instance: instance, accountIdentity: user, accountScope: scope, transportID: UUID()))
            anchors.append(ExpectedAccountIdentity(association: f.associations[i], key: user))
        }
        let reader = UsageFixtureReader(Dictionary(uniqueKeysWithValues: contexts.map { ($0.profileID, $0.accountIdentity) }))
        var policy = UsageCoordinator.Policy(); policy.timeout = timeout; policy.retryBase = retryBase
        let service = UsageCoordinator(provider: provider, verifier: AccountIdentityVerifier(reader: reader, expected: anchors), policy: policy)
        service.synchronize(f.associations); for context in contexts { service.bind(context) }
        return UsageLab(fixture: f, provider: provider, reader: reader, contexts: contexts, service: service)
    }
    func settle(_ id: UUID? = nil) async throws {
        let id = id ?? contexts[0].profileID, deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while [.loading, .refreshing].contains(service.state(for: id).status) {
            guard ContinuousClock.now < deadline else { throw CheckFailure(description: "Synthetic usage did not settle") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func waitForRead() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await provider.calls == 0 {
            guard ContinuousClock.now < deadline else { throw CheckFailure(description: "Synthetic read did not start") }
            await Task.yield()
        }
    }
}

extension CoreChecks {
    @MainActor static func usageChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        func root(_ name: String) -> URL { base.appendingPathComponent("usage-" + name) }
        func json(_ string: String) -> Data { Data(string.utf8) }
        for (used, remaining) in [(0.0, 100.0), (100, 0), (28, 72), (28.125, 71.875), (-5, 100), (125, 0)] {
            await run("Usage parsing: fictional used \(used) becomes remaining \(remaining)") {
                let parsed = try UsageDecoder.initial(fictionalUsage(used: used), at: Date())
                try expect(parsed.buckets[0].primary?.remainingPercent == remaining, "Normalize remaining without reversing meaning")
                if used == 28.125 { try expect(parsed.buckets[0].primary?.remainingText == "71.875% left", "Source precision retained") }
            }
        }
        for raw in ["true", "\"50\"", "null", "1e999"] {
            await run("Usage parsing: rejects malformed percentage \(raw)") {
                do { _ = try UsageDecoder.initial(json("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(raw)}}}"), at: Date()); throw CheckFailure(description: "Bad percentage accepted") } catch is CheckFailure { throw CheckFailure(description: "Bad percentage accepted") } catch {}
            }
        }
        await run("Usage parsing: rejects non-finite model values") {
            for n in [Double.nan, Double.infinity, -Double.infinity] {
                do { _ = try UsageWindow(usedPercent: n, durationMinutes: nil, resetsAt: nil, observedAt: Date()); throw CheckFailure(description: "Nonfinite accepted") }
                catch UsageFailure.invalidData {}
            }
        }
        for (minutes, title) in [(300, "5h"), (10080, "Weekly"), (15, "15 min")] {
            await run("Usage parsing: single actual window \(title), missing reset and unknown plan") {
                let value = try UsageDecoder.initial(json("{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":\(minutes)},\"planType\":\"fictional-future-plan\"}}"), at: Date())
                try expect(value.buckets[0].windows.count == 1 && value.buckets[0].windows[0].title == title && value.buckets[0].windows[0].resetsAt == nil && value.buckets[0].plan == nil && value.accountScope == nil, "No inferred reset, plan, identity or missing window")
            }
        }
        for raw in ["0", "-1", "1.5", "1e99"] {
            await run("Usage parsing: rejects invalid duration \(raw)") {
                do { _ = try UsageDecoder.initial(json("{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":\(raw)}}}"), at: Date()); throw CheckFailure(description: "Bad duration accepted") } catch UsageFailure.invalidData {}
            }
        }
        await run("Usage parsing: reviewed plan variants remain metadata, invalid reset and contradictory IDs fail") {
            let data = json("{\"rateLimits\":{\"planType\":\"self_serve_business_prolite\",\"primary\":{\"usedPercent\":25}}}")
            try expect(try UsageDecoder.initial(data, at: Date()).buckets[0].plan == "self_serve_business_prolite", "Known reviewed wire plan is retained")
            for reset in ["-1", "0", "253402300800", "true"] {
                do { _ = try UsageDecoder.initial(json("{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"resetsAt\":\(reset)}}}"), at: Date()); throw CheckFailure(description: "Bad reset accepted") }
                catch UsageFailure.invalidData {}
            }
            do { _ = try UsageDecoder.initial(json("{\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"other\"}}}"), at: Date()); throw CheckFailure(description: "Contradictory ID accepted") }
            catch UsageFailure.invalidData {}
            let extreme = try UsageWindow(usedPercent: 1e300, durationMinutes: nil, resetsAt: nil, observedAt: Date())
            try expect(extreme.remainingText == "0% left" && extreme.remainingPercent == 0, "Text and bar clamp agree")
        }
        await run("Usage parsing: keyed buckets override legacy; credits never become windows") {
            let data = json("{\"rateLimits\":{\"primary\":{\"usedPercent\":0}},\"rateLimitsByLimitId\":{\"codex_other\":{\"primary\":{\"usedPercent\":80,\"windowDurationMins\":60}},\"codex\":{\"secondary\":{\"usedPercent\":59,\"windowDurationMins\":10080},\"credits\":{\"remainingPercent\":99},\"individualLimit\":{\"remainingPercent\":90}}}}")
            let value = try UsageDecoder.initial(data, at: Date())
            try expect(value.buckets.map(\.limitID) == ["codex", "codex_other"] && value.buckets[0].windows.count == 1 && value.buckets[0].windows[0].remainingPercent == 41 && value.buckets[1].windows[0].remainingPercent == 20, "Buckets are separate, no legacy fallback or credit mixing")
        }
        await run("Usage parsing: sparse omitted, explicit null and metadata null differ; freshness is per window") {
            let oldDate = Date().addingTimeInterval(-400)
            let base = try UsageDecoder.initial(fictionalUsage(), at: oldDate)
            let update = try UsageDecoder.rolling(json("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":40},\"planType\":null}}"), previous: base, at: Date())
            try expect(update.buckets[0].secondary == base.buckets[0].secondary && update.buckets[0].plan == "plus", "Omitted window and unavailable metadata retained")
            try expect(update.buckets[0].secondary?.isFresh(at: Date(), ttl: 300) == false, "Sparse update does not renew retained window")
            let cleared = try UsageDecoder.rolling(json("{\"rateLimits\":{\"limitId\":\"codex\",\"secondary\":null}}"), previous: update, at: Date())
            try expect(cleared.buckets[0].secondary == nil && cleared.buckets[0].primary == update.buckets[0].primary, "Explicit null clears window")
            try expect(try UsageDecoder.initial(json("{\"rateLimits\":{\"secondary\":null}}"), at: Date()).buckets[0].windows.isEmpty, "Initial missing data is empty")
        }
        await run("Usage identity: both fictional accounts refresh concurrently without sharing values") {
            let lab = try await UsageLab.make(root("parallel"))
            for c in lab.contexts { lab.service.refresh(c.profileID) }
            for c in lab.contexts { try await lab.settle(c.profileID) }
            let first = lab.service.state(for: lab.contexts[0].profileID), second = lab.service.state(for: lab.contexts[1].profileID)
            try expect(first.status == .available && second.status == .available && first.snapshot?.data.buckets[0].primary?.remainingPercent == 72 && second.snapshot?.data.buckets[0].primary?.remainingPercent == 86, "Profile UUID, independent identities and values retained")
            try expect(await lab.provider.calls == 2, "Two independently routed mock reads")
        }
        for mode in ["wrong identity", "missing usage scope", "wrong usage scope", "missing payload accountId", "wrong payload accountId", "stale source", "authentication", "account changed during request"] {
            await run("Usage identity: blocks \(mode)") {
                let lab = try await UsageLab.make(root(mode)), id = lab.contexts[0].profileID
                switch mode {
                case "wrong identity": await lab.reader.configure(wrong: true)
                case "missing usage scope": await lab.provider.configure(missingScope: true)
                case "wrong usage scope": await lab.provider.configure(wrongScope: true)
                case "missing payload accountId": await lab.provider.configure(data: json("{\"rateLimits\":{\"primary\":{\"usedPercent\":10}}}"))
                case "wrong payload accountId": await lab.provider.configure(data: fictionalUsage("fictional-free-scope"))
                case "stale source": await lab.provider.configure(wrongSource: true)
                case "authentication": await lab.reader.configure(signedOut: true)
                default: await lab.reader.configure(changeAfterRead: true)
                }
                lab.service.refresh(id); try await lab.settle()
                let state = lab.service.state(for: id)
                try expect(state.snapshot == nil && [.verificationRequired, .authenticationRequired].contains(state.status) && !state.canRefresh, "No values assigned after failed identity proof")
                if ["wrong identity", "stale source", "authentication"].contains(mode) { try expect(await lab.provider.calls == 0, "Blocked before usage request") }
            }
        }
        await run("Usage refresh: no permission means zero source, identity and usage reads or polling") {
            let lab = try await UsageLab.make(root("blocked"), allowed: false), id = lab.contexts[0].profileID
            lab.service.refresh(id); lab.service.startAutomaticRefresh(); lab.service.automaticTick()
            await Task.yield()
            try expect(await lab.provider.calls == 0, "No usage request")
            try expect(await lab.provider.proofs == 0, "No I/O")
            try expect(await lab.reader.calls == 0, "No identity I/O")
            try expect(lab.service.state(for: id).status == .verificationRequired && !lab.service.state(for: id).canRefresh && !UsageIntegrationPolicy.liveEnabled, "Honest disabled UI and production gate")
        }
        await run("Usage refresh: duplicate requests deduplicate and refreshing retains only own cache") {
            let lab = try await UsageLab.make(root("dedup")), id = lab.contexts[0].profileID
            lab.service.refresh(id); try await lab.settle()
            await lab.provider.configure(held: true)
            lab.service.refresh(id); lab.service.refresh(id); try await lab.waitForRead()
            try expect(lab.service.state(for: id).status == .refreshing && lab.service.state(for: id).snapshot != nil, "Own fresh cache during refresh")
            await lab.provider.release(); try await lab.settle()
            try expect(await lab.provider.calls == 2, "One initial and one deduplicated refresh")
        }
        for (name, error, expected) in [("network", UsageFailure.networkUnavailable, UsageStatus.error), ("rate", .rateLimited(retryAfter: 120), .rateLimited)] {
            await run("Usage refresh: \(name) error is sanitized and backoff blocks another read") {
                let lab = try await UsageLab.make(root(name)), id = lab.contexts[0].profileID
                await lab.provider.configure(error: error); lab.service.refresh(id); try await lab.settle(); lab.service.refresh(id)
                try expect(lab.service.state(for: id).status == expected && !lab.service.state(for: id).canRefresh && lab.service.state(for: id).snapshot == nil, "Visible error and backoff")
                try expect(await lab.provider.calls == 1, "No retry storm")
            }
        }
        await run("Usage refresh: timeout settles even a noncooperative provider; late answer is discarded") {
            let lab = try await UsageLab.make(root("timeout"), timeout: .milliseconds(25)), id = lab.contexts[0].profileID
            await lab.provider.configure(held: true); lab.service.refresh(id); try await lab.waitForRead(); try await lab.settle()
            try expect(lab.service.state(for: id).status == .error && lab.service.state(for: id).explanation.contains("timed out"), "Bounded UI deadline")
            await lab.provider.release(); try await Task.sleep(for: .milliseconds(10))
            try expect(lab.service.state(for: id).snapshot == nil && lab.service.state(for: id).status == .error, "Late result rejected")
        }
        for mode in ["environment", "generation", "transport", "protocol", "identity", "cancel", "removed profile"] {
            await run("Usage invalidation: \(mode) rejects the old pending response and cache") {
                let lab = try await UsageLab.make(root("invalidate-" + mode)), c = lab.contexts[0], id = c.profileID
                await lab.provider.configure(held: true); lab.service.refresh(id); try await lab.waitForRead()
                if mode == "cancel" { lab.service.cancel(id) }
                else if mode == "removed profile" { lab.service.synchronize([lab.contexts[1].association]) }
                else {
                    let gen = DesktopGeneration(pid: c.instance.main.pid, uid: getuid(), started: "fictional-reused-pid")
                    var association = c.association
                    if mode == "environment" {
                        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(association)) as! [String: Any]
                        raw["environmentID"] = UUID().uuidString
                        raw["codexHome"] = association.codexHome + "/fictional-rebound"
                        association = try JSONDecoder().decode(EnvironmentAssociation.self, from: JSONSerialization.data(withJSONObject: raw))
                    }
                    let changed = UsageContext(association: association,
                        instance: mode == "generation" ? DesktopInstance(main: gen, related: [gen], nativeLaunchDate: Date()) : c.instance,
                        accountIdentity: mode == "identity" ? lab.contexts[1].accountIdentity : c.accountIdentity, accountScope: c.accountScope,
                        transportID: mode == "transport" ? UUID() : c.transportID, protocolVersion: mode == "protocol" ? "unknown-v99" : c.protocolVersion)
                    lab.service.bind(changed)
                }
                await lab.provider.release(); try await Task.sleep(for: .milliseconds(10))
                try expect(lab.service.state(for: id).snapshot == nil && lab.service.state(for: lab.contexts[1].profileID).snapshot == nil, "Old data cannot appear under either profile")
            }
        }
        await run("Usage identity: unsupported protocol stops before any source request") {
            let lab = try await UsageLab.make(root("unsupported")), c = lab.contexts[0]
            lab.service.bind(UsageContext(association: c.association, instance: c.instance, accountIdentity: c.accountIdentity, accountScope: c.accountScope, transportID: c.transportID, protocolVersion: "unknown-v99"))
            lab.service.refresh(c.profileID)
            try expect(lab.service.state(for: c.profileID).status == .unsupportedProtocol && lab.service.state(for: c.profileID).snapshot == nil, "Unsupported is explicit")
            try expect(await lab.provider.calls == 0, "No usage request")
            try expect(await lab.provider.proofs == 0, "No protocol guessing")
        }
        await run("Usage cache: Plus snapshot cannot be read as Free; TTL and reset do not imply 100 percent") {
            let lab = try await UsageLab.make(root("cache")), c = lab.contexts[0]
            lab.service.refresh(c.profileID); try await lab.settle()
            let snapshot = lab.service.state(for: c.profileID).snapshot!
            var cache = UsageCache(); cache.store(snapshot)
            try expect(cache.snapshot(for: lab.contexts[1]) == nil, "No cross-profile fallback")
            let changed = UsageContext(association: c.association, instance: c.instance, accountIdentity: lab.contexts[1].accountIdentity, accountScope: lab.contexts[1].accountScope, transportID: c.transportID)
            try expect(cache.snapshot(for: changed) == nil, "Same UUID is insufficient after account change")
            try expect(!snapshot.isFresh(at: Date().addingTimeInterval(301), ttl: 300), "TTL expiry")
            let w = try UsageWindow(usedPercent: 80, durationMinutes: 300, resetsAt: Date().addingTimeInterval(-1), observedAt: Date())
            try expect(!w.isFresh(at: Date(), ttl: 300) && w.remainingPercent == 20, "Passed reset remains old data, never inferred recovery")
            cache.clearAll(); try expect(cache.snapshot(for: c) == nil, "Explicit memory clear")
        }
        await run("Usage refresh: old snapshot rejected") {
            let lab = try await UsageLab.make(root("old")), id = lab.contexts[0].profileID
            await lab.provider.configure(age: 400); lab.service.refresh(id); try await lab.settle()
            try expect(lab.service.state(for: id).status == .error && lab.service.state(for: id).snapshot == nil, "Old read not displayed")
        }
        await run("Usage refresh: automatic failures stop after three; manual retry remains explicit") {
            let lab = try await UsageLab.make(root("auto"), retryBase: 0), id = lab.contexts[0].profileID
            // Only one registered context for the automatic policy test.
            lab.service.synchronize([lab.contexts[0].association])
            await lab.provider.configure(error: .networkUnavailable)
            for _ in 0..<4 { lab.service.automaticTick(); try await lab.settle(id) }
            try expect(await lab.provider.calls == 3, "Automatic circuit stops after three failures")
            lab.service.refresh(id); try await lab.settle(id)
            try expect(await lab.provider.calls == 4, "Explicit manual retry works after backoff")
            lab.service.stopAutomaticRefresh()
        }
        await run("Usage cache: rejects a manually misbound Plus snapshot for Free") {
            let lab = try await UsageLab.make(root("cache-injection"))
            lab.service.refresh(lab.contexts[0].profileID); try await lab.settle()
            let plus = lab.service.state(for: lab.contexts[0].profileID).snapshot!
            var cache = UsageCache()
            cache.store(AccountUsageSnapshot(context: lab.contexts[1], data: plus.data, updatedAt: plus.updatedAt))
            try expect(cache.snapshot(for: lab.contexts[1]) == nil, "Cache validates payload account scope against destination")
        }
        await run("Usage freshness: expired cache becomes Stale and account change immediately removes it") {
            let lab = try await UsageLab.make(root("stale-state")), c = lab.contexts[0]
            lab.service.refresh(c.profileID); try await lab.settle()
            var policy = UsageCoordinator.Policy(); policy.freshness = 0.2
            let service = UsageCoordinator(provider: lab.provider, verifier: AccountIdentityVerifier(reader: lab.reader,
                expected: [ExpectedAccountIdentity(association: c.association, key: c.accountIdentity)]), policy: policy)
            service.bind(c)
            // Timestamp freshness can expire after a successful read, independent of the view.
            service.refresh(c.profileID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while [.loading, .refreshing].contains(service.state(for: c.profileID).status) && ContinuousClock.now < deadline { await Task.yield() }
            try await Task.sleep(for: .milliseconds(250))
            try expect(service.state(for: c.profileID).status == .stale && service.state(for: c.profileID).snapshot != nil, "Old values explicitly marked stale")
            service.invalidate(c.profileID)
            try expect(service.state(for: c.profileID).status == .verificationRequired && service.state(for: c.profileID).snapshot == nil, "External identity change clears values")
        }
        await run("Usage sparse integration: attested update preserves untouched buckets and window age") {
            let lab = try await UsageLab.make(root("scoped-rolling")), id = lab.contexts[0].profileID
            lab.service.refresh(id); try await lab.settle()
            let oldWeekly = lab.service.state(for: id).snapshot?.data.buckets[0].secondary
            await lab.provider.configure(data: json("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":40,\"windowDurationMins\":300}}}"), kind: .rolling)
            lab.service.refresh(id); try await lab.settle()
            let value = lab.service.state(for: id).snapshot
            try expect(value?.data.buckets[0].primary?.remainingPercent == 60 && value?.data.buckets[0].secondary == oldWeekly, "Only updated window changes")
        }
        await run("Usage source: identity proof expiring during ownership recheck blocks usage") {
            let lab = try await UsageLab.make(root("proof-expiry")), id = lab.contexts[0].profileID
            await lab.reader.configure(shortExpiry: true)
            await lab.provider.configure(slowFinalProof: true)
            lab.service.refresh(id); try await lab.settle()
            try expect(lab.service.state(for: id).status == .verificationRequired && lab.service.state(for: id).snapshot == nil, "Fresh identity is checked after asynchronous source validation")
            try expect(await lab.provider.calls == 0, "No usage request with expired proof")
            try expect(await lab.provider.proofs == 2, "Expiry occurs during final source check")
        }
        await run("Usage source: ownership inspection failure purges cached values before another usage read") {
            let lab = try await UsageLab.make(root("proof-failure")), id = lab.contexts[0].profileID
            lab.service.refresh(id); try await lab.settle()
            await lab.provider.configure(proofFailure: true)
            lab.service.refresh(id); try await lab.settle()
            try expect(lab.service.state(for: id).status == .verificationRequired && lab.service.state(for: id).snapshot == nil, "Lost provenance clears the cache")
            try expect(await lab.provider.calls == 1, "No usage read after lost ownership")
        }
        await run("Usage parsing: malformed JSON is a data error and rolling buckets are bounded") {
            do { _ = try UsageDecoder.initial(json("not-json"), at: Date()); throw CheckFailure(description: "Malformed JSON accepted") }
            catch UsageFailure.invalidData {}
            let buckets = (0..<64).map { UsageBucket(limitID: "fictional-\($0)") }
            do { _ = try UsageDecoder.rolling(json("{\"rateLimits\":{\"limitId\":\"fictional-overflow\"}}"), previous: DecodedUsage(accountScope: nil, buckets: buckets), at: Date()); throw CheckFailure(description: "Unbounded rolling cache") }
            catch UsageFailure.invalidData {}
        }
        await run("Usage sparse integration: unscoped update cannot inherit cached account ownership") {
            let lab = try await UsageLab.make(root("rolling")), id = lab.contexts[0].profileID
            lab.service.refresh(id); try await lab.settle()
            await lab.provider.configure(missingScope: true, data: json("{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":1}}}"), kind: .rolling)
            lab.service.refresh(id); try await lab.settle()
            try expect(lab.service.state(for: id).status == .verificationRequired && lab.service.state(for: id).snapshot == nil, "No ownership inherited from a notification")
        }
    }
}
