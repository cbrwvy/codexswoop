import AppKit
import SwiftUI
import CodexSwoopCore

/// Real AppKit windows and this process's own disposable status items only.
/// Does not control another application's menu icons or read account storage.
@main struct PopoverAnchorChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        let window = NSWindow(contentRect: NSRect(x: 350, y: 350, width: 500, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NSButton(frame: NSRect(x: 150, y: 100, width: 28, height: 24))
        window.contentView!.addSubview(button)
        window.orderFrontRegardless(); settle()
        let popover = NSPopover(); popover.animates = false; popover.behavior = .applicationDefined
        let content = NSViewController(); content.view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 100))
        let field = NSTextField(string: "Unsaved fixture text"); field.frame = NSRect(x: 10, y: 30, width: 180, height: 22)
        content.view.addSubview(field); popover.contentViewController = content
        var anchor: NSView? = button
        let controller = StatusPopoverAnchor(popover: popover) { anchor }
        precondition(controller.show()); settle()
        let originalWindow = content.view.window!
        let first = originalWindow.frame
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 100, y: window.frame.minY)); settle()
        precondition(abs(originalWindow.frame.minX - first.minX - 100) < 3, "Popover must follow its positioning window")
        let moved = originalWindow.frame
        button.setFrameOrigin(NSPoint(x: button.frame.minX - 50, y: button.frame.minY)); settle()
        precondition(abs(originalWindow.frame.minX - moved.minX + 50) < 3, "Popover must follow button layout")
        popover.contentSize = NSSize(width: 260, height: 140); settle()
        precondition(popover.isShown && content.view.window === originalWindow && field.stringValue == "Unsaved fixture text")
        button.setBoundsSize(NSSize(width: 34, height: 24)); settle()
        precondition(popover.positioningRect == button.bounds, "Bounds changes must update local positioning rect")
        popover.performClose(nil); settle()
        window.setFrameOrigin(NSPoint(x: 470, y: 350))
        precondition(controller.show()); settle()
        precondition(popover.positioningRect == button.bounds)
        anchor = nil; controller.refresh(); settle()
        precondition(!popover.isShown, "Missing anchor must safely close")
        anchor = button; precondition(controller.show()); settle()
        button.isHidden = true; controller.refresh(); settle(); precondition(!popover.isShown)
        button.isHidden = false; window.orderOut(nil); precondition(!controller.show())
        window.orderFrontRegardless(); settle(); precondition(controller.show()); settle()
        precondition(field.stringValue == "Unsaved fixture text")
        popover.performClose(nil); window.orderOut(nil)
        print("PASS AppKit anchor window/button movement, bounds/size, reopen, missing/hidden anchor, restoration and content continuity")

        let neighbor = NSStatusBar.system.statusItem(withLength: 90); neighbor.button?.title = "Swoop QA"
        let insertion = NSStatusBar.system.statusItem(withLength: 70); insertion.button?.title = "QA add"; insertion.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(insertion) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); item.button?.title = "S"
        defer { NSStatusBar.system.removeStatusItem(item) }
        settle()
        guard let statusButton = item.button, let statusWindow = statusButton.window, statusWindow.isVisible else {
            NSStatusBar.system.removeStatusItem(neighbor)
            print("SKIP real status-item movement: Menu Bar unavailable")
            return
        }
        let live = StatusPopoverAnchor(popover: popover) { item.button }
        let baseline = CommandLine.arguments.contains("--native-baseline")
        if baseline { popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY) }
        else { precondition(live.show()) }
        settle()
        let beforeX = statusWindow.frame.minX, beforePopoverX = content.view.window!.frame.minX
        NSStatusBar.system.removeStatusItem(neighbor); settle()
        let delta = statusWindow.frame.minX - beforeX
        if abs(delta) > 1 {
            if !baseline { precondition(abs(content.view.window!.frame.minX - beforePopoverX - delta) < 3, "Real status-item removal must track anchor window") }
            print("\(baseline ? "BASELINE" : "PASS") real Menu Bar neighbor removal; icon delta=\(delta), popover delta=\(content.view.window!.frame.minX - beforePopoverX)")
        } else { print("SKIP removal movement: system kept this item's position") }
        let beforeAdd = statusWindow.frame.minX, beforeAddPopover = content.view.window!.frame.minX
        insertion.isVisible = true
        settle()
        let addDelta = statusWindow.frame.minX - beforeAdd
        if abs(addDelta) > 1 {
            if !baseline { precondition(abs(content.view.window!.frame.minX - beforeAddPopover - addDelta) < 3, "Real status-item insertion must track anchor window") }
            print("\(baseline ? "BASELINE" : "PASS") real Menu Bar neighbor insertion; icon delta=\(addDelta), popover delta=\(content.view.window!.frame.minX - beforeAddPopover)")
        } else {
            precondition(abs(content.view.window!.frame.minX - beforeAddPopover) < 3)
            print("PASS real Menu Bar neighbor insertion; icon/popover position unchanged by system layout")
        }
        popover.performClose(nil)
        let configuration = ProfileManager.storageConfiguration()
        precondition(configuration.isTest)
        let suite = "codexswoop-anchor-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProfileManager(defaults: defaults)
        try! MainThreadPreparation.wait {
            let store = ProfileStore(root: configuration.root)
            _ = try await store.load()
            if try await store.inspect().profiles.count < 2 {
                _ = try await store.create(name: "Fixture One")
                _ = try await store.create(name: "Fixture Two")
            }
            await manager.reload()
        }
        manager.previewOpeningReviewForChecks(.environment(.backendNotReady))
        let menu = NSHostingController(rootView: MenuBarView(manager: manager, maximumHeight: 240, contentHeightChanged: { live.contentHeightChanged($0) }))
        menu.sizingOptions = [.preferredContentSize]
        popover.contentViewController = menu
        precondition(live.show()); settle(); settle()
        precondition(popover.contentSize.height <= 241)
        let boundedWindow = menu.view.window!
        precondition(boundedWindow.frame.maxY <= statusWindow.screen!.visibleFrame.maxY + 1,
            "Real popover must stay below the menu bar")
        precondition(boundedWindow.frame.minY >= statusWindow.screen!.visibleFrame.minY - 1)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = scrollViews(menu.view).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }!
        let document = scroll.documentView!
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView); settle()
        precondition(scroll.contentView.bounds.origin.y > 0, "Diagnostics and footer must remain reachable")
        manager.errorMessage = String(repeating: "Synthetic diagnostic detail. ", count: 25); settle()
        precondition(popover.contentSize.height <= 241 && menu.view.window === boundedWindow)
        manager.errorMessage = nil; manager.previewOpeningReviewForChecks(nil); settle()
        precondition(popover.contentSize.height <= 241)
        popover.performClose(nil)
        let growingMenu = NSHostingController(rootView: MenuBarView(manager: manager, maximumHeight: 560, contentHeightChanged: { live.contentHeightChanged($0) }))
        growingMenu.sizingOptions = [.preferredContentSize]
        popover.contentViewController = growingMenu
        precondition(live.show()); settle(); settle()
        let compactHeight = popover.contentSize.height
        precondition(compactHeight < 500, "A short menu must shrink to its measured content")
        let tracking = NSMenu(title: "Fixture tracking")
        NotificationCenter.default.post(name: .swoopMenuBeganTracking, object: tracking)
        let stableFrame = growingMenu.view.window!.frame
        manager.previewInstallationForChecks(.unverified); settle(); settle()
        live.refresh()
        precondition(popover.contentSize.height == compactHeight && growingMenu.view.window!.frame == stableFrame,
            "Resize/reanchor must wait until the native menu tracking session ends")
        NotificationCenter.default.post(name: .swoopMenuEndedTracking, object: tracking)
        settle(); settle()
        let diagnostics = "Sizing QA compact=\(compactHeight), grown=\(popover.contentSize.height), preferred=\(growingMenu.preferredContentSize), fitting=\(growingMenu.view.fittingSize), documents=\(scrollViews(growingMenu.view).map { $0.documentView?.bounds.height ?? 0 })\n"
        FileHandle.standardError.write(Data(diagnostics.utf8))
        precondition(popover.contentSize.height > compactHeight, "Installation warning growth must update the native content height")
        manager.previewInstallationForChecks(.verified); settle(); settle()
        precondition(abs(popover.contentSize.height - compactHeight) < 1, "Installation warning removal must shrink the native content height")
        popover.performClose(nil)
        print("PASS real bounded SwiftUI popover, diagnostic growth/shrink, single-scroll footer reachability and native screen containment")
        print("PASS real status-item opening/closing; only disposable icons in this QA process were changed")
    }
}
