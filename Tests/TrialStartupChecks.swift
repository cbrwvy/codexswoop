import Foundation

// Standalone physical-main-thread regression check; no AppKit or real processes.
@main struct TrialStartupChecks {
    enum FixtureError: Error { case rejected }

    @MainActor static func main() throws {
        precondition(Thread.isMainThread)
        let value = try MainThreadPreparation.wait {
            try await Task.sleep(for: .milliseconds(20))
            return 42
        }
        precondition(value == 42 && Thread.isMainThread)
        do {
            let _: Int = try MainThreadPreparation.wait {
                try await Task.sleep(for: .milliseconds(20))
                throw FixtureError.rejected
            }
            fatalError("Preparation errors must prevent GUI startup")
        } catch FixtureError.rejected {
            precondition(Thread.isMainThread)
        }
        print("PASS: async success resumes on original main thread; failure propagates before GUI startup")
    }
}
