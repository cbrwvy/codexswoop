import Foundation

/// Prepared empty storage is not a connected account or an enrollment permission.
public struct ManagedEnvironmentCatalog: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision: UInt64 = 0
    public var prepared: [EnvironmentAssociation] = []
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw EnvironmentError.unsupportedSchema }
        guard prepared.allSatisfy({ $0.kind == .managed && $0.environmentID == $0.profileID }) else {
            throw EnvironmentError.invalidMetadata
        }
        var catalog = AssociationCatalog(); catalog.associations = prepared
        try catalog.validate()
    }
}
