import AppKit
import Carbon.HIToolbox

enum Direction {
    case left, right
}

enum Command: Hashable {
    case focus(Direction)
    case move(Direction)
    case widen
    case narrow
    case fill
    case center
    case toggleFloat
    case sendToOtherDisplay
    case switchWorkspace(Int)
    case moveToWorkspace(Int)

    var title: String {
        switch self {
        case .focus(.left): "Go to the window on the left"
        case .focus(.right): "Go to the window on the right"
        case .move(.left): "Move the window left, swapping it with its neighbour"
        case .move(.right): "Move the window right, swapping it with its neighbour"
        case .widen: "Make the window wider: ½ → ⅔ → full width"
        case .narrow: "Make the window narrower again"
        case .fill: "Fill the screen with the window"
        case .center: "Bring the window to the centre of the screen"
        case .toggleFloat: "Let the window float above the row, or put it back"
        case .sendToOtherDisplay: "Send the window to your other display"
        case .switchWorkspace(let n): "Switch to workspace \(n)"
        case .moveToWorkspace(let n): "Move the window to workspace \(n)"
        }
    }
}

struct Shortcut {
    enum Key {
        case left, right
        case character(String, keyCode: Int)

        var keyCode: Int {
            switch self {
            case .left: kVK_LeftArrow
            case .right: kVK_RightArrow
            case .character(_, let keyCode): keyCode
            }
        }

        var symbol: String {
            switch self {
            case .left: "←"
            case .right: "→"
            case .character(let c, _): c.uppercased()
            }
        }

        var menuKeyEquivalent: String {
            switch self {
            case .left: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .right: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .character(let c, _): c
            }
        }
    }

    let key: Key
    let shift: Bool
    let command: Command

    func label(modifier: ModifierChoice) -> String {
        modifier.symbol + (shift ? "⇧" : "") + key.symbol
    }
}

enum Shortcuts {
    static let vimKeys: [(Direction, Shortcut.Key)] = [
        (.left, .character("h", keyCode: kVK_ANSI_H)),
        (.right, .character("l", keyCode: kVK_ANSI_L)),
    ]

    static let arrowKeys: [(Direction, Shortcut.Key)] = [
        (.left, .left), (.right, .right),
    ]

    static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// Shortcuts shown in the menu and settings, in display order.
    static let primary: [Shortcut] = {
        var list: [Shortcut] = []
        for (direction, key) in arrowKeys {
            list.append(Shortcut(key: key, shift: false, command: .focus(direction)))
        }
        for (direction, key) in arrowKeys {
            list.append(Shortcut(key: key, shift: true, command: .move(direction)))
        }
        list += [
            Shortcut(key: .character("r", keyCode: kVK_ANSI_R), shift: false, command: .widen),
            Shortcut(key: .character("r", keyCode: kVK_ANSI_R), shift: true, command: .narrow),
            Shortcut(key: .character("f", keyCode: kVK_ANSI_F), shift: false, command: .fill),
            Shortcut(key: .character("c", keyCode: kVK_ANSI_C), shift: false, command: .center),
            Shortcut(key: .character("t", keyCode: kVK_ANSI_T), shift: false, command: .toggleFloat),
            Shortcut(key: .character("n", keyCode: kVK_ANSI_N), shift: false, command: .sendToOtherDisplay),
        ]
        return list
    }()

    static func workspaceShortcuts(count: Int) -> [Shortcut] {
        (1...count).flatMap { n in
            let key = Shortcut.Key.character("\(n)", keyCode: digitKeyCodes[n - 1])
            return [
                Shortcut(key: key, shift: false, command: .switchWorkspace(n)),
                Shortcut(key: key, shift: true, command: .moveToWorkspace(n)),
            ]
        }
    }

    /// Every registered hotkey, including the H and L alternatives.
    static func all(workspaceCount: Int) -> [Shortcut] {
        var list = primary
        for (direction, key) in vimKeys {
            list.append(Shortcut(key: key, shift: false, command: .focus(direction)))
            list.append(Shortcut(key: key, shift: true, command: .move(direction)))
        }
        return list + workspaceShortcuts(count: workspaceCount)
    }
}
