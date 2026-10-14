import Foundation

public enum ActivityLocation: Sendable { case local, cloud, unknown }
public enum ActivityOperationKind: Sendable { case runningTurn, waitingForApproval, waitingForUserInput, backgroundProcess }

/// Only allowlisted status metadata belongs here: no messages, commands, paths or credentials.
public struct ActivityOperation: Sendable {
    public let location: ActivityLocation
    public let kind: ActivityOperationKind
    public init(location: ActivityLocation, kind: ActivityOperationKind) {
        self.location = location; self.kind = kind
    }
}

public struct ActivitySummary: Equatable, Sendable {
    public let localTasks: Int
    public let cloudTasks: Int
    public let unlocatedTasks: Int
    public let awaitingApproval: Int
    public let awaitingUserInput: Int
    public let backgroundProcesses: Int
    public let hasIncompleteCoverage: Bool
    public var taskCount: Int { localTasks + cloudTasks + unlocatedTasks }

    fileprivate init(operations: [ActivityOperation], complete: Bool) {
        let tasks = operations.filter { $0.kind != .backgroundProcess }
        localTasks = tasks.filter { $0.location == .local }.count
        cloudTasks = tasks.filter { $0.location == .cloud }.count
        unlocatedTasks = tasks.filter { $0.location == .unknown }.count
        awaitingApproval = tasks.filter { $0.kind == .waitingForApproval }.count
        awaitingUserInput = tasks.filter { $0.kind == .waitingForUserInput }.count
        backgroundProcesses = operations.filter { $0.kind == .backgroundProcess }.count
        hasIncompleteCoverage = !complete
    }
}

public enum ActivityUnknownReason: Equatable, Sendable {
    case desktopConnectionUnverified, incompleteCoverage, staleEvidence, checkFailed
}

public enum CodexActivityStatus: Equatable, Sendable {
    case idle
    case busy(ActivitySummary)
    case unknown(ActivityUnknownReason)

    /// A future verified bridge must deduplicate tasks and cover children/background work.
    /// A partial empty result (including an empty newly started server) cannot establish Idle.
    public static func assess(operations: [ActivityOperation], coverageComplete: Bool, fresh: Bool) -> Self {
        guard fresh else { return .unknown(.staleEvidence) }
        if !operations.isEmpty { return .busy(ActivitySummary(operations: operations, complete: coverageComplete)) }
        return coverageComplete ? .idle : .unknown(.incompleteCoverage)
    }
}

public protocol CodexActivityChecking: Sendable {
    func checkActivity() async throws -> CodexActivityStatus
    func checkActivity(for instance: DesktopInstance) async throws -> CodexActivityStatus
}
public extension CodexActivityChecking {
    // An unscoped Idle result cannot establish that this particular Desktop instance is idle.
    func checkActivity(for instance: DesktopInstance) async throws -> CodexActivityStatus { .unknown(.desktopConnectionUnverified) }
}

/// No documented external Desktop connection with complete status coverage is established.
/// Do not replace this with PID, CPU, log scraping or a separate App Server's empty inventory.
public struct ConservativeActivityChecker: CodexActivityChecking {
    public init() {}
    public func checkActivity() async throws -> CodexActivityStatus { .unknown(.desktopConnectionUnverified) }
}

public struct SwitchingWarning: Sendable {
    public let message: String
    public let detail: String
    public static var cancelTitle: String { L10n.text("common.cancel") }
    public static var continueTitle: String { L10n.text("message.53980467fa") }

    public init?(activity: CodexActivityStatus) {
        switch activity {
        case .idle: return nil
        case .unknown:
            message = L10n.text("message.46c6de9805")
            detail = L10n.text("message.2aa0810102")
        case .busy(let summary):
            message = L10n.text("message.87ac78e2c2")
            var lines = [L10n.text("message.1da138e845", summary.taskCount, summary.localTasks, summary.cloudTasks, summary.unlocatedTasks),
                         L10n.text("message.66b08526db", summary.awaitingApproval, summary.awaitingUserInput, summary.backgroundProcesses),
                         L10n.text("message.2185869f0b")]
            if summary.hasIncompleteCoverage { lines.append(L10n.text("message.8a58f94ff3")) }
            detail = lines.joined(separator: "\n\n")
        }
    }
}
