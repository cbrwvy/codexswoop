import Foundation
import CryptoKit

public enum AccountIdentityState: String, Sendable {
    case verified, unverified, authenticationRequired, verificationUnavailable, identityMismatch, verificationError
    public var title: String {
        switch self {
        case .verified: L10n.text("message.11aa986ff4")
        case .unverified: L10n.text("message.4585bf8efa")
        case .authenticationRequired: L10n.text("message.0fcfb12dfa")
        case .verificationUnavailable: L10n.text("common.none")
        case .identityMismatch: L10n.text("message.b802bd2f80")
        case .verificationError: L10n.text("message.d725b066a6")
        }
    }
}

/// Runtime-only equality key. No email, plan, credential or raw identifier is retained or logged.
/// The provider must establish stable subject semantics; the experimental workspace ID alone is insufficient.
public struct AccountIdentityKey: Equatable, Sendable, CustomStringConvertible {
    private let digest: Data
    public var description: String { "<account identity>" }
    public init(namespace: String, subject: String) throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 128, !subject.isEmpty, subject.utf8.count <= 512,
              !namespace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw EnvironmentError.invalidMetadata
        }
        digest = Data(SHA256.hash(data: Data((namespace + "\u{0}" + subject).utf8)))
    }
}

/// An independently approved enrollment anchor, never inferred from an API response or manual report.
public struct ExpectedAccountIdentity: Sendable {
    public let association: EnvironmentAssociation
    public let key: AccountIdentityKey
    public init(association: EnvironmentAssociation, key: AccountIdentityKey) { self.association = association; self.key = key }
}

public struct AccountIdentityRequest: Sendable {
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public init(association: EnvironmentAssociation, instance: DesktopInstance) {
        self.association = association; self.instance = instance
    }
}

/// An owned App Server has a separate authentication actor; it is never Desktop ownership evidence.
public enum AccountEvidenceScope: Sendable { case desktopBackend, ownedAppServer }

/// Sanitized transport evidence. A future adapter must prove connection ownership, both directory
/// identities and the exact Desktop generation before constructing it. Response fields are not routing proof.
public struct RoutedAccountIdentity: Sendable {
    public let scope: AccountEvidenceScope
    public let request: AccountIdentityRequest
    public let key: AccountIdentityKey?
    public let authenticated: Bool
    public let checkedAt: Date
    public let expiresAt: Date
    public init(request: AccountIdentityRequest, key: AccountIdentityKey?, authenticated: Bool,
                checkedAt: Date = Date(), expiresAt: Date = Date().addingTimeInterval(5),
                scope: AccountEvidenceScope = .desktopBackend) {
        self.scope = scope
        self.request = request; self.key = key; self.authenticated = authenticated
        self.checkedAt = checkedAt; self.expiresAt = expiresAt
    }
}

public enum IdentityReadResult: Sendable { case unavailable, response(RoutedAccountIdentity) }
public enum IdentityReadError: Error, Sendable { case authenticationExpired, failed }
public protocol AccountIdentityReading: Sendable {
    /// Must enforce a finite deadline, respect cancellation and return sanitized fields only.
    func read(_ request: AccountIdentityRequest) async throws -> IdentityReadResult
}

/// No process, file, network or account API I/O. No runtime preference enables this bridge.
public struct BlockedAccountIdentityReader: AccountIdentityReading {
    public init() {}
    public func read(_ request: AccountIdentityRequest) async throws -> IdentityReadResult { .unavailable }
}

public struct AccountIdentityAssessment: Equatable, Sendable {
    public let state: AccountIdentityState
    public let proof: AccountVerification
    fileprivate init(_ state: AccountIdentityState, proof: AccountVerification = .unavailable) {
        self.state = state; self.proof = proof
    }
}

/// Manual observations are informational, scoped to an environment and never create a runtime proof.
public struct ManualAccountConfirmation: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let profileID: UUID
    public let environmentID: UUID
    public let confirmedAt: Date
    public init(association: EnvironmentAssociation, confirmedAt: Date = Date()) {
        self.association = association
        profileID = association.profileID; environmentID = association.environmentID; self.confirmedAt = confirmedAt
    }
}

public struct AccountIdentityVerifier: DesktopAccountVerifying {
    private let reader: any AccountIdentityReading
    private let expected: [ExpectedAccountIdentity]
    public init(reader: any AccountIdentityReading = BlockedAccountIdentityReader(), expected: [ExpectedAccountIdentity] = []) {
        self.reader = reader; self.expected = expected
    }
    public func expects(_ key: AccountIdentityKey, for association: EnvironmentAssociation) -> Bool {
        let anchors = expected.filter { $0.association == association }
        return anchors.count == 1 && anchors[0].key == key
    }
    public func assess(_ request: AccountIdentityRequest) async throws -> AccountIdentityAssessment {
        try Task.checkCancellation()
        // A malformed/stale instance must never cause an account query.
        guard (try? DesktopObservation(matching: [request.instance], ambiguous: false).unique()) == request.instance else {
            return AccountIdentityAssessment(.verificationError)
        }
        let result: IdentityReadResult
        do { result = try await reader.read(request) }
        catch is CancellationError { throw CancellationError() }
        catch IdentityReadError.authenticationExpired { return AccountIdentityAssessment(.authenticationRequired, proof: .signedOut) }
        catch { return AccountIdentityAssessment(.verificationError) }
        try Task.checkCancellation()
        guard case let .response(response) = result else { return AccountIdentityAssessment(.verificationUnavailable) }
        guard response.scope == .desktopBackend else { return AccountIdentityAssessment(.verificationUnavailable) }
        let now = Date()
        guard response.request.association == request.association, response.request.instance == request.instance,
              response.checkedAt <= now, now.timeIntervalSince(response.checkedAt) <= 5, response.expiresAt > now else {
            return AccountIdentityAssessment(.verificationError)
        }
        guard response.authenticated else { return AccountIdentityAssessment(.authenticationRequired, proof: .signedOut) }
        guard let key = response.key else { return AccountIdentityAssessment(.unverified) }
        let anchors = expected.filter { $0.association == request.association }
        guard anchors.count == 1 else { return AccountIdentityAssessment(.unverified) }
        guard anchors[0].key == key else { return AccountIdentityAssessment(.identityMismatch, proof: .identityMismatch) }
        return AccountIdentityAssessment(.verified, proof: .verified(profileID: request.association.profileID,
            environmentID: request.association.environmentID, generation: request.instance.main,
            checkedAt: response.checkedAt, expiresAt: min(response.expiresAt, response.checkedAt.addingTimeInterval(5))))
    }
    public func verify(_ association: EnvironmentAssociation, instance: DesktopInstance) async throws -> AccountVerification {
        let result = try await assess(AccountIdentityRequest(association: association, instance: instance))
        switch result.state {
        case .verificationError: throw EnvironmentError.verificationError
        default: return result.proof
        }
    }
}
