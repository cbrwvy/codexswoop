import Foundation
import Darwin
import CodexSwoopCore

@MainActor
struct ReplacementFixture {
    let store: ProfileStore, validator: EnvironmentValidator, lab: URL
    let profile: AccountProfile, old: EnvironmentAssociation, target: EnvironmentAssociation
    static func make(_ root: URL) async throws -> Self {
        let store = ProfileStore(root: root), validator = EnvironmentValidator(managedRoot: root)
        _ = try await store.create(name: "Основной")
        let profile = try await store.create(name: "Рабочий").profiles[1]
        let target = try await store.prepareManagedEnvironment(profileID: profile.id)
        let primary = try await store.inspect().profiles[0]
        let base = root.appendingPathComponent("Profiles/\(primary.directoryIdentifier)")
        for name in ["codex-home", "electron-user-data"] { try AssociationFixture.directory(base.appendingPathComponent(name)) }
        let primaryValue = try validator.link(profileID: primary.id, environmentID: primary.id, kind: .managed,
            home: base.path + "/codex-home", electron: base.path + "/electron-user-data")
        _ = try await store.linkEnvironment(primaryValue, validator: validator)
        let runID = UUID(), envID = UUID(), lab = URL(fileURLWithPath: "/private/tmp/codexswoop-lab-\(runID.uuidString.lowercased())")
        let pair = lab.appendingPathComponent("Profiles/\(envID.uuidString.lowercased())")
        for url in [lab, lab.appendingPathComponent("Profiles"), pair, pair.appendingPathComponent("codex-home"), pair.appendingPathComponent("electron-user-data")] {
            try AssociationFixture.directory(url)
        }
        let marker: [String: Any] = ["schema": 1, "mode": "guarded", "owner_uid": getuid(), "protected_uid": getuid(),
            "run_id": runID.uuidString, "profiles": ["A": envID.uuidString, "B": UUID().uuidString]]
        let markerURL = lab.appendingPathComponent("lab.json")
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        let old = try validator.link(profileID: profile.id, environmentID: envID, kind: .temporaryResearch,
            home: pair.path + "/codex-home", electron: pair.path + "/electron-user-data")
        _ = try await store.linkEnvironment(old, validator: validator)
        return Self(store: store, validator: validator, lab: lab, profile: profile, old: old, target: target)
    }
    func preview(store override: ProfileStore? = nil) async throws -> AssociationReplacementPreview {
        try await (override ?? store).previewEnvironmentReplacement(profileID: profile.id, expectedProfile: profile,
            expectedRevision: 2, expectedCurrent: old, target: target, validator: validator)
    }
    func url(_ name: String) -> URL { validator.managedRoot.appendingPathComponent(name) }
    func bytes(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
}

@MainActor
func replacementError(_ error: AssociationReplacementError, _ body: () async throws -> Void) async throws {
    do { try await body(); throw CheckFailure(description: "Replacement should fail") }
    catch let caught as AssociationReplacementError { try expect(caught == error, "Expected \(error), got \(caught)") }
}

extension CoreChecks {
    @MainActor
    static func replacementChecks(base: URL, run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        let fm = FileManager.default
        func scenario(_ name: String, _ body: @escaping @MainActor (ReplacementFixture) async throws -> Void) async {
            await run("Replacement: " + name) {
                let f = try await ReplacementFixture.make(base.appendingPathComponent("replacement-" + UUID().uuidString))
                defer { try? fm.removeItem(at: f.lab) } // Generated empty synthetic lab only.
                try await body(f)
            }
        }
        await scenario("read-only preview, atomic success, prior bytes backup, legacy reload and UUID preservation") { f in
            let names = ["profiles.json", "profiles.backup.json", "environments.json", "environments.backup.json", "managed-environments.json", "metadata.lock"]
            let before = try names.map { try f.bytes($0) }, profiles = try await f.store.inspect()
            let preview = try await f.preview()
            try expect(try names.map { try f.bytes($0) } == before, "Preview writes nothing")
            try expect(try await f.store.replaceEnvironmentAssociation(profileID: preview.profile.id, preview: preview, validator: f.validator) == .committed(revision: 3), "One commit")
            let reopened = ProfileStore(root: f.validator.managedRoot)
            let catalog = try await reopened.inspectAssociations()
            try expect(catalog == preview.proposedCatalog && catalog.associations.count == 2, "Compatible schema-1 reload")
            try expect(try f.bytes("environments.backup.json") == before[2], "Exact previous catalog retained")
            try expect(try f.bytes("profiles.json") == before[0] && f.bytes("profiles.backup.json") == before[1], "Profiles byte-identical")
            try expect(try await reopened.inspect() == profiles && Set(catalog.associations.map(\.profileID)) == Set(profiles.profiles.map(\.id)), "All UUIDs retained")
            try expect(try f.bytes("managed-environments.json") == before[4], "Pending catalog retained")
            try f.validator.revalidate(f.old); try f.validator.revalidate(f.target)
            try expect(ConnectionPresentation.state(association: preview.replacement) == .verificationRequired && !DesktopIntegrationPolicy.lifecycleEnabled, "UI proof and switching gate unchanged")
        }
        await scenario("repeated capability and old revision both conflict") { f in
            let p = try await f.preview(); _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator)
            try await replacementError(.conflict) { _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            try await replacementError(.conflict) { _ = try await f.preview() }
        }
        await scenario("wrong profile UUID is rejected") { f in
            try await replacementError(.invalidTransition) {
                _ = try await f.store.previewEnvironmentReplacement(profileID: f.profile.id, expectedProfile: f.profile,
                    expectedRevision: 2, expectedCurrent: f.old, target: (try await f.store.inspectAssociations()).associations[0], validator: f.validator)
            }
        }
        await scenario("wrong commit UUID cannot use another profile's preview") { f in
            let p = try await f.preview(), before = try f.bytes("environments.json")
            try await replacementError(.invalidTransition) {
                _ = try await f.store.replaceEnvironmentAssociation(profileID: UUID(), preview: p, validator: f.validator)
            }
            try expect(try f.bytes("environments.json") == before, "No write for mismatched UUID")
        }
        await scenario("missing profile") { f in
            do {
                _ = try await f.store.previewEnvironmentReplacement(profileID: UUID(), expectedProfile: f.profile,
                    expectedRevision: 2, expectedCurrent: f.old, target: f.target, validator: f.validator)
                throw CheckFailure(description: "Missing profile accepted")
            } catch ProfileError.missingProfile {}
        }
        await scenario("unexpected full source association") { f in
            try await replacementError(.conflict) {
                _ = try await f.store.previewEnvironmentReplacement(profileID: f.profile.id, expectedProfile: f.profile,
                    expectedRevision: 2, expectedCurrent: f.target, target: f.target, validator: f.validator)
            }
        }
        for file in ["profiles.json", "environments.json", "managed-environments.json", "environments.backup.json"] {
            await scenario("detects concurrent same-byte file replacement: " + file) { f in
                let p = try await f.preview(), bytes = try f.bytes(file)
                try AtomicMetadataWriter().write(bytes, to: f.url(file))
                try await replacementError(.conflict) { _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            }
        }
        await scenario("profile rename conflicts without changing association") { f in
            let p = try await f.preview(), before = try f.bytes("environments.json")
            _ = try await f.store.rename(id: f.profile.id, name: "Changed")
            try await replacementError(.conflict) { _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            try expect(try f.bytes("environments.json") == before, "No write after rename")
        }
        for file in ["environments.json", "managed-environments.json"] {
            await scenario("corrupt metadata blocks preview: " + file) { f in
                try Data("damaged synthetic metadata".utf8).write(to: f.url(file))
                try await environmentError(.invalidMetadata) { _ = try await f.preview() }
            }
        }
        await scenario("future schema cannot be overwritten") { f in
            var o = try JSONSerialization.jsonObject(with: f.bytes("environments.json")) as! [String: Any]
            o["schemaVersion"] = 99
            try JSONSerialization.data(withJSONObject: o).write(to: f.url("environments.json"))
            try await environmentError(.unsupportedSchema) { _ = try await f.preview() }
        }
        for (destination, failure) in [("environments.backup.json", AssociationReplacementError.backupFailed), ("environments.json", .writeFailedPreviousRetained)] {
            await scenario("I/O failure at " + destination + " retains previous active bytes") { f in
                let failing = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { url in
                    if url.lastPathComponent == destination { throw ProfileError.storageUnavailable }
                })
                let p = try await f.preview(store: failing), before = try f.bytes("environments.json")
                try await replacementError(failure) { _ = try await failing.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
                try expect(try f.bytes("environments.json") == before, "No partial active write")
                if destination == "environments.json" { try expect(try f.bytes("environments.backup.json") == before, "Crash-between-writes backup") }
            }
        }
        await scenario("change at active writer's final barrier cannot overwrite unknown bytes") { f in
            let injected = Data("concurrent synthetic writer".utf8), url = f.url("environments.json")
            let store = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { target in
                if target == url { try injected.write(to: url) }
            })
            let p = try await f.preview(store: store)
            try await replacementError(.outcomeUncertain) { _ = try await store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            try expect(try f.bytes("environments.json") == injected, "Unknown state retained")
        }
        await scenario("explicit recovery preserves damaged metadata after simulated crash") { f in
            let store = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "environments.json" { throw ProfileError.storageUnavailable }
            })
            let p = try await f.preview(store: store), before = try f.bytes("environments.json")
            try await replacementError(.writeFailedPreviousRetained) { _ = try await store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            try Data("damaged synthetic crash".utf8).write(to: f.url("environments.json"))
            let recovered = try await f.store.recoverAssociationsBackup()
            try expect(recovered.associations[1] == f.old && recovered.revision == 2, "Explicit valid prior snapshot")
            let damaged = try fm.contentsOfDirectory(atPath: f.validator.managedRoot.path).filter { $0.hasPrefix("environments-damaged-") }
            try expect(damaged.count == 1 && (try JSONDecoder().decode(AssociationCatalog.self, from: before)) == recovered, "Damaged original preserved")
        }
        await scenario("metadata-only reverse replacement retains primary and advances revision") { f in
            let forward = try await f.preview(); _ = try await f.store.replaceEnvironmentAssociation(profileID: forward.profile.id, preview: forward, validator: f.validator)
            let reverse = try await f.store.previewEnvironmentReplacement(profileID: f.profile.id, expectedProfile: f.profile,
                expectedRevision: 3, expectedCurrent: forward.replacement, target: f.old, validator: f.validator)
            try expect(try await f.store.replaceEnvironmentAssociation(profileID: reverse.profile.id, preview: reverse, validator: f.validator) == .committed(revision: 4), "Restore through same transaction")
            let restored = try await f.store.inspectAssociations()
            try expect(restored.associations[1].kind == .temporaryResearch && restored.associations[1].codexHome == f.old.codexHome
                && restored.associations[0] == forward.proposedCatalog.associations[0], "Only Work restored")
        }
        for file in ["profiles.json", "metadata.lock", "environments.backup.json"] {
            await scenario("unsafe metadata permissions: " + file) { f in
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.url(file).path)
                try await environmentError(.invalidMetadata) { _ = try await f.preview() }
            }
        }
        await scenario("unsafe managed directory permissions are not repaired") { f in
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.target.codexHome)
            try await environmentError(.unsafeDirectory) { _ = try await f.preview() }
        }
        await scenario("missing target directory is not recreated") { f in
            try fm.removeItem(atPath: f.target.codexHome)
            try await environmentError(.missingDirectory) { _ = try await f.preview() }
            try expect(!fm.fileExists(atPath: f.target.codexHome), "No repair")
        }
        await scenario("symlink escaping fails without touching its destination") { f in
            try fm.removeItem(atPath: f.target.codexHome)
            try fm.createSymbolicLink(atPath: f.target.codexHome, withDestinationPath: f.old.codexHome)
            try await environmentError(.unsafeDirectory) { _ = try await f.preview() }
        }
        await scenario("conflict with another profile's directories") { f in
            var object = try JSONSerialization.jsonObject(with: f.bytes("environments.json")) as! [String: Any]
            var entries = object["associations"] as! [[String: Any]]
            entries[0]["codexHome"] = f.target.codexHome
            entries[0]["electronData"] = f.target.electronData
            object["associations"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: f.url("environments.json"))
            try await environmentError(.duplicateAssociation) { _ = try await f.preview() }
        }
        await scenario("unknown schema-1 fields on every object are preserved") { f in
            var object = try JSONSerialization.jsonObject(with: f.bytes("environments.json")) as! [String: Any]
            object["extension"] = ["value": "retained"]
            var entries = object["associations"] as! [[String: Any]]
            for index in entries.indices { entries[index]["futureField"] = "retained" }
            object["associations"] = entries
            try JSONSerialization.data(withJSONObject: object).write(to: f.url("environments.json"))
            let p = try await f.preview(); _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator)
            let after = try JSONSerialization.jsonObject(with: f.bytes("environments.json")) as! [String: Any]
            try expect((after["extension"] as? [String: String]) == ["value": "retained"], "Top extension retained")
            let rows = after["associations"] as! [[String: Any]]
            try expect(rows.allSatisfy { $0["futureField"] as? String == "retained" }, "Entry extensions retained")
        }
        await scenario("cancellation before commit writes nothing") { f in
            let p = try await f.preview(), before = try f.bytes("environments.json")
            let task = Task { try Task.checkCancellation(); return try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(description: "Cancelled replacement accepted") } catch is CancellationError {}
            try expect(try f.bytes("environments.json") == before, "Cancelled active retained")
        }
        await scenario("managed registry mismatch blocks a previously plausible target") { f in
            var object = try JSONSerialization.jsonObject(with: f.bytes("managed-environments.json")) as! [String: Any]
            object["prepared"] = []
            try JSONSerialization.data(withJSONObject: object).write(to: f.url("managed-environments.json"))
            try await replacementError(.invalidTransition) { _ = try await f.preview() }
        }
        await scenario("directory replacement after preview conflicts") { f in
            let p = try await f.preview()
            let oldDirectory = f.target.codexHome + "-retained-fixture"
            try fm.moveItem(atPath: f.target.codexHome, toPath: oldDirectory)
            try AssociationFixture.directory(URL(fileURLWithPath: f.target.codexHome))
            try await environmentError(.changedDirectory) { _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
        }
        await scenario("hard-linked metadata blocks preview") { f in
            try fm.linkItem(at: f.url("profiles.json"), to: f.url("synthetic-hardlink.json"))
            try await environmentError(.invalidMetadata) { _ = try await f.preview() }
        }
        await scenario("backup symlink escaping blocks preview") { f in
            try fm.removeItem(at: f.url("environments.backup.json"))
            try fm.createSymbolicLink(at: f.url("environments.backup.json"), withDestinationURL: f.url("profiles.json"))
            do { _ = try await f.preview(); throw CheckFailure(description: "Backup symlink accepted") }
            catch ProfileError.unsafePath {}
        }
        await scenario("conflict at backup final barrier preserves unknown active state and old backup") { f in
            let active = f.url("environments.json"), injected = Data("unknown concurrent fixture".utf8)
            let store = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "environments.backup.json" { try injected.write(to: active) }
            })
            let p = try await f.preview(store: store), backup = try f.bytes("environments.backup.json")
            try await replacementError(.conflict) { _ = try await store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator) }
            try expect(try f.bytes("environments.json") == injected && f.bytes("environments.backup.json") == backup, "Neither state overwritten")
        }
        await scenario("cancellation after backup keeps old active and recoverable full backup") { f in
            let store = ProfileStore(root: f.validator.managedRoot, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "environments.json" { throw CancellationError() }
            })
            let p = try await f.preview(store: store), before = try f.bytes("environments.json")
            do { _ = try await store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator); throw CheckFailure(description: "Cancellation ignored") }
            catch is CancellationError {}
            try expect(try f.bytes("environments.json") == before && f.bytes("environments.backup.json") == before, "Old active/full backup retained")
        }
        await scenario("two stores with the same preview commit at most once") { f in
            let p = try await f.preview(), second = ProfileStore(root: f.validator.managedRoot)
            async let firstResult = attemptReplacement(f.store, p, validator: f.validator)
            async let secondResult = attemptReplacement(second, p, validator: f.validator)
            let results = await [firstResult, secondResult]
            let after = try await f.store.inspectAssociations()
            try expect(results.filter { $0 }.count == 1 && after.revision == 3, "Exactly one concurrent writer commits")
        }
        await scenario("exclusive lock contention rejects rather than waits or overwrites") { f in
            let p = try await f.preview(), fd = open(f.url("metadata.lock").path, O_RDONLY)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CheckFailure(description: "Fixture lock failed") }
            defer { flock(fd, LOCK_UN); close(fd) }
            do { _ = try await f.store.replaceEnvironmentAssociation(profileID: p.profile.id, preview: p, validator: f.validator); throw CheckFailure(description: "Contended lock accepted") }
            catch ProfileError.storeBusy {}
        }
    }

    static func attemptReplacement(_ store: ProfileStore, _ preview: AssociationReplacementPreview,
        validator: EnvironmentValidator) async -> Bool {
        do { return try await store.replaceEnvironmentAssociation(profileID: preview.profile.id, preview: preview, validator: validator) == .committed(revision: 3) }
        catch { return false }
    }

    @MainActor
    static func previewRealReplacement() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--preview-environment-replacement"), args.count == index + 2,
              let id = UUID(uuidString: args[index + 1]) else { throw EnvironmentError.invalidMetadata }
        let store = ProfileStore(root: ProfileStore.defaultRoot)
        guard let profile = try await store.inspect().profiles.first(where: { $0.id == id }),
              let old = try await store.inspectAssociations().associations.first(where: { $0.profileID == id }),
              let target = try await store.inspectManagedEnvironments().prepared.first(where: { $0.profileID == id }) else {
            throw EnvironmentError.missingAssociation
        }
        let catalog = try await store.inspectAssociations()
        let p = try await store.previewEnvironmentReplacement(profileID: id, expectedProfile: profile,
            expectedRevision: catalog.revision, expectedCurrent: old, target: target)
        print("GO: read-only metadata preview; identity verification required")
        print("Profile: \(p.profile.name) / \(p.profile.id)")
        print("Transition: \(p.previous.kind.rawValue) -> \(p.replacement.kind.rawValue)")
        print("Revision: \(p.expectedRevision) -> \(p.proposedCatalog.revision)")
        print("Target: \(p.replacement.codexHome) | \(p.replacement.electronData)")
        print("Changed: \(p.changedFields.joined(separator: ", "))")
        print("Unchanged: \(p.unchangedFields.joined(separator: ", "))")
        print("Backup on separately authorized commit only: \(p.backupURL.path)")
        print("Restore: separately approved reverse preview using exact post-commit revision/reference and retained A; same transaction, new revision, no lifecycle actions")
        print("Proposed environments.json (Swoop metadata only):")
        print(String(decoding: p.proposedMetadata, as: UTF8.self))
    }
}
