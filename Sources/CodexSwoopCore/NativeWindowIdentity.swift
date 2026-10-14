import AppKit
import ApplicationServices
import CoreGraphics

/// Main-actor retained native handle. Only AX window handles/roles/PIDs/focus are accessed, never titles or contents.
@MainActor
final class NativeWindowIdentity {
    let token: UUID
    let instance: DesktopInstance
    let application: AXUIElement
    let window: AXUIElement
    let native: NSRunningApplication
    let windowIDs: Set<UInt32>
    private init(token: UUID, instance: DesktopInstance, application: AXUIElement, window: AXUIElement,
                 native: NSRunningApplication, windowIDs: Set<UInt32>) {
        self.token = token; self.instance = instance; self.application = application; self.window = window
        self.native = native; self.windowIDs = windowIDs
    }
    static func capture(_ instance: DesktopInstance, previous: NativeWindowIdentity?) throws -> NativeWindowIdentity {
        guard AXIsProcessTrusted() else { throw EnvironmentError.missingPermissions } // Never request/prompt.
        guard let native = NSRunningApplication(processIdentifier: instance.main.pid), !native.isTerminated,
              native.processIdentifier == instance.main.pid,
              native.launchDate == instance.nativeLaunchDate, native.bundleIdentifier == "com.openai.codex",
              native.executableURL?.path == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" else { throw EnvironmentError.processChanged }
        let application = AXUIElementCreateApplication(instance.main.pid)
        var applicationPID: pid_t = 0
        guard AXUIElementGetPid(application, &applicationPID) == .success,
              applicationPID == instance.main.pid else { throw EnvironmentError.processChanged }
        guard AXUIElementSetMessagingTimeout(application, 1) == .success else { throw EnvironmentError.activationUnavailable }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement], windows.count == 1 else { throw EnvironmentError.activationUnavailable }
        let candidates = windows.filter { window in
            var pid: pid_t = 0, role: CFTypeRef?
            return AXUIElementGetPid(window, &pid) == .success && pid == instance.main.pid
                && AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == kAXWindowRole
        }
        guard candidates.count == 1 else { throw EnvironmentError.activationUnavailable }
        let selected = candidates[0]
        guard AXUIElementSetMessagingTimeout(selected, 1) == .success else { throw EnvironmentError.activationUnavailable }
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { throw EnvironmentError.activationUnavailable }
        var ids = Set<UInt32>()
        for row in rows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == instance.main.pid,
                  let layer = row[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let number = row[kCGWindowNumber as String] as? NSNumber, number.uint32Value > 0 else { continue }
            ids.insert(number.uint32Value)
        }
        // CG IDs prove owner/set continuity, not a public CG-to-AX mapping. Require a sole candidate in both APIs.
        guard ids.count == 1 else { throw EnvironmentError.activationUnavailable }
        let token: UUID
        if let previous, previous.instance == instance, previous.native.isEqual(native), CFEqual(previous.window, selected) { token = previous.token }
        else { token = UUID() }
        return NativeWindowIdentity(token: token, instance: instance, application: application, window: selected, native: native, windowIDs: ids)
    }
    func raiseAndConfirm() throws {
        let fresh = try Self.capture(instance, previous: self)
        guard fresh.token == token, fresh.windowIDs == windowIDs, !Task.isCancelled else { throw EnvironmentError.activationUnavailable }
        // Address the retained AX window, never an arbitrary window found by title, coordinates or bundle ID.
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
              native.activate(options: []),
              AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window) == .success else {
            throw EnvironmentError.activationUnavailable
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, window), native.isActive, !native.isTerminated,
              native.launchDate == instance.nativeLaunchDate else { throw EnvironmentError.activationUnavailable }
    }
}
