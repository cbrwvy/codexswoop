import Foundation

public enum EnvironmentEffectDisposition: Sendable, Equatable {
    case notDispatched, mayHaveOccurred, unknown
}

public enum EnvironmentSubmittedEffect: Codable, Sendable, Equatable {
    case activation(DesktopInstance), normalQuit(DesktopInstance), launch, unknown
}

/// Records submission immediately before the native call, after its final receiver checks.
/// Consumption of a capability alone is not evidence that an OS effect was submitted.
public final class EnvironmentDispatchLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDispatched: UUID?
    private var submitted: [EnvironmentSubmittedEffect] = []
    public init() {}
    public func mark(_ operation: UUID, effect: EnvironmentSubmittedEffect = .unknown) {
        lock.lock(); defer { lock.unlock() }
        if lastDispatched != operation { submitted = [] }
        lastDispatched = operation
        submitted.append(effect)
    }
    public func disposition(for operation: UUID) -> EnvironmentEffectDisposition {
        lock.lock(); defer { lock.unlock() }
        return lastDispatched == operation ? .mayHaveOccurred : .notDispatched
    }
    public func effects(for operation: UUID) -> [EnvironmentSubmittedEffect] {
        lock.lock(); defer { lock.unlock() }
        return lastDispatched == operation ? submitted : []
    }
}
