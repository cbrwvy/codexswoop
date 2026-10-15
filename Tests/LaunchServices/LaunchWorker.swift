import AppKit
import Foundation

/// Disposable QA parent with an original physical AppKit main thread. Never addresses Codex.
@main struct LaunchWorker {
    static func trace(_ stage: String) {
        FileHandle.standardError.write(Data(("LaunchWorker: " + stage + " mainThread=\(Thread.isMainThread)\n").utf8))
    }
    @MainActor static func main() {
        do { try run() }
        catch {
            let error = error as NSError
            trace("failure domain=\(error.domain) code=\(error.code)")
            exit(10)
        }
    }
    @MainActor static func run() throws {
        trace("entry mainThread=\(Thread.isMainThread)")
        precondition(Thread.isMainThread)
        let args = CommandLine.arguments
        guard args.count == 5, args[1].hasPrefix("/private/tmp/codexswoop-p0-"),
              args[1].hasSuffix("/Probe.app"), args[2].hasPrefix("/private/tmp/csp0-"),
              args[3].hasPrefix("/private/tmp/csp0-"), args[4].hasPrefix("/private/tmp/codexswoop-p0-") else { exit(2) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        trace("application initialized")
        let receiver = try MainThreadPreparation.wait {
            trace("request")
            return try await LaunchServicesRequest.open(URL(fileURLWithPath: args[1]), arguments: ["--user-data-dir=" + args[3]],
                environment: ["PATH": "/usr/bin:/bin", "CODEX_HOME": args[2], "CODEX_ELECTRON_USER_DATA_PATH": args[3]])
        }
        trace("receiver returned")
        guard let native = NSRunningApplication(processIdentifier: receiver.0) else {
            trace("receiver unavailable before verification"); exit(3)
        }
        guard native.bundleURL?.path == args[1], native.launchDate == receiver.1 else { exit(3) }
        let report: [String: Any] = ["pid": receiver.0, "launchDate": receiver.1.timeIntervalSince1970, "bundle": native.bundleURL!.path]
        try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: args[4]))
        try Data().write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("receiver-verified"))
        let deadline = Date().addingTimeInterval(3)
        while !native.isTerminated && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard native.isTerminated else { exit(4) }
    }
}
