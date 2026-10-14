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
                else {
                    guard args.count == 4, args[0] == "--apply", args[1] == "--consent",
                          args[3] == "--accept-historical-outcome-unknown" else { throw OpeningEpochError.consentRequired }
                    result = try await tool.apply(consent: args[2], acceptingUnknownOutcome: true)
                }
                print("storeID=\(result.storeID.uuidString) operationID=\(result.operationID.uuidString) journalSHA256=\(result.journalSHA256)")
                print("consent=\(result.consent)")
                if result.alreadyApplied { print("ALREADY_APPLIED: no metadata changed") }
                else if args == ["--inspect"] { print(result.swoopRunning ? "BLOCKED: Swoop is running; no metadata changed" : "READY: fresh evidence passed; no metadata changed") }
                else { print("APPLIED: new epoch committed; historicalOutcome=unknown; restart only the compatible Swoop with separate permission") }
            } catch { print("BLOCKED: \(error)"); exit(2) }
            return
        }
        if args == ["--help"] {
            print("codexswoop-recovery --inspect")
            print("codexswoop-recovery --apply --consent TOKEN --accept-historical-outcome-unknown")
            print("Uses only the current user's existing Swoop metadata. Never stops or starts applications.")
            return
        }
        do {
            let applying = args.count == 4 && args[0] == "--apply" && args[1] == "--consent"
                && args[3] == "--accept-historical-outcome-unknown"
            guard applying || args == ["--inspect"] else { throw OpeningEpochError.consentRequired }
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
