import XCTest
@testable import CodexSwoopCore

@MainActor
final class AccountSetupTests: XCTestCase {
    private func qaRoot() -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func committed(_ outcome: AccountSetupOutcome) throws -> AccountSetupState {
        guard case let .committed(state) = outcome else { XCTFail("Unexpected partial transaction"); throw AccountSetupError.recoveryRequired }
        return state
    }
    func testNewManagedAccountHasEmptyIndependentRootsAndReloads() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let preview = try await f.store.previewNewAccount(name: "New Fixture", managed: true, validator: f.validator)
        let state = try committed(await f.store.commitAccountSetup(preview))
        let association = try XCTUnwrap(state.associations.associations.last)
        XCTAssertFalse(f.profiles.contains { $0.id == association.profileID })
        for path in [association.codexHome, association.electronData] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        }
        let reopened = try await ProfileStore(root: f.validator.managedRoot).inspectAccountSetup()
        XCTAssertEqual(reopened, state)
    }
    func testUseExistingAccountLinksOnlyExplicitSyntheticStandardRoots() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let home = f.validator.userHome.appendingPathComponent(".codex")
        let electron = f.validator.userHome.appendingPathComponent("Library/Application Support/Codex")
        for path in [home, electron] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let preview = try await f.store.previewNewAccount(name: "Existing Fixture", managed: false, validator: f.validator)
        let state = try committed(await f.store.commitAccountSetup(preview))
        let association = try XCTUnwrap(state.associations.associations.last)
        XCTAssertEqual(association.kind, .standardExternal)
        XCTAssertEqual(association.codexHome, home.path)
        XCTAssertEqual(association.electronData, electron.path)
        let effects = await f.system.effects
        XCTAssertTrue(effects.isEmpty)
    }
    func testRemoveRetainsEnvironmentAndRestorePreservesUUID() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let association = f.associations[1]
        let sentinel = URL(fileURLWithPath: association.codexHome).appendingPathComponent("fixture-sentinel")
        try Data("fictional payload".utf8).write(to: sentinel)
        let preview = try await f.store.previewProfileRemoval(id: f.profiles[1].id)
        let removed = try committed(await f.store.commitAccountSetup(preview))
        XCTAssertEqual(removed.profiles.profiles, [f.profiles[0]])
        XCTAssertEqual(removed.retained.environments.map(\.association), [association])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("fictional payload".utf8))
        let restore = try await f.store.previewSavedManagedRestore(environmentID: association.environmentID)
        let restored = try committed(await f.store.commitAccountSetup(restore))
        XCTAssertEqual(restored.profiles.profiles, f.profiles)
        XCTAssertEqual(restored.associations.associations, f.associations)
    }
    func testResetClearsSavedRowsWithoutChangingActiveFilesOrDirectories() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        _ = try await f.store.removeRecord(id: f.profiles[1].id)
        let names = ["profiles.json", "environments.json", "managed-environments.json"]
        let bytes = try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }
        let preview = try await f.store.previewAccountSetupReset()
        let state = try committed(await f.store.commitAccountSetup(preview))
        XCTAssertTrue(state.retained.environments.isEmpty)
        XCTAssertEqual(state.profiles, preview.before.profiles)
        XCTAssertEqual(state.associations, preview.before.associations)
        XCTAssertEqual(state.managed, preview.before.managed)
        XCTAssertEqual(try names.map { try Data(contentsOf: f.validator.managedRoot.appendingPathComponent($0)) }, bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.associations[1].codexHome))
    }
    func testStaleRemovalPreviewCannotRemoveRenamedProfile() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let preview = try await f.store.previewProfileRemoval(id: f.profiles[1].id)
        _ = try await f.store.rename(id: f.profiles[1].id, name: "Changed")
        do { _ = try await f.store.commitAccountSetup(preview); XCTFail("Stale preview committed") }
        catch { XCTAssertEqual(error as? AccountSetupError, .conflict) }
        let current = try await f.store.inspect()
        XCTAssertEqual(current.profiles.count, 2)
        XCTAssertEqual(current.profiles[1].name, "Changed")
    }
    func testBackupFailurePreventsActiveWritesAndJournal() async throws {
        let f = try await ReleaseFixture.make(root: qaRoot())
        let faulty = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { path in
            if path.lastPathComponent == "snapshot.json" { throw ProfileError.storageUnavailable }
        })
        let preview = try await faulty.previewProfileRemoval(id: f.profiles[1].id)
        do { _ = try await faulty.commitAccountSetup(preview); XCTFail("Missing backup accepted") }
        catch { XCTAssertEqual(error as? AccountSetupError, .backupFailed) }
        let current = try await f.store.inspectAccountSetup(), pending = try await f.store.inspectPendingAccountSetup()
        XCTAssertEqual(current, preview.before)
        XCTAssertNil(pending)
    }
    func testPartialWriteRequiresExplicitRecoveryAfterReopen() async throws {
        let root = qaRoot()
        for decision in [AccountSetupRecovery.finish, .restorePrevious] {
            let f = try await ReleaseFixture.make(root: root.appendingPathComponent(decision.rawValue))
            let faulty = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { path in
                if path == f.validator.managedRoot.appendingPathComponent("environments.json") { throw ProfileError.storageUnavailable }
            })
            let preview = try await faulty.previewProfileRemoval(id: f.profiles[1].id)
            let outcome = try await faulty.commitAccountSetup(preview)
            XCTAssertEqual(outcome, .reviewRequired)
            do { _ = try await f.store.create(name: "Blocked"); XCTFail("Mutation during recovery") }
            catch { XCTAssertEqual(error as? AccountSetupError, .recoveryRequired) }
            let reopened = ProfileStore(root: f.validator.managedRoot)
            let pending = try await reopened.inspectPendingAccountSetup()
            XCTAssertEqual(pending?.id, preview.id)
            let restored = try committed(await reopened.recoverAccountSetup(id: preview.id, decision: decision))
            XCTAssertEqual(restored, decision == .finish ? preview.after : preview.before)
            let remaining = try await reopened.inspectPendingAccountSetup()
            XCTAssertNil(remaining)
        }
    }
}
