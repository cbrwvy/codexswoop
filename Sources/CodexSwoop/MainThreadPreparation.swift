import Foundation

/// Keeps the original main thread alive while read-only trial preparation awaits.
/// A MainActor task after dispatchMain() is not sufficient for AppKit's thread requirement.
enum MainThreadPreparation {
    @MainActor static func wait<Value>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) throws -> Value {
        precondition(Thread.isMainThread)
        var result: Result<Value, Error>?
        Task { @MainActor in
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
        }
        while result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(Thread.isMainThread)
        return try result!.get()
    }
}
