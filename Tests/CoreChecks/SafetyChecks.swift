import Foundation
import CodexSwoopCore

/// Test-only sequences. Production never reads fixtures or fabricates Desktop activity.
actor ScenarioActivityChecker: CodexActivityChecking {
    private let statuses: [CodexActivityStatus]
    private let throwsOnCheck: Bool
    private(set) var checks = 0
    init(_ statuses: [CodexActivityStatus], throwsOnCheck: Bool = false) {
        precondition(!statuses.isEmpty)
        self.statuses = statuses; self.throwsOnCheck = throwsOnCheck
    }
    func checkActivity() async throws -> CodexActivityStatus {
        let index = checks; checks += 1
        if throwsOnCheck { throw CheckFailure(description: "Test connection failed") }
        return statuses[min(index, statuses.count - 1)]
    }
}

actor TestActivityConfirmation {
    private let answers: [Bool]
    private(set) var seen: [CodexActivityStatus] = []
    init(_ answers: [Bool]) { self.answers = answers }
    func confirm(_ status: CodexActivityStatus) -> Bool {
        seen.append(status)
        return answers.indices.contains(seen.count - 1) ? answers[seen.count - 1] : false
    }
}

extension CoreChecks {
    @MainActor
    static func safetyChecks(run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let unknown = CodexActivityStatus.unknown(.desktopConnectionUnverified)
        let busy = CodexActivityStatus.assess(operations: [.init(location: .local, kind: .runningTurn)], coverageComplete: true, fresh: true)
        let more = CodexActivityStatus.assess(operations: [.init(location: .local, kind: .runningTurn), .init(location: .local, kind: .waitingForApproval)], coverageComplete: true, fresh: true)

        await run("Production activity checker is conservatively Unknown on every check") {
            let checker = ConservativeActivityChecker()
            for _ in 0..<3 { try expect(try await checker.checkActivity() == unknown, "No invented Desktop status") }
        }
        await run("Idle requires fresh complete coverage; partial empty and stale evidence are Unknown") {
            try expect(CodexActivityStatus.assess(operations: [], coverageComplete: true, fresh: true) == .idle, "Complete empty snapshot")
            try expect(CodexActivityStatus.assess(operations: [], coverageComplete: false, fresh: true) == .unknown(.incompleteCoverage), "Partial is not idle")
            try expect(CodexActivityStatus.assess(operations: [.init(location: .local, kind: .runningTurn)], coverageComplete: true, fresh: false) == .unknown(.staleEvidence), "Stale Busy cannot be asserted as current")
        }
        await run("Approval waits, child/background work and execution locations remain visible") {
            let result = CodexActivityStatus.assess(operations: [
                .init(location: .local, kind: .waitingForApproval),
                .init(location: .cloud, kind: .runningTurn),
                .init(location: .unknown, kind: .runningTurn),
                .init(location: .local, kind: .waitingForUserInput),
                .init(location: .local, kind: .backgroundProcess)
            ], coverageComplete: false, fresh: true)
            guard case .busy(let summary) = result else { throw CheckFailure(description: "Unfinished operations missed") }
            try expect(summary.taskCount == 4 && summary.localTasks == 2 && summary.cloudTasks == 1 && summary.unlocatedTasks == 1, "Counts by execution location")
            try expect(summary.awaitingApproval == 1 && summary.awaitingUserInput == 1 && summary.backgroundProcesses == 1 && summary.hasIncompleteCoverage, "No double-counting waits; partial coverage disclosed")
            let backgroundOnly = CodexActivityStatus.assess(operations: [.init(location: .local, kind: .backgroundProcess)], coverageComplete: true, fresh: true)
            guard case .busy = backgroundOnly else { throw CheckFailure(description: "Background operation overlooked") }
        }
        await run("Native warning contract uses distinct Unknown text, exact Busy copy and safe button order") {
            try expect(SwitchingWarning(activity: .idle) == nil, "Idle needs no activity warning")
            try expect(SwitchingWarning(activity: busy)?.message == "Codex has unfinished tasks. Switching accounts may interrupt their execution. Are you sure you want to continue?", "Required Busy text")
            try expect(SwitchingWarning(activity: unknown)?.message.contains("cannot verify") == true, "Unknown warning is separate")
            try expect(SwitchingWarning.cancelTitle == "Cancel" && SwitchingWarning.continueTitle == "Switch Anyway", "Native button contract")
            let cloud = CodexActivityStatus.assess(operations: [.init(location: .cloud, kind: .runningTurn)], coverageComplete: true, fresh: true)
            try expect(SwitchingWarning(activity: cloud)?.detail.contains("continuation is not guaranteed") == true, "Cloud is not a local termination claim or continuation guarantee")
        }
        await run("Idle switches without activity consent and rechecks after preparation") {
            let p = try AccountProfile(name: "Safety test")
            let driver = TestDriver(identity: p.id)
            let checker = ScenarioActivityChecker([.idle])
            let confirmation = TestActivityConfirmation([])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: checker)
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) { await confirmation.confirm($0) }
            try expect(await confirmation.seen.isEmpty, "No Idle warning")
            try expect(await checker.checks == 2, "Fresh check immediately before quit")
            try expect(await coordinator.state == .active(p.id), "Completed test transaction")
        }
        await run("Busy confirmation rechecks after consent and again immediately before quit") {
            let p = try AccountProfile(name: "Safety test")
            let driver = TestDriver(identity: p.id)
            let checker = ScenarioActivityChecker([busy])
            let confirmation = TestActivityConfirmation([true])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: checker)
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) { await confirmation.confirm($0) }
            try expect(await confirmation.seen == [busy], "One consent for unchanged Busy")
            try expect(await checker.checks == 3, "Post-consent and final checks")
            try expect(await driver.events.contains("quit"), "Confirmed graceful quit")
        }
        await run("Busy and Unknown Cancel prevent preparation, quitting and launching") {
            for status in [busy, unknown] {
                let driver = TestDriver(identity: nil)
                let confirmation = TestActivityConfirmation([false])
                let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([status]))
                do {
                    try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                    throw CheckFailure(description: "Cancel ignored")
                } catch SwitchingError.cancelled {}
                try expect(await driver.events == ["validate", "inspect"], "Cancellation before effects")
                try expect(await coordinator.state == .cancelled, "Cancelled state")
            }
        }
        await run("Unknown never bypasses consent even with generic interruption consent or no running process") {
            for running in [true, false] {
                let driver = TestDriver(identity: nil, running: running)
                let coordinator = AccountSwitchingCoordinator(driver: driver)
                do {
                    try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true)
                    throw CheckFailure(description: "Unknown bypassed")
                } catch SwitchingError.cancelled {}
                try expect(await driver.events == ["validate", "inspect"], "Process presence/absence is not activity evidence")
            }
        }
        await run("Conservative Unknown warns on every confirmed switching attempt") {
            let p = try AccountProfile(name: "Safety test")
            let driver = TestDriver(identity: p.id)
            let confirmation = TestActivityConfirmation([true, true])
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            for _ in 0..<2 {
                try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) { await confirmation.confirm($0) }
            }
            try expect(await confirmation.seen == [unknown, unknown], "Consent cannot leak to another switch")
        }
        await run("Activity-check failure becomes Unknown and can be cancelled") {
            let driver = TestDriver(identity: nil)
            let confirmation = TestActivityConfirmation([false])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle], throwsOnCheck: true))
            do {
                try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                throw CheckFailure(description: "Connection error treated as Idle")
            } catch SwitchingError.cancelled {}
            try expect(await confirmation.seen == [.unknown(.checkFailed)], "Failure warning is conservative")
        }
        await run("Busy changing to Unknown while warning is open requires new consent") {
            let driver = TestDriver(identity: nil)
            let confirmation = TestActivityConfirmation([true, false])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([busy, unknown]))
            do {
                try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                throw CheckFailure(description: "Stale consent reused")
            } catch SwitchingError.cancelled {}
            try expect(await confirmation.seen == [busy, unknown], "Changed evidence warned again")
            try expect(await driver.events == ["validate", "inspect"], "No quit after changed evidence")
        }
        await run("Idle changing to Busy during preparation permits cancellation and rollback") {
            let driver = TestDriver(identity: nil)
            let confirmation = TestActivityConfirmation([false])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([.idle, busy]))
            do {
                try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                throw CheckFailure(description: "New work interrupted")
            } catch SwitchingError.cancelled {}
            try expect(await driver.events == ["validate", "inspect", "prepare", "rollback"], "No quit/launch; staging rolled back")
        }
        await run("Increased task count before quit is reconfirmed and rechecked") {
            let p = try AccountProfile(name: "Safety test")
            let driver = TestDriver(identity: p.id)
            let checker = ScenarioActivityChecker([busy, busy, more, more])
            let confirmation = TestActivityConfirmation([true, true])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: checker)
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) { await confirmation.confirm($0) }
            try expect(await confirmation.seen == [busy, more], "New task count needs renewed consent")
            try expect(await checker.checks == 4, "Reconfirmed state checked before quit")
        }
        await run("Work completing after confirmation allows a freshly verified Idle state") {
            let p = try AccountProfile(name: "Safety test")
            let driver = TestDriver(identity: p.id)
            let checker = ScenarioActivityChecker([unknown, .idle])
            let confirmation = TestActivityConfirmation([true])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: checker)
            try await coordinator.switchAccount(to: p, workInterruptionConfirmed: true) { await confirmation.confirm($0) }
            try expect(await confirmation.seen == [unknown], "No repeated warning after verified completion")
            try expect(await checker.checks == 3, "Final fresh Idle check")
        }
        await run("Continuously changing activity aborts instead of reusing stale consent") {
            let driver = TestDriver(identity: nil)
            let confirmation = TestActivityConfirmation([true, true, true])
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: ScenarioActivityChecker([busy, unknown, more, busy]))
            do {
                try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { await confirmation.confirm($0) }
                throw CheckFailure(description: "Unstable activity accepted")
            } catch SwitchingError.activityUnstable {}
            try expect(await driver.events == ["validate", "inspect"], "Bounded retries cannot quit")
        }
        await run("Task cancellation while confirming cannot authorize quit") {
            let driver = TestDriver(identity: nil)
            let coordinator = AccountSwitchingCoordinator(driver: driver)
            let task = Task {
                try await coordinator.switchAccount(to: AccountProfile(name: "Safety test"), workInterruptionConfirmed: true) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            }
            do { try await task.value; throw CheckFailure(description: "Cancelled task continued") }
            catch SwitchingError.cancelled {}
            try expect(await driver.events == ["validate", "inspect"], "No effects after cancelled confirmation")
        }
    }
}
