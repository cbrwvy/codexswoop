import XCTest
import Darwin
@testable import CodexSwoopCore

@MainActor
final class EnvironmentAssociationTests: XCTestCase {
    func testLegacyCatalogUnchangedByManagedLinkAndDisconnect() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root), validator = EnvironmentValidator(managedRoot: root)
        _ = try await store.create(name: "Основной")
        let profiles = try await store.create(name: "Рабочий").profiles
        let bytes = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        let base = root.appendingPathComponent("Profiles/\(profiles[1].directoryIdentifier)")
        for name in ["codex-home", "electron-user-data"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let value = try validator.link(profileID: profiles[1].id, environmentID: profiles[1].id, kind: .managed,
            home: base.appendingPathComponent("codex-home").path, electron: base.appendingPathComponent("electron-user-data").path)
        _ = try await store.linkEnvironment(value, validator: validator)
        let reopened = try await ProfileStore(root: root).inspectAssociations()
        XCTAssertEqual(reopened.associations, [value])
        XCTAssertEqual(ConnectionPresentation.state(association: value), .verificationRequired)
        _ = try await store.disconnectEnvironment(profileID: value.profileID)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: value.codexHome))
        let retained = try await store.inspect().profiles
        XCTAssertEqual(retained, profiles)
    }
    func testFutureSchemaIsNeverRecoverableOver() throws {
        var catalog = AssociationCatalog(); catalog.schemaVersion = 999
        XCTAssertThrowsError(try catalog.validate()) { XCTAssertEqual($0 as? EnvironmentError, .unsupportedSchema) }
    }
    func testProcessOwnershipRequiresBothRootsAndDirectBackend() throws {
        let generation = DesktopGeneration(pid: 123, uid: getuid(), started: "fixture")
        let windowOnly = DesktopProcessEvidence(generation: generation, parent: 1, role: .main, electronDescriptors: 1)
        XCTAssertThrowsError(try DesktopOwnership.resolve(before: [windowOnly], after: [windowOnly], standard: false))
    }
    func testNativeLifecycleGateClosedWithoutInvokingOfficialApplication() {
        XCTAssertFalse(DesktopIntegrationPolicy.lifecycleEnabled)
        XCTAssertFalse(NativeDesktopSystem().lifecycleAllowed)
    }
}
