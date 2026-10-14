import Foundation
import CoreFoundation
import Darwin

/// Injected byte transport. Only fictional implementations are accepted in this stage.
/// A future native implementation must prove pipe ownership and both roots independently of JSON.
/// send writes one complete frame atomically; close must release pending receive/proof/send work.
public protocol AppServerByteChannel: Sendable {
    var isSynthetic: Bool { get }
    func owner() async throws -> AppServerOwnerEvidence
    func send(_ frame: Data) async throws
    func receive() async throws -> Data?
    func close() async
}

/// JSONL stdio protocol engine, exercised only with in-memory channels. It is not a native adapter.
/// One actor/connection per immutable binding, one reader, bounded pending work, no automatic retries.
public actor AppServerProtocolSession {
    public enum Method: Sendable { case accountRead, rateLimitsRead }
    private enum State { case idle, opening, ready, closed }
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<Data, any Error>
        let deadline: Task<Void, Never>
        var work: Task<Void, Never>?
    }
    public let binding: AppServerBinding
    private let channel: any AppServerByteChannel
    private let timeout: Duration
    private var state = State.idle
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private let maximumFrame = 262_144

    public init(binding: AppServerBinding, channel: any AppServerByteChannel, timeout: Duration = .seconds(10)) {
        self.binding = binding; self.channel = channel
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(10))
    }
    public func connect() async throws {
        guard state == .idle else { throw AppServerFailure.invalidState }
        guard channel.isSynthetic else { throw AppServerFailure.gateClosed }
        guard binding.cliVersion == AppServerIntegrationPolicy.reviewedCLIVersion,
              binding.protocolFingerprint == AppServerIntegrationPolicy.reviewedProtocol else { throw AppServerFailure.unsupportedBuild }
        guard binding.child.pid > 1, binding.child.uid == getuid(), !binding.child.started.isEmpty,
              EnvironmentValidator.canonical(binding.association.codexHome),
              EnvironmentValidator.canonical(binding.association.electronData),
              !EnvironmentValidator.overlaps(binding.association.codexHome, binding.association.electronData) else { throw AppServerFailure.ownerChanged }
        state = .opening
        reader = Task { await pump() }
        _ = try await rpc("initialize", params: ["clientInfo": ["name": "codexswoop", "version": "0.1.0"],
                                               "capabilities": ["experimentalApi": false]])
    }
    public func request(_ method: Method) async throws -> Data {
        guard state == .ready else { throw AppServerFailure.closed }
        switch method {
        case .accountRead: return try await rpc("account/read", params: ["refreshToken": false])
        case .rateLimitsRead: return try await rpc("account/rateLimits/read", params: ["excludeResetCreditDetails": true])
        }
    }
    public func close() async { await retire(AppServerFailure.closed) }

    private func rpc(_ method: String, params: [String: any Sendable]) async throws -> Data {
        try Task.checkCancellation()
        guard pending.count < 16, nextID < Int.max else { throw AppServerFailure.invalidState }
        let id = nextID; nextID += 1
        let frame = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([10])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task {
                    do { try await Task.sleep(for: timeout); await retire(AppServerFailure.timeout) }
                    catch {} // Timer cancellation is normal completion, never logged.
                }
                pending[id] = Pending(method: method, continuation: continuation, deadline: deadline)
                let work = Task { await transmit(frame, id: id) }
                pending[id]?.work = work
            }
        } onCancel: {
            Task { await self.retire(CancellationError()) }
        }
    }
    private func validateOwner() async throws {
        let evidence = try await channel.owner()
        try Task.checkCancellation()
        guard state != .closed, evidence.binding == binding, evidence.checkedAt <= Date(),
              Date().timeIntervalSince(evidence.checkedAt) <= 5 else { throw AppServerFailure.ownerChanged }
    }
    private func transmit(_ frame: Data, id: Int) async {
        do {
            try await validateOwner()
            guard pending[id] != nil else { return }
            try await channel.send(frame)
            try await validateOwner()
        } catch { await retire(sanitized(error)) }
    }
    private func pump() async {
        do {
            while !Task.isCancelled && state != .closed {
                guard let chunk = try await channel.receive(), !chunk.isEmpty else { throw AppServerFailure.disconnected }
                try Task.checkCancellation()
                // Bound allocation even when a defective channel returns a huge chunk or no delimiter.
                guard chunk.count <= maximumFrame, buffer.count + chunk.count <= maximumFrame else { throw AppServerFailure.invalidFrame }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    try await consume(frame)
                }
            }
        } catch { await retire(sanitized(error)) }
    }
    private func consume(_ frame: Data) async throws {
        try await validateOwner()
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw AppServerFailure.invalidFrame }
        if let method = object["method"] as? String {
            // Server requests are not part of this adapter; never provide auth tokens or execute tools.
            guard object["id"] == nil else { throw AppServerFailure.invalidFrame }
            if method == "account/updated" || method == "account/login/completed" { throw AppServerFailure.authenticationChanged }
            return // No cache assignment from unscoped quota notifications or unknown events.
        }
        guard let number = object["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue),
              let entry = pending[number.intValue], (object["result"] != nil) != (object["error"] != nil) else {
            throw AppServerFailure.invalidFrame
        }
        guard object["error"] == nil else { throw AppServerFailure.serverError }
        guard let result = object["result"] as? [String: Any] else { throw AppServerFailure.invalidFrame }
        let payload = try JSONSerialization.data(withJSONObject: result)
        if entry.method == "initialize" {
            guard state == .opening, let agent = result["userAgent"] as? String, !agent.isEmpty, agent.utf8.count <= 1024,
                  result["codexHome"] as? String == binding.association.codexHome,
                  result["platformFamily"] as? String == "unix", result["platformOs"] as? String == "macos" else { throw AppServerFailure.unsupportedBuild }
            // initialize has no negotiated protocolVersion. Build/fingerprint policy is independent.
            try await channel.send(Data("{\"method\":\"initialized\"}\n".utf8))
        }
        try await validateOwner()
        guard let current = pending.removeValue(forKey: number.intValue), state != .closed else { return }
        if entry.method == "initialize" { state = .ready }
        current.deadline.cancel(); current.continuation.resume(returning: payload)
    }
    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        return (error as? AppServerFailure) ?? AppServerFailure.disconnected
    }
    private func retire(_ error: any Error) async {
        guard state != .closed else { return }
        state = .closed; reader?.cancel(); reader = nil; buffer.removeAll(keepingCapacity: false)
        let entries = Array(pending.values); pending.removeAll()
        for entry in entries { entry.deadline.cancel(); entry.work?.cancel(); entry.continuation.resume(throwing: error) }
        await channel.close()
    }
}
