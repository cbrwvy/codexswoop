import Foundation

/// Technical build evidence only; no account, environment or authorization data.
public struct OpeningBuildFingerprint: Codable, Equatable, Sendable {
    public let policyRevision: UInt64
    public let version: String
    public let build: String
    public let signingRequirement: String
    public let archiveSHA256: String
    public let codeDirectoryHash: String
    public let bundleGenerationSHA256: String
    public init(policyRevision: UInt64 = 1, version: String, build: String, signingRequirement: String,
                archiveSHA256: String, codeDirectoryHash: String, bundleGenerationSHA256: String) {
        self.policyRevision = policyRevision; self.version = version; self.build = build
        self.signingRequirement = signingRequirement; self.archiveSHA256 = archiveSHA256
        self.codeDirectoryHash = codeDirectoryHash; self.bundleGenerationSHA256 = bundleGenerationSHA256
    }
    public func validate() throws {
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard policyRevision > 0, [version, build, signingRequirement].allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
              hex(archiveSHA256, count: 64), hex(bundleGenerationSHA256, count: 64),
              hex(codeDirectoryHash, count: 40) || hex(codeDirectoryHash, count: 64) else { throw OpeningJournalError.invalid }
    }
}
