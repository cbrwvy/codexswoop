import CodexSwoopCore
import Darwin
import Foundation

@main struct RecoveryCommand {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--detached" {
            args.removeFirst()
            do {
                for _ in 0..<100 where getppid() != 1 { try await Task.sleep(for: .milliseconds(50)) }
                guard getppid() == 1 else { throw OpeningEpochError.unavailable }
                let tool = OpeningEpochRecovery(), result: OpeningEpochReview
                if args == ["--inspect"] { result = try await tool.inspect() }
                else if args.count == 3, args[0] == "--inspect-launch-only", args[1] == "--operation", let id = UUID(uuidString: args[2]) {
                    result = try await tool.inspectLaunchOnly(operationID: id)
                } else {
                    guard args.count == 4, ["--apply", "--retire-launch-only"].contains(args[0]), args[1] == "--consent",
                          args[3] == "--accept-historical-outcome-unknown" else { throw OpeningEpochError.consentRequired }
                    result = args[0] == "--apply"
                        ? try await tool.apply(consent: args[2], acceptingUnknownOutcome: true)
                        : try await tool.retireLaunchOnly(consent: args[2], acceptingUnknownOutcome: true)
                }
                print("storeID=\(result.storeID.uuidString) operationID=\(result.operationID.uuidString) journalSHA256=\(result.journalSHA256)")
                print("consent=\(result.consent)")
                if result.alreadyApplied { print("ALREADY_APPLIED: no metadata changed") }
                else if args.first?.hasPrefix("--inspect") == true { print(result.swoopRunning ? "BLOCKED: Swoop is running; no metadata changed" : "READY: fresh evidence passed; no metadata changed") }
                else { print("APPLIED: new epoch committed; historicalOutcome=unknown; restart only the compatible Swoop with separate permission") }
            } catch { print("BLOCKED: \(error)"); exit(2) }
            return
        }
        if args == ["--help"] {
            print("codexswoop-recovery --inspect")
            print("codexswoop-recovery --apply --consent TOKEN --accept-historical-outcome-unknown")
            print("codexswoop-recovery --inspect-launch-only --operation UUID")
            print("codexswoop-recovery --retire-launch-only --consent TOKEN --accept-historical-outcome-unknown")
            print("Uses only the current user's existing Swoop metadata. Never stops or starts applications.")
            return
        }
        do {
            let applying = args.count == 4 && ["--apply", "--retire-launch-only"].contains(args[0]) && args[1] == "--consent"
                && args[3] == "--accept-historical-outcome-unknown"
            let inspectingLaunch = args.count == 3 && args[0] == "--inspect-launch-only" && args[1] == "--operation" && UUID(uuidString: args[2]) != nil
            guard applying || args == ["--inspect"] || inspectingLaunch else { throw OpeningEpochError.consentRequired }
            // Foundation uses posix_spawn: child execs a fresh runtime. Parent exits
            // without waiting; child requires adoption by launchd before observing.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--detached"] + args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            print("STARTED detached recovery helper; await its READY/BLOCKED/APPLIED output (launch is not completion)")
        } catch { print("BLOCKED: \(error)"); exit(2) }
    }
}
