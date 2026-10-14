import Foundation
import Darwin
import CodexSwoopCore

/// In-memory bytes and fictional process IDs only. No Process, socket, network or auth store.
actor FictionalAppServerChannel: AppServerByteChannel {
    nonisolated let isSynthetic: Bool
    var binding: AppServerBinding
    var hold = false, badInitialize = false, failSend = false, fragment = false
    var staleOwner = false
    var sent: [String] = [], ids: [Int] = [], initialized = 0, closed = false
    private var chunks: [Data] = [], delayed: [Data] = []
    private var receivers: [CheckedContinuation<Data?, any Error>] = []
    init(_ binding: AppServerBinding, synthetic: Bool = true) { self.binding = binding; isSynthetic = synthetic }
    func configure(hold: Bool = false, badInitialize: Bool = false, failSend: Bool = false,
                   fragment: Bool = false, staleOwner: Bool = false) {
        self.hold = hold; self.badInitialize = badInitialize; self.failSend = failSend
        self.fragment = fragment; self.staleOwner = staleOwner
    }
    func rebind(_ binding: AppServerBinding) { self.binding = binding }
    func owner() -> AppServerOwnerEvidence {
        AppServerOwnerEvidence(binding: binding, checkedAt: Date().addingTimeInterval(staleOwner ? -10 : 0))
    }
    func send(_ frame: Data) throws {
        if failSend { throw CheckFailure(description: "Fictional secret-like transport detail must not escape") }
        let object = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        let method = object["method"] as! String
        if method == "initialized" { initialized += 1; return }
        let id = (object["id"] as! NSNumber).intValue
        ids.append(id); sent.append(method)
        try expect(object["jsonrpc"] == nil && frame.last == 10, "Official newline framing without JSON-RPC header")
        let result: [String: Any]
        switch method {
        case "initialize":
            let params = object["params"] as! [String: Any]
            try expect(params["protocolVersion"] == nil, "No invented protocol negotiation")
            result = ["userAgent": "fictional-codex", "codexHome": binding.association.codexHome,
                      "platformFamily": "unix", "platformOs": badInitialize ? "fictional-os" : "macos"]
        case "account/read":
            try expect((object["params"] as! [String: Any])["refreshToken"] as? Bool == false, "No proactive refresh")
            result = ["account": ["type": "chatgpt", "email": "fictional@example.invalid", "planType": "free"], "requiresOpenaiAuth": true]
        default:
            result = ["accountId": binding.association.profileID.uuidString, "rateLimits": ["primary": ["usedPercent": 20]]]
        }
        let response = try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10])
        if hold && method != "initialize" { delayed.append(response) } else { emit(response) }
    }
    func emit(_ data: Data) {
        if fragment && data.count > 4 {
            queue(Data(data.prefix(3))); queue(Data(data.dropFirst(3)))
        } else { queue(data) }
    }
    private func queue(_ data: Data) {
        if !receivers.isEmpty { receivers.removeFirst().resume(returning: data) } else { chunks.append(data) }
    }
    func release() { let frames = delayed.reversed(); delayed.removeAll(); for frame in frames { emit(frame) } }
    func receive() async throws -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func close() {
        closed = true; chunks.removeAll(); delayed.removeAll()
        let waits = receivers; receivers.removeAll(); for wait in waits { wait.resume(returning: nil) }
    }
}

struct OwnedIdentityFixture: AccountIdentityReading {
    let key: AccountIdentityKey
    func read(_ request: AccountIdentityRequest) async throws -> IdentityReadResult {
        .response(RoutedAccountIdentity(request: request, key: key, authenticated: true, scope: .ownedAppServer))
    }
}

@MainActor
struct TransportLab {
    let binding: AppServerBinding, channel: FictionalAppServerChannel, session: AppServerProtocolSession
    static func make(_ association: EnvironmentAssociation, timeout: Duration = .seconds(2),
                     synthetic: Bool = true, fingerprint: String = AppServerIntegrationPolicy.reviewedProtocol,
                     pid: Int32 = 240_001) -> Self {
        let binding = AppServerBinding(association: association,
            child: AppServerChildGeneration(pid: pid, uid: getuid(), started: "fictional-child-generation-\(pid)"),
            protocolFingerprint: fingerprint)
        let channel = FictionalAppServerChannel(binding, synthetic: synthetic)
        return Self(binding: binding, channel: channel, session: AppServerProtocolSession(binding: binding, channel: channel, timeout: timeout))
    }
    func waitForRequest(_ count: Int = 2) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while await channel.sent.count < count {
            guard ContinuousClock.now < limit else { throw CheckFailure(description: "Fictional request not observed") }
            await Task.yield()
        }
    }
}

extension CoreChecks {
    @MainActor static func transportChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fixture: AssociationFixture
        do { fixture = try await AssociationFixture.make(base.appendingPathComponent("transport-fictional")) }
        catch { await run("Transport fixture setup") { throw error }; return }
        let a = fixture.associations[0], b = fixture.associations[1]
        func rejects(_ expected: AppServerFailure, _ work: () async throws -> Void) async throws {
            do { try await work(); throw CheckFailure(description: "Expected sanitized transport rejection") }
            catch let error as AppServerFailure { try expect(error == expected, "Unexpected sanitized transport failure") }
        }
        await run("Transport: native gate and default integration remain closed") {
            try expect(!AppServerIntegrationPolicy.nativeEnabled && !UsageIntegrationPolicy.liveEnabled, "Compile-time gates closed")
            do { try NativeAppServerAccess.requireAvailable(); throw CheckFailure(description: "Native gate open") }
            catch AppServerFailure.gateClosed {}
            let boundary = OwnedAppServerAccountBoundary()
            let result = try await boundary.read(AccountIdentityRequest(association: a, instance: fixture.sourceInstance))
            guard case .unavailable = result else { throw CheckFailure(description: "Owned child became Desktop identity") }
            try expect(!boundary.permitsSyntheticRequests, "Boundary cannot start coordinator I/O")
        }
        await run("Transport: explicit launch plan excludes inherited authorization variables") {
            let plan = try OwnedAppServerLaunchPlan(association: a, executable: "/fictional/codex", userHome: "/fictional/user")
            try expect(plan.arguments == ["app-server", "--listen", "stdio://"] && plan.environment["CODEX_HOME"] == a.codexHome,
                       "Explicit stdio and profile root")
            try expect(Set(plan.environment.keys) == ["HOME", "CODEX_HOME", "PATH", "LANG"], "No environment inheritance")
        }
        await run("Transport: non-synthetic channels rejected before any byte I/O") {
            let lab = TransportLab.make(a, synthetic: false)
            try await rejects(.gateClosed) { try await lab.session.connect() }
            let sent = await lab.channel.sent; try expect(sent.isEmpty, "No initialize")
        }
        await run("Transport: unexpected protocol fingerprint rejected before initialize") {
            let lab = TransportLab.make(a, fingerprint: "fictional-v999")
            try await rejects(.unsupportedBuild) { try await lab.session.connect() }
            let sent = await lab.channel.sent; try expect(sent.isEmpty, "No fake version negotiation")
        }
        await run("Transport: two independent profiles route responses through separate channels") {
            let first = TransportLab.make(a), second = TransportLab.make(b, pid: 240_002)
            async let c1: Void = first.session.connect(); async let c2: Void = second.session.connect()
            _ = try await (c1, c2)
            async let r1 = first.session.request(.rateLimitsRead); async let r2 = second.session.request(.rateLimitsRead)
            let replies = try await (r1, r2)
            let one = try UsageDecoder.initial(replies.0, at: Date()), two = try UsageDecoder.initial(replies.1, at: Date())
            try expect(one.accountScope != two.accountScope && first.binding.connectionID != second.binding.connectionID
                       && first.binding.child != second.binding.child, "Distinct routing/scope/processes")
            await first.session.close(); await second.session.close()
        }
        await run("Transport: fragmented JSONL and exactly one initialization handshake") {
            let lab = TransportLab.make(a); await lab.channel.configure(fragment: true)
            try await lab.session.connect()
            _ = try await lab.session.request(.accountRead)
            let initialized = await lab.channel.initialized; try expect(initialized == 1, "One initialized notification")
            try await rejects(.invalidState) { try await lab.session.connect() }
            await lab.session.close()
        }
        await run("Transport: concurrent requests match reversed response IDs") {
            let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(hold: true)
            let account = Task { try await lab.session.request(.accountRead) }
            let usage = Task { try await lab.session.request(.rateLimitsRead) }
            try await lab.waitForRequest(3); await lab.channel.release()
            let snapshot = try AppServerAccountSnapshot.decode(await account.value)
            let limits = try UsageDecoder.initial(await usage.value, at: Date())
            try expect(snapshot.stableIdentity == nil && limits.accountScope != nil, "Replies matched by ID, scope is not user identity")
            await lab.session.close()
        }
        for mode in ["environment", "process", "auth", "connection"] {
            await run("Transport: \(mode) change rejects in-flight response") {
                let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(hold: true)
                let request = Task { try await lab.session.request(.accountRead) }; try await lab.waitForRequest()
                let old = lab.binding
                let changed = AppServerBinding(association: mode == "environment" ? b : a,
                    child: mode == "process" ? AppServerChildGeneration(pid: old.child.pid, uid: getuid(), started: "fictional-reused-pid") : old.child,
                    connectionID: mode == "connection" ? UUID() : old.connectionID, authEpoch: mode == "auth" ? 1 : 0)
                await lab.channel.rebind(changed); await lab.channel.release()
                try await rejects(.ownerChanged) { _ = try await request.value }
                let closed = await lab.channel.closed; try expect(closed, "Changed source retired")
            }
        }
        await run("Transport: account change notification cancels all pending work") {
            let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(hold: true)
            let request = Task { try await lab.session.request(.accountRead) }; try await lab.waitForRequest()
            await lab.channel.emit(Data("{\"method\":\"account/updated\",\"params\":{\"planType\":\"free\"}}\n".utf8))
            try await rejects(.authenticationChanged) { _ = try await request.value }
            await lab.channel.release()
            try await rejects(.closed) { _ = try await lab.session.request(.rateLimitsRead) }
        }
        await run("Transport: stale owner evidence fails before account request") {
            let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(staleOwner: true)
            try await rejects(.ownerChanged) { _ = try await lab.session.request(.accountRead) }
            let count = await lab.channel.sent.count; try expect(count == 1, "No account bytes sent")
        }
        await run("Transport: unexpected initialize schema/platform closes channel") {
            let lab = TransportLab.make(a); await lab.channel.configure(badInitialize: true)
            try await rejects(.unsupportedBuild) { try await lab.session.connect() }
        }
        await run("Transport: deadline retires channel with zero retries and late data rejected") {
            let lab = TransportLab.make(a, timeout: .milliseconds(25)); try await lab.session.connect()
            await lab.channel.configure(hold: true)
            try await rejects(.timeout) { _ = try await lab.session.request(.accountRead) }
            await lab.channel.release(); let count = await lab.channel.sent.count
            try expect(count == 2, "No retry after unknown request outcome")
            try await rejects(.closed) { _ = try await lab.session.request(.accountRead) }
        }
        await run("Transport: cancellation closes channel and rejects subsequent use") {
            let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(hold: true)
            let request = Task { try await lab.session.request(.accountRead) }; try await lab.waitForRequest(); request.cancel()
            do { _ = try await request.value; throw CheckFailure(description: "Cancellation ignored") } catch is CancellationError {}
            try await rejects(.closed) { _ = try await lab.session.request(.accountRead) }
        }
        await run("Transport: raw errors are reduced to sanitized failure") {
            let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(failSend: true)
            try await rejects(.disconnected) { _ = try await lab.session.request(.accountRead) }
        }
        for frame in [Data("{\"id\":999,\"result\":{}}\n".utf8), Data("{\"id\":true,\"result\":{}}\n".utf8),
                      Data("{\"id\":2,\"result\":{},\"error\":{}}\n".utf8), Data(repeating: 65, count: 262_145)] {
            await run("Transport: invalid/unmatched/oversized frame fails closed (\(frame.count) bytes)") {
                let lab = TransportLab.make(a); try await lab.session.connect(); await lab.channel.configure(hold: true)
                let request = Task { try await lab.session.request(.accountRead) }; try await lab.waitForRequest()
                await lab.channel.emit(frame)
                try await rejects(.invalidFrame) { _ = try await request.value }
            }
        }
        for extra in ["", ",\"accountId\":\"fictional-other\"", ",\"workspaceRouting\":{\"chatgptAccountId\":\"fictional-workspace\"}"] {
            await run("Transport identity: official account fields never manufacture stable subject (\(extra.isEmpty ? "missing ID" : "extra scope"))") {
                let raw = Data("{\"account\":{\"type\":\"chatgpt\",\"email\":null,\"planType\":\"plus\"},\"requiresOpenaiAuth\":true\(extra)}".utf8)
                let result = try AppServerAccountSnapshot.decode(raw)
                try expect(result.stableIdentity == nil, "No enrollment from email, plan or experimental workspace")
            }
        }
        await run("Transport identity: child proof cannot authorize Desktop despite matching anchor") {
            let key = try AccountIdentityKey(namespace: "fictional-user", subject: "fictional-owner")
            let verifier = AccountIdentityVerifier(reader: OwnedIdentityFixture(key: key), expected: [ExpectedAccountIdentity(association: a, key: key)])
            let result = try await verifier.assess(AccountIdentityRequest(association: a, instance: fixture.sourceInstance))
            try expect(result.state == .verificationUnavailable && result.proof == .unavailable, "Evidence scopes remain separate")
        }
        await run("Transport usage: child source purges Desktop cache before another read") {
            let lab = try await UsageLab.make(base.appendingPathComponent("transport-usage-scope"))
            let id = lab.contexts[0].profileID
            lab.service.refresh(id); try await lab.settle()
            try expect(lab.service.state(for: id).snapshot != nil, "Fictional verified Desktop cache exists")
            await lab.provider.configure(ownedSource: true)
            let before = await lab.provider.calls
            lab.service.refresh(id); try await lab.settle()
            let after = await lab.provider.calls
            try expect(after == before && lab.service.state(for: id).snapshot == nil && lab.service.state(for: id).status == .verificationRequired,
                       "Owned server cannot refresh or retain Desktop values")
        }
    }
}
