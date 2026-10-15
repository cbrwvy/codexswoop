import AppKit
import Foundation

/// Shared request implementation, also compiled into the physical-main-thread QA worker.
/// Publisher/root/receiver authorization stays in NativeDesktopSystem.
enum LaunchServicesRequest {
    @MainActor static func open(_ app: URL, arguments: [String], environment: [String: String]) async throws -> (Int32, Date) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        configuration.environment = environment
        return try await withCheckedThrowingContinuation { continuation in
            let completion = LaunchServicesCompletion(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                completion.finish(.failure(NSError(domain: "CodexSwoop.LaunchServices", code: -1001)))
            }
            // AppKit calls this on a concurrent queue. Older SDK imports otherwise
            // let the closure inherit MainActor and trap before its body executes.
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { @Sendable running, error in
                guard error == nil, let running, !running.isTerminated, let date = running.launchDate else {
                    completion.finish(.failure(NSError(domain: "CodexSwoop.LaunchServices", code: (error as NSError?)?.code ?? -1)))
                    return
                }
                completion.finish(.success((running.processIdentifier, date)))
            }
        }
    }
}

private final class LaunchServicesCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Int32, Date), any Error>?
    init(_ continuation: CheckedContinuation<(Int32, Date), any Error>) { self.continuation = continuation }
    func finish(_ result: Result<(Int32, Date), any Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
