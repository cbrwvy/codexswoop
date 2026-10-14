import XCTest
@testable import CodexSwoopCore

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testUnicodeNamesAndUUIDPaths() async throws {
        let p = try AccountProfile(name: " ../Рабочий 🚀 ")
        XCTAssertEqual(p.name, "../Рабочий 🚀")
        XCTAssertNotNil(UUID(uuidString: p.directoryIdentifier))
        XCTAssertThrowsError(try AccountProfile(name: "\n"))
        XCTAssertThrowsError(try AccountProfile(name: String(repeating: "a", count: 81)))
    }

    func testPersistenceAndMetadataOnlyRemoval() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let p = try await store.create(name: "Personal").profiles[0]
        _ = try await store.rename(id: p.id, name: "Work")
        let reopened = try await ProfileStore(root: root).load()
        XCTAssertEqual(reopened.profiles[0].name, "Work")
        XCTAssertEqual(reopened.profiles[0].id, p.id)
        _ = try await store.removeRecord(id: p.id)
        let empty = try await store.load()
        XCTAssertTrue(empty.profiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Profiles/\(p.directoryIdentifier)").path))
    }

    func testCorruptionCannotBeOverwritten() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        _ = try await store.create(name: "One")
        _ = try await store.create(name: "Two")
        let file = root.appendingPathComponent("profiles.json")
        let damaged = Data("damaged".utf8)
        try damaged.write(to: file)
        do { _ = try await store.create(name: "Blocked"); XCTFail("Corruption accepted") }
        catch { XCTAssertEqual(error as? ProfileError, .corruptedStore) }
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        let recovered = try await store.recoverBackup()
        XCTAssertEqual(recovered.profiles.map(\.name), ["One"])
    }

    func testLiveSwitchingFailsClosed() async throws {
        let coordinator = AccountSwitchingCoordinator()
        do {
            try await coordinator.switchAccount(to: AccountProfile(name: "Test"), workInterruptionConfirmed: true)
            XCTFail("Live switching must be unavailable")
        } catch { XCTAssertEqual(error as? SwitchingError, .unavailable) }
    }
    func testFailedCommitKeepsExistingCatalog() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let original = try await store.create(name: "Existing")
        let faulty = ProfileStore(root: root, writer: AtomicMetadataWriter { destination in
            if destination.lastPathComponent == "profiles.json" { throw ProfileError.storageUnavailable }
        })
        do { _ = try await faulty.rename(id: original.profiles[0].id, name: "Uncommitted"); XCTFail("Fault ignored") }
        catch { XCTAssertEqual(error as? ProfileError, .storageUnavailable) }
        let reopened = try await store.load()
        XCTAssertEqual(reopened, original)
    }

    func testDuplicateIDsCannotReplaceMetadata() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        var catalog = try await store.create(name: "Existing")
        catalog.profiles.append(catalog.profiles[0])
        let url = root.appendingPathComponent("profiles.json")
        let bytes = try JSONEncoder().encode(catalog)
        try bytes.write(to: url)
        do { _ = try await store.create(name: "Blocked"); XCTFail("Duplicate IDs accepted") }
        catch { XCTAssertEqual(error as? ProfileError, .corruptedStore) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testDiagnosticsDoNotInitializeStorage() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        let catalog = try await ProfileStore(root: root).inspect()
        XCTAssertTrue(catalog.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

}
