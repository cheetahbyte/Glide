import AppKit
import ApplicationServices

enum SystemSetup {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openTrackpadSettings() {
        open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension")
    }

    enum SwipeConflict { case pages, fullScreenApps }

    static func horizontalSwipeConflict(fingers: Int) -> SwipeConflict? {
        let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadFourFingerHorizSwipeGesture"
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let values = domains.compactMap { CFPreferencesCopyAppValue(key as CFString, $0 as CFString) as? Int }
        guard let value = values.first(where: { $0 != 0 }) else { return nil }
        return value == 1 ? .pages : .fullScreenApps
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
