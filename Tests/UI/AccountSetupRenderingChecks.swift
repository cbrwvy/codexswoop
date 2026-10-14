import AppKit
import SwiftUI
import CodexSwoopCore
import ServiceManagement

/// Only fixture Swoop metadata and empty synthetic directories. Optional modal checks stay in this QA process; no lifecycle adapter is enabled.
@main struct AccountSetupRenderingChecks {
    @MainActor static func main() throws {
        let withAccessibility = CommandLine.arguments.contains("--with-accessibility")
        let menuLayoutOnly = CommandLine.arguments.contains("--menu-layout-checks")
        NSApplication.shared.setActivationPolicy(withAccessibility ? .accessory : .prohibited)
        if withAccessibility {
            NSApplication.shared.finishLaunching()
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        }
        for frame in [NSRect(x: 0, y: 0, width: 800, height: 480),
                      NSRect(x: -1200, y: 90, width: 1200, height: 700),
                      NSRect(x: 200, y: -900, width: 900, height: 600)] {
            let anchor = NSRect(x: frame.midX, y: frame.maxY, width: 24, height: 24)
            let height = MenuPopoverGeometry.maximumContentHeight(anchor: anchor, visibleFrame: frame)
            precondition(height > 0 && height <= 560 && height + 40 <= frame.height)
            let lower = anchor.offsetBy(dx: 0, dy: -100)
            precondition(MenuPopoverGeometry.maximumContentHeight(anchor: lower, visibleFrame: frame) <= height)
            for chrome in [CGFloat(16), 32, 60] {
                let limit = MenuPopoverGeometry.maximumContentHeight(anchor: anchor, visibleFrame: frame, chromeHeight: chrome)
                let oversizedOrigin = NSRect(x: frame.maxX + 100, y: frame.maxY + 200, width: 320, height: limit + chrome)
                let bounded = MenuPopoverGeometry.constrainedFrame(oversizedOrigin, anchor: anchor, visibleFrame: frame)
                precondition(frame.contains(bounded) && bounded.maxY <= anchor.minY,
                    "Popover must fit below the menu bar on scaled/negative-coordinate displays")
            }
        }
        NativeAccountMenuChecks.run()
        if withAccessibility {
            for language in [AppLanguage.english, .russian, .uzbek] {
                L10n.setSessionLanguage(language)
                let ui = AccountSetupConfirmationUI(title: "Fixture Escape check", detail: "Synthetic UI only", button: "Fixture confirm")
                var timedOut = false
                let number = ui.alert.window.windowNumber
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: number, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                DispatchQueue.main.async { NSApplication.shared.postEvent(event, atStart: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if NSApplication.shared.modalWindow === ui.alert.window { timedOut = true; NSApplication.shared.stopModal(withCode: .abort) }
                }
                precondition(!ui.run() && !timedOut, "Escape must cancel a localized Cancel-default modal")
                precondition(ui.alert.window.defaultButtonCell === ui.alert.buttons[0].cell)
            }
            print("PASS Escape cancels native Cancel-default modal in EN/RU/UZ without consent or effects")
        }
        let configuration = ProfileManager.storageConfiguration()
        precondition(configuration.isTest && configuration.root.path.hasPrefix("/private/tmp/codexswoop-"))
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let user = configuration.root.appendingPathComponent("fixture-user")
        for path in [user.appendingPathComponent(".codex"), user.appendingPathComponent("Library/Application Support/Codex")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let managerFixtureSuite = "codexswoop-ui-fixture-" + UUID().uuidString
        let fixtureDefaults = UserDefaults(suiteName: managerFixtureSuite)!
        defer { fixtureDefaults.removePersistentDomain(forName: managerFixtureSuite) }
        let manager = ProfileManager(defaults: fixtureDefaults)
        manager.setLanguage(.english)
        let store = ProfileStore(root: configuration.root)
        var rendered = 0, semanticChecks = 0
        func attribute(_ node: NSObject, _ key: NSAccessibility.Attribute) -> Any? {
            if let accessible = node as? any NSAccessibilityProtocol {
                switch key {
                case .children: return accessible.accessibilityChildren()
                case .identifier: return accessible.accessibilityIdentifier()
                case .role: return accessible.accessibilityRole()?.rawValue
                case .description: return accessible.accessibilityLabel()
                case .help: return accessible.accessibilityHelp()
                case .value: return accessible.accessibilityValue()
                case .enabled: return accessible.isAccessibilityEnabled()
                default: break
                }
            }
            if key == .enabled, node.responds(to: NSSelectorFromString("isAccessibilityEnabled")) {
                return node.value(forKey: "accessibilityEnabled")
            }
            // SwiftUI's private bridge may implement getters without adopting the full protocol.
            let getters: [NSAccessibility.Attribute: String] = [.children: "accessibilityChildren", .identifier: "accessibilityIdentifier",
                .role: "accessibilityRole", .description: "accessibilityLabel", .help: "accessibilityHelp", .value: "accessibilityValue"]
            if let getter = getters[key], node.responds(to: NSSelectorFromString(getter)) {
                return node.perform(NSSelectorFromString(getter))?.takeUnretainedValue()
            }
            return node.accessibilityAttributeValue(key)
        }
        func accessibilityNodes(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 30, let node = value as? NSObject else { return [] }
            let children = attribute(node, .children) as? [Any] ?? []
            return [node] + children.flatMap { accessibilityNodes($0, depth: depth + 1) }
        }
        func popupControls(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popupControls)
        }
        func render<V: View>(_ view: V, _ name: String, highContrast: Bool = false, owner: ProfileManager? = nil) throws {
            let renderingManager = owner ?? manager
            if menuLayoutOnly && name != "two-profiles" && !name.hasPrefix("bounded-warning-") && name != "six-long-profiles" { return }
            for language in [AppLanguage.english, .russian, .uzbek] {
            renderingManager.setLanguage(language)
            if name == "login-error" { precondition(manager.loginError == L10n.text("onboarding.login.failed")) }
            if name == "previous-error" || name == "error-diagnostics" { precondition(manager.errorMessage == EnvironmentError.readinessTimedOut.errorDescription) }
            for scheme in [ColorScheme.light, .dark] {
                NSApplication.shared.appearance = NSAppearance(named: highContrast ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (scheme == .dark ? .darkAqua : .aqua))
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).background(scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white))
                host.appearance = NSApplication.shared.appearance
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let size = host.fittingSize
                precondition(size.width >= 300 && size.width <= 560 && size.height > 100 && size.height < 800, "Invalid layout \(name): \(size)")
                if name.hasPrefix("bounded-warning-") {
                    let limit = CGFloat(Int(name.split(separator: "-").last!)!)
                    precondition(size.height <= limit + 1, "Menu exceeded synthetic screen budget")
                }
                host.frame = NSRect(origin: .zero, size: size)
                // AppKit-backed scroll views need a window for layout/cacheDisplay, even
                // offscreen. An unattached host can produce a nonempty all-black PNG.
                let renderingWindow = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                renderingWindow.isReleasedWhenClosed = false
                renderingWindow.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let fitted = host.fittingSize
                precondition(fitted.width >= 300 && fitted.height > 100, "Collapsed layout \(name): \(fitted)")
                renderingWindow.setContentSize(fitted)
                host.frame = NSRect(origin: .zero, size: fitted)
                if name.hasPrefix("bounded-warning-") {
                    precondition(fitted.height <= CGFloat(Int(name.split(separator: "-").last!)!) + 1)
                }
                defer { renderingWindow.contentView = nil; renderingWindow.close() }
                host.layoutSubtreeIfNeeded()
                if name == "opening-review-restored-details" {
                    renderingManager.showDiagnostics = false
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    renderingManager.showDiagnostics = true
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                for control in popupControls(host) {
                    let rect = control.convert(control.bounds, to: host)
                    precondition(rect.width <= host.bounds.width + 1 && rect.minX >= -1 && rect.maxX <= host.bounds.maxX + 1,
                        "Native control overflow in " + name + ": " + String(describing: rect))
                }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]), png.count > 1000 else { fatalError("Empty bitmap") }
                try png.write(to: output.appendingPathComponent(name + "-" + language.rawValue + (scheme == .dark ? "-dark.png" : "-light.png")))
                if name == "bounded-warning-240" {
                    func scrollViews(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                    }
                    guard let scroll = scrollViews(host).first(where: {
                        ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
                    }), let document = scroll.documentView else { fatalError("Overflowing menu must scroll") }
                    let beforeScroll = scroll.contentView.bounds.origin
                    document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    precondition(scroll.contentView.bounds.origin != beforeScroll, "Warnings/footer must be reachable")
                    guard let scrolledRep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No scrolled bitmap") }
                    host.cacheDisplay(in: host.bounds, to: scrolledRep)
                    let scrolledPNG = scrolledRep.representation(using: .png, properties: [:])!
                    try scrolledPNG.write(to: output.appendingPathComponent(name + "-scrolled-" + language.rawValue + (scheme == .dark ? "-dark.png" : "-light.png")))
                }
                if withAccessibility && (name == "link-existing" || name == "add-another") {
                    // Visible in-process component host, enabled only for an explicit logged-in QA run.
                    // No native input, permission request, or Desktop adapter is used.
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    let nodes = accessibilityNodes(window)
                    func node(_ identifier: String) -> NSObject {
                        guard let item = nodes.first(where: { attribute($0, .identifier) as? String == identifier }) else { fatalError("Missing accessibility element: " + identifier) }
                        return item
                    }
                    for method in AddAccountMethod.allCases {
                        let card = node("add-account-" + method.rawValue)
                        let selected = (method == .existing) == (name == "link-existing")
                        precondition(attribute(card, .role) as? String == NSAccessibility.Role.button.rawValue)
                        precondition(attribute(card, .description) as? String == L10n.text(method.titleKey))
                        precondition(attribute(card, .help) as? String == L10n.text(method.detailKey))
                        precondition(attribute(card, .value) as? String == L10n.text(selected ? "onboarding.selected" : "onboarding.notSelected"))
                    }
                    precondition(attribute(node("add-account-name"), .description) as? String == L10n.text("account.profileName"))
                    precondition(attribute(node("add-account-continue"), .enabled) as? Bool == false)
                    semanticChecks += 1
                    window.orderOut(nil); window.contentView = nil
                }
                rendered += 1
            }
            }
            manager.setLanguage(.english)
        }
        try MainThreadPreparation.wait { await manager.reload() }
        precondition(manager.storageReady && manager.profiles.isEmpty)
        precondition(manager.showsWelcome && manager.codexAvailability == .verified)
        precondition(manager.accessibilityStatus == .denied && manager.loginError == nil)
        try render(MenuBarView(manager: manager), "empty")
        for state in [CodexAvailability.missing, .checking, .unverified] {
            manager.previewInstallationForChecks(state)
            let before = try MainThreadPreparation.wait { try await store.inspectAccountSetup() }
            precondition(manager.addAccountBlockedReason(managed: true) == nil)
            let after = try MainThreadPreparation.wait { try await store.inspectAccountSetup() }
            precondition(after == before, "Read-only discovery cannot mutate local profiles")
            try render(MenuBarView(manager: manager), "onboarding-" + state.rawValue)
            try render(ProfileEditor(manager: manager, profile: nil), "onboarding-form-" + state.rawValue)
            manager.errorMessage = nil
        }
        manager.previewInstallationForChecks(.verified)
        try render(ProfileEditor(manager: manager, profile: nil)
            .dynamicTypeSize(.accessibility1), "contrast-large-text", highContrast: true)
        try render(SettingsView(manager: manager).frame(width: 440, height: 400), "permission-denied-login-off")
        for status in [SMAppService.Status.notRegistered, .notFound, .requiresApproval, .enabled] {
            manager.previewLoginStatusForChecks(status)
            precondition(manager.loginEnabled == (status == .enabled))
            precondition(manager.loginNeedsApproval == (status == .requiresApproval))
        }
        manager.previewLoginStatusForChecks(.requiresApproval)
        try render(SettingsView(manager: manager).frame(width: 540, height: 640), "login-awaiting-approval")
        manager.previewLoginStatusForChecks(.notFound, failed: true)
        try render(SettingsView(manager: manager).frame(width: 540, height: 640), "login-error")
        manager.previewLoginStatusForChecks(.notFound)
        manager.refreshLoginStatus()
        try render(ProfileEditor(manager: manager, profile: nil), "link-existing")
        try render(ProfileEditor(manager: manager, profile: nil, managed: true), "add-another")
        try render(ProfileEditor(manager: manager, profile: nil, managed: true, initialName: "Work"), "filled-name")
        try render(ProfileEditor(manager: manager, profile: nil, initialName: String(repeating: "W", count: 81)), "invalid-long-name")
        precondition(manager.addAccountBlockedReason(managed: false) == nil)
        let detected = manager.installation
        manager.previewInstallationForChecks(.missing)
        precondition(manager.addAccountBlockedReason(managed: false) == nil)
        try render(ProfileEditor(manager: manager, profile: nil), "codex-not-installed")
        manager.previewInstallationForChecks(.verified)
        precondition(manager.installation == detected)
        let defaultHome = user.appendingPathComponent(".codex")
        try FileManager.default.moveItem(at: defaultHome, to: user.appendingPathComponent("unavailable-fixture"))
        precondition(manager.addAccountBlockedReason(managed: false) == L10n.text("account.unavailable"))
        try render(ProfileEditor(manager: manager, profile: nil), "default-unavailable")
        try FileManager.default.moveItem(at: user.appendingPathComponent("unavailable-fixture"), to: defaultHome)
        manager.previewInstallationForChecks(.verified, version: "26.1007.71326", build: "updated-fixture")
        precondition(manager.installationCompatibilityNotice?.contains("26.1007.71326") == true)
        try render(ProfileEditor(manager: manager, profile: nil, managed: true, initialName: "Work"), "updated-version-continue-enabled")
        try MainThreadPreparation.wait {
            guard await manager.addAccount(name: "Fictional Primary", managed: false),
                  await manager.addAccount(name: "Fictional Work", managed: true) else { fatalError(manager.errorMessage ?? "Fixture add failed") }
        }
        precondition(manager.profiles.count == 2 && manager.associations.count == 2 && !manager.showsWelcome)
        let activeBeforeUpdate = try MainThreadPreparation.wait { try await store.inspectAccountSetup() }
        manager.previewInstallationForChecks(.unverified)
        precondition(!manager.showsWelcome && manager.profiles.allSatisfy { manager.openingBlockedReason(for: $0) != nil })
        precondition(manager.addAccountBlockedReason(managed: true) == nil, "Unverifiable processes/signatures only block lifecycle, not metadata setup")
        let activeAfterUpdate = try MainThreadPreparation.wait { try await store.inspectAccountSetup() }
        precondition(activeAfterUpdate == activeBeforeUpdate)
        try render(MenuBarView(manager: manager), "updated-codex-profiles-preserved")
        manager.previewInstallationForChecks(.verified)
        precondition(manager.addAccountBlockedReason(managed: false) == L10n.text("account.alreadyLinked"))
        precondition(manager.addAccountBlockedReason(managed: true) == nil)
        try render(ProfileEditor(manager: manager, profile: nil), "already-linked")
        try MainThreadPreparation.wait {
            let before = try await store.inspectAccountSetup()
            let added = await manager.addAccount(name: "Duplicate default", managed: false)
            let after = try await store.inspectAccountSetup()
            precondition(!added && after == before)
        }
        manager.errorMessage = nil
        try render(MenuBarView(manager: manager), "two-profiles")
        manager.previewOpeningReviewForChecks(.opening(.recoveryTargetChanged))
        for height in [CGFloat(240), CGFloat(360)] {
            try render(MenuBarView(manager: manager, maximumHeight: height), "bounded-warning-\(Int(height))")
        }
        manager.previewOpeningReviewForChecks(nil)

        try MainThreadPreparation.wait {
            for index in 0..<4 { guard await manager.create(name: "Fictional extra \(index)") else { fatalError("Fixture create") } }
            _ = await manager.rename(id: manager.profiles[0].id, name: "Very long fictional profile name · Очень длинное имя · Juda uzun hisob nomi")
        }
        precondition(manager.profiles.count == 6)
        try render(MenuBarView(manager: manager), "six-long-profiles")
        if menuLayoutOnly { print("PASS bounded menu geometry and \(rendered) two/six-profile warning renders"); return }
        manager.show(EnvironmentError.readinessTimedOut)
        try render(MenuBarView(manager: manager), "previous-error")
        try render(SettingsView(manager: manager).frame(width: 440, height: 400), "error-diagnostics")
        manager.errorMessage = nil
        try MainThreadPreparation.wait {
            for profile in manager.profiles.dropFirst(2) {
                let preview = try await store.previewProfileRemoval(id: profile.id)
                _ = try await store.commitAccountSetup(preview)
            }
            await manager.reload()
        }
        manager.previewOpeningReviewForChecks(.opening(.launchFailure))
        manager.errorMessage = nil // Reproduce dismissing a form/clearing an unrelated message.
        precondition(manager.needsOpeningReview)
        precondition(manager.diagnosticErrorMessage == SwitchingError.opening(.launchFailure).errorDescription)
        for language in [AppLanguage.english, .russian, .uzbek] {
            manager.setLanguage(language)
            precondition(manager.diagnosticErrorMessage == SwitchingError.opening(.launchFailure).errorDescription)
        }
        manager.setLanguage(.english)
        precondition(manager.profiles.allSatisfy { manager.openingBlockedReason(for: $0) == L10n.text("review.previousOperation") })
        try render(MenuBarView(manager: manager), "opening-review-required")
        try render(SettingsView(manager: manager).frame(width: 440, height: 400), "opening-review-retained-error")
        manager.previewOpeningReviewForChecks(nil)
        precondition(manager.diagnosticErrorMessage == nil)
        let previousJournal = try Data(contentsOf: configuration.root.appendingPathComponent("opening-journal.json"))
        let previousWatermark = try Data(contentsOf: configuration.root.appendingPathComponent("opening-journal-watermark.json"))
        // A fresh manager must discover a real pending journal in fixture storage, not a preview latch.
        try MainThreadPreparation.wait {
            let validator = EnvironmentValidator(userHome: user, managedRoot: configuration.root)
            let driver = DesktopSwitchingDriver(bootSession: { "synthetic-boot" }, store: store, validator: validator,
                system: JournalRenderingDesktopSystem())
            let plan = try await driver.planEnvironmentAccount(profile: manager.profiles[0], mode: .openSeparately)
            let managed = try await store.inspectManagedEnvironments()
            let journal = OpeningOperationJournal(root: configuration.root)
            try journal.begin(PendingOpeningOperation(scope: EnvironmentOperationScope(plan: plan, managed: managed), bootSession: "synthetic-boot", buildFingerprint: try await JournalRenderingDesktopSystem().openingBuildFingerprint()))
            journal.abandon()
        }
        let recoveredManager = ProfileManager(defaults: fixtureDefaults)
        try MainThreadPreparation.wait { await recoveredManager.reload() }
        precondition(recoveredManager.needsOpeningReview && recoveredManager.storageReady)
        precondition(recoveredManager.profiles.allSatisfy { recoveredManager.openingBlockedReason(for: $0) != nil })
        try render(MenuBarView(manager: recoveredManager), "opening-review-restored", owner: recoveredManager)
        try render(SettingsView(manager: recoveredManager).frame(width: 440, height: 400), "opening-review-restored-details", owner: recoveredManager)
        // Test-only cleanup; the production UI has no reset/delete-journal action.
        try FileManager.default.removeItem(at: configuration.root.appendingPathComponent("opening-journal.json"))
        try MainThreadPreparation.wait { await recoveredManager.reload() }
        precondition(recoveredManager.needsOpeningReview, "A missing journal cannot dismiss a live latch")
        // Restore the earlier paired fixture snapshot, never a production recovery mechanism.
        try AtomicMetadataWriter().write(previousWatermark, to: configuration.root.appendingPathComponent("opening-journal-watermark.json"))
        try AtomicMetadataWriter().write(previousJournal, to: configuration.root.appendingPathComponent("opening-journal.json"))
        let windowController = SettingsWindowController(manager: manager)
        let originalWindow = windowController.window
        for _ in 0..<3 {
            windowController.present(); windowController.close()
            precondition(windowController.window === originalWindow)
        }
        let currentLanguage = manager.language
        manager.setLanguage(.uzbek)
        let reloadedPreferences = ProfileManager(defaults: UserDefaults(suiteName: managerFixtureSuite)!)
        precondition(reloadedPreferences.language == .uzbek)
        manager.setLanguage(currentLanguage)
        try MainThreadPreparation.wait {
            let preview = try await store.previewProfileRemoval(id: manager.profiles[1].id)
            _ = try await store.commitAccountSetup(preview); await manager.reload()
        }
        precondition(manager.profiles.count == 1 && manager.retainedEnvironments.count == 1)
        try MainThreadPreparation.wait {
            let remaining = try await store.previewProfileRemoval(id: manager.profiles[0].id)
            _ = try await store.commitAccountSetup(remaining); await manager.reload()
        }
        precondition(manager.showsWelcome && !manager.retainedEnvironments.isEmpty)
        try render(MenuBarView(manager: manager), "welcome-with-retained-accounts")
        try MainThreadPreparation.wait {
            guard await manager.addAccount(name: "Fictional Primary", managed: false) else { fatalError("Relink fixture") }
        }
        try render(MenuBarView(manager: manager), "one-profile")
        try render(SettingsView(manager: manager).frame(width: 540, height: 640), "saved-environment-settings")
        try render(SettingsView(manager: manager).frame(width: 440, height: 400), "narrow-small-settings")
        try MainThreadPreparation.wait {
            let before = try await store.inspectAccountSetup()
            let preview = try await store.previewAccountSetupReset()
            precondition(preview.removedProfiles.isEmpty && preview.removedSavedEnvironmentCount == 1)
            _ = try await store.commitAccountSetup(preview); await manager.reload()
            let after = try await store.inspectAccountSetup()
            precondition(after.profiles == before.profiles && after.associations == before.associations && after.managed == before.managed)
            precondition(after.retained.environments == before.retained.environments.filter { $0.association.kind != .managed })
        }
        precondition(manager.storageReady && manager.profiles.count == 1 && manager.retainedEnvironments.count == 1
            && manager.retainedEnvironments.allSatisfy { $0.association.kind == .standardExternal })
        try render(SettingsView(manager: manager).frame(width: 540, height: 640), "cleared-saved-settings")
        try render(MenuBarView(manager: manager), "active-profile-after-saved-clear")
        try MainThreadPreparation.wait {
            guard await manager.addAccount(name: "Saved for interrupted clear", managed: true) else { fatalError("Fixture add") }
            let removal = try await store.previewProfileRemoval(id: manager.profiles.last!.id)
            _ = try await store.commitAccountSetup(removal); await manager.reload()
        }
        try MainThreadPreparation.wait {
            let faulty = ProfileStore(root: configuration.root, writer: AtomicMetadataWriter { url in
                if url.lastPathComponent == "retained-environments.json" { throw AccountSetupError.writeFailed }
            })
            let preview = try await faulty.previewAccountSetupReset()
            let outcome = try await faulty.commitAccountSetup(preview)
            precondition(outcome == .reviewRequired)
            await manager.reload()
        }
        precondition(manager.pendingSetup != nil && !manager.storageReady)
        try render(MenuBarView(manager: manager), "interrupted-setup")
        let removal = AccountSetupConfirmationUI(title: "Remove “Fictional Work”?", detail: "Profile and active link only. Codex data and running instances stay unchanged.", button: "Remove Profile")
        precondition(removal.alert.buttons.map(\.title) == ["Cancel", "Remove Profile"])
        precondition(removal.alert.window.defaultButtonCell === removal.alert.buttons[0].cell)
        // AppKit rewrites the default cell's key equivalent to Return; Cancel remains default.
        precondition(removal.alert.buttons[0].keyEquivalent == "\r" && removal.alert.buttons[1].keyEquivalent.isEmpty)
        let reset = AccountSetupConfirmationUI(title: L10n.text("message.10250dfdab"), detail: L10n.text("message.a80bbaae71", 1), button: L10n.text("message.d1e7d1ae9c"), additionalConsent: true)
        precondition(reset.alert.messageText == "Clear saved accounts?")
        precondition(reset.alert.informativeText.contains("Active profiles and their links stay unchanged"))
        precondition(reset.consent.title.contains("only saved records"))
        precondition(reset.alert.window.defaultButtonCell === reset.alert.buttons[0].cell)
        precondition(reset.consent.state == .off && !reset.alert.buttons[1].isEnabled)
        reset.consent.performClick(nil)
        precondition(reset.consent.state == .on && reset.alert.buttons[1].isEnabled)
        reset.consent.performClick(nil)
        precondition(!reset.alert.buttons[1].isEnabled)
        for language in [AppLanguage.english, .russian, .uzbek] {
            manager.setLanguage(language)
            for _ in 0..<6 {
                let close = NativeSwitchingConfirmation.makeCloseConfirmationUI(detail: "Fixture: close only QA Primary", primaryNames: ["QA Primary"])
                precondition(close.alert.window.defaultButtonCell === close.alert.buttons[0].cell)
                precondition(close.alert.buttons[0].keyEquivalent == "\r" && close.alert.buttons[1].keyEquivalent.isEmpty)
                precondition(close.consent.state == .off && !close.alert.buttons[1].isEnabled)
                precondition(close.consent.title.contains("QA Primary") && !close.consent.title.contains("Standard External"))
                close.consent.performClick(nil)
                precondition(close.consent.state == .on && close.alert.buttons[1].isEnabled)
                close.consent.performClick(nil)
                precondition(!close.alert.buttons[1].isEnabled)
                let work = NativeSwitchingConfirmation.makeCloseConfirmationUI(detail: "Fixture: close only QA Work", primaryNames: [])
                precondition(work.alert.accessoryView == nil && work.alert.buttons[1].isEnabled)
            }
        }
        if !withAccessibility { print("SKIP live AppKit accessibility tree: use --with-accessibility in an unlocked macOS session") }
        print("PASS \(rendered) offscreen account-setup renders; \(semanticChecks) AppKit accessibility tree checks; native Cancel default, unchecked/reset-disabled consent, fixture add/remove/reset/recovery UI. Fixture UI only; no official lifecycle action.")
    }
}


/// Metadata and observation only; no native adapter or lifecycle action is available.
private struct JournalRenderingDesktopSystem: DesktopSystem {
    let lifecycleAllowed = false
    func openingBuildFingerprint() async throws -> OpeningBuildFingerprint {
        OpeningBuildFingerprint(version: "synthetic", build: "fixture", signingRequirement: "synthetic-only",
            archiveSHA256: String(repeating: "a", count: 64), codeDirectoryHash: String(repeating: "b", count: 40),
            bundleGenerationSHA256: String(repeating: "c", count: 64))
    }
    func validateInstallation() {}
    func observe(_ association: EnvironmentAssociation, timeout: Duration) -> DesktopObservation {
        DesktopObservation(matching: [], ambiguous: false)
    }
    func requestNormalQuit(_ instance: DesktopInstance, association: EnvironmentAssociation) throws { throw EnvironmentOpeningError.unavailable }
    func waitForExit(_ instance: DesktopInstance, association: EnvironmentAssociation, timeout: Duration) throws { throw EnvironmentOpeningError.unavailable }
    func launch(_ specification: DesktopLaunchSpecification) throws { throw EnvironmentOpeningError.unavailable }
}
