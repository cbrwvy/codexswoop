import Foundation
import CodexSwoopCore

extension CoreChecks {
    @MainActor static func installationValidationChecks(base: URL,
        run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        await run("Installation validation: unchanged bundle generation is reusable") {
            let root = base.appendingPathComponent("snapshot-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("fixture code".utf8).write(to: root.appendingPathComponent("code"))
            let first = try InstallationValidationSnapshot.capture(root)
            try expect(try InstallationValidationSnapshot.capture(root) == first, "Stable metadata snapshot")
        }
        for change in ["content", "replacement", "mode", "addition", "deletion", "link"] {
            await run("Installation validation: reject changed bundle " + change) {
                let fm = FileManager.default, root = base.appendingPathComponent("snapshot-" + UUID().uuidString)
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("code"), other = root.appendingPathComponent("other"), link = root.appendingPathComponent("link")
                try Data("original".utf8).write(to: file); try Data("separate".utf8).write(to: other)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "code")
                let before = try InstallationValidationSnapshot.capture(root)
                switch change {
                case "content":
                    let modified = try fm.attributesOfItem(atPath: file.path)[.modificationDate]!
                    try Data("modified".utf8).write(to: file)
                    try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
                case "replacement": try AtomicMetadataWriter().write(Data("original".utf8), to: file)
                case "mode": try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                case "addition": try Data().write(to: root.appendingPathComponent("new"))
                case "deletion": try fm.removeItem(at: other)
                default:
                    try fm.removeItem(at: link); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "other")
                }
                try expect(try InstallationValidationSnapshot.capture(root) != before, "Cache invalidated, including same-size content with restored mtime")
            }
        }
        await run("Installation validation: external symlink is never cached") {
            let fm = FileManager.default, root = base.appendingPathComponent("snapshot-" + UUID().uuidString)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: base.path)
            do { _ = try InstallationValidationSnapshot.capture(root); throw CheckFailure(description: "External link accepted") }
            catch EnvironmentError.incompatibleBuild {}
        }
        await run("Dispatch ledger: only a submitted operation is uncertain") {
            let ledger = EnvironmentDispatchLedger(), a = UUID(), b = UUID()
            try expect(ledger.disposition(for: a) == .notDispatched, "Capability checks are not dispatch")
            ledger.mark(a)
            try expect(ledger.disposition(for: a) == .mayHaveOccurred && ledger.disposition(for: b) == .notDispatched, "Exact operation identity")
        }
    }
}
