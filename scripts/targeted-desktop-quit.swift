// Research-only normal-quit helper. Never linked into CodexSwoop.
// Inspect is read-only. Request requires separately approved, freshly validated metadata.
import AppKit
import Foundation

struct Handle: Codable {
    let pid: Int32
    let launched: Double
}

struct QuitApproval: Decodable {
    let schema: Int
    let authorized: Bool
    let primary: Handle
    let target: Handle
}

enum Refusal: Error { case invalid }
let bundlePath = "/Applications/ChatGPT.app"
let executablePath = bundlePath + "/Contents/MacOS/ChatGPT"
let approvalPath = FileManager.default.currentDirectoryPath + "/build/research/stage24/quit-authorization.json"

func application(_ handle: Handle) throws -> NSRunningApplication {
    guard handle.pid > 0, handle.launched.isFinite,
          let app = NSRunningApplication(processIdentifier: handle.pid),
          !app.isTerminated, app.bundleIdentifier == "com.openai.codex",
          app.bundleURL?.path == bundlePath, app.executableURL?.path == executablePath,
          app.launchDate?.timeIntervalSince1970 == handle.launched else { throw Refusal.invalid }
    return app
}

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 2, args[0] == "inspect", let pid = Int32(args[1]), pid > 0 {
        guard let app = NSRunningApplication(processIdentifier: pid), let date = app.launchDate else {
            throw Refusal.invalid
        }
        _ = try application(Handle(pid: pid, launched: date.timeIntervalSince1970))
        try emit(["pid": pid, "launched": date.timeIntervalSince1970,
                  "bundle_path": bundlePath, "executable_path": executablePath,
                  "terminated": app.isTerminated, "finished_launching": app.isFinishedLaunching])
    } else if args == ["request-approved-normal-quit"] {
        // This file must not exist before the human approves the concrete stage-2.4 operation.
        let approval = try JSONDecoder().decode(QuitApproval.self, from: Data(contentsOf: URL(fileURLWithPath: approvalPath)))
        guard approval.schema == 1, approval.authorized,
              approval.primary.pid != approval.target.pid else { throw Refusal.invalid }
        let primary = try application(approval.primary)
        let target = try application(approval.target)
        guard !target.isEqual(primary) else { throw Refusal.invalid }
        // Consume before delivery. A refused/failed/timed-out request grants no retry.
        try Data("consumed-before-request\n".utf8).write(
            to: URL(fileURLWithPath: approvalPath + ".consumed"), options: [.withoutOverwriting])
        guard try application(approval.primary).isEqual(primary),
              try application(approval.target).isEqual(target) else { throw Refusal.invalid }
        let delivered = target.terminate()
        try emit(["normal_quit_request_sent": delivered])
        guard delivered else { throw Refusal.invalid }
        let deadline = Date().addingTimeInterval(10)
        while !target.isTerminated && Date() < deadline {
            guard try application(approval.primary).isEqual(primary) else { throw Refusal.invalid }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard try application(approval.primary).isEqual(primary) else { throw Refusal.invalid }
        guard target.isTerminated else { throw Refusal.invalid }
        try emit(["target_exited": true, "primary_identity_retained": true,
                  "next_step": "external fresh process/helper/path checks; no automatic launch"])
    } else {
        throw Refusal.invalid
    }
} catch {
    // Never print arbitrary OS errors or application state.
    fputs("STOP: normal-quit helper refused or could not confirm exit; no retry or escalation.\n", stderr)
    exit(1)
}
