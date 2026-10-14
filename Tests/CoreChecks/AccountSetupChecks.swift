import Foundation
import Darwin
import CodexSwoopCore

private struct ActiveSetupFile: Equatable {
    let data: Data?
    let inode: UInt64?
    let modified: Date?
}

extension CoreChecks {
    @MainActor static func accountSetupChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        func scenario(_ name: String, _ body: @escaping @MainActor (OpeningFixture) async throws -> Void) async {
            await run("Account setup: " + name) {
                let f = try await OpeningFixture.make(base.appendingPathComponent(UUID().uuidString), primary: true)
                for a in f.f.associations {
                    for path in [a.codexHome, a.electronData] { try Data("synthetic authorization sentinel".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("fixture-auth-sentinel")) }
                }
                try await body(f)
                for a in f.f.associations {
                    for path in [a.codexHome, a.electronData] {
                        try expect(try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("fixture-auth-sentinel")) == Data("synthetic authorization sentinel".utf8), "Original environment/data untouched")
                    }
                }
                try expect(await f.system.effects.isEmpty, "Profile setup never invokes desktop lifecycle")
            }
        }
        func committed(_ outcome: AccountSetupOutcome) throws -> AccountSetupState {
            guard case let .committed(state) = outcome else { throw CheckFailure(description: "Unexpected review-required outcome") }
            return state
        }
        for index in [0, 1] {
            await scenario(index == 0 ? "remove linked Standard External" : "remove linked Managed") { f in
                let original = try await f.f.store.inspectAccountSetup(), profile = f.f.profiles[index]
                let preview = try await f.f.store.previewProfileRemoval(id: profile.id)
                try expect(preview.before == original && preview.removedProfiles == [profile], "Fresh exact UUID/catalog preview")
                let state = try committed(await f.f.store.commitAccountSetup(preview))
                try expect(state.profiles.profiles == [f.f.profiles[1-index]], "Other profile unchanged")
                try expect(state.associations.associations == [f.f.associations[1-index]], "Other active association unchanged")
                try expect(state.retained.environments.contains(where: { $0.profile == profile && $0.association == f.f.associations[index] && $0.status == "Retained · not linked" }), "Saved reference retained")
                try expect(try await ProfileStore(root: f.f.validator.managedRoot).inspectAccountSetup() == state, "Restart persistence")
                try expect(try await f.f.store.inspectPendingAccountSetup() == nil, "Completed journal removed")
            }
        }
        await scenario("remove last profile and add again with new UUID") { f in
            for profile in f.f.profiles { _ = try await f.f.store.removeRecord(id: profile.id) }
            let empty = try await f.f.store.inspectAccountSetup()
            try expect(empty.profiles.profiles.isEmpty && empty.associations.associations.isEmpty && empty.managed.prepared.isEmpty, "Clean active empty state")
            let preview = try await f.f.store.previewNewAccount(name: "Primary", managed: false, validator: f.f.validator)
            let state = try committed(await f.f.store.commitAccountSetup(preview))
            try expect(state.profiles.profiles.count == 1 && !f.f.profiles.contains(where: { $0.id == state.profiles.profiles[0].id }), "New profile UUID")
            try expect(state.associations.associations[0].codexHome == f.f.associations[0].codexHome, "Existing defaults relinked, no login/move")
        }
        await scenario("remove unlinked profile") { f in
            let profile = try await f.f.store.create(name: "Unlinked").profiles.last!
            _ = try await f.f.store.removeRecord(id: profile.id)
            try expect(try await f.f.store.inspect().profiles == f.f.profiles, "Only unlinked record removed")
        }
        func activeFiles(_ root: URL) throws -> [String: ActiveSetupFile] {
            var result: [String: ActiveSetupFile] = [:]
            for name in ["profiles.json", "profiles.backup.json", "environments.json", "environments.backup.json", "managed-environments.json", "managed-environments.backup.json"] {
                let path = root.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: path.path)
                result[name] = ActiveSetupFile(data: try? Data(contentsOf: path),
                    inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
                    modified: attributes?[.modificationDate] as? Date)
            }
            return result
        }
        await scenario("clear saved records preserves active catalogs and exact file generations") { f in
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let before = try await f.f.store.inspectAccountSetup()
            let bytes = try activeFiles(f.f.validator.managedRoot)
            let preview = try await f.f.store.previewAccountSetupReset()
            try expect(preview.removedProfiles.isEmpty && preview.removedSavedEnvironmentCount == 1, "Only the saved row is selected")
            let state = try committed(await f.f.store.commitAccountSetup(preview))
            try expect(state.profiles == before.profiles && state.associations == before.associations && state.managed == before.managed, "Active UUIDs, names, links and revisions unchanged")
            try expect(state.retained.environments.isEmpty, "Saved row removed rather than active records archived")
            try expect(try activeFiles(f.f.validator.managedRoot) == bytes, "Active files and backups retain bytes, inode and modification date")
            let backup = f.f.validator.managedRoot.appendingPathComponent("SetupBackups/\(preview.id.uuidString.lowercased())/snapshot.json")
            try expect(fm.fileExists(atPath: backup.path) && (try Data(contentsOf: backup)).count > 100, "Verified complete snapshot persisted")
            try expect(try await ProfileStore(root: f.f.validator.managedRoot).inspectAccountSetup() == state, "Cleared list survives restart")
            do { _ = try await f.f.store.previewSavedManagedRestore(environmentID: f.target.id); throw CheckFailure(description: "Cleared row was still restorable") }
            catch AccountSetupError.incompatibleEnvironment {}
        }
        await scenario("empty saved list is a no-op with two active profiles") { f in
            let before = try await f.f.store.inspectAccountSetup(), bytes = try activeFiles(f.f.validator.managedRoot)
            let preview = try await f.f.store.previewAccountSetupReset()
            let after = try committed(await f.f.store.commitAccountSetup(preview))
            try expect(preview.removedSavedEnvironmentCount == 0 && after == before, "No active reset or revision increment")
            try expect(try activeFiles(f.f.validator.managedRoot) == bytes, "No active file replacement")
        }
        await scenario("clear multiple saved rows with two active profiles and repeat") { f in
            for name in ["Saved one", "Saved two"] {
                let add = try await f.f.store.previewNewAccount(name: name, managed: true, validator: f.f.validator)
                let state = try committed(await f.f.store.commitAccountSetup(add))
                _ = try await f.f.store.removeRecord(id: state.profiles.profiles.last!.id)
            }
            let before = try await f.f.store.inspectAccountSetup(), bytes = try activeFiles(f.f.validator.managedRoot)
            let preview = try await f.f.store.previewAccountSetupReset()
            let after = try committed(await f.f.store.commitAccountSetup(preview))
            try expect(preview.removedSavedEnvironmentCount == 2 && after.retained.environments.isEmpty, "Both saved rows cleared")
            try expect(after.profiles == before.profiles && after.profiles.profiles == f.f.profiles && after.associations == before.associations && after.managed == before.managed, "Both active profiles unchanged")
            let repeated = try await f.f.store.previewAccountSetupReset()
            try expect(try committed(await f.f.store.commitAccountSetup(repeated)) == after, "Repeated clear is a no-op")
            try expect(try activeFiles(f.f.validator.managedRoot) == bytes, "No active writes in either clear")
        }
        await scenario("clearing saved Managed rows preserves other retained references") { f in
            for profile in f.f.profiles { _ = try await f.f.store.removeRecord(id: profile.id) }
            let before = try await f.f.store.inspectAccountSetup()
            let preview = try await f.f.store.previewAccountSetupReset()
            let after = try committed(await f.f.store.commitAccountSetup(preview))
            try expect(after.retained.environments == before.retained.environments.filter { $0.association.kind != .managed }, "Only rows displayed in Settings are cleared")
            try expect(after.profiles == before.profiles && after.associations == before.associations && after.managed == before.managed, "Empty active catalogs unchanged")
        }
        await scenario("saved restore retains original Managed UUID and metadata") { f in
            let before = try await f.f.store.inspectAccountSetup()
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let restore = try await f.f.store.previewSavedManagedRestore(environmentID: f.target.id)
            let restored = try committed(await f.f.store.commitAccountSetup(restore))
            try expect(restored.profiles.profiles == before.profiles.profiles, "Original UUID/name/dates restored")
            let reference = before.associations.associations.first { $0.profileID == f.target.id }!
            try expect(restored.associations.associations.count == before.associations.associations.count &&
                restored.associations.associations.allSatisfy { before.associations.associations.contains($0) } &&
                restored.managed.prepared == [reference], "Original association restored and Managed registry coherent")
        }
        await scenario("concurrent active rename conflicts with saved clear preview") { f in
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let preview = try await f.f.store.previewAccountSetupReset()
            _ = try await f.f.store.rename(id: f.f.profiles[0].id, name: "Still active")
            let changed = try await f.f.store.inspectAccountSetup()
            do { _ = try await f.f.store.commitAccountSetup(preview); throw CheckFailure(description: "Stale clear accepted") }
            catch AccountSetupError.conflict {}
            try expect(try await f.f.store.inspectAccountSetup() == changed, "Concurrent active change preserved")
        }
        for decision in [AccountSetupRecovery.finish, .restorePrevious] {
            await scenario("saved clear partial write and " + decision.rawValue) { f in
                _ = try await f.f.store.removeRecord(id: f.target.id)
                let root = f.f.validator.managedRoot, bytes = try activeFiles(f.f.validator.managedRoot)
                let faulty = ProfileStore(root: root, writer: AtomicMetadataWriter { path in
                    if path == root.appendingPathComponent("retained-environments.backup.json") { throw ProfileError.storageUnavailable }
                })
                let preview = try await faulty.previewAccountSetupReset()
                try expect(try await faulty.commitAccountSetup(preview) == .reviewRequired, "Unfinished clear is not success")
                try expect(try activeFiles(root) == bytes, "Active files untouched during interruption")
                let reopened = ProfileStore(root: root)
                let state = try committed(await reopened.recoverAccountSetup(id: preview.id, decision: decision))
                try expect(state == (decision == .finish ? preview.after : preview.before), "Saved list explicitly reconciled")
                try expect(try activeFiles(root) == bytes, "Active files untouched during either recovery")
            }
        }
        await scenario("legacy reset journal retains its original reviewed recovery meaning") { f in
            let root = f.f.validator.managedRoot
            let faulty = ProfileStore(root: root, writer: AtomicMetadataWriter { path in
                if path == root.appendingPathComponent("environments.json") { throw ProfileError.storageUnavailable }
            })
            let preview = try await faulty.previewProfileRemoval(id: f.target.id)
            try expect(try await faulty.commitAccountSetup(preview) == .reviewRequired, "Fixture durable intent")
            // Model an already-approved old reset journal, not a new reset request.
            for path in [root.appendingPathComponent("setup-journal.json"),
                         root.appendingPathComponent("SetupBackups/\(preview.id.uuidString.lowercased())/snapshot.json")] {
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                object["operation"] = "reset"
                try AtomicMetadataWriter().write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: path)
            }
            let reopened = ProfileStore(root: root)
            try expect(try await reopened.inspectPendingAccountSetup()?.operation == "reset", "Old operation stays explicit")
            let recovered = try committed(await reopened.recoverAccountSetup(id: preview.id, decision: .finish))
            try expect(recovered == preview.after, "Recovery applies old verified bytes, never reinterprets as saved-list clear")
        }
        await scenario("cancel preview does not change metadata") { f in
            let before = try await f.f.store.inspectAccountSetup()
            _ = try await f.f.store.previewProfileRemoval(id: f.target.id)
            _ = try await f.f.store.previewAccountSetupReset()
            try expect(try await f.f.store.inspectAccountSetup() == before, "No commit without user consent")
            try expect(!fm.fileExists(atPath: f.f.validator.managedRoot.appendingPathComponent("SetupBackups").path), "No destructive-preview writes")
        }
        await scenario("concurrent rename conflicts with confirmed preview") { f in
            let preview = try await f.f.store.previewProfileRemoval(id: f.target.id)
            _ = try await ProfileStore(root: f.f.validator.managedRoot).rename(id: f.target.id, name: "Changed")
            do { _ = try await f.f.store.commitAccountSetup(preview); throw CheckFailure(description: "Stale preview accepted") }
            catch AccountSetupError.conflict {}
            try expect(try await f.f.store.inspect().profiles.count == 2, "No removal after concurrent change")
        }
        await scenario("identical bytes with changed inode conflict") { f in
            let preview = try await f.f.store.previewProfileRemoval(id: f.target.id)
            let path = f.f.validator.managedRoot.appendingPathComponent("environments.json")
            try AtomicMetadataWriter().write(Data(contentsOf: path), to: path)
            do { _ = try await f.f.store.commitAccountSetup(preview); throw CheckFailure(description: "Changed filesystem generation accepted") }
            catch AccountSetupError.conflict {}
        }
        await scenario("repeat commit and removed UUID are rejected") { f in
            let preview = try await f.f.store.previewProfileRemoval(id: f.target.id)
            _ = try await f.f.store.commitAccountSetup(preview)
            do { _ = try await f.f.store.commitAccountSetup(preview); throw CheckFailure(description: "Repeat accepted") }
            catch AccountSetupError.conflict {}
            try await expectError(.missingProfile) { _ = try await f.f.store.removeRecord(id: f.target.id) }
        }
        await scenario("backup failure makes no active writes") { f in
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let before = try await f.f.store.inspectAccountSetup()
            let faulty = ProfileStore(root: f.f.validator.managedRoot, writer: AtomicMetadataWriter { path in
                if path.lastPathComponent == "snapshot.json" { throw ProfileError.storageUnavailable }
            })
            let preview = try await faulty.previewAccountSetupReset()
            do { _ = try await faulty.commitAccountSetup(preview); throw CheckFailure(description: "Missing backup accepted") }
            catch AccountSetupError.backupFailed {}
            try expect(try await f.f.store.inspectAccountSetup() == before, "No active change")
            try expect(try await f.f.store.inspectPendingAccountSetup() == nil, "No intent")
        }
        for decision in [AccountSetupRecovery.finish, .restorePrevious] {
            await scenario("partial multi-file write and explicit " + decision.rawValue) { f in
                let root = f.f.validator.managedRoot
                let faulty = ProfileStore(root: root, writer: AtomicMetadataWriter { path in
                    if path == root.appendingPathComponent("environments.json") { throw ProfileError.storageUnavailable }
                })
                let preview = try await faulty.previewProfileRemoval(id: f.target.id)
                try expect(try await faulty.commitAccountSetup(preview) == .reviewRequired, "Partial write is not success")
                do { _ = try await f.f.store.inspect(); throw CheckFailure(description: "Inconsistent read allowed") }
                catch AccountSetupError.recoveryRequired {}
                do { _ = try await f.f.store.create(name: "No retry"); throw CheckFailure(description: "Mutation during recovery") }
                catch AccountSetupError.recoveryRequired {}
                let reopened = ProfileStore(root: root), pending = try await reopened.inspectPendingAccountSetup()
                try expect(pending?.id == preview.id, "Restart discovers exact journal")
                let state = try committed(await reopened.recoverAccountSetup(id: preview.id, decision: decision))
                try expect(state == (decision == .finish ? preview.after : preview.before), "Whole coherent set reconciled")
                try expect(try await reopened.inspectPendingAccountSetup() == nil, "Journal cleared only after verification")
                do { _ = try await reopened.recoverAccountSetup(id: preview.id, decision: decision); throw CheckFailure(description: "Repeated recovery") }
                catch AccountSetupError.conflict {}
            }
        }
        for tamper in ["current", "backup"] {
            await scenario("recovery refuses changed " + tamper) { f in
                let root = f.f.validator.managedRoot
                let faulty = ProfileStore(root: root, writer: AtomicMetadataWriter { path in
                    if path == root.appendingPathComponent("environments.json") { throw ProfileError.storageUnavailable }
                })
                let preview = try await faulty.previewProfileRemoval(id: f.target.id)
                _ = try await faulty.commitAccountSetup(preview)
                let url = tamper == "current" ? root.appendingPathComponent("environments.json")
                    : root.appendingPathComponent("SetupBackups/\(preview.id.uuidString.lowercased())/snapshot.json")
                try AtomicMetadataWriter().write(Data("foreign bytes".utf8), to: url)
                do { _ = try await f.f.store.inspectPendingAccountSetup(); throw CheckFailure(description: "Tampered recovery accepted") }
                catch AccountSetupError.invalidJournal {} catch ProfileError.storageUnavailable {}
                try expect(fm.fileExists(atPath: root.appendingPathComponent("setup-journal.json").path), "Journal/data preserved")
            }
        }
        await scenario("invalid or incomplete new name leaves setup unchanged") { f in
            let before = try await f.f.store.inspectAccountSetup()
            for name in ["", "   ", String(repeating: "W", count: 81)] {
                do {
                    _ = try await f.f.store.previewNewAccount(name: name, managed: true, validator: f.f.validator)
                    throw CheckFailure(description: "Invalid new profile name accepted")
                } catch ProfileError.invalidName {}
            }
            try expect(try await f.f.store.inspectAccountSetup() == before, "No partial profile or association")
        }
        await scenario("missing standard roots never select another environment") { f in
            _ = try await f.f.store.removeRecord(id: f.f.profiles[0].id)
            let before = try await f.f.store.inspectAccountSetup()
            let path = URL(fileURLWithPath: f.f.associations[0].codexHome)
            let moved = path.deletingLastPathComponent().appendingPathComponent("temporarily-unavailable")
            try fm.moveItem(at: path, to: moved)
            defer { try? fm.moveItem(at: moved, to: path) }
            do {
                _ = try await f.f.store.previewNewAccount(name: "Default", managed: false, validator: f.f.validator)
                throw CheckFailure(description: "Selected another environment instead of defaults")
            } catch EnvironmentError.missingDirectory {}
            try expect(try await f.f.store.inspectAccountSetup() == before, "Unavailable standard setup is read-only")
        }
        await scenario("duplicate default binding refused") { f in
            do { _ = try await f.f.store.previewNewAccount(name: "Duplicate", managed: false, validator: f.f.validator)
                throw CheckFailure(description: "Duplicate environment accepted")
            } catch EnvironmentError.duplicateAssociation {}
            try expect(try await f.f.store.inspect().profiles == f.f.profiles, "No extra profile")
        }
        await scenario("fresh Managed uses new UUID and empty roots") { f in
            let preview = try await f.f.store.previewNewAccount(name: "Another", managed: true, validator: f.f.validator)
            let state = try committed(await f.f.store.commitAccountSetup(preview))
            let reference = state.associations.associations.last!
            try expect(!f.f.profiles.contains(where: { $0.id == reference.profileID }) && reference.environmentID == reference.profileID, "Independent UUID")
            for root in [reference.codexHome, reference.electronData] {
                try expect(try fm.contentsOfDirectory(atPath: root).isEmpty, "No copied auth or history")
            }
            try f.f.validator.revalidate(reference)
        }
        await scenario("managed restore refuses reused UUID and changed directory identity") { f in
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let preview = try await f.f.store.previewSavedManagedRestore(environmentID: f.target.id)
            _ = try await f.f.store.commitAccountSetup(preview)
            do { _ = try await f.f.store.previewSavedManagedRestore(environmentID: f.target.id); throw CheckFailure(description: "Repeat restore") }
            catch AccountSetupError.incompatibleEnvironment {} catch AccountSetupError.alreadyRestored {}
            _ = try await f.f.store.removeRecord(id: f.target.id)
            chmod(f.f.associations[1].codexHome, 0o777)
            do { _ = try await f.f.store.previewSavedManagedRestore(environmentID: f.target.id); throw CheckFailure(description: "Unsafe restore") }
            catch EnvironmentError.unsafeDirectory {}
            chmod(f.f.associations[1].codexHome, 0o700)
        }
        await scenario("new association directory changes before commit") { f in
            let preview = try await f.f.store.previewNewAccount(name: "Fresh", managed: true, validator: f.f.validator)
            let reference = preview.after.associations.associations.last!
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reference.codexHome)
            do { _ = try await f.f.store.commitAccountSetup(preview); throw CheckFailure(description: "Changed environment accepted") }
            catch EnvironmentError.changedDirectory {} catch EnvironmentError.unsafeDirectory {}
            try expect(try await f.f.store.inspectAccountSetup() == preview.before, "No metadata write for changed roots")
        }
        await scenario("intent write failure makes no active changes") { f in
            let faulty = ProfileStore(root: f.f.validator.managedRoot, writer: AtomicMetadataWriter { path in
                if path.lastPathComponent == "setup-journal.json" { throw ProfileError.storageUnavailable }
            })
            let preview = try await faulty.previewAccountSetupReset()
            do { _ = try await faulty.commitAccountSetup(preview); throw CheckFailure(description: "Missing intent accepted") }
            catch AccountSetupError.writeFailed {}
            try expect(try await f.f.store.inspectAccountSetup() == preview.before, "No metadata writes without journal")
        }
        await scenario("cancelled commit leaves exact previous state") { f in
            _ = try await f.f.store.removeRecord(id: f.target.id)
            let preview = try await f.f.store.previewAccountSetupReset()
            let task = Task { () throws -> AccountSetupOutcome in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.f.store.commitAccountSetup(preview)
            }
            do { _ = try await task.value; throw CheckFailure(description: "Cancelled mutation") } catch is CancellationError {}
            try expect(try await f.f.store.inspectAccountSetup() == preview.before, "No cancellation side effect")
        }
        await run("Account setup: full removal/re-add and both opening strategies with synthetic processes") {
            let f = try await OpeningFixture.make(base.appendingPathComponent(UUID().uuidString), primary: true)
            let originalProcesses = await f.system.instances
            for profile in f.f.profiles { _ = try await f.f.store.removeRecord(id: profile.id) }
            try expect(await f.system.instances == originalProcesses, "Removed profiles never close processes")
            let primaryPreview = try await f.f.store.previewNewAccount(name: "Primary", managed: false, validator: f.f.validator)
            _ = try await f.f.store.commitAccountSetup(primaryPreview)
            let workPreview = try await f.f.store.previewNewAccount(name: "Work", managed: true, validator: f.f.validator)
            let state = try committed(await f.f.store.commitAccountSetup(workPreview)), target = state.profiles.profiles[1]
            let system = OpeningSystem(primaryAllowed: false, lifecycle: false)
            // Old Work remains unowned: include it as unknown rather than closing or ignoring it.
            await system.seed(state.associations.associations, targetRunning: false)
            await system.configure(unknown: 1)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: f.f.store, validator: f.f.validator, system: system)
            let coordinator = AccountSwitchingCoordinator(driver: driver, activityChecker: OpeningActivity())
            try await coordinator.openAccount(to: target, mode: .openSeparately, environmentScoped: true, confirmOpen: { _ in true })
            try await openingError(.opening(.unknownInstances)) {
                try await coordinator.openAccount(to: target, mode: .closeOthersAndOpen, environmentScoped: true, confirmClose: { _ in .confirm(allowPrimary: true) })
            }
            await system.configure(unknown: 0) // User closed the unmanaged original themselves.
            try await openingError(.opening(.userCancelled)) { try await coordinator.openAccount(to: target, mode: .closeOthersAndOpen, environmentScoped: true) }
            try await coordinator.openAccount(to: target, mode: .closeOthersAndOpen, environmentScoped: true, confirmClose: { _ in .confirm(allowPrimary: true) })
            try expect(await system.effects == ["launch", "pidActivate", "quit", "wait", "pidActivate"], "Both strategies preserved after fresh setup")
            try expect(try await ProfileStore(root: f.f.validator.managedRoot).inspectAccountSetup() == state, "Relaunch persistence")
        }
    }
}
