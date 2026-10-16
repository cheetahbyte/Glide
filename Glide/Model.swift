import AppKit

final class Column {
    let window: AXWindow
    var width: CGFloat

    init(_ window: AXWindow, width: CGFloat) {
        self.window = window
        self.width = width
    }
}

final class Workspace {
    var columns: [Column] = []
    var floating: [AXWindow] = []
    var scroll: CGFloat = 0
    var focused: AXWindow?

    var allWindows: [AXWindow] { columns.map(\.window) + floating }

    func columnIndex(of window: AXWindow) -> Int? {
        columns.firstIndex { $0.window == window }
    }

    func contains(_ window: AXWindow) -> Bool {
        floating.contains(window) || columnIndex(of: window) != nil
    }

    var focusedColumnIndex: Int? {
        focused.flatMap { columnIndex(of: $0) }
    }
}

final class Display {
    let id: CGDirectDisplayID
    var frame: CGRect
    var visibleFrame: CGRect
    var workspaces: [Workspace]
    var activeIndex = 0

    init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect, workspaceCount: Int) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        workspaces = (0..<workspaceCount).map { _ in Workspace() }
    }

    var active: Workspace { workspaces[activeIndex] }

    func workspace(containing window: AXWindow) -> Workspace? {
        workspaces.first { $0.contains(window) }
    }
}

enum Coordinates {
    static var mainScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func ax(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func ax(fromCocoa point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
