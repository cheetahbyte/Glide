import Combine
import Foundation

enum ModifierChoice: String, CaseIterable, Identifiable {
    case controlOption
    case option
    case commandOption

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .option: "⌥"
        case .commandOption: "⌘⌥"
        }
    }

    var title: String {
        switch self {
        case .controlOption: "Control + Option (⌃⌥)"
        case .option: "Option (⌥)"
        case .commandOption: "Command + Option (⌘⌥)"
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let maxWorkspaces = 9
    static let gapRange: ClosedRange<Double> = 0...40

    private let defaults = UserDefaults.standard

    @Published var modifier: ModifierChoice {
        didSet { defaults.set(modifier.rawValue, forKey: Key.modifier) }
    }

    @Published var gap: Double {
        didSet { defaults.set(gap, forKey: Key.gap) }
    }

    @Published var swipeFingers: Int {
        didSet { defaults.set(swipeFingers, forKey: Key.swipeFingers) }
    }

    @Published var swipeEnabled: Bool {
        didSet { defaults.set(swipeEnabled, forKey: Key.swipeEnabled) }
    }

    @Published var workspaceCount: Int {
        didSet { defaults.set(workspaceCount, forKey: Key.workspaceCount) }
    }

    @Published var appOrder: [String] {
        didSet { defaults.set(appOrder, forKey: Key.appOrder) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) }
    }

    private enum Key {
        static let modifier = "modifier"
        static let gap = "gap"
        static let swipeFingers = "swipeFingers"
        static let swipeEnabled = "swipeEnabled"
        static let workspaceCount = "workspaceCount"
        static let onboarding = "hasCompletedOnboarding"
        static let appOrder = "appOrder"
    }

    private init() {
        defaults.register(defaults: [
            Key.modifier: ModifierChoice.controlOption.rawValue,
            Key.gap: 8.0,
            Key.swipeFingers: 3,
            Key.swipeEnabled: true,
            Key.workspaceCount: 4,
            Key.onboarding: false,
        ])
        modifier = ModifierChoice(rawValue: defaults.string(forKey: Key.modifier) ?? "") ?? .controlOption
        gap = min(max(defaults.double(forKey: Key.gap), Self.gapRange.lowerBound), Self.gapRange.upperBound)
        swipeFingers = defaults.integer(forKey: Key.swipeFingers) == 4 ? 4 : 3
        swipeEnabled = defaults.bool(forKey: Key.swipeEnabled)
        workspaceCount = min(max(defaults.integer(forKey: Key.workspaceCount), 1), Self.maxWorkspaces)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        appOrder = defaults.stringArray(forKey: Key.appOrder) ?? []
    }
}
