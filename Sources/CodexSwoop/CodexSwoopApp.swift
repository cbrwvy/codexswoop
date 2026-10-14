import AppKit
import SwiftUI
import CodexSwoopCore

#if !SETUP_UI_CHECKS
@main
struct CodexSwoopApp {
    @MainActor static func main() {
        if ProcessInfo.processInfo.arguments.contains("--pid-opening-trial") {
            print(L10n.text("message.4fe12ddf22"))
            exit(2)
        }
        if ProcessInfo.processInfo.arguments.contains("--window-ownership-preflight") {
            let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
            // A separate diagnostics process with this installed bundle's AX identity. No app UI,
            // metadata load/mutation, permission prompt or activation coordinator is started.
            Task {
                guard arguments.first == "--window-ownership-preflight" else { exit(2) }
                exit(await EnvironmentWindowPreflight.run(arguments: Array(arguments.dropFirst())))
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            let detector = CodexDetector()
            let configuration = ProfileManager.storageConfiguration()
            let preferredPath = configuration.isTest ? nil : UserDefaults.standard.string(forKey: "codexApplicationPath")
            let installation = detector.detect(preferredPath: preferredPath)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("message.d7b589254c")
            let store = ProfileStore(root: configuration.root)
            Task {
                // Deliberate allowlist: no profile names, paths, environment, or user file contents.
                print(L10n.text("message.9fffb9bda0", version))
                print(L10n.text("message.63b8a0d3a4", ProcessInfo.processInfo.operatingSystemVersionString))
                print(L10n.text("message.a9a56b6644", installation != nil))
                print(L10n.text("message.76aa43e568", installation?.version ?? L10n.text("common.none")))
                do {
                    let catalog = try await store.inspect()
                    print(L10n.text("message.bd13d1307f", catalog.profiles.count))
                    print(L10n.text("message.c6e5a682a1"))
                } catch {
                    print(L10n.text("message.68b9f4aa0d"))
                    print(L10n.text("message.05d6c12c8e", (error as? ProfileError)?.errorDescription ?? L10n.text("diagnostics.storageUnavailable")))
                }
                print(L10n.text("message.4479980b60"))
                print(L10n.text("message.177d857991"))
                print(L10n.text("message.79df49e4c0", loadMenuBarIcon() != nil ? L10n.text("diagnostics.iconAvailable") : L10n.text("common.none")))
                exit(0)
            }
            dispatchMain()
        }
        runGUI()
    }

    @MainActor private static func runGUI() {
        precondition(Thread.isMainThread, "AppKit must run on the original main thread")
        let application = NSApplication.shared
        let delegate = AppDelegate(manager: ProfileManager())
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let manager: ProfileManager
    private lazy var popoverAnchor = StatusPopoverAnchor(popover: popover) { [weak self] in self?.statusItem?.button }
    private lazy var settingsController = SettingsWindowController(manager: manager)

    init(manager: ProfileManager) { self.manager = manager; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = loadMenuBarIcon()
            button.toolTip = "CodexSwoop"
            button.setAccessibilityLabel("CodexSwoop")
            button.target = self
            button.action = #selector(togglePopover)
        }
        var testColorScheme: ColorScheme?
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--appearance"), args.indices.contains(index + 1) {
            testColorScheme = args[index + 1] == "dark" ? .dark : .light
        } else if manager.isTestStorage, let appearance = Bundle.main.object(forInfoDictionaryKey: "CodexSwoopTestAppearance") as? String {
            testColorScheme = appearance == "dark" ? .dark : .light
        }
        if let testColorScheme {
            popover.appearance = NSAppearance(named: testColorScheme == .dark ? .darkAqua : .aqua)
            NSApplication.shared.appearance = popover.appearance
        }
        #endif
        manager.presentSettings = { [weak self] diagnostics in
            guard let self else { return }
            self.popover.performClose(nil)
            self.settingsController.present(diagnostics: diagnostics)
        }
        manager.languageChanged = { [weak self] in
            self?.settingsController.window?.title = L10n.text("settings.title")
            self?.configureApplicationMenu()
        }
        configureApplicationMenu()
        statusItem = item
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: MenuBarView(manager: manager).preferredColorScheme(testColorScheme))
        Task {
            await manager.reload()
            #if DEBUG
            if manager.isTestStorage, Bundle.main.object(forInfoDictionaryKey: "CodexSwoopTestPreviewError") as? Bool == true {
                manager.show(EnvironmentError.readinessTimedOut)
            }
            #endif
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-menu") || (manager.isTestStorage && Bundle.main.object(forInfoDictionaryKey: "CodexSwoopTestShowMenu") as? Bool == true) { showPopover() }
        // Only an isolated debug session can preview the real conservative warning; no switching occurs.
        if ProfileManager.storageConfiguration().isTest,
           ProcessInfo.processInfo.arguments.contains("--preview-switch-warning") {
            Task {
                let activity = (try? await ConservativeActivityChecker().checkActivity()) ?? .unknown(.checkFailed)
                _ = await NativeSwitchingConfirmation.confirm(activity)
            }
        }
        #endif
    }

    /// Standard AppKit commands must also work while the Settings window owns the responder chain.
    private func configureApplicationMenu() {
        let menu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu()
        let settings = NSMenuItem(title: L10n.text("settings.title"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; applicationMenu.addItem(settings)
        applicationMenu.addItem(NSMenuItem(title: L10n.text("onboarding.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared; applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        NSApplication.shared.mainMenu = menu
    }
    @objc private func showSettings() { manager.openSettings() }

    func applicationDidBecomeActive(_ notification: Notification) {
        manager.refreshLoginStatus(); manager.refreshPermissionStatus(); manager.refreshDetection()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        showPopover()
    }

    private func showPopover() {
        guard !popover.isShown, popoverAnchor.show() else { return }
        popover.contentViewController?.view.window?.makeKey()
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await manager.reload() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// AppKit tracks the positioning view. A status button can also move with its *window*
/// while its local bounds remain unchanged. Reassert the current view on those events.
/// No stored screen coordinates, timer, content replacement, or close/reopen cycle.
@MainActor
final class StatusPopoverAnchor: NSObject, NSPopoverDelegate {
    private let popover: NSPopover
    private let currentButton: () -> NSView?
    private weak var observedButton: NSView?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    private var previousFrameNotifications = false
    private var previousBoundsNotifications = false

    init(popover: NSPopover, currentButton: @escaping () -> NSView?) {
        self.popover = popover; self.currentButton = currentButton
        super.init()
        popover.delegate = self
    }

    @discardableResult func show() -> Bool {
        guard let button = currentButton(), let window = button.window,
              window.isVisible, !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { return false }
        observe(button, window: window)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        return popover.isShown
    }

    private func observe(_ button: NSView, window: NSWindow) {
        guard observedButton !== button || observedWindow !== window else { return }
        stopObserving()
        observedButton = button; observedWindow = window
        previousFrameNotifications = button.postsFrameChangedNotifications
        previousBoundsNotifications = button.postsBoundsChangedNotifications
        button.postsFrameChangedNotifications = true
        button.postsBoundsChangedNotifications = true
        let events: [(Notification.Name, AnyObject?)] = [
            (NSView.frameDidChangeNotification, button), (NSView.boundsDidChangeNotification, button),
            (NSWindow.didMoveNotification, window), (NSWindow.didResizeNotification, window),
            (NSWindow.didChangeScreenNotification, window), (NSWindow.willCloseNotification, window),
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSApplication.didChangeScreenParametersNotification, nil)
        ]
        for (name, object) in events {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    private func scheduleRefresh() {
        guard popover.isShown, pendingRefresh == nil else { return }
        // Coalesce a layout burst, then read the actual button after AppKit finishes layout.
        pendingRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            self.refresh()
        }
    }

    func refresh() {
        guard popover.isShown else { stopObserving(); return }
        guard let button = currentButton(), let window = button.window,
              window.isVisible, !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else {
            popover.performClose(nil)
            stopObserving()
            return
        }
        observe(button, window: window)
        // On an already visible popover this updates its anchor; it does not reopen it.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) { stopObserving() }

    private func stopObserving() {
        pendingRefresh?.cancel(); pendingRefresh = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        observedButton?.postsFrameChangedNotifications = previousFrameNotifications
        observedButton?.postsBoundsChangedNotifications = previousBoundsNotifications
        observedButton = nil; observedWindow = nil
    }
}

@MainActor
private func loadMenuBarIcon() -> NSImage? {
    let image = NSImage(named: "MenuBarIcon")
    image?.isTemplate = true
    image?.size = NSSize(width: 18, height: 18)
    return image
}

/// Bound to the coordinator; each environment operation receives specific consent.
@MainActor
enum NativeSwitchingConfirmation {
    static func confirm(_ activity: CodexActivityStatus) async -> Bool {
        guard let warning = SwitchingWarning(activity: activity) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.message
        alert.informativeText = warning.detail
        alert.addButton(withTitle: SwitchingWarning.cancelTitle).keyEquivalent = "\r"
        alert.addButton(withTitle: SwitchingWarning.continueTitle).keyEquivalent = ""
        // Cancel is the default and Escape action. Closing the warning never authorizes a switch.
        alert.buttons[0].keyEquivalentModifierMask = []
        NSApplication.shared.activate(ignoringOtherApps: true)
        return NativeModalPresentation.run(alert) == .alertSecondButtonReturn
    }
}


extension NativeSwitchingConfirmation {
    @MainActor static func confirmOpening(_ plan: AccountOpeningPlan) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("message.ecdf29e1bb", plan.target.name)
        let action = plan.targetInstance.map { L10n.text("message.327af4e2b1", $0.main.pid) }
            ?? L10n.text("message.c422428afb")
        alert.informativeText = action + L10n.text("message.c27e7f0170", plan.association.kind == .standardExternal ? "Standard External" : "Managed Environment", plan.association.codexHome, plan.association.electronData)
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel")); cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("message.47c40f7547")).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        guard !Task.isCancelled else { return false }
        return NativeModalPresentation.run(alert) == .alertSecondButtonReturn && !Task.isCancelled
    }

    @MainActor static func confirmPIDEnvironment(_ plan: PIDEnvironmentOpeningPlan) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("message.f0d7f42301", plan.profile.name)
        alert.informativeText = EnvironmentOpeningPolicy.explanation
            + L10n.text("message.5a767395c3")
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("message.47c40f7547")).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        guard !Task.isCancelled else { return false }
        return NativeModalPresentation.run(alert) == .alertSecondButtonReturn && !Task.isCancelled
    }

    @MainActor static func confirmEnvironment(_ plan: EnvironmentOpeningPlan) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("message.f0d7f42301", plan.profile.name)
        alert.informativeText = EnvironmentOpeningPolicy.explanation + L10n.text("message.f8baba2ae8")
        let cancel = alert.addButton(withTitle: L10n.text("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("message.47c40f7547")).keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        guard !Task.isCancelled else { return false }
        return NativeModalPresentation.run(alert) == .alertSecondButtonReturn && !Task.isCancelled
    }

    @MainActor static func confirmClose(_ confirmation: AccountCloseConfirmation) -> AccountCloseDecision {
        let ui = makeCloseConfirmationUI(detail: confirmation.detail,
            primaryNames: confirmation.affected.filter(\.isPrimary).map(\.displayName))
        guard !Task.isCancelled, ui.run(), !Task.isCancelled else { return .cancel }
        return .confirm(allowPrimary: confirmation.requiresPrimaryConsent)
    }

    @MainActor static func makeCloseConfirmationUI(detail: String, primaryNames: [String]) -> AccountSetupConfirmationUI {
        AccountSetupConfirmationUI(title: L10n.text("message.6ac8869344"), detail: detail,
            button: L10n.text("message.b9c00fd9e0"), additionalConsent: !primaryNames.isEmpty,
            consentTitle: L10n.text("message.1c0410c771", primaryNames.joined(separator: ", ")))
    }
}
