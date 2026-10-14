import AppKit

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
        print("PASS real status-item opening/closing; only disposable icons in this QA process were changed")
    }
}
