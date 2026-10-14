import AppKit
import Combine
import ServiceManagement
import ApplicationServices
import CodexSwoopCore

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var language: AppLanguage = .system
    @Published var showDiagnostics = false
    var presentSettings: ((Bool) -> Void)?
    var languageChanged: (() -> Void)?
    func openSettings(diagnostics: Bool = false) { presentSettings?(diagnostics) }
    func setLanguage(_ value: AppLanguage) {
        defaults.set(value.rawValue, forKey: L10n.preferenceKey)
        language = value; L10n.setSessionLanguage(value)
        if let lastErrorProvider { errorMessage = lastErrorProvider() }
        if loginError != nil { loginError = L10n.text("onboarding.login.failed") }
        languageChanged?()
    }
    @Published private(set) var offerManagedSignIn = false
    @Published private(set) var retainedEnvironments: [RetainedEnvironment] = []
    @Published private(set) var pendingSetup: PendingAccountSetup?
    @Published private(set) var profiles: [AccountProfile] = []
    @Published private(set) var isBusy = false
    @Published private(set) var needsOpeningReview = false
    @Published var menuMaximumHeight: CGFloat = 560
    @Published private(set) var openingReviewResolved = false
    @Published private(set) var openingMode: AccountOpeningMode?
    @Published private(set) var storageReady = false
    @Published var errorMessage: String? { didSet { if errorMessage == nil { lastErrorProvider = nil } } }
    private var lastErrorProvider: (() -> String)?
    // Ordinary form/connection messages may be cleared while the coordinator still requires review.
    // Keep the uncertain operation's cause independently until read-only reconciliation succeeds.
    private var openingReviewErrorProvider: (() -> String)?
    var diagnosticErrorMessage: String? {
        if needsOpeningReview {
            return errorMessage ?? openingReviewErrorProvider?() ?? L10n.text("review.requiredDetail")
        }
        return errorMessage ?? (openingReviewResolved ? L10n.text("review.safeDetail") : nil)
    }
    #if SETUP_UI_CHECKS
    func previewLoginStatusForChecks(_ status: SMAppService.Status, failed: Bool = false) {
        precondition(isTestStorage)
        loginStatus = status
        loginError = failed ? L10n.text("onboarding.login.failed") : nil
    }
    func previewOpeningReviewForChecks(_ error: SwitchingError?) {
        precondition(isTestStorage)
        needsOpeningReview = error != nil
        openingReviewErrorProvider = error.map { failure in { failure.errorDescription ?? L10n.text("review.requiredDetail") } }
        errorMessage = openingReviewErrorProvider?()
    }
    #endif
    @Published var installation: CodexInstallation?
    @Published private(set) var codexAvailability: CodexAvailability = .checking
    @Published private(set) var accessibilityStatus: AccessibilityStatus = .denied
    @Published private(set) var loginError: String?
    private let desktopSystem: any DesktopSystem
    private var detectionTask: Task<Void, Never>?
    private var detectionRevision = 0
    var showsWelcome: Bool { FirstRunPresentation.showsWelcome(profileCount: profiles.count, storageReady: storageReady) }
    var installationBlockedReason: String? {
        installation == nil ? L10n.text("onboarding.codex.missing")
            : (codexAvailability.permitsOpening ? nil : L10n.text(codexAvailability.messageKey))
    }
    var installationCompatibilityNotice: String? {
        guard let installation, !LastTestedCodexBuild.matches(installation) else { return nil }
        return L10n.text("onboarding.codex.untested", installation.version)
    }
    var friendlyError: String { L10n.text(needsOpeningReview ? "review.previousOperation" : "onboarding.actionFailed") }

    @Published private(set) var associations: [EnvironmentAssociation] = [] {
        didSet { usage.synchronize(associations) }
    }
    @Published private(set) var usageRevision = 0
    private let usage: UsageCoordinator
    @Published private(set) var associationsReady = true
    @Published private(set) var connectionErrors: Set<UUID> = []
    @Published private(set) var connectionNotice: String?
    @Published private(set) var preparedEnvironments: [EnvironmentAssociation] = []
    @Published private(set) var managedStorageReady = true
    @Published private(set) var manualConfirmations: [UUID: ManualAccountConfirmation] = [:]
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    var loginEnabled: Bool { loginStatus == .enabled }
    var loginNeedsApproval: Bool { loginStatus == .requiresApproval }
    var loginStatusKey: String {
        switch loginStatus {
        case .enabled: "onboarding.login.enabled"
        case .requiresApproval: "onboarding.login.approval"
        case .notRegistered: "onboarding.login.off"
        case .notFound: "onboarding.login.unavailable"
        @unknown default: "onboarding.login.unknown"
        }
    }
    private let store: ProfileStore
    private var testPreferredPath: String?
    private let defaults: UserDefaults
    private let validator: EnvironmentValidator
    private let coordinator: AccountSwitchingCoordinator
    private var operationTask: Task<Void, Never>?
    let isTestStorage: Bool

    init(defaults: UserDefaults = .standard, usage: UsageCoordinator = UsageCoordinator()) {
        self.usage = usage
        self.defaults = defaults
        self.language = AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "system") ?? .system
        L10n.setSessionLanguage(AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "system") ?? .system)
        let configuration = Self.storageConfiguration()
        self.isTestStorage = configuration.isTest
        self.store = ProfileStore(root: configuration.root)
        self.validator = EnvironmentValidator(userHome: configuration.isTest ? configuration.root.appendingPathComponent("fixture-user") : FileManager.default.homeDirectoryForCurrentUser, managedRoot: configuration.root)
        let desktopSystem: any DesktopSystem = configuration.isTest ? SetupPreviewDesktopSystem() : NativeDesktopSystem(validator: validator)
        self.desktopSystem = desktopSystem
        self.coordinator = AccountSwitchingCoordinator(driver: DesktopSwitchingDriver(
            store: store, validator: validator, system: desktopSystem))
        usage.onChange = { [weak self] in self?.usageRevision += 1 }
        refreshDetection()
    }

    static func storageConfiguration() -> (root: URL, isTest: Bool) {
        var root = ProfileStore.defaultRoot
        var testStorage = false
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // A separate QA bundle can pin its fixture root even when a UI tool relaunches without argv.
        // Normal Debug/Release Info.plists contain no such key; Release ignores it entirely.
        var testPath = Bundle.main.object(forInfoDictionaryKey: "CodexSwoopTestStorageRoot") as? String
        if let index = args.firstIndex(of: "--test-storage-root") {
            guard args.indices.contains(index + 1) else { exit(2) }
            testPath = args[index + 1]
        }
        if let testPath {
            guard EnvironmentValidator.canonical(testPath), testPath.hasPrefix("/private/tmp/codexswoop-") else { exit(2) }
            root = URL(fileURLWithPath: testPath)
            testStorage = true
        }
        #endif
        return (root, testStorage)
    }

    func refreshDetection() {
        detectionTask?.cancel(); detectionRevision += 1
        refreshPermissionStatus()
        #if DEBUG
        if isTestStorage, testPreferredPath == nil {
            let state = CodexAvailability(rawValue: Bundle.main.object(forInfoDictionaryKey: "CodexSwoopTestInstallationState") as? String ?? "verified") ?? .unverified
            previewInstallationForChecks(state)
            return
        }
        #endif
        installation = CodexDetector().detect(preferredPath: isTestStorage ? testPreferredPath : defaults.string(forKey: "codexApplicationPath"))
        guard let found = installation else { codexAvailability = .missing; return }
        guard OfficialCodexPolicy.acceptsMetadata(found), !isTestStorage else { codexAvailability = .unverified; return }
        codexAvailability = .checking
        let revision = detectionRevision
        detectionTask = Task { [weak self] in
            guard let self else { return }
            let verified: Bool
            do { try await desktopSystem.validateInstallation(); verified = true }
            catch { verified = false }
            guard !Task.isCancelled, revision == detectionRevision else { return }
            codexAvailability = verified && CodexDetector().inspect(found.url) == found ? .verified : .unverified
        }
    }

    func refreshPermissionStatus() {
        accessibilityStatus = !isTestStorage && AXIsProcessTrusted() ? .allowed : .denied
    }

    #if DEBUG
    /// Only isolated fixture UI can inject a display state; its desktop adapter has no native effects.
    func previewInstallationForChecks(_ state: CodexAvailability, version: String? = nil, build: String? = nil) {
        precondition(isTestStorage)
        installation = state == .missing ? nil : CodexInstallation(url: URL(fileURLWithPath: OfficialCodexPolicy.path),
            version: version ?? (state == .unverified ? "0.0-fixture" : LastTestedCodexBuild.version), build: build ?? LastTestedCodexBuild.build)
        codexAvailability = state
    }
    #endif

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // First startup may create Swoop metadata storage, never a Codex environment.
            if FileManager.default.fileExists(atPath: validator.managedRoot.appendingPathComponent("metadata.lock").path) {
                pendingSetup = try await store.inspectPendingAccountSetup()
                if pendingSetup != nil { throw AccountSetupError.recoveryRequired }
            }
            profiles = try await store.load().profiles
            retainedEnvironments = try await store.inspectAccountSetup().retained.environments
            // Reopening after the application picker must not erase its validation error.
            if !storageReady { errorMessage = nil }
            storageReady = true
            do {
                preparedEnvironments = try await store.inspectManagedEnvironments().prepared
                managedStorageReady = true
            } catch {
                preparedEnvironments = []; managedStorageReady = false; show(error)
            }
            do {
                associations = try await store.inspectAssociations().associations
                associationsReady = true
            } catch {
                associations = []; associationsReady = false
                show(error)
            }
        } catch {
            storageReady = false
            show(error)
        }
        do {
            needsOpeningReview = try await coordinator.refreshOpeningRecovery()
            if needsOpeningReview && openingReviewErrorProvider == nil {
                openingReviewErrorProvider = { L10n.text("review.pendingDetail") }
            }
        }
        catch SwitchingError.busy { show(SwitchingError.busy) }
        catch {
            needsOpeningReview = true
            openingReviewErrorProvider = { (error as? OpeningJournalError)?.errorDescription ?? L10n.text("review.journalDetail") }
        }
        refreshDetection()
        refreshLoginStatus()
    }

    func create(name: String) async -> Bool { await update { try await self.store.create(name: name) } }
    func rename(id: UUID, name: String) async -> Bool { await update { try await self.store.rename(id: id, name: name) } }
    func remove(id: UUID) async -> Bool {
        guard !isBusy, !needsOpeningReview, storageReady else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            let preview = try await store.previewProfileRemoval(id: id)
            let name = preview.removedProfiles[0].name
            guard confirmSetup(title: L10n.text("message.0394db2a65", name), detail: L10n.text("message.00f1271bcc"), button: L10n.text("message.2f996d867a")) else { return false }
            return try await applySetup(preview, success: L10n.text("message.476470c77c"))
        } catch { await setupFailed(error); return false }
    }

    func resetAccountSetup() async {
        guard !isBusy, !needsOpeningReview, storageReady else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let preview = try await store.previewAccountSetupReset()
            guard preview.removedSavedEnvironmentCount > 0 else { return }
            guard confirmSetup(title: L10n.text("message.10250dfdab"), detail: L10n.text("message.a80bbaae71", preview.removedSavedEnvironmentCount), button: L10n.text("message.d1e7d1ae9c"), additionalConsent: true) else { return }
            _ = try await applySetup(preview, success: L10n.text("message.a0eca2612a"))
        } catch { await setupFailed(error) }
    }

    /// Fixed standard roots only: never select a running Codex instance or inspect its authorization.
    func addAccountBlockedReason(managed: Bool) -> String? {
        if needsOpeningReview { return L10n.text("review.previousOperation") }
        if !storageReady || !associationsReady || !managedStorageReady { return L10n.text("account.storageUnavailable") }
        if !managed && associations.contains(where: { $0.kind == .standardExternal }) { return L10n.text("account.alreadyLinked") }
        // Local metadata preparation performs no Codex validation, authorization read or lifecycle effect.
        if !managed {
            do {
                _ = try validator.directory(validator.userHome.appendingPathComponent(".codex").path, privateOnly: false)
                _ = try validator.directory(validator.userHome.appendingPathComponent("Library/Application Support/Codex").path, privateOnly: false)
            } catch { return L10n.text("account.unavailable") }
        }
        return nil
    }

    func addAccount(name: String, managed: Bool) async -> Bool {
        guard !isBusy, !needsOpeningReview, storageReady else { return false }
        if let reason = addAccountBlockedReason(managed: managed) { errorMessage = reason; return false }
        isBusy = true; defer { isBusy = false }
        do {
            let preview = try await store.previewNewAccount(name: name, managed: managed, validator: validator)
            let success = try await applySetup(preview, success: managed
                ? L10n.text("message.7fcd27f57c")
                : L10n.text("message.0746d362c1"))
            offerManagedSignIn = success && managed
            return success
        } catch {
            await setupFailed(error)
            // Keep profile validation/recovery errors; simplify environment-only setup failures.
            if pendingSetup == nil, storageReady, !(error is ProfileError) {
                let key = (error as? EnvironmentError) == .duplicateAssociation ? "account.alreadyLinked"
                    : (managed ? "account.createFailed" : "account.unavailable")
                lastErrorProvider = { L10n.text(key) }; errorMessage = L10n.text(key)
            }
            return false
        }
    }

    func restoreSavedManaged(_ id: UUID) async {
        guard !isBusy, !needsOpeningReview, storageReady else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let preview = try await store.previewSavedManagedRestore(environmentID: id)
            guard let item = retainedEnvironments.first(where: { $0.id == id }) else { throw AccountSetupError.conflict }
            guard confirmSetup(title: L10n.text("message.ca4dd4cbef"), detail: L10n.text("message.f9b461fcfb", item.profile.name, id.uuidString, item.association.codexHome, item.association.electronData), button: L10n.text("message.f8268d31fc")) else { return }
            _ = try await applySetup(preview, success: L10n.text("message.89787c9311"))
        } catch { await setupFailed(error) }
    }

    func reviewPendingSetup() async {
        guard !isBusy, let pending = pendingSetup else { return }
        isBusy = true; defer { isBusy = false }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L10n.text("message.1e8e229013")
        alert.informativeText = L10n.text("message.9d592c131b", pending.operation)
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel")); cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("message.02b55c56ec")).keyEquivalent = ""
        alert.addButton(withTitle: L10n.text("message.f37361768d")).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        let response = NativeModalPresentation.run(alert)
        guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
        do {
            let outcome = try await store.recoverAccountSetup(id: pending.id, decision: response == .alertSecondButtonReturn ? .finish : .restorePrevious)
            try acceptSetup(outcome, preservingActiveState: pending.operation == "clearSavedManaged")
            pendingSetup = try await store.inspectPendingAccountSetup()
            connectionNotice = L10n.text("message.166c987ae9")
        } catch { await setupFailed(error) }
    }

    private func confirmSetup(title: String, detail: String, button: String, additionalConsent: Bool = false) -> Bool {
        AccountSetupConfirmationUI(title: title, detail: detail, button: button, additionalConsent: additionalConsent).run()
    }

    private func acceptSetup(_ outcome: AccountSetupOutcome, preservingActiveState: Bool = false) throws {
        guard case let .committed(state) = outcome else { throw AccountSetupError.recoveryRequired }
        if profiles != state.profiles.profiles { profiles = state.profiles.profiles }
        if associations != state.associations.associations { associations = state.associations.associations }
        if preparedEnvironments != state.managed.prepared { preparedEnvironments = state.managed.prepared }
        retainedEnvironments = state.retained.environments
        manualConfirmations = manualConfirmations.filter { id, _ in profiles.contains(where: { $0.id == id }) }
        if !preservingActiveState { connectionErrors = []; offerManagedSignIn = false }
        storageReady = true; associationsReady = true; managedStorageReady = true
        errorMessage = nil; pendingSetup = nil
    }
    private func applySetup(_ preview: AccountSetupPreview, success: String) async throws -> Bool {
        let outcome = try await store.commitAccountSetup(preview)
        try acceptSetup(outcome, preservingActiveState: preview.operation == "clearSavedManaged")
        connectionNotice = success; return true
    }
    private func setupFailed(_ error: Error) async {
        show(error)
        do {
            pendingSetup = try await store.inspectPendingAccountSetup()
            if pendingSetup != nil { storageReady = false; associationsReady = false }
        } catch { storageReady = false; associationsReady = false; show(error) }
    }
    func recover() async -> Bool { await update { try await self.store.recoverBackup() } }

    func association(for profile: AccountProfile) -> EnvironmentAssociation? {
        associations.first { $0.profileID == profile.id }
    }
    func usageState(for profile: AccountProfile) -> UsageViewState { usage.state(for: profile.id) }
    func refreshUsage(_ profile: AccountProfile) { usage.refresh(profile.id) }

    func connectionState(for profile: AccountProfile) -> ProfileConnectionState {
        guard associationsReady else { return .error }
        return ConnectionPresentation.state(association: association(for: profile), failed: connectionErrors.contains(profile.id))
    }
    func canSwitch(_ profile: AccountProfile) -> Bool {
        DesktopIntegrationPolicy.lifecycleEnabled && associationsReady && !isBusy
            && connectionState(for: profile) == .connected
    }
    func manuallyConfirmAccount(_ profile: AccountProfile) {
        guard let association = association(for: profile) else { return }
        manualConfirmations[profile.id] = ManualAccountConfirmation(association: association)
        connectionNotice = L10n.text("message.6910fb9db8")
    }
    func prepareManagedEnvironment(_ profile: AccountProfile) async {
        guard !isBusy, storageReady, associationsReady, managedStorageReady, association(for: profile) == nil else { return }
        isBusy = true; defer { isBusy = false }
        do {
            _ = try await store.prepareManagedEnvironment(profileID: profile.id)
            preparedEnvironments = try await store.inspectManagedEnvironments().prepared
            errorMessage = nil
            connectionNotice = L10n.text("message.8306c1732d")
        } catch { show(error) }
    }

    func makeAssociation(for profile: AccountProfile, current: Bool, directory: URL?) throws -> EnvironmentAssociation {
        guard profiles.contains(where: { $0.id == profile.id }) else { throw ProfileError.missingProfile }
        if current {
            return try validator.link(profileID: profile.id, environmentID: profile.id, kind: .standardExternal,
                home: validator.userHome.appendingPathComponent(".codex").path,
                electron: validator.userHome.appendingPathComponent("Library/Application Support/Codex").path)
        }
        guard let directory, let environmentID = UUID(uuidString: directory.lastPathComponent) else { throw EnvironmentError.invalidPath }
        let managed = validator.managedRoot.appendingPathComponent("Profiles/\(profile.directoryIdentifier)")
        let kind: EnvironmentKind = directory == managed ? .managed :
            (directory.path.hasPrefix("/private/tmp/codexswoop-lab-") ? .temporaryResearch : .isolatedExternal)
        return try validator.link(profileID: profile.id, environmentID: environmentID, kind: kind,
                                  home: directory.appendingPathComponent("codex-home").path,
                                  electron: directory.appendingPathComponent("electron-user-data").path)
    }
    func link(_ candidate: EnvironmentAssociation) async -> Bool {
        guard !isBusy, storageReady, associationsReady else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            associations = try await store.linkEnvironment(candidate, validator: validator).associations
            connectionErrors.remove(candidate.profileID); errorMessage = nil; connectionNotice = nil
            return true
        } catch { show(error); return false }
    }
    func disconnect(_ profile: AccountProfile) async {
        guard !isBusy, associationsReady else { return }
        isBusy = true; defer { isBusy = false }
        do {
            associations = try await store.disconnectEnvironment(profileID: profile.id).associations
            connectionErrors.remove(profile.id); errorMessage = nil; connectionNotice = nil
            manualConfirmations.removeValue(forKey: profile.id)
        } catch { show(error) }
    }
    func checkConnection(_ profile: AccountProfile) {
        guard let value = association(for: profile) else { return }
        do {
            try validator.revalidate(value)
            connectionErrors.remove(profile.id)
            errorMessage = nil
            connectionNotice = L10n.text("message.ee301ab0fc")
        } catch { connectionNotice = nil; connectionErrors.insert(profile.id); show(error) }
    }
    func recoverEnvironmentMetadata() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            associations = try await store.recoverAssociationsBackup().associations
            associationsReady = true; connectionErrors = []; errorMessage = nil
        } catch { show(error) }
    }
    func openingBlockedReason(for profile: AccountProfile, mode: AccountOpeningMode = .openSeparately) -> String? {
        if isBusy { return L10n.text("message.7bdf731db2") }
        if needsOpeningReview { return L10n.text("review.previousOperation") }
        if !storageReady || !associationsReady { return L10n.text("message.92d6637423") }
        if association(for: profile) == nil { return L10n.text("message.0301e88b40") }
        if connectionErrors.contains(profile.id) { return L10n.text("message.cbdc541d36") }
        if let reason = installationBlockedReason { return reason }
        guard let association = association(for: profile), association.kind == .managed || association.kind == .standardExternal else {
            return L10n.text("message.f3a93ef749")
        }
        return nil
    }
    func startOpening(_ profile: AccountProfile, mode: AccountOpeningMode) {
        guard operationTask == nil, !isBusy else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.openProfile(profile, mode: mode)
            self.operationTask = nil
        }
    }
    func cancelOpening() { operationTask?.cancel() }
    func openProfile(_ profile: AccountProfile, mode: AccountOpeningMode) async {
        if let reason = openingBlockedReason(for: profile, mode: mode) { errorMessage = reason; return }
        isBusy = true; openingReviewResolved = false; openingMode = mode; connectionNotice = nil; errorMessage = nil
        defer { isBusy = false; openingMode = nil }
        do {
            try await coordinator.openAccount(to: profile, mode: mode, environmentScoped: true,
                confirmOpen: { await NativeSwitchingConfirmation.confirmOpening($0) },
                confirmClose: { await NativeSwitchingConfirmation.confirmClose($0) })
            switch await coordinator.openingResult {
            case .activatedExisting: connectionNotice = L10n.text("opening.activated")
            case .launched: connectionNotice = L10n.text("opening.launched")
            case nil: errorMessage = L10n.text("opening.noResult")
            }
        } catch {
            let disposition = await coordinator.openingDisposition
            needsOpeningReview = await coordinator.state == .recoveryRequired
            let closed = await coordinator.openingProgress.closedInstanceNames
            let requiresReview = needsOpeningReview
            lastErrorProvider = {
                let prefix = closed.isEmpty ? "" : L10n.text("message.56e563ef71") + closed.joined(separator: ", ") + ". "
                let dispositionText = requiresReview ? (disposition.flatMap { $0.errorDescription }.map { $0 + " " } ?? "") : ""
                let detail = (error as? any LocalizedError)?.errorDescription ?? L10n.text("message.ee90487fb2")
                return prefix + dispositionText + detail
            }
            openingReviewErrorProvider = needsOpeningReview ? lastErrorProvider : nil
            errorMessage = lastErrorProvider?()

        }
    }

    func reviewOpeningResult() async {
        guard !isBusy, needsOpeningReview else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("review.title")
        alert.informativeText = L10n.text("review.detail")
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel")); cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("review.check")).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        guard NativeModalPresentation.run(alert) == .alertSecondButtonReturn else { return }
        isBusy = true; defer { isBusy = false }
        do {
            _ = try await coordinator.refreshOpeningRecovery()
            try await coordinator.reconcileOpeningRecovery()
            needsOpeningReview = false; openingReviewErrorProvider = nil; errorMessage = nil; offerManagedSignIn = false
            openingReviewResolved = await coordinator.openingRecoveryResolution == .safeForNewOperation
            connectionNotice = L10n.text("review.resolved")
        } catch {
            show(error)
            // Keep the exact failed proof after dismissing unrelated form messages.
            openingReviewErrorProvider = lastErrorProvider
        }
    }

    private func update(_ operation: () async throws -> ProfileCatalog) async -> Bool {
        guard !isBusy, !needsOpeningReview else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            profiles = try await operation().profiles
            storageReady = true
            errorMessage = nil
            return true
        } catch {
            show(error)
            if let profileError = error as? ProfileError,
               [.corruptedStore, .unsupportedVersion, .unsafePath, .storageUnavailable].contains(profileError) {
                storageReady = false
            }
            return false
        }
    }

    func show(_ error: Error) {
        if error is OpeningJournalError { needsOpeningReview = true; openingReviewErrorProvider = { (error as? OpeningJournalError)?.errorDescription ?? L10n.text("review.journalDetail") } }
        lastErrorProvider = {
            if let description = (error as? ProfileError)?.errorDescription { return description }
            if let description = (error as? EnvironmentError)?.errorDescription { return description }
            if let description = (error as? SwitchingError)?.errorDescription { return description }
            if let description = (error as? AccountSetupError)?.errorDescription { return description }
            if let description = (error as? OpeningJournalError)?.errorDescription { return description }
            if let description = (error as? AccountOpeningError)?.errorDescription { return description }
            return L10n.text("message.944d592a28")
        }
        errorMessage = lastErrorProvider?()
    }

    func chooseCodex() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("message.287b34a6b0")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard let installation = CodexDetector().inspect(url) else {
                self.errorMessage = L10n.text("message.abc04aa349")
                return
            }
            if self.isTestStorage { self.testPreferredPath = url.path }
            else { self.defaults.set(url.path, forKey: "codexApplicationPath") }
            self.installation = installation
            self.refreshDetection()
            self.errorMessage = nil
        }
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setLoginEnabled(_ enabled: Bool) {
        guard !isTestStorage else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            if enabled && !loginEnabled && !loginNeedsApproval { loginError = L10n.text("onboarding.login.failed") }
        } catch {
            refreshLoginStatus()
            loginError = L10n.text("onboarding.login.failed")
            let failure = error as NSError
            lastErrorProvider = { L10n.text("onboarding.login.errorDetail", failure.domain, failure.code) }
            errorMessage = lastErrorProvider?()
        }
    }
}

/// Fixture UI has no path to native effects, even if an opening button is selected.
private struct SetupPreviewDesktopSystem: DesktopSystem {
    let lifecycleAllowed = false
    func validateInstallation() throws { throw EnvironmentOpeningError.unavailable }
    func observe(_ association: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        DesktopObservation(matching: [], ambiguous: false)
    }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) throws { throw EnvironmentOpeningError.unavailable }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) throws { throw EnvironmentOpeningError.unavailable }
    func launch(_ specification: DesktopLaunchSpecification) throws { throw EnvironmentOpeningError.unavailable }
}

@MainActor
private final class SetupConsentController: NSObject {
    private weak var button: NSButton?
    init(button: NSButton) { self.button = button }
    @objc func changed(_ sender: NSButton) { button?.isEnabled = sender.state == .on }
}

/// Native confirmation shared by production actions and offscreen fixture checks.
@MainActor
final class AccountSetupConfirmationUI {
    let alert = NSAlert()
    let consent = NSButton(checkboxWithTitle: L10n.text("message.3d3016d2b1"), target: nil, action: nil)
    private let controller: SetupConsentController
    private let additionalConsent: Bool
    init(title: String, detail: String, button: String, additionalConsent: Bool = false, consentTitle: String? = nil) {
        self.additionalConsent = additionalConsent
        alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel")); cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: button).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        consent.state = .off
        if let consentTitle { consent.title = consentTitle }
        consent.setAccessibilityLabel(consentTitle ?? L10n.text("message.4088b2673d"))
        controller = SetupConsentController(button: alert.buttons[1])
        if additionalConsent {
            alert.accessoryView = consent; alert.buttons[1].isEnabled = false
            consent.target = controller; consent.action = #selector(SetupConsentController.changed(_:))
        }
    }
    func run() -> Bool {
        NativeModalPresentation.run(alert) == .alertSecondButtonReturn && (!additionalConsent || consent.state == .on)
    }
}

/// AppKit replaces the Cancel button's Escape equivalent with Return when it becomes default.
/// Keep Escape reliable for every UI language without changing default/consent semantics.
@MainActor enum NativeModalPresentation {
    @MainActor private final class Cancellation {
        weak var alert: NSAlert?
        init(_ alert: NSAlert) { self.alert = alert }
        func cancelCurrentModal() -> Bool {
            guard let alert, NSApplication.shared.modalWindow === alert.window else { return false }
            NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
            return true
        }
    }
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let cancellation = Cancellation(alert)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { cancellation.cancelCurrentModal() }
            return consumed ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }
}
