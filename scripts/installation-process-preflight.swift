// Compile against the current shared core. This helper has no effect or bootstrap mode.
import CodexSwoopCore
import Darwin
import Foundation

@main struct InstallationProcessInspection {
    static func main() async {
        do {
            guard CommandLine.arguments.dropFirst() == ["--detached-read-only"] else { exit(2) }
            // An orphaned, one-shot diagnostic cannot contaminate Codex's descendant tree.
            for _ in 0..<100 where getppid() != 1 { try await Task.sleep(for: .milliseconds(50)) }
            guard getppid() == 1 else { throw EnvironmentError.processChanged }
            let root = ProfileStore.defaultRoot, store = ProfileStore(root: root)
            let state = try await store.inspectAccountSetup()
            guard try await store.inspectPendingAccountSetup() == nil else { throw AccountSetupError.recoveryRequired }
            // This entry point is specifically for an uninitialized legacy upgrade.
            // Absence is not evidence about the old app's volatile operation history.
            for name in ["opening-journal.json", "opening-journal-watermark.json"] {
                var info = stat()
                guard lstat(root.appendingPathComponent(name).path, &info) != 0, errno == ENOENT else {
                    throw OpeningJournalError.conflict
                }
            }
            let retained = try await store.inspectRetainedResearchEnvironments()
            var references = state.associations.associations
            for association in retained + state.retained.environments.map(\.association) + state.managed.prepared {
                if !references.contains(where: { $0.environmentID == association.environmentID }) { references.append(association) }
            }
            let validator = EnvironmentValidator(), native = NativeDesktopSystem()
            for association in references { try validator.revalidate(association) }
            _ = try await native.openingBuildFingerprint()
            // Reproduce the unchanged production refusal, without reconciling anything.
            do {
                _ = try await native.environmentInstanceInventory(associations: references)
                print("strictInventory=PASS")
            } catch let error as EnvironmentError where error == .processChanged {
                print("strictInventory=processChanged")
            }
            let first = try await native.inspectInstallationProcesses()
            let second = try await native.inspectInstallationProcesses()
            guard first == second,
                  try await store.inspectAccountSetup() == state,
                  try await store.inspectRetainedResearchEnvironments() == retained,
                  try await store.inspectPendingAccountSetup() == nil else { throw EnvironmentError.processChanged }
            for association in references { try validator.revalidate(association) }
            print("PASS read-only legacy installation preflight; profiles=\(state.profiles.profiles.count) associations=\(state.associations.associations.count) activeInstances=\(first.activeInstances) mains=\(first.mainGenerationCount) backends=\(first.backendGenerationCount) confirmedZombies=\(first.confirmedZombieCount) references=\(first.referenceCount) historicalAliases=\(first.historicalAliasCount) unknownInstances=0 repeated=true legacyUninitialized=true")
            for (index, group) in first.referenceGroupIndices.enumerated() {
                let label = index < 26 ? String(UnicodeScalar(65 + index)!) : "Reference\(index + 1)"
                print("reference=\(label) verifiedGroup=\(group + 1)")
            }
            print("No recovery resolution, bootstrap, lifecycle effect or installation was performed.")
        } catch let error as EnvironmentError {
            // This enum carries no paths, identifiers, process arguments or authorization.
            print("FAIL read-only installation preflight: \(error)"); exit(2)
        } catch {
            print("FAIL read-only installation preflight: catalog, journal or build evidence unavailable"); exit(2)
        }
    }
}
