import Foundation
import CoreFoundation

public enum AppServerIntegrationPolicy {
    /// Compile-time closure, independent of UI settings. No native channel is implemented or shipped.
    public static let nativeEnabled = false
    public static let reviewedCLIVersion = "0.162.0-alpha.17.2"
    public static let reviewedProtocol = UsageIntegrationPolicy.reviewedProtocol
}

/// Sanitized failures deliberately carry no stderr, RPC messages, URLs, headers or response bodies.
public enum AppServerFailure: Error, Equatable, Sendable {
    case gateClosed, unsupportedBuild, ownerChanged, invalidFrame, serverError
    case disconnected, timeout, closed, invalidState, authenticationChanged
}

/// A launch proposal only. Constructing it performs no file, process or credential I/O.
/// CODEX_HOME isolates a state root, not a user identity, Keychain or existing Desktop connection.
public struct OwnedAppServerLaunchPlan: Sendable {
    public let executable: String
    public let arguments = ["app-server", "--listen", "stdio://"]
    public let environment: [String: String]
    public let association: EnvironmentAssociation
    public init(association: EnvironmentAssociation, executable: String, userHome: String) throws {
        guard EnvironmentValidator.canonical(executable), EnvironmentValidator.canonical(userHome),
              EnvironmentValidator.canonical(association.codexHome), EnvironmentValidator.canonical(association.electronData),
              !EnvironmentValidator.overlaps(association.codexHome, association.electronData) else {
            throw EnvironmentError.invalidPath
        }
        self.association = association; self.executable = executable
        // Never inherit API keys, endpoint overrides, remote-daemon settings or another profile's CODEX_HOME.
        environment = ["CODEX_HOME": association.codexHome, "HOME": userHome,
                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }
}

/// Not interchangeable with DesktopGeneration. Values supplied by fixtures are not native attestation.
public struct AppServerChildGeneration: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let started: String
    public init(pid: Int32, uid: UInt32, started: String) { self.pid = pid; self.uid = uid; self.started = started }
}

public struct AppServerBinding: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let child: AppServerChildGeneration
    public let connectionID: UUID
    public let authEpoch: UInt64
    /// Must come from an independently reviewed executable, not from an initialize response.
    public let cliVersion: String
    public let protocolFingerprint: String
    public init(association: EnvironmentAssociation, child: AppServerChildGeneration,
                connectionID: UUID = UUID(), authEpoch: UInt64 = 0,
                cliVersion: String = AppServerIntegrationPolicy.reviewedCLIVersion,
                protocolFingerprint: String = AppServerIntegrationPolicy.reviewedProtocol) {
        self.association = association; self.child = child; self.connectionID = connectionID; self.authEpoch = authEpoch
        self.cliVersion = cliVersion; self.protocolFingerprint = protocolFingerprint
    }
}

public struct AppServerOwnerEvidence: Sendable {
    public let binding: AppServerBinding
    public let checkedAt: Date
    public init(binding: AppServerBinding, checkedAt: Date = Date()) { self.binding = binding; self.checkedAt = checkedAt }
}

/// Minimal projection of the official account/read result. Email and workspace routing are discarded.
/// Neither an extra "accountId" nor "userId" in an unreviewed response is an identity extension.
public struct AppServerAccountSnapshot: Sendable {
    public enum Authentication: Sendable { case signedOut, chatgpt, apiKey, amazonBedrock }
    public let authentication: Authentication
    public var stableIdentity: AccountIdentityKey? { nil }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requiresAuth = root["requiresOpenaiAuth"] as? NSNumber,
              CFGetTypeID(requiresAuth) == CFBooleanGetTypeID(), let account = root["account"] else { throw AppServerFailure.invalidFrame }
        if account is NSNull { return Self(authentication: .signedOut) }
        guard let object = account as? [String: Any], let type = object["type"] as? String else { throw AppServerFailure.invalidFrame }
        switch type {
        case "chatgpt":
            guard object["planType"] is String, object["email"] is String || object["email"] is NSNull else { throw AppServerFailure.invalidFrame }
            return Self(authentication: .chatgpt)
        case "apiKey": return Self(authentication: .apiKey)
        case "amazonBedrock": return Self(authentication: .amazonBedrock)
        default: throw AppServerFailure.invalidFrame
        }
    }
}

/// Compatibility boundary for the existing verifier/provider. An owned child cannot satisfy their
/// Desktop-backed contract, even if a synthetic channel knows a fictional subject. Zero account I/O.
public struct OwnedAppServerAccountBoundary: AccountIdentityReading, AccountUsageProvider {
    public init() {}
    public var permitsSyntheticRequests: Bool { false }
    public func read(_ request: AccountIdentityRequest) async throws -> IdentityReadResult { .unavailable }
    public func proveSource(_ context: UsageContext) async throws -> UsageSourceEvidence { throw UsageFailure.verificationRequired }
    public func read(_ context: UsageContext) async throws -> UsageReply { throw UsageFailure.verificationRequired }
}

/// No native factory, executable invocation, guessed socket or runtime preference bypass exists.
public enum NativeAppServerAccess {
    public static func requireAvailable() throws { throw AppServerFailure.gateClosed }
}
