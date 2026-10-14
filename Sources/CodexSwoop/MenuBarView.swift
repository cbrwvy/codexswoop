import SwiftUI
import CodexSwoopCore

private typealias ViewState<Value> = SwiftUI.State<Value>

struct MenuBarView: View {
    @ObservedObject var manager: ProfileManager
    @ViewState<Editor?> private var editor: Editor?
    @ViewState<AccountProfile?> private var connectionProfile: AccountProfile?
    @ViewState<AccountProfile?> private var pendingDisconnect: AccountProfile?
    @ViewState<AccountProfile?> private var pendingManualVerification: AccountProfile?
    private enum FocusTarget: Hashable { case add, settings, profile(UUID), manage(UUID) }
    @FocusState private var focused: FocusTarget?
    @ViewState<[FocusTarget: Int]> private var menuActivations: [FocusTarget: Int] = [:]
    private struct Editor: Identifiable { let id = UUID(); let profile: AccountProfile? }
    private let maximumHeight: CGFloat?
    init(manager: ProfileManager, maximumHeight: CGFloat? = nil) {
        self.manager = manager; self.maximumHeight = maximumHeight
    }
    private var heightLimit: CGFloat { maximumHeight ?? manager.menuMaximumHeight }

    var body: some View {
        ViewThatFits(in: .vertical) {
            menuContent.padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                menuContent.padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(width: 320).frame(maxHeight: heightLimit).fixedSize(horizontal: false, vertical: true)
        .onAppear { restoreFocus() }
        .onChange(of: manager.storageReady) { _, _ in restoreFocus() }
        .onChange(of: manager.isBusy) { _, busy in if !busy { restoreFocus() } }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            focused = nil
            Task { @MainActor in await Task.yield(); restoreFocus() }
        }
        .onChange(of: manager.profiles) { _, profiles in
            switch focused {
            case let .profile(id), let .manage(id): if !profiles.contains(where: { $0.id == id }) { restoreFocus() }
            case nil: restoreFocus()
            default: break
            }
        }
        .sheet(item: $editor, onDismiss: restoreFocus) { ProfileEditor(manager: manager, profile: $0.profile) }
        .sheet(item: $connectionProfile, onDismiss: restoreFocus) { ConnectionEditor(manager: manager, profile: $0) }
        .alert(L10n.text("visual.title"), isPresented: Binding(get: { pendingManualVerification != nil }, set: { if !$0 { pendingManualVerification = nil } })) {
            Button(L10n.text("common.cancel"), role: .cancel) { pendingManualVerification = nil }
            Button(L10n.text("visual.confirm")) {
                if let profile = pendingManualVerification { manager.manuallyConfirmAccount(profile) }
                pendingManualVerification = nil
            }
        } message: { Text(L10n.text("visual.detail")) }
        .alert(L10n.text("disconnect.title"), isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } })) {
            Button(L10n.text("common.cancel"), role: .cancel) { pendingDisconnect = nil }
            Button(L10n.text("disconnect.confirm")) {
                if let profile = pendingDisconnect { Task { await manager.disconnect(profile) } }
                pendingDisconnect = nil
            }
        } message: { Text(L10n.text("disconnect.detail")) }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CodexSwoop").font(.headline)
                Spacer()
                Button { manager.openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help(L10n.text("settings.title")).focusable()
                    .onKeyPress(.space) { manager.openSettings(); return .handled }
                    .accessibilityLabel(L10n.text("settings.title"))
                    .focused($focused, equals: .settings)
            }
            Divider()
            HStack {
                Text(L10n.text("menu.accounts")).font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                if manager.isBusy { ProgressView().controlSize(.mini).accessibilityLabel(L10n.text("menu.loading")) }
            }
            if manager.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(manager.showsWelcome ? "onboarding.welcome" : (manager.isBusy ? "menu.loading" : "menu.unavailable")))
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    if manager.showsWelcome {
                        Text(L10n.text("onboarding.intro")).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !manager.retainedEnvironments.isEmpty {
                            Button(L10n.text("onboarding.saved")) { manager.openSettings() }.buttonStyle(.link)
                        }
                    }
                }.padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.profiles) { profile in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary).accessibilityHidden(true)
                                    NativeAccountMenu(title: profile.name, label: L10n.text("menu.open", profile.name),
                                        value: L10n.text(manager.connectionErrors.contains(profile.id) ? "menu.environmentError" : (manager.association(for: profile) == nil ? "menu.notLinked" : "onboarding.linked")),
                                        activation: menuActivations[.profile(profile.id), default: 0], items: AccountOpeningMode.allCases.map { mode in
                                            AccountMenuItem(title: mode.title, enabled: manager.openingBlockedReason(for: profile, mode: mode) == nil,
                                                hint: manager.openingBlockedReason(for: profile, mode: mode) ?? mode.subtitle) {
                                                manager.startOpening(profile, mode: mode)
                                            }
                                        }).frame(maxWidth: .infinity, alignment: .leading)
                                        .focusable().focused($focused, equals: .profile(profile.id))
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: focused == .profile(profile.id) ? 2 : 0))
                                        .onKeyPress(.space) { activateMenu(.profile(profile.id)); return .handled }
                                        .onKeyPress(.return) { activateMenu(.profile(profile.id)); return .handled }
                                        .onKeyPress(.downArrow) { activateMenu(.profile(profile.id)); return .handled }
                                    NativeAccountMenu(title: L10n.text("menu.manage", profile.name), label: L10n.text("menu.manage", profile.name),
                                        symbol: "ellipsis.circle", activation: menuActivations[.manage(profile.id), default: 0], items: managementItems(profile))
                                        .frame(width: 24).focusable().focused($focused, equals: .manage(profile.id))
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: focused == .manage(profile.id) ? 2 : 0))
                                        .onKeyPress(.space) { activateMenu(.manage(profile.id)); return .handled }
                                        .onKeyPress(.return) { activateMenu(.manage(profile.id)); return .handled }
                                        .onKeyPress(.downArrow) { activateMenu(.manage(profile.id)); return .handled }

                                }
                                if manager.connectionErrors.contains(profile.id) || manager.association(for: profile) == nil {
                                    Text(L10n.text(manager.connectionErrors.contains(profile.id) ? "menu.environmentError" : "menu.notLinked"))
                                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 32)
                                }
                                // Strict Usage models/cache remain unchanged. No unavailable block or invented percentages.
                                if manager.usageState(for: profile).snapshot != nil {
                                    AccountUsageView(state: manager.usageState(for: profile)) { manager.refreshUsage(profile) }
                                        .padding(.leading, 32)
                                }
                            }.padding(.vertical, 8).padding(.horizontal, 2)
                        }
                    }
                }.frame(height: min(manager.profiles.reduce(CGFloat.zero) { height, profile in
                    height + (manager.usageState(for: profile).snapshot != nil ? 190 :
                        (manager.connectionErrors.contains(profile.id) || manager.association(for: profile) == nil ? 66 : 46))
                }, min(280, heightLimit * 0.45)))
            }
            Button { editor = Editor(profile: nil) } label: { Label(L10n.text("menu.add"), systemImage: "plus") }
                .buttonStyle(.bordered).keyboardShortcut("n").disabled(!manager.storageReady || manager.isBusy)
                .focusable().focused($focused, equals: .add)
                .onKeyPress(.space) {
                    guard manager.storageReady, !manager.isBusy else { return .ignored }
                    editor = Editor(profile: nil); return .handled
                }
                .accessibilityHint(L10n.text("onboarding.addHint"))
            if manager.installationBlockedReason != nil || manager.installationCompatibilityNotice != nil { CodexAvailabilityView(manager: manager) }
            if manager.needsOpeningReview || manager.errorMessage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(manager.friendlyError).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L10n.text("menu.details")) { manager.openSettings(diagnostics: true) }.buttonStyle(.link)
                    }
                    if manager.needsOpeningReview {
                        Button(L10n.text("menu.review")) { Task { await manager.reviewOpeningResult() } }
                            .disabled(manager.isBusy).accessibilityIdentifier("review-opening-result")
                    }
                }.accessibilityElement(children: .contain)
            } else if manager.connectionNotice != nil {
                Label(L10n.text(manager.openingReviewResolved ? "review.resolved" : (manager.offerManagedSignIn ? "message.7fcd27f57c" : "menu.done")), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if manager.openingMode != nil {
                Button(L10n.text("menu.cancel")) { manager.cancelOpening() }.buttonStyle(.link).help(L10n.text("menu.cancelHelp"))
            }
            Divider()
            HStack {
                Label(L10n.text(manager.codexAvailability == .verified ? "menu.detected" : (manager.installation == nil ? "menu.notFound" : "onboarding.codex.statusUnverified")) + (manager.installation.map { " · " + $0.version } ?? ""), systemImage: manager.codexAvailability == .verified ? "checkmark.circle" : "questionmark.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.text("menu.quit"))
                    .accessibilityLabel(L10n.text("menu.quit")).keyboardShortcut("q").focusable()
                    .onKeyPress(.space) { NSApplication.shared.terminate(nil); return .handled }
            }
            if manager.isTestStorage { Text(L10n.text("menu.qa")).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func activateMenu(_ target: FocusTarget) { menuActivations[target, default: 0] += 1 }
    private func managementItems(_ profile: AccountProfile) -> [AccountMenuItem] {
        var items: [AccountMenuItem] = []
        if manager.association(for: profile) == nil {
            items.append(AccountMenuItem(title: L10n.text("menu.connect"), enabled: manager.associationsReady) { connectionProfile = profile })
            if !manager.preparedEnvironments.contains(where: { $0.profileID == profile.id }) {
                items.append(AccountMenuItem(title: L10n.text("menu.prepare"), enabled: manager.managedStorageReady) { Task { await manager.prepareManagedEnvironment(profile) } })
            }
        } else {
            items.append(AccountMenuItem(title: L10n.text("menu.recheck")) { manager.checkConnection(profile) })
            items.append(AccountMenuItem(title: L10n.text("menu.visual")) { pendingManualVerification = profile })
            items.append(AccountMenuItem(title: L10n.text("menu.disconnect")) { pendingDisconnect = profile })
        }
        items.append(AccountMenuItem(title: L10n.text("menu.rename")) { editor = Editor(profile: profile) })
        items.append(AccountMenuItem(title: "", action: nil))
        items.append(AccountMenuItem(title: L10n.text("menu.remove")) { Task { _ = await manager.remove(id: profile.id) } })
        return items
    }
    private func restoreFocus() {
        let previous = focused
        focused = nil
        Task { @MainActor in
            await Task.yield()
            guard manager.storageReady, !manager.isBusy else { focused = .settings; return }
            switch previous {
            case let .profile(id), let .manage(id):
                if manager.profiles.contains(where: { $0.id == id }) { focused = previous }
                else if let first = manager.profiles.first { focused = .profile(first.id) } else { focused = .add }
            case .add: focused = .add
            default: if let first = manager.profiles.first { focused = .profile(first.id) } else { focused = .add }
            }
        }
    }

}

/// Real NSPopUpButton keeps native Space/Return/arrows/Escape and menu-item disabled semantics.
/// SwiftUI Menu's extra focus surface did not dispatch Space in the logged-in keyboard audit.
@MainActor private struct AccountMenuItem {
    let title: String
    var enabled = true
    var hint: String? = nil
    var action: (@MainActor () -> Void)?
}

@MainActor private final class AccountActionMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?
    @objc func invokeAccountAction(_ sender: Any?) {
        guard isEnabled else { return }
        handler?()
    }
}

@MainActor private struct NativeAccountMenu: NSViewRepresentable {
    let title: String
    let label: String
    var value: String? = nil
    var symbol: String? = nil
    let activation: Int
    let items: [AccountMenuItem]
    @MainActor final class Coordinator: NSObject {
        var activation = 0
        @objc func selectedAccountItem(_ sender: NSPopUpButton) {
            (sender.selectedItem as? AccountActionMenuItem)?.invokeAccountAction(sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false; button.focusRingType = .exterior
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? (symbol == nil ? 120 : 24)), height: 22)
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        for item in items {
            if item.action == nil { menu.addItem(.separator()); continue }
            let entry = AccountActionMenuItem(title: item.title, action: nil, keyEquivalent: "")
            entry.handler = item.action; entry.isEnabled = item.enabled; entry.toolTip = item.hint
            menu.addItem(entry)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectedAccountItem(_:))
        button.menu = menu; button.toolTip = title
        let display = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        display.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        (button.cell as? NSPopUpButtonCell)?.menuItem = display
        button.imagePosition = symbol == nil ? .noImage : .imageOnly
        button.setAccessibilityLabel(label); button.setAccessibilityValue(value)
        if context.coordinator.activation != activation {
            context.coordinator.activation = activation
            DispatchQueue.main.async { [weak button] in button?.performClick(nil) }
        }
    }
}

#if SETUP_UI_CHECKS
@MainActor enum NativeAccountMenuChecks {
    static func run() {
        var invoked = 0
        let item = AccountActionMenuItem(title: "Fixture action", action: #selector(AccountActionMenuItem.invokeAccountAction(_:)), keyEquivalent: "")
        item.handler = { invoked += 1 }; item.target = item
        precondition(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
        precondition(invoked == 1, "Native menu must dispatch the selected closure")
        item.isEnabled = false
        _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        precondition(invoked == 1, "Disabled menu item cannot invoke an action")
        let replacement = AccountActionMenuItem(title: "Other fixture", action: #selector(AccountActionMenuItem.invokeAccountAction(_:)), keyEquivalent: "")
        replacement.handler = { invoked += 10 }; replacement.target = replacement
        item.isEnabled = true
        _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        precondition(invoked == 2, "An old menu item must retain its own action after a view refresh")
        let button = NSPopUpButton(frame: .zero, pullsDown: true), menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")); menu.addItem(replacement)
        let coordinator = NativeAccountMenu.Coordinator()
        button.menu = menu; button.target = coordinator; button.action = #selector(NativeAccountMenu.Coordinator.selectedAccountItem(_:))
        button.selectItem(at: 1)
        precondition(NSApplication.shared.sendAction(button.action!, to: button.target, from: button))
        precondition(invoked == 12, "Popup control must route the selected menu item")
        print("PASS native popup selection, Objective-C dispatch, disabled-action guard and retained action identity")
    }
}
#endif

/// Shared discovery guidance uses the existing application picker and read-only revalidation.
struct CodexAvailabilityView: View {
    @ObservedObject var manager: ProfileManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text(manager.codexAvailability.messageKey), systemImage: manager.codexAvailability == .verified ? "checkmark.circle" : "info.circle")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let installation = manager.installation {
                Text(L10n.text("onboarding.codex.version", installation.version)).font(.caption).foregroundStyle(.secondary)
            }
            if let notice = manager.installationCompatibilityNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("onboarding.codex.lastTested", LastTestedCodexBuild.version)).font(.caption).foregroundStyle(.secondary)
            if manager.codexAvailability != .verified {
                HStack {
                    Button(L10n.text("settings.choose")) { manager.chooseCodex() }
                    if manager.installation == nil {
                        Link(L10n.text("onboarding.download"), destination: FirstRunPresentation.downloadURL)
                            .accessibilityHint(L10n.text("onboarding.downloadHint"))
                    } else {
                        Button(L10n.text("onboarding.checkAgain")) { manager.refreshDetection() }
                            .disabled(manager.codexAvailability == .checking)
                    }
                }.controlSize(.small)
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct ConnectionEditor: View {
    @ObservedObject var manager: ProfileManager
    let profile: AccountProfile
    @ViewState<Bool> private var useCurrent = true
    @ViewState<URL?> private var directory: URL?
    @ViewState<EnvironmentAssociation?> private var candidate: EnvironmentAssociation?
    @ViewState<String?> private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("message.06f2a0edf2")).font(.headline)
            Text(profile.name).font(.subheadline)
            Text(L10n.text("message.ee986a6259"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("connection.environment"), selection: $useCurrent) {
                Text(L10n.text("connection.current")).tag(true)
                Text(L10n.text("connection.isolated")).tag(false)
            }.pickerStyle(.radioGroup).onChange(of: useCurrent) { _, _ in candidate = nil; message = nil }
            if useCurrent {
                Text(L10n.text("message.ffc6526840"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button(L10n.text("connection.choose")) { chooseDirectory() }
                Text(directory?.path ?? L10n.text("connection.chooseDetail"))
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.text("connection.check")) {
                do {
                    candidate = try manager.makeAssociation(for: profile, current: useCurrent, directory: directory)
                    message = nil
                } catch {
                    candidate = nil
                    message = (error as? EnvironmentError)?.errorDescription ?? L10n.text("message.c15cdd6496")
                }
            }
            if let candidate {
                Text(candidate.isTemporary
                     ? L10n.text("message.4ce4ee0d33")
                     : L10n.text("message.8598a8cfdb"))
                    .font(.caption).foregroundStyle(candidate.isTemporary ? .orange : .secondary)
                Text(L10n.text("message.5638c9c401"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("message.60100daa61")) {
                    guard let candidate else { return }
                    Task {
                        if await manager.link(candidate) { dismiss() }
                        else { message = manager.errorMessage }
                    }
                }.disabled(candidate == nil || manager.isBusy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 380)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("message.f1d0272f0e")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            directory = panel.url; candidate = nil; message = nil
        }
    }
}

enum AddAccountMethod: String, CaseIterable {
    case existing, another
    var titleKey: String { self == .existing ? "account.link" : "account.new" }
    var detailKey: String { self == .existing ? "account.linkDetail" : "account.newDetail" }
    var symbol: String { self == .existing ? "desktopcomputer" : "person.crop.circle.badge.plus" }
}

/// A native button keeps Tab/Space, VoiceOver, and full-card hit testing consistent.
private struct AccountMethodCard: View {
    let method: AddAccountMethod
    let selected: Bool
    let action: () -> Void
    @ViewState<Bool> private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private let coral = Color(red: 0.89, green: 0.38, blue: 0.32)

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: method.symbol).font(.system(size: 17))
                    .frame(width: 22).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(method.titleKey)).font(.system(size: 13, weight: .semibold))
                    Text(L10n.text(method.detailKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.primary : Color.secondary).accessibilityHidden(true)
            }
            .padding(12).contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? coral.opacity(0.10) : Color.primary.opacity(hovered ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor : (contrast == .increased ? Color.primary : (selected ? coral : Color.primary.opacity(0.25))), lineWidth: focused || selected ? 2 : 1))
        }
        .buttonStyle(.plain).focusable().focused($focused)
        // Plain full-card buttons expose a separate focus surface on macOS; Space selects it.
        .onKeyPress(.space) { action(); return .handled }
        .onHover { hovered = $0 }
        .accessibilityLabel(L10n.text(method.titleKey)).accessibilityHint(L10n.text(method.detailKey))
        .accessibilityValue(L10n.text(selected ? "onboarding.selected" : "onboarding.notSelected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("add-account-" + method.rawValue)
    }
}

struct ProfileEditor: View {
    @ObservedObject var manager: ProfileManager
    let profile: AccountProfile?
    @ViewState<String> private var name: String
    @ViewState<Bool> private var attempted = false
    @ViewState<AddAccountMethod> private var method: AddAccountMethod
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    init(manager: ProfileManager, profile: AccountProfile?, managed: Bool = false, initialName: String = "") {
        self.manager = manager; self.profile = profile
        self._name = SwiftUI.State(initialValue: profile?.name ?? initialName)
        self._method = SwiftUI.State(initialValue: managed ? .another : .existing)
    }

    private var validName: Bool { (try? AccountProfile.validatedName(name)) != nil }
    private var blockedReason: String? { profile == nil ? manager.addAccountBlockedReason(managed: method == .another) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile == nil ? L10n.text("menu.add") : L10n.text("account.rename")).font(.headline)
            if profile == nil {
                VStack(spacing: 8) {
                    ForEach(AddAccountMethod.allCases, id: \.self) { choice in
                        AccountMethodCard(method: choice, selected: method == choice) {
                            method = choice; attempted = false
                        }
                    }
                }.disabled(manager.isBusy)
            }
            if profile == nil && (manager.installationBlockedReason != nil || manager.installationCompatibilityNotice != nil) { CodexAvailabilityView(manager: manager) }
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("account.profileName")).font(.system(size: 12, weight: .medium))
                TextField(L10n.text("account.namePlaceholder"), text: $name).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).accessibilityLabel(L10n.text("account.profileName"))
                    .accessibilityIdentifier("add-account-name").accessibilityHint(L10n.text("account.nameHint")).onSubmit { save() }
                    .disabled(manager.isBusy)
                Text(L10n.text("account.nameHint")).font(.caption).foregroundStyle(.secondary)
            }
            if !name.isEmpty && !validName {
                Text(ProfileError.invalidName.errorDescription ?? L10n.text("message.f04d8455dd"))
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let blockedReason, manager.installationBlockedReason == nil {
                Text(blockedReason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if attempted, let message = manager.errorMessage {
                Label(L10n.text("onboarding.actionFailed"), systemImage: "exclamationmark.circle")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.text("menu.details")) { Text(message).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(manager.isBusy)
                Spacer()
                if manager.isBusy { ProgressView().controlSize(.small) }
                Button(L10n.text(profile == nil ? "account.continue" : "common.save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(!validName || manager.isBusy || blockedReason != nil)
                    .accessibilityIdentifier("add-account-continue")
            }
        }.padding(20).frame(width: 400)
            .onAppear { nameFocused = true }
            .onDisappear { if manager.storageReady { manager.errorMessage = nil } }
    }

    private func save() {
        guard validName, !manager.isBusy, blockedReason == nil else { return }
        attempted = true
        let submittedName = name
        let managed = method == .another
        Task {
            let success: Bool
            if let profile { success = await manager.rename(id: profile.id, name: submittedName) }
            else { success = await manager.addAccount(name: submittedName, managed: managed) }
            if success { dismiss() } else { nameFocused = true }
        }
    }
}
