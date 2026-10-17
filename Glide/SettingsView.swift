import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: CaseIterable {
    case general, layout, shortcuts, trackpad

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .shortcuts: "Shortcuts"
        case .trackpad: "Trackpad"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "rectangle.split.3x1"
        case .shortcuts: "keyboard"
        case .trackpad: "hand.draw"
        }
    }

    var view: AnyView {
        switch self {
        case .general: AnyView(GeneralSettings().frame(width: 560, height: 220))
        case .layout: AnyView(LayoutSettings().frame(width: 560, height: 480))
        case .shortcuts: AnyView(ShortcutSettings().frame(width: 560, height: 480))
        case .trackpad: AnyView(TrackpadSettings().frame(width: 560, height: 420))
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var trusted = SystemSetup.isAccessibilityTrusted

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

            Section("Workspaces") {
                Stepper(value: $prefs.workspaceCount, in: 1...Preferences.maxWorkspaces) {
                    LabeledContent("Workspaces per display", value: "\(prefs.workspaceCount)")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = SystemSetup.isAccessibilityTrusted }
        .onReceive(poll) { _ in trusted = SystemSetup.isAccessibilityTrusted }
    }
}

struct LayoutSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
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

            AppOrderSection(order: $prefs.appOrder)
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Shortcuts") {
                Picker("Shortcuts start with", selection: $prefs.modifier) {
                    ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) }
                }
                ShortcutList(modifier: prefs.modifier, workspaceCount: prefs.workspaceCount)
                Text("H and L work in place of ← and → in every shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TrackpadSettings: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var swipeConflict: SystemSetup.SwipeConflict?

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Trackpad") {
                Toggle("Slide the row with a swipe", isOn: $prefs.swipeEnabled)
                Picker("Fingers", selection: $prefs.swipeFingers) {
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                }
                .disabled(!prefs.swipeEnabled)
                if prefs.swipeEnabled, let swipeConflict {
                    SwipeConflictNote(conflict: swipeConflict, fingers: prefs.swipeFingers)
                }
            }

            Section("Mouse") {
                Toggle("Slide the row by scrolling while holding \(prefs.modifier.symbol)", isOn: $prefs.scrollEnabled)
                Text("Works with a Magic Mouse swipe or a scroll wheel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
        .onChange(of: prefs.swipeFingers) { _ in refresh() }
    }

    private func refresh() {
        swipeConflict = SystemSetup.horizontalSwipeConflict(fingers: prefs.swipeFingers)
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
    let conflict: SystemSetup.SwipeConflict
    let fingers: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(advice)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Trackpad Settings…") { SystemSetup.openTrackpadSettings() }
        }
    }

    private var summary: String {
        let count = fingers == 3 ? "three" : "four"
        switch conflict {
        case .pages: return "macOS may also use a \(count)-finger swipe to go back and forward between pages."
        case .fullScreenApps: return "macOS may also use a \(count)-finger swipe to switch between full-screen apps."
        }
    }

    private var advice: String {
        switch conflict {
        case .pages:
            return "If swiping goes back a page instead of sliding the row, open Trackpad › More Gestures and set “Swipe between pages” to “Scroll left or right with two fingers”, or pick the other finger count here."
        case .fullScreenApps:
            return "If swiping switches desktops instead of sliding the row, open Trackpad › More Gestures and change “Swipe between full-screen applications”, or pick the other finger count here."
        }
    }
}

struct AppOrderSection: View {
    @Binding var order: [String]

    var body: some View {
        Section {
            ForEach(order, id: \.self) { bundleID in
                HStack {
                    Image(nsImage: AppInfo.icon(bundleID))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(AppInfo.name(bundleID))
                    Spacer()
                    Button {
                        order.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the order")
                }
            }
            .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            Menu("Add App") {
                ForEach(AppInfo.runningApps(excluding: order), id: \.self) { bundleID in
                    Button(AppInfo.name(bundleID)) { order.append(bundleID) }
                }
                Divider()
                Button("Choose…", action: chooseApp)
            }
            .fixedSize()
        } header: {
            Text("App order")
        } footer: {
            Text("Windows of these apps always line up from left to right in this order. Drag to rearrange. Other apps open next to the focused window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !order.contains(bundleID) else { return }
        order.append(bundleID)
    }
}

enum AppInfo {
    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func runningApps(excluding: [String]) -> [String] {
        let own = Bundle.main.bundleIdentifier
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != own && !excluding.contains($0) }
        return Array(Set(ids)).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
}
