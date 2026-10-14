import Foundation

public enum AccountSwitchingStrategy: Equatable, Sendable { case restart, launch, activate }

/// No titles, accessibility text or screenshots. A future native adapter must prove every window's
/// ownership using the retained native process handle; matching a shared bundle identifier is insufficient.
public struct DesktopActivationEvidence: Equatable, Sendable {
    public let association: EnvironmentAssociation
    public let instance: DesktopInstance
    public let windowIDs: Set<UInt32>
    public let windowOwners: Set<DesktopGeneration>
    public let ownershipConfirmed: Bool
    public let observedAt: Date
    public let windowToken: UUID?
    public init(association: EnvironmentAssociation, instance: DesktopInstance, windowIDs: Set<UInt32>,
                windowOwners: Set<DesktopGeneration>, ownershipConfirmed: Bool, observedAt: Date = Date(), windowToken: UUID? = nil) {
        self.association = association; self.instance = instance; self.windowIDs = windowIDs
        self.windowOwners = windowOwners; self.ownershipConfirmed = ownershipConfirmed; self.observedAt = observedAt; self.windowToken = windowToken
    }
    public func validate(association: EnvironmentAssociation, instance: DesktopInstance, now: Date = Date()) throws {
        guard self.association == association, self.instance == instance, ownershipConfirmed,
              !windowIDs.isEmpty, !windowIDs.contains(0), windowOwners == [instance.main],
              observedAt <= now, now.timeIntervalSince(observedAt) <= 5 else { throw EnvironmentError.activationUnavailable }
    }
}
