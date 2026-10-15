import AppKit
import SwiftUI
import ServiceManagement
import CodexSwoopCore

private typealias SettingsState<Value> = SwiftUI.State<Value>

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let manager: ProfileManager
    init(manager: ProfileManager) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 400)
        window.contentViewController = NSHostingController(rootView: SettingsView(manager: manager))
        window.setContentSize(NSSize(width: 540, height: 640))
        window.setFrameAutosaveName(manager.isTestStorage ? "QASettingsWindow" : "SettingsWindow")
        super.init(window: window); window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present(diagnostics: Bool = false) {
        manager.showDiagnostics = diagnostics
        manager.refreshLoginStatus()
        manager.refreshPermissionStatus()
        window?.title = L10n.text("settings.title")
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { manager.showDiagnostics = false }
    func windowDidBecomeKey(_ notification: Notification) {
        manager.refreshLoginStatus(); manager.refreshPermissionStatus()
    }
}

struct SettingsView: View {
    @ObservedObject var manager: ProfileManager
    @SettingsState<Bool> private var profileRecovery = false
    @SettingsState<Bool> private var environmentRecovery = false
    @FocusState private var languageFocused: Bool
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if manager.showDiagnostics { diagnosticsSection }
                Section(L10n.text("settings.general")) {
                    Picker(L10n.text("settings.language"), selection: Binding(get: { manager.language }, set: { manager.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).focused($languageFocused)
                    Toggle(L10n.text("settings.login"), isOn: Binding(get: { manager.loginEnabled }, set: { manager.setLoginEnabled($0) }))
                        .disabled(manager.isTestStorage)
                    Text(L10n.text(manager.loginStatusKey)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("login-status")
                    Text(L10n.text("onboarding.login.optional")).font(.caption).foregroundStyle(.secondary)
                    if let error = manager.loginError {
                        Text(error).font(.caption)
                        Button(L10n.text("menu.details")) { manager.showDiagnostics = true }
                    }
                    if manager.loginNeedsApproval { Text(L10n.text("settings.loginApproval")).font(.caption).foregroundStyle(.secondary) }
                    Button(L10n.text("onboarding.checkStatus")) { manager.refreshLoginStatus() }
                    if manager.loginNeedsApproval { Button(L10n.text("onboarding.login.openSettings")) { SMAppService.openSystemSettingsLoginItems() } }
                }
                Section(L10n.text("settings.codex")) {
                    CodexAvailabilityView(manager: manager)
                    Button(L10n.text("settings.refresh")) { manager.refreshDetection() }
                    if manager.codexAvailability == .verified { Button(L10n.text("settings.choose")) { manager.chooseCodex() } }
                }
                Section(L10n.text("settings.accessibility")) {
                    LabeledContent(L10n.text("onboarding.permissionStatus")) {
                        Text(L10n.text(manager.accessibilityStatus.messageKey)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("accessibility-status")
                    }
                    Text(L10n.text("settings.axExplanation")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("onboarding.checkStatus")) { manager.refreshPermissionStatus() }
                    DisclosureGroup(L10n.text("onboarding.windowFeatures")) {
                        Text(L10n.text("onboarding.axWindowExplanation")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text("settings.openAX")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Section(L10n.text("settings.storage")) {
                    Text(L10n.text("settings.saved")).font(.subheadline).fontWeight(.medium)
                    if manager.retainedEnvironments.filter({ $0.association.kind == .managed }).isEmpty {
                        Text(L10n.text("settings.savedEmpty")).foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.retainedEnvironments.filter { $0.association.kind == .managed }) { item in
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.profile.name).lineLimit(1).truncationMode(.middle).help(item.profile.name)
                                    Text(L10n.text("settings.retained"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Button(L10n.text("settings.restore")) { Task { await manager.restoreSavedManaged(item.id) } }
                                    .accessibilityLabel(L10n.text("onboarding.restore", item.profile.name))
                            }.accessibilityElement(children: .contain)
                        }
                    }
                    Text(L10n.text("settings.preserve")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("settings.reset"), role: .destructive) { Task { await manager.resetAccountSetup() } }
                }
                if !manager.showDiagnostics { diagnosticsSection }

                Section {
                    LabeledContent("CodexSwoop") { Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))").foregroundStyle(.secondary) }
                    Text(L10n.text("settings.about")).font(.caption).foregroundStyle(.secondary)
                    if manager.isTestStorage { Text(L10n.text("menu.qa")).font(.caption2).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped).id(manager.language)
            .onAppear { languageFocused = !manager.showDiagnostics }
            .onChange(of: manager.showDiagnostics) { _, show in if show { languageFocused = false; proxy.scrollTo("diagnostics", anchor: .top) } }
            .onAppear { if manager.showDiagnostics { proxy.scrollTo("diagnostics", anchor: .top) } }
        }
        .onExitCommand { NSApplication.shared.keyWindow?.performClose(nil) }
        .frame(minWidth: 400, idealWidth: 540, minHeight: 340, idealHeight: 640)
        .alert(L10n.text("backup.profileTitle"), isPresented: $profileRecovery) {
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("common.recover")) { Task { _ = await manager.recover() } }
        } message: { Text(L10n.text("backup.profileDetail")) }
        .alert(L10n.text("backup.environmentTitle"), isPresented: $environmentRecovery) {
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("common.recover")) { Task { await manager.recoverEnvironmentMetadata() } }
        } message: { Text(L10n.text("backup.environmentDetail")) }
    }

    private var diagnosticsSection: some View {
        Section(L10n.text("settings.diagnostics")) {
            Button(L10n.text("settings.openErrorLog")) { manager.openErrorLog() }
            Button(L10n.text("settings.checkAll")) { for profile in manager.profiles { manager.checkConnection(profile) } }
            DisclosureGroup(L10n.text("settings.usage")) {
                Text(L10n.text("settings.usageDetail")).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("settings.lastError")).font(.subheadline).fontWeight(.medium)
                Text(manager.diagnosticErrorMessage ?? L10n.text("settings.noError"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if manager.needsOpeningReview {
                    Button(L10n.text("menu.review")) { Task { await manager.reviewOpeningResult() } }
                }
                if manager.pendingSetup != nil {
                    Button(L10n.text("setup.review")) { Task { await manager.reviewPendingSetup() } }
                } else {
                    if !manager.storageReady {
                        HStack {
                            Button(L10n.text("common.retry")) { Task { await manager.reload() } }
                            Button(L10n.text("backup.profileTitle")) { profileRecovery = true }
                        }
                    }
                    if !manager.associationsReady { Button(L10n.text("backup.environmentTitle")) { environmentRecovery = true } }
                }
            }.id("diagnostics")
        }
    }
}
