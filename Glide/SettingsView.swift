import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var trusted = SystemSetup.isAccessibilityTrusted
    @State private var swipeConflict = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        AccessibilityButton()
                    }
                }
            }

            Section("Shortcuts") {
                Picker("Shortcuts start with", selection: $prefs.modifier) {
                    ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) }
                }
                ShortcutList(modifier: prefs.modifier, workspaceCount: prefs.workspaceCount)
                Text("H and L work in place of ← and → in every shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Layout") {
                LabeledContent("Space between windows") {
                    HStack {
                        Slider(value: $prefs.gap, in: Preferences.gapRange, step: 1)
                            .frame(width: 180)
                        Text("\(Int(prefs.gap)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Trackpad") {
                Toggle("Slide the row with a swipe", isOn: $prefs.swipeEnabled)
                Picker("Fingers", selection: $prefs.swipeFingers) {
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                }
                .disabled(!prefs.swipeEnabled)
                if prefs.swipeEnabled && swipeConflict {
                    SwipeConflictNote(fingers: prefs.swipeFingers)
                }
            }

            Section("Workspaces") {
                Stepper(value: $prefs.workspaceCount, in: 1...Preferences.maxWorkspaces) {
                    LabeledContent("Workspaces per display", value: "\(prefs.workspaceCount)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
        .onChange(of: prefs.swipeFingers) { _ in refresh() }
    }

    private func refresh() {
        trusted = SystemSetup.isAccessibilityTrusted
        swipeConflict = SystemSetup.systemUsesHorizontalSwipe(fingers: prefs.swipeFingers)
    }
}

struct ShortcutList: View {
    let modifier: ModifierChoice
    let workspaceCount: Int

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(Shortcuts.primary.enumerated()), id: \.offset) { _, shortcut in
                ShortcutRow(keys: shortcut.label(modifier: modifier), title: shortcut.command.title)
            }
            ShortcutRow(keys: "\(modifier.symbol)1–\(workspaceCount)", title: "Switch to workspace 1 to \(workspaceCount)")
            ShortcutRow(keys: "\(modifier.symbol)⇧1–\(workspaceCount)", title: "Move the window to workspace 1 to \(workspaceCount)")
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let title: String

    var body: some View {
        GridRow {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .gridColumnAlignment(.trailing)
            Text(title)
        }
    }
}

struct AccessibilityButton: View {
    var body: some View {
        Button("Open Accessibility Settings…") {
            SystemSetup.requestAccessibility()
            SystemSetup.openAccessibilitySettings()
        }
    }
}

struct SwipeConflictNote: View {
    let fingers: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "macOS may also use a \(fingers == 3 ? "three" : "four")-finger swipe to switch between full-screen apps.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Text("If swiping switches desktops instead of sliding the row, open Trackpad › More Gestures and change “Swipe between full-screen applications”, or pick the other finger count here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Trackpad Settings…") { SystemSetup.openTrackpadSettings() }
        }
    }
}
