import Foundation
import Darwin
import CodexSwoopCore

/// Every path, process and effect in these fixtures is synthetic. No native adapter is invoked.
@MainActor
struct ReleaseFixture {
    let root: URL
    let store: ProfileStore
    let validator: EnvironmentValidator
    let profiles: [AccountProfile]
    let associations: [EnvironmentAssociation]
    let system: ReleaseDesktopSystem
    let coordinator: AccountSwitchingCoordinator

    static func make(root: URL, running: Bool = true) async throws -> Self {
        let store = ProfileStore(root: root.appendingPathComponent("store"))
        let validator = EnvironmentValidator(userHome: root.appendingPathComponent("user"), managedRoot: root.appendingPathComponent("store"))
        _ = try await store.create(name: "Fixture One")
        let profiles = try await store.create(name: "Fixture Two").profiles
        var associations: [EnvironmentAssociation] = []
        for profile in profiles {
            let association = try await store.prepareManagedEnvironment(profileID: profile.id)
            _ = try await store.linkEnvironment(association, validator: validator)
            associations.append(association)
        }
        let system = ReleaseDesktopSystem()
        await system.seed(associations, running: running)
        let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: store, validator: validator, system: system)
        return Self(root: root, store: store, validator: validator, profiles: profiles, associations: associations,
                    system: system, coordinator: AccountSwitchingCoordinator(driver: driver))
    }
    func open(_ mode: AccountOpeningMode = .openSeparately) async throws {
        try await coordinator.openAccount(to: profiles[1], mode: mode, environmentScoped: true,
            confirmOpen: { _ in true }, confirmClose: { _ in .confirm(allowPrimary: false) })
    }
}

actor ReleaseDesktopSystem: DesktopSystem {
    nonisolated let lifecycleAllowed = false
    nonisolated let environmentActivationAllowed = true
    var instances: [UUID: DesktopInstance] = [:]
    var effects: [String] = []
    var unknownCount = 0
    var failActivation = false, failLaunch = false
    var scope: EnvironmentOperationScope?
    var pidScope: PIDActivationScope?
    var pidConsumed = false
    var foreground: DesktopInstance?
    let ledger = EnvironmentDispatchLedger()

    static func instance(_ offset: Int32) -> DesktopInstance {
        let generation = DesktopGeneration(pid: 190_000 + offset, uid: getuid(), started: "synthetic-\(offset)")
        return DesktopInstance(main: generation, related: [generation], nativeLaunchDate: Date().addingTimeInterval(-10))
    }
    func seed(_ values: [EnvironmentAssociation], running: Bool) {
        for (index, value) in values.enumerated() where running || index == 0 {
            instances[value.environmentID] = Self.instance(Int32(index))
        }
    }
    func configure(unknown: Int = 0, activation: Bool = false, launch: Bool = false) {
        unknownCount = unknown; failActivation = activation; failLaunch = launch
    }
    func removeSyntheticInstance(_ id: UUID) { instances.removeValue(forKey: id) }
    func replace(_ association: EnvironmentAssociation) { instances[association.environmentID] = Self.instance(20) }
    var buildStamp = "c"
    var installationVersion = "synthetic", installationBuild = "fixture"
    var signatureValid = true
    func changeBuild() { buildStamp = "d" }
    func updateInstallation(version: String, build: String, stamp: String = "d") {
        installationVersion = version; installationBuild = build; buildStamp = stamp
    }
    func setSignatureValid(_ value: Bool) { signatureValid = value }
    func setSyntheticInstance(_ id: UUID, _ instance: DesktopInstance) { instances[id] = instance }
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint { try currentBuildFingerprint() }
    private func currentBuildFingerprint() throws -> OpeningBuildFingerprint {
        OpeningBuildFingerprint(version: installationVersion, build: installationBuild, signingRequirement: OfficialCodexPolicy.signingRequirement,
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: buildStamp, count: 64))
    }
    func validateInstallation() throws {
        try OfficialCodexPolicy.validate(CodexInstallation(url: URL(fileURLWithPath: OfficialCodexPolicy.path),
            version: installationVersion, build: installationBuild),
            signature: CodexSigningIdentity(identifier: CodexBundleInspector.bundleIdentifier,
                teamIdentifier: OfficialCodexPolicy.teamIdentifier, codeDirectoryHash: String(repeating: "b", count: 40)),
            signatureValid: signatureValid, before: buildStamp, after: buildStamp)
    }
    func observe(_ association: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        DesktopObservation(matching: instances[association.environmentID].map { [$0] } ?? [], ambiguous: false)
    }
    func instanceInventory(associations: [EnvironmentAssociation]) -> DesktopInstanceInventory {
        DesktopInstanceInventory(entries: associations.compactMap { association in
            instances[association.environmentID].map { DesktopInventoryEntry(association: association, instance: $0) }
        }, unknownCount: unknownCount)
    }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) {
        effects.append("quit"); instances.removeValue(forKey: association.environmentID)
    }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) { effects.append("wait") }
    func launch(_ specification: DesktopLaunchSpecification) throws {
        effects.append("launch")
        if failLaunch { throw EnvironmentError.launchFailed }
        instances[specification.association.environmentID] = Self.instance(10)
    }
    func authorizeEnvironmentOperation(_ value: EnvironmentOperationScope, allowPrimary: Bool) throws {
        try value.validate()
        try validateInstallation()
        if let expected = value.buildFingerprint {
            guard try currentBuildFingerprint() == expected else { throw EnvironmentError.incompatibleBuild }
        }
        scope = value
    }
    func activateScopedEnvironment(_ value: EnvironmentOperationScope, instance: DesktopInstance) throws {
        guard scope == value else { throw EnvironmentOpeningError.stalePlan }
        ledger.mark(value.id, effect: .activation(instance)); effects.append("activate")
        if failActivation { throw SwitchingError.activationFailed }
        foreground = instance
    }
    func launchScopedEnvironment(_ value: EnvironmentOperationScope) throws -> DesktopInstance {
        guard scope == value else { throw EnvironmentOpeningError.stalePlan }
        ledger.mark(value.id, effect: .launch)
        try launch(DesktopLaunchSpecification(association: value.target))
        return instances[value.target.environmentID]!
    }
    func quitScopedEnvironment(_ value: EnvironmentOperationScope, item: DesktopInventoryEntry) throws {
        guard scope == value else { throw EnvironmentOpeningError.stalePlan }
        ledger.mark(value.id, effect: .normalQuit(item.instance))
        requestNormalQuit(item.instance, association: item.association)
    }
    func waitForScopedExit(_ value: EnvironmentOperationScope, item: DesktopInventoryEntry) {
        waitForExit(item.instance, association: item.association, timeout: .seconds(10))
    }
    func finishEnvironmentOperation(_ id: UUID) { if scope?.id == id { scope = nil } }
    func environmentEffectDisposition(_ id: UUID) -> EnvironmentEffectDisposition { ledger.disposition(for: id) }
    func confirmEnvironmentOperationSettled(_ value: EnvironmentOperationScope, inventoryAssociations: [EnvironmentAssociation]) throws {
        try EnvironmentRecoveryProof.validate(scope: value, effects: ledger.effects(for: value.id),
            inventory: instanceInventory(associations: inventoryAssociations),
            livePIDs: Set(instances.values.flatMap { $0.related.map(\.pid) }), launcherRunning: false)
    }
    func confirmPersistedEnvironmentOperationSettled(_ value: EnvironmentOperationScope, effects: [EnvironmentSubmittedEffect], inventoryAssociations: [EnvironmentAssociation]) throws {
        try EnvironmentRecoveryProof.validate(scope: value, effects: effects,
            inventory: instanceInventory(associations: inventoryAssociations),
            livePIDs: Set(instances.values.flatMap { $0.related.map(\.pid) }), launcherRunning: false)
    }
    func configurePID(_ value: PIDActivationScope) { pidScope = value }
    func permitsPIDActivation(_ a: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) -> Bool {
        pidScope?.permits(a, revision: revision, instance: instance) == true
    }
    func activatePIDEnvironment(_ a: EnvironmentAssociation, revision: UInt64, instance: DesktopInstance) throws {
        guard !pidConsumed, permitsPIDActivation(a, revision: revision, instance: instance) else { throw EnvironmentOpeningError.unavailable }
        pidConsumed = true; effects.append("pidActivate"); foreground = instance
    }
    func verifyPIDForeground(_ instance: DesktopInstance) throws {
        guard foreground == instance else { throw SwitchingError.activationFailed }
    }
}
