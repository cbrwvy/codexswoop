import AppKit
import ApplicationServices
import Foundation

/// Explicit diagnostic entry shared by the installed app and standalone inspection helper.
public enum EnvironmentWindowPreflight {
    public static func run(arguments: [String]) async -> Int32 {
        var report: [String: Any] = ["activationPerformed": false, "launchPerformed": false,
            "terminationPerformed": false, "accountAPIUsed": false, "activationAuthorized": false,
            "accessibilityTrusted": AXIsProcessTrusted()]
        do {
            let args = arguments
            guard args.count == 4, args[0] == "--profile", let id = UUID(uuidString: args[1]),
                  args[2] == "--revision", let revision = UInt64(args[3]) else { throw EnvironmentError.invalidMetadata }
            let store = ProfileStore(root: ProfileStore.defaultRoot), validator = EnvironmentValidator()
            let profiles = try await store.inspect(), catalog = try await store.inspectAssociations()
            let managed = try await store.inspectManagedEnvironments()
            guard profiles.profiles.count == 2, profiles.profiles.contains(where: { $0.id == id }),
                  catalog.revision == revision, catalog.associations.count == 2,
                  let association = catalog.associations.first(where: { $0.profileID == id }),
                  association.kind == .managed else { throw EnvironmentError.missingAssociation }
            report["profileID"] = id.uuidString; report["environmentID"] = association.environmentID.uuidString
            report["associationRevision"] = revision
            try validator.revalidate(association)
            report["environmentOwnershipVerified"] = true
            let system = NativeDesktopSystem(validator: validator)
            try await system.validateInstallation()
            report["installationSignatureAndReviewedBuildVerified"] = true
            guard let instance = try await system.observe(association).unique() else { throw EnvironmentOpeningError.targetNotRunning }
            report["processOwnershipVerified"] = true
            report["process"] = ["pid": instance.main.pid, "uid": instance.main.uid, "started": instance.main.started,
                "launchDate": instance.nativeLaunchDate.timeIntervalSince1970, "relatedCount": instance.related.count]
            let evidence = try await system.inspectEnvironmentWindow(association, instance: instance)
            try evidence.validate(association: association, instance: instance)
            guard evidence.windowToken != nil, evidence.windowIDs.count == 1 else { throw EnvironmentError.activationUnavailable }
            guard try await system.observe(association).unique() == instance,
                  try await store.inspect() == profiles, try await store.inspectAssociations() == catalog,
                  try await store.inspectManagedEnvironments() == managed else { throw EnvironmentError.processChanged }
            try validator.revalidate(association)
            report["windowOwnershipVerified"] = true
            report["windowIDs"] = evidence.windowIDs.sorted()
            report["windowToken"] = evidence.windowToken!.uuidString
            report["result"] = "readOnlyOwnershipConfirmed; fresh checks and separate authorization required before activation"
        } catch {
            report["result"] = "blocked"
            report["reason"] = (error as? EnvironmentError)?.errorDescription
                ?? (error as? EnvironmentOpeningError)?.errorDescription
                ?? (error as? ProfileError)?.errorDescription ?? L10n.text("diagnostics.preflightFailed")
            report["errorCode"] = (error as? EnvironmentError).map { String(describing: $0) }
                ?? (error as? EnvironmentOpeningError).map { String(describing: $0) } ?? "metadataOrInspectionFailure"
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return report["windowOwnershipVerified"] as? Bool == true ? 0 : 2
    }
}
