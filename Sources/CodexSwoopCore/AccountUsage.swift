import Foundation
import CoreFoundation

public enum UsageIntegrationPolicy {
    public static let liveEnabled = false
    public static var blockedReason: String { L10n.text("message.5b12ebbdb3") }
    public static let reviewedProtocol = "v2:740e5af33c71225640e0c1c1555c514c2c93ab74"
    public static let accountScopeNamespace = "codex.usage-account"
}

public enum UsageStatus: String, CaseIterable, Sendable {
    case loading = "Loading", available = "Available", refreshing = "Refreshing"
    case unavailable = "Unavailable", verificationRequired = "Verification required"
    case authenticationRequired = "Authentication required", stale = "Stale", error = "Error"
    case rateLimited = "Rate limited", unsupportedProtocol = "Unsupported protocol"
}

public enum UsageFailure: Error, Equatable, Sendable {
    case unavailable, verificationRequired, authenticationRequired, unsupportedProtocol
    case invalidData, networkUnavailable, timeout, rateLimited(retryAfter: TimeInterval)
    var status: UsageStatus {
        switch self {
        case .unavailable: .unavailable
        case .verificationRequired: .verificationRequired
        case .authenticationRequired: .authenticationRequired
        case .unsupportedProtocol: .unsupportedProtocol
        case .rateLimited: .rateLimited
        default: .error
        }
    }
    var explanation: String {
        switch self {
        case .unavailable: L10n.text("message.47d20f9886")
        case .verificationRequired: L10n.text("message.0e257d4445")
        case .authenticationRequired: L10n.text("message.438dd16a76")
        case .unsupportedProtocol: L10n.text("message.e4107a4e39")
        case .invalidData: L10n.text("message.8b95130155")
        case .networkUnavailable: L10n.text("message.311398edea")
        case .timeout: L10n.text("message.0f49303465")
        case .rateLimited: L10n.text("message.f103e3036e")
        }
    }
}

/// Both independently established user identity and backend usage scope are required.
/// The full association includes canonical roots, directory identities and validation metadata.
public struct UsageContext: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public let accountIdentity: AccountIdentityKey
    public let accountScope: AccountIdentityKey
    public let transportID: UUID
    public let protocolVersion: String
    public var profileID: UUID { association.profileID }
    public init(association: EnvironmentAssociation, instance: DesktopInstance,
                accountIdentity: AccountIdentityKey, accountScope: AccountIdentityKey,
                transportID: UUID, protocolVersion: String = UsageIntegrationPolicy.reviewedProtocol) {
        self.association = association; self.instance = instance
        self.accountIdentity = accountIdentity; self.accountScope = accountScope
        self.transportID = transportID; self.protocolVersion = protocolVersion
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public let observedAt: Date
    public init(usedPercent: Double, durationMinutes: Int?, resetsAt: Date?, observedAt: Date) throws {
        guard usedPercent.isFinite, durationMinutes.map({ $0 > 0 && $0 <= 525_600_000 }) ?? true,
              resetsAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 && $0.timeIntervalSince1970 <= 253_402_300_799 }) ?? true
        else { throw UsageFailure.invalidData }
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt; self.observedAt = observedAt
    }
    public var title: String {
        switch durationMinutes {
        case 300: L10n.text("usage.fiveHours")
        case 10_080: L10n.text("message.2975132481")
        case .some(let minutes): L10n.text("message.96d15cf84b", minutes)
        case nil: L10n.text("message.fa0fc3a9fe")
        }
    }
    public var remainingText: String {
        if usedPercent <= 0 { return L10n.text("message.eea70ce79c") }
        if usedPercent >= 100 { return L10n.text("message.c6c3f80446") }
        // Decimal subtraction avoids exposing binary floating point noise; no fixed digit rounding.
        let used = Decimal(string: String(usedPercent), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let left = min(Decimal(100), max(Decimal(0), Decimal(100) - used))
        let separator = L10n.locale.decimalSeparator ?? "."
        return L10n.text("usage.remaining", NSDecimalNumber(decimal: left).stringValue.replacingOccurrences(of: ".", with: separator))
    }
    public func isFresh(at now: Date, ttl: TimeInterval) -> Bool {
        now >= observedAt && now.timeIntervalSince(observedAt) < ttl && (resetsAt.map { now < $0 } ?? true)
    }
}

public struct UsageBucket: Equatable, Sendable {
    public let limitID: String
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    public var plan: String?
    public init(limitID: String, primary: UsageWindow? = nil, secondary: UsageWindow? = nil, plan: String? = nil) {
        self.limitID = limitID; self.primary = primary; self.secondary = secondary; self.plan = plan
    }
    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
    public var title: String { limitID == "codex" ? "Codex" : L10n.text("message.2c23be5fbf", limitID) }
}

public struct DecodedUsage: Equatable, Sendable {
    public let accountScope: AccountIdentityKey?
    public var buckets: [UsageBucket]
    public init(accountScope: AccountIdentityKey?, buckets: [UsageBucket]) { self.accountScope = accountScope; self.buckets = buckets }
}

/// Parses only quota windows. Credits, spend controls, banners and token counts are discarded.
/// Full reads replace all buckets. Rolling updates retain omitted windows and nullable plan metadata;
/// explicit null windows clear values conservatively. Unchanged windows retain their own timestamp.
public enum UsageDecoder {
    private static let plans: Set<String> = [
        "free", "go", "plus", "pro", "prolite", "promax", "team", "business", "ent26", "enterprise", "edu",
        "self_serve_business_prolite", "self_serve_business_usage_based", "enterprise_cbp_automation",
        "enterprise_cbp_usage_based", "edu_plus", "edu_pro"
    ]
    public static func initial(_ data: Data, at date: Date) throws -> DecodedUsage {
        let root = try object(data)
        var buckets: [UsageBucket] = []
        if let multi = root["rateLimitsByLimitId"], !(multi is NSNull) {
            guard let map = multi as? [String: Any], map.count <= 64 else { throw UsageFailure.invalidData }
            for (id, value) in map { buckets.append(try bucket(value, id: id, at: date)) }
        } else if let legacy = root["rateLimits"], !(legacy is NSNull) {
            guard let value = legacy as? [String: Any] else { throw UsageFailure.invalidData }
            buckets = [try bucket(value, id: try text(value["limitId"]) ?? "codex", at: date)]
        }
        return DecodedUsage(accountScope: try scope(root["accountId"]), buckets: sorted(buckets))
    }
    public static func rolling(_ data: Data, previous: DecodedUsage, at date: Date) throws -> DecodedUsage {
        let root = try object(data)
        if let scope = try scope(root["accountId"]), scope != previous.accountScope { throw UsageFailure.verificationRequired }
        guard let patch = root["rateLimits"] as? [String: Any], let id = try text(patch["limitId"])
        else { throw UsageFailure.invalidData }
        var result = previous
        var value = previous.buckets.first { $0.limitID == id } ?? UsageBucket(limitID: id)
        if patch.keys.contains("primary") { value.primary = try window(patch["primary"], at: date) }
        if patch.keys.contains("secondary") { value.secondary = try window(patch["secondary"], at: date) }
        if let raw = try text(patch["planType"]) { value.plan = plans.contains(raw) ? raw : nil }
        result.buckets.removeAll { $0.limitID == id }; result.buckets.append(value)
        guard result.buckets.count <= 64 else { throw UsageFailure.invalidData }
        result.buckets = sorted(result.buckets)
        return result
    }
    private static func sorted(_ buckets: [UsageBucket]) -> [UsageBucket] {
        buckets.sorted { a, b in a.limitID == "codex" ? b.limitID != "codex" : b.limitID != "codex" && a.limitID < b.limitID }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard data.count <= 262_144, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw UsageFailure.invalidData }
            return root
        } catch { throw UsageFailure.invalidData }
    }
    private static func scope(_ raw: Any?) throws -> AccountIdentityKey? {
        guard let id = try text(raw) else { return nil }
        return try AccountIdentityKey(namespace: UsageIntegrationPolicy.accountScopeNamespace, subject: id)
    }
    private static func text(_ raw: Any?) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw UsageFailure.invalidData }
        return value
    }
    private static func number(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw UsageFailure.invalidData }
        return n.doubleValue
    }
    private static func bucket(_ raw: Any, id: String, at date: Date) throws -> UsageBucket {
        _ = try text(id)
        guard let value = raw as? [String: Any], try text(value["limitId"]).map({ $0 == id }) ?? true else { throw UsageFailure.invalidData }
        let plan = try text(value["planType"])
        return UsageBucket(limitID: id, primary: try window(value["primary"], at: date), secondary: try window(value["secondary"], at: date), plan: plan.flatMap { plans.contains($0) ? $0 : nil })
    }
    private static func window(_ raw: Any?, at date: Date) throws -> UsageWindow? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? [String: Any], let used = try number(value["usedPercent"]) else { throw UsageFailure.invalidData }
        let minutes = try number(value["windowDurationMins"]), reset = try number(value["resetsAt"])
        guard minutes.map({ $0 > 0 && $0 <= 525_600_000 && $0.rounded() == $0 }) ?? true else { throw UsageFailure.invalidData }
        return try UsageWindow(usedPercent: used, durationMinutes: minutes.map(Int.init), resetsAt: reset.map(Date.init(timeIntervalSince1970:)), observedAt: date)
    }
}

public struct AccountUsageSnapshot: Equatable, Sendable {
    public let context: UsageContext
    public let data: DecodedUsage
    public let updatedAt: Date
    public init(context: UsageContext, data: DecodedUsage, updatedAt: Date) { self.context = context; self.data = data; self.updatedAt = updatedAt }
    public func isFresh(at now: Date, ttl: TimeInterval) -> Bool {
        now >= updatedAt && now.timeIntervalSince(updatedAt) < ttl && data.buckets.flatMap(\.windows).allSatisfy { $0.isFresh(at: now, ttl: ttl) }
    }
}

public struct UsageViewState: Equatable, Sendable {
    public let status: UsageStatus
    public let snapshot: AccountUsageSnapshot?
    public let explanation: String
    public let canRefresh: Bool
    public let lastSuccessfulUpdate: Date?
    public init(status: UsageStatus, snapshot: AccountUsageSnapshot? = nil, explanation: String, canRefresh: Bool = false, lastSuccessfulUpdate: Date? = nil) {
        self.status = status; self.snapshot = snapshot; self.explanation = explanation; self.canRefresh = canRefresh
        self.lastSuccessfulUpdate = lastSuccessfulUpdate ?? snapshot?.updatedAt
    }
}

/// Memory only. No serialization, shared fallback, name-based key or on-disk response storage.
public struct UsageCache: Sendable {
    private var values: [UUID: AccountUsageSnapshot] = [:]
    public init() {}
    public mutating func store(_ snapshot: AccountUsageSnapshot) {
        guard snapshot.data.accountScope == snapshot.context.accountScope else { clear(snapshot.context.profileID); return }
        values[snapshot.context.profileID] = snapshot
    }
    public func snapshot(for context: UsageContext) -> AccountUsageSnapshot? {
        guard let value = values[context.profileID], value.context == context else { return nil }
        return value
    }
    public mutating func clear(_ profileID: UUID) { values.removeValue(forKey: profileID) }
    public mutating func clearAll() { values.removeAll() }
}

public struct UsageSourceEvidence: Sendable {
    public let scope: AccountEvidenceScope
    public let context: UsageContext
    public let checkedAt: Date
    public init(context: UsageContext, checkedAt: Date = Date(), scope: AccountEvidenceScope = .desktopBackend) {
        self.context = context; self.checkedAt = checkedAt; self.scope = scope
    }
}
public struct UsageReply: Sendable {
    public enum Kind: Sendable { case initial, rolling }
    public let source: UsageSourceEvidence
    /// Fresh source-attested scope, never copied from the request or inherited from a cache.
    public let accountScope: AccountIdentityKey?
    public let payload: Data
    public let capturedAt: Date
    public let kind: Kind
    public init(source: UsageSourceEvidence, accountScope: AccountIdentityKey?, payload: Data, capturedAt: Date = Date(), kind: Kind = .initial) {
        self.source = source; self.accountScope = accountScope; self.payload = payload; self.capturedAt = capturedAt; self.kind = kind
    }
}

public protocol AccountUsageProvider: Sendable {
    /// This stage exposes only disabled or explicitly injected synthetic access, never live access.
    var permitsSyntheticRequests: Bool { get }
    /// Must revalidate both root identities, process ancestry/generations and exact transport owner.
    func proveSource(_ context: UsageContext) async throws -> UsageSourceEvidence
    func read(_ context: UsageContext) async throws -> UsageReply
}
public struct BlockedAccountUsageProvider: AccountUsageProvider {
    public init() {}
    public var permitsSyntheticRequests: Bool { false }
    public func proveSource(_ context: UsageContext) throws -> UsageSourceEvidence { throw UsageFailure.unavailable }
    public func read(_ context: UsageContext) throws -> UsageReply { throw UsageFailure.unavailable }
}

public extension UsageStatus {
    var localizedTitle: String {
        let key: String
        switch self {
        case .unavailable: key = "usage.status.unavailable"
        case .verificationRequired: key = "usage.status.verification"
        case .authenticationRequired: key = "usage.status.authentication"
        case .available: key = "usage.status.available"
        case .loading: key = "usage.status.loading"
        case .refreshing: key = "usage.status.refreshing"
        case .stale: key = "usage.status.stale"
        case .error: key = "usage.status.error"
        case .rateLimited: key = "usage.status.rateLimited"
        case .unsupportedProtocol: key = "usage.status.unsupported"
        }
        return L10n.text(key)
    }
}
