import Combine
import SwiftUI

/// First-launch setup and the "Mac Setup" check: permission, trackpad, and the core shortcuts.
struct SetupView: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var trusted = SystemSetup.isAccessibilityTrusted
    @State private var swipeConflict = false
    let onDone: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var coreShortcuts: [Shortcut] {
        let core: [Command] = [.focus(.left), .focus(.right), .move(.right), .widen, .fill, .center]
        return core.compactMap { command in Shortcuts.primary.first { $0.command == command } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Glide").font(.largeTitle.bold())
                Text("Windows sit side by side in a row. New windows take the next spot, and the others keep their size.")
                    .foregroundStyle(.secondary)
            }

            step(number: 1, title: "Allow Accessibility", done: trusted) {
                Text("Glide needs this one permission to move and resize windows. It changes no system settings.")
                    .foregroundStyle(.secondary)
                if !trusted {
                    Button("Open Accessibility Settings…") {
                        SystemSetup.requestAccessibility()
                        SystemSetup.openAccessibilitySettings()
                    }
                }
            }

            step(number: 2, title: "Check the trackpad", done: !swipeConflict || !prefs.swipeEnabled) {
                Text("A \(prefs.swipeFingers == 3 ? "three" : "four")-finger swipe slides the row.")
                    .foregroundStyle(.secondary)
                if swipeConflict && prefs.swipeEnabled {
                    SwipeConflictNote(fingers: prefs.swipeFingers)
                }
            }

            step(number: 3, title: "Learn the core shortcuts", done: true) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(coreShortcuts.enumerated()), id: \.offset) { _, shortcut in
                        GridRow {
                            Text(shortcut.label(modifier: prefs.modifier))
                                .font(.system(.body, design: .monospaced))
                                .gridColumnAlignment(.trailing)
                            Text(shortcut.command.title)
                        }
                    }
                }
                Text("Every shortcut is listed in the menu bar icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(trusted ? "Done" : "Finish Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        trusted = SystemSetup.isAccessibilityTrusted
        swipeConflict = SystemSetup.systemUsesHorizontalSwipe(fingers: prefs.swipeFingers)
    }

    private func step<Content: View>(
        number: Int,
        title: String,
        done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
