import AppKit
import ApplicationServices

/// A window seen through the Accessibility API. Identity follows `CFEqual`, so two
/// references obtained separately for the same window compare equal.
struct AXWindow: Hashable {
    let element: AXUIElement
    let pid: pid_t

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    var frame: CGRect? {
        guard let origin = AX.point(element, kAXPositionAttribute),
              let size = AX.size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var size: CGSize? { AX.size(element, kAXSizeAttribute) }

    var isMinimized: Bool { AX.bool(element, kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { AX.bool(element, "AXFullScreen") ?? false }
    var isAlive: Bool { AX.string(element, kAXRoleAttribute) != nil }

    /// Standard, resizable, movable windows of regular apps. Dialogs, panels and
    /// sheets are left alone.
    var isTileable: Bool {
        guard AX.string(element, kAXRoleAttribute) == kAXWindowRole,
              AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              AX.isSettable(element, kAXPositionAttribute),
              AX.isSettable(element, kAXSizeAttribute),
              !isMinimized, !isFullScreen else { return false }
        return true
    }

    /// Returns true when the size had to change.
    @discardableResult
    func setFrame(_ target: CGRect, current: CGRect?) -> Bool {
        let sizeChanged = current.map { abs($0.width - target.width) > 0.5 || abs($0.height - target.height) > 0.5 } ?? true
        let originChanged = current.map { abs($0.minX - target.minX) > 0.5 || abs($0.minY - target.minY) > 0.5 } ?? true
        guard sizeChanged || originChanged else { return false }

        let app = AXUIElementCreateApplication(pid)
        let enhanced = AX.bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        // Size, then position, then size again: macOS clamps sizes against the
        // screen edge relative to the old position.
        if sizeChanged { AX.setSize(element, target.size) }
        if originChanged || sizeChanged { AX.setPoint(element, target.origin) }
        if sizeChanged { AX.setSize(element, target.size) }
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
        return sizeChanged
    }

    func focus() {
        let app = AXUIElementCreateApplication(pid)
        AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if let running = NSRunningApplication(processIdentifier: pid), !running.isActive {
            if #available(macOS 14.0, *) {
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = value(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = value(element, attribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! [CFTypeRef]
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue((value as! AXValue), .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue((value as! AXValue), .cgSize, &size) ? size : nil
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func setPoint(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { set(element, kAXPositionAttribute, value) }
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { set(element, kAXSizeAttribute, value) }
    }

    static func windows(of pid: pid_t) -> [AXWindow] {
        elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute).map { AXWindow(element: $0, pid: pid) }
    }

    static func focusedWindow(of pid: pid_t) -> AXWindow? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).map { AXWindow(element: $0, pid: pid) }
    }
}
