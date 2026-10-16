import AppKit
import Combine
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let prefs = Preferences.shared
    private let manager = TilingManager()
    private let swipe = SwipeMonitor()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private lazy var hotKeys = HotKeys { [weak self] command in self?.manager.perform(command) }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var trustTimer: Timer?
    private var preferencesSubscription: AnyCancellable?
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Glide")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        swipe.onBegan = { [weak self] in self?.manager.swipeBegan() }
        swipe.onMoved = { [weak self] delta in self?.manager.swipeMoved(by: delta) }
        swipe.onEnded = { [weak self] in self?.manager.swipeEnded() }

        preferencesSubscription = prefs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyPreferences() } }
        }

        if !SystemSetup.isAccessibilityTrusted || !prefs.hasCompletedOnboarding {
            showSetup()
        }
        startWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEngine()
    }

    // MARK: Engine

    private func startWhenTrusted() {
        trustTimer?.invalidate()
        trustTimer = nil
        if SystemSetup.isAccessibilityTrusted {
            startEngine()
            return
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, SystemSetup.isAccessibilityTrusted else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        guard !isPaused, SystemSetup.isAccessibilityTrusted else { return }
        manager.start()
        hotKeys.register(Shortcuts.all(workspaceCount: prefs.workspaceCount), modifier: prefs.modifier)
        updateSwipe()
        statusItem?.button?.appearsDisabled = false
    }

    private func stopEngine() {
        hotKeys.unregisterAll()
        swipe.stop()
        manager.stop()
    }

    private func updateSwipe() {
        swipe.fingers = prefs.swipeFingers
        if prefs.swipeEnabled && manager.isRunning {
            if !swipe.start() { NSLog("Glide: could not create the trackpad event tap") }
        } else {
            swipe.stop()
        }
    }

    private func applyPreferences() {
        guard manager.isRunning else { return }
        hotKeys.register(Shortcuts.all(workspaceCount: prefs.workspaceCount), modifier: prefs.modifier)
        updateSwipe()
        manager.preferencesChanged()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        statusItem?.button?.appearsDisabled = isPaused
        if isPaused {
            trustTimer?.invalidate()
            trustTimer = nil
            stopEngine()
        } else {
            startWhenTrusted()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !SystemSetup.isAccessibilityTrusted {
            menu.addItem(item("Allow Accessibility Access…", #selector(showSetup)))
            menu.addItem(.separator())
        }
        menu.addItem(item(isPaused ? "Resume Glide" : "Pause Glide", #selector(togglePause)))
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, shortcut) in menuShortcuts.enumerated() {
            let entry = item(shortcut.command.title, #selector(runShortcut(_:)))
            entry.keyEquivalent = shortcut.key.menuKeyEquivalent
            entry.keyEquivalentModifierMask = modifierFlags(shift: shortcut.shift)
            entry.tag = index
            entry.isEnabled = manager.isRunning
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let settings = item("Settings…", #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(item("Mac Setup…", #selector(showSetup)))
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func modifierFlags(shift: Bool) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags
        switch prefs.modifier {
        case .controlOption: flags = [.control, .option]
        case .option: flags = [.option]
        case .commandOption: flags = [.command, .option]
        }
        if shift { flags.insert(.shift) }
        return flags
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard menuShortcuts.indices.contains(sender.tag) else { return }
        manager.perform(menuShortcuts[sender.tag].command)
    }

    private var menuShortcuts: [Shortcut] {
        Shortcuts.primary + Shortcuts.workspaceShortcuts(count: prefs.workspaceCount)
    }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Glide Settings", content: SettingsView())
        }
        present(settingsWindow)
    }

    @objc private func showSetup() {
        if setupWindow == nil {
            setupWindow = makeWindow(title: "Mac Setup", content: SetupView { [weak self] in
                guard let self else { return }
                self.prefs.hasCompletedOnboarding = true
                self.setupWindow?.close()
            })
        }
        present(setupWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Frees the SwiftUI views and their timers once a window is closed.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { settingsWindow = nil }
        if window === setupWindow { setupWindow = nil }
    }

    private func present(_ window: NSWindow?) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
