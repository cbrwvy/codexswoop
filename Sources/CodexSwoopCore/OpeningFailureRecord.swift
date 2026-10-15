import Foundation

/// Closed vocabulary only: never persist raw errors, paths, arguments or application payloads.
public struct OpeningFailureRecord: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case launchServices, processExited, readinessTimeout, backendNotReady, ownershipUnconfirmed
        case processChanged, activation, launch, incompatibleBuild, cancelled, other
    }
    public enum Stage: String, Codable, Sendable {
        case launch, quitDispatch, exitWait, activation, activationScopeTarget, activationScopeInventory, activationDispatch, activationPostflight
        case driverPostflightTarget, driverPostflightInventory, driverInventoryComparison, driverForeground, journalCompletion
    }
    public let stage: Stage?
    public let reason: Reason
    public let code: Int?
    public init(_ error: SwitchingError, stage: Stage? = nil) {
        self.stage = stage
        var number: Int?
        switch error {
        case .environment(.launchServicesFailed(let value)): reason = .launchServices; number = value
        case .environment(.launchedProcessExited): reason = .processExited
        case .environment(.readinessTimedOut): reason = .readinessTimeout
        case .environment(.backendNotReady): reason = .backendNotReady
        case .environment(.ownershipUnconfirmed), .opening(.ambiguousInstance): reason = .ownershipUnconfirmed
        case .environment(.processChanged), .opening(.processChanged): reason = .processChanged
        case .environment(.incompatibleBuild): reason = .incompatibleBuild
        case .activationFailed: reason = .activation
        case .launchFailed, .opening(.launchFailure): reason = .launch
        case .cancelled, .opening(.userCancelled): reason = .cancelled
        default: reason = .other
        }
        code = number
    }
    func validate() throws {
        guard reason == .launchServices || code == nil else { throw OpeningJournalError.invalid }
    }
    public var error: SwitchingError {
        switch reason {
        case .launchServices: .environment(.launchServicesFailed(code ?? 0))
        case .processExited: .environment(.launchedProcessExited)
        case .readinessTimeout: .environment(.readinessTimedOut)
        case .backendNotReady: .environment(.backendNotReady)
        case .ownershipUnconfirmed: .environment(.ownershipUnconfirmed)
        case .processChanged: .opening(.processChanged)
        case .activation: .activationFailed
        case .launch: .opening(.launchFailure)
        case .incompatibleBuild: .environment(.incompatibleBuild)
        case .cancelled: .opening(.userCancelled)
        case .other: .verificationFailed
        }
    }
}
