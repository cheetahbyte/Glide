import AppKit
import ApplicationServices

final class TilingManager {
    static let widthPresets: [CGFloat] = [1.0 / 2, 2.0 / 3, 1]
    static let newWindowWidth: CGFloat = 1.0 / 2
    static let offlineGrace: TimeInterval = 15

    private let prefs = Preferences.shared
    private let mover = WindowMover.shared
    private(set) var isRunning = false
    private var displays: [Display] = []
    private var offline: [(display: Display, since: TimeInterval)] = []
    private var screenChangeGeneration = 0
    private var observers: [pid_t: AXObserver] = [:]
    private var dormant: Set<AXWindow> = []
    private var parked: [AXWindow: CGRect] = [:]
    private var placed: [AXWindow: CGRect] = [:]
    private var observedWindows: Set<AXWindow> = []
    private var floatingFrames: [AXWindow: CGRect] = [:]
    private var draggedWindows: Set<AXWindow> = []
    private var suppressFollowUntil = Date.distantPast
    private var swipeDisplay: Display?
    private var pendingSwipe: CGFloat = 0
    private var swipeFlushScheduled = false
    private var swipeVelocity: CGFloat = 0
    private var lastSwipeTime: TimeInterval = 0
    private var swipeCanRevealDesktop = false
    private var lastHapticTime: TimeInterval = 0
    private var settleTimer: Timer?
    private var isSettlingSwipe = false
    private var offsets: [AXWindow: CGFloat] = [:]
    private var appliedAppOrder: [String] = []
    private var reconcileTimer: Timer?
    private var dragTimer: Timer?
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    private var gap: CGFloat { CGFloat(prefs.gap) }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        appliedAppOrder = prefs.appOrder
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        rebuildDisplays()
        adoptExistingWindows()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { manager, app in manager.appLaunched(app) }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { manager, app in manager.appTerminated(app.processIdentifier) }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { manager, app in manager.focusChanged(app.processIdentifier) }
        observe(workspace, NSWorkspace.didHideApplicationNotification) { manager, app in manager.appHidden(app.processIdentifier) }
        observe(workspace, NSWorkspace.didUnhideApplicationNotification) { manager, app in manager.scan(app.processIdentifier) }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { manager, _ in manager.reconcile() }
        observe(workspace, NSWorkspace.didWakeNotification) { manager, _ in
            manager.reconcile()
            manager.scheduleResync()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { manager, _ in manager.screensChanged() }

        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer.tolerance = 10
        reconcileTimer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reconcileTimer?.invalidate()
        dragTimer?.invalidate()
        cancelSettle()
        reconcileTimer = nil
        dragTimer = nil
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens = []
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers = [:]
        releaseParkedWindows()
        mover.restoreEnhancedUI()
        displays = []
        offline = []
        dormant = []
        parked = [:]
        placed = [:]
        observedWindows = []
        floatingFrames = [:]
        draggedWindows = []
        swipeDisplay = nil
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (TilingManager, NSRunningApplication) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                handler(self, app ?? NSRunningApplication.current)
            }
        }
        notificationTokens.append((center, token))
    }

    func preferencesChanged() {
        guard isRunning else { return }
        for display in displays { resizeWorkspaces(of: display, to: prefs.workspaceCount) }
        if prefs.appOrder != appliedAppOrder {
            appliedAppOrder = prefs.appOrder
            for display in displays {
                for workspace in display.workspaces where workspace !== display.active { applyAppOrder(to: workspace) }
                transition(display) { applyAppOrder(to: display.active) }
            }
        }
        layoutAll()
    }

    private func resizeWorkspaces(of display: Display, to count: Int) {
        while display.workspaces.count < count { display.workspaces.append(Workspace()) }
        guard display.workspaces.count > count else { return }
        let keep = display.workspaces[count - 1]
        for extra in display.workspaces[count...] {
            keep.columns += extra.columns
            keep.floating += extra.floating
        }
        applyAppOrder(to: keep)
        display.workspaces.removeLast(display.workspaces.count - count)
        display.activeIndex = min(display.activeIndex, count - 1)
    }

    private func rebuildDisplays() {
        let known = displays + offline.map(\.display)
        var updated: [Display] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let frame = Coordinates.ax(fromCocoa: screen.frame)
            let visible = Coordinates.ax(fromCocoa: screen.visibleFrame)
            if let existing = known.first(where: { $0.id == id }) {
                existing.frame = frame
                existing.visibleFrame = visible
                updated.append(existing)
            } else {
                updated.append(Display(id: id, frame: frame, visibleFrame: visible, workspaceCount: prefs.workspaceCount))
            }
        }
        updated.sort { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let now = ProcessInfo.processInfo.systemUptime
        let removed = displays.filter { old in !updated.contains { $0 === old } }
        offline = offline.filter { entry in !updated.contains { $0 === entry.display } } + removed.map { ($0, now) }
        displays = updated
        if !removed.isEmpty {
            after(Self.offlineGrace + 0.5) { [weak self] in self?.retireOfflineDisplays() }
        }
    }

    // Displays often drop out for a few seconds on wake, so their workspaces are kept until the grace period passes.
    private func retireOfflineDisplays() {
        guard isRunning, let fallback = displays.first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let expired = offline.filter { now - $0.since >= Self.offlineGrace }.map(\.display)
        guard !expired.isEmpty else { return }
        offline.removeAll { entry in expired.contains { $0 === entry.display } }
        for display in expired {
            for (index, workspace) in display.workspaces.enumerated() {
                let target = fallback.workspaces[min(index, fallback.workspaces.count - 1)]
                target.columns += workspace.columns
                target.floating += workspace.floating
                applyAppOrder(to: target)
                workspace.allWindows.forEach { parked.removeValue(forKey: $0) }
            }
        }
        layoutAll()
    }

    private func screensChanged() {
        rebuildDisplays()
        layoutAll()
        scheduleResync()
    }

    // macOS moves off-screen windows back on screen when displays change, which leaves the cached frames stale.
    private func scheduleResync() {
        screenChangeGeneration += 1
        let generation = screenChangeGeneration
        after(1) { [weak self] in
            guard let self, self.isRunning, generation == self.screenChangeGeneration else { return }
            self.resyncFrames()
            self.layoutAll()
        }
    }

    private func resyncFrames() {
        for window in allManagedWindows() {
            guard let frame = window.frame else { continue }
            if parked[window] != nil { parked[window] = frame }
            if placed[window] != nil { placed[window] = frame }
        }
    }

    private func display(containing point: CGPoint) -> Display? {
        if let match = displays.first(where: { $0.frame.contains(point) }) { return match }
        return displays.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }

    private func displayUnderMouse() -> Display? {
        display(containing: Coordinates.ax(fromCocoa: NSEvent.mouseLocation))
    }

    private func location(of window: AXWindow) -> (Display, Workspace)? {
        for display in displays + offline.map(\.display) {
            if let workspace = display.workspace(containing: window) { return (display, workspace) }
        }
        return nil
    }

    private func isManaged(_ window: AXWindow) -> Bool { location(of: window) != nil }

    private func regularApps() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated
        }
    }

    private func isRegularApp(_ pid: pid_t) -> Bool {
        pid != ProcessInfo.processInfo.processIdentifier
            && NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    @discardableResult
    private func observeApp(_ pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<TilingManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { manager.handle(name, element) }
        }, &created)
        guard status == .success, let observer = created else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success || result == .notificationAlreadyRegistered else { return nil }
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return observer
    }

    private func observeWindow(_ window: AXWindow) {
        guard !observedWindows.contains(window), let observer = observeApp(window.pid) else { return }
        observedWindows.insert(window)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ] {
            AXObserverAddNotification(observer, window.element, name as CFString, refcon)
        }
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        guard isRunning else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let window = AXWindow(element: element, pid: pid)
        switch notification {
        case kAXWindowCreatedNotification:
            windowCreated(window, attempt: 0)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            focusChanged(pid)
        case kAXUIElementDestroyedNotification:
            forget(window)
        case kAXWindowMiniaturizedNotification:
            makeDormant(window)
        case kAXWindowDeminiaturizedNotification:
            revive(window)
        case kAXWindowMovedNotification:
            windowMovedOrResized(window, resized: false)
        case kAXWindowResizedNotification:
            windowMovedOrResized(window, resized: true)
        default:
            break
        }
    }

    private func adoptExistingWindows() {
        let focused = systemFocusedWindow()
        var found: [CGDirectDisplayID: [(AXWindow, CGRect)]] = [:]
        for app in regularApps() {
            let pid = app.processIdentifier
            observeApp(pid)
            for window in AX.windows(of: pid) {
                if window.isTileable, !app.isHidden, let frame = window.frame,
                   let display = display(containing: CGPoint(x: frame.midX, y: frame.midY)) {
                    observeWindow(window)
                    found[display.id, default: []].append((window, frame))
                } else if window.isMinimized || window.isFullScreen || app.isHidden {
                    observeWindow(window)
                    dormant.insert(window)
                }
            }
        }
        for display in displays {
            let viewport = viewport(of: display)
            let workspace = display.active
            for (window, frame) in (found[display.id] ?? []).sorted(by: { $0.1.minX < $1.1.minX }) {
                workspace.columns.append(Column(window, width: fraction(forWidth: frame.width, viewport)))
            }
            applyAppOrder(to: workspace)
            workspace.focused = focused.flatMap { workspace.contains($0) ? $0 : nil } ?? workspace.columns.first?.window
            if let index = workspace.focusedColumnIndex { ensureVisible(index, in: workspace, on: display) }
            layout(display)
        }
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        after(0.5) { [weak self] in self?.scan(pid) }
    }

    private func appTerminated(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        mover.forget(pid)
        for window in allManagedWindows() + Array(dormant) where window.pid == pid {
            forget(window)
        }
    }

    private func appHidden(_ pid: pid_t) {
        for window in allManagedWindows() where window.pid == pid {
            makeDormant(window)
        }
    }

    private func scan(_ pid: pid_t) {
        guard isRunning, isRegularApp(pid) else { return }
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return }
        guard observeApp(pid) != nil else { return }
        for window in AX.windows(of: pid) {
            if isManaged(window) {
                observeWindow(window)
                if window.isMinimized || window.isFullScreen { makeDormant(window) }
            } else if window.isTileable {
                observeWindow(window)
                dormant.remove(window)
                if !adoptTab(window) { insert(window) }
            } else if window.isMinimized || window.isFullScreen {
                observeWindow(window)
                dormant.insert(window)
            }
        }
    }

    private func reconcile() {
        guard isRunning else { return }
        let apps = regularApps()
        let pids = Set(apps.map(\.processIdentifier))
        for window in allManagedWindows() where !pids.contains(window.pid) || !window.isAlive {
            forget(window)
        }
        dormant = dormant.filter { pids.contains($0.pid) && $0.isAlive }
        for pid in observers.keys where !pids.contains(pid) {
            appTerminated(pid)
        }
        for app in apps { scan(app.processIdentifier) }
    }

    private func allManagedWindows() -> [AXWindow] {
        (displays + offline.map(\.display)).flatMap { $0.workspaces.flatMap(\.allWindows) }
    }

    private func windowCreated(_ window: AXWindow, attempt: Int) {
        guard isRunning, isRegularApp(window.pid), !isManaged(window) else { return }
        if window.isTileable {
            observeWindow(window)
            dormant.remove(window)
            if !adoptTab(window) { insert(window) }
        } else if attempt < 3 {
            after([0.1, 0.3, 1.0][attempt]) { [weak self] in self?.windowCreated(window, attempt: attempt + 1) }
        }
    }

    // Each native tab is its own window, but only the selected one is listed, so a newly shown tab takes its hidden sibling's place.
    private func adoptTab(_ window: AXWindow) -> Bool {
        let tabs = window.tabTitles
        guard tabs.count > 1 else { return false }
        let listed = Set(AX.windows(of: window.pid))
        let frame = window.frame
        let candidates = allManagedWindows().filter { sibling in
            sibling.pid == window.pid && !listed.contains(sibling) && sibling.title.map(tabs.contains) == true
        }
        let distance = { (sibling: AXWindow) -> CGFloat in
            guard let known = self.placed[sibling] ?? self.parked[sibling], let frame else { return .greatestFiniteMagnitude }
            return abs(known.minX - frame.minX) + abs(known.minY - frame.minY)
        }
        guard let sibling = candidates.min(by: { distance($0) < distance($1) }),
              let (display, workspace) = location(of: sibling) else { return false }
        if let index = workspace.columnIndex(of: sibling) {
            workspace.columns[index] = Column(window, width: workspace.columns[index].width)
        } else if let index = workspace.floating.firstIndex(of: sibling) {
            workspace.floating[index] = window
        }
        if workspace.focused == sibling { workspace.focused = window }
        placed[window] = placed.removeValue(forKey: sibling)
        parked[window] = parked.removeValue(forKey: sibling)
        floatingFrames[window] = floatingFrames.removeValue(forKey: sibling)
        draggedWindows.remove(sibling)
        layout(display)
        return true
    }

    private func insert(_ window: AXWindow, on target: Display? = nil, width: CGFloat = TilingManager.newWindowWidth) {
        guard let display = target ?? window.frame.flatMap({ display(containing: CGPoint(x: $0.midX, y: $0.midY)) }) ?? displays.first
        else { return }
        let workspace = display.active
        let index = insertionIndex(for: window, in: workspace)
        workspace.columns.insert(Column(window, width: width), at: index)
        workspace.focused = window
        ensureVisible(index, in: workspace, on: display)
        layout(display)
    }

    private func appRank(of window: AXWindow) -> Int? {
        guard let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier else { return nil }
        return appliedAppOrder.firstIndex(of: bundleID)
    }

    // Ranked apps form one block on the left in list order; every other app goes after that block.
    private func insertionIndex(for window: AXWindow, in workspace: Workspace) -> Int {
        let ranks = workspace.columns.compactMap { appRank(of: $0.window) }
        guard let rank = appRank(of: window) else {
            let nextToFocused = workspace.focusedColumnIndex.map { $0 + 1 } ?? workspace.columns.count
            return max(nextToFocused, ranks.count)
        }
        return ranks.filter { $0 <= rank }.count
    }

    private func applyAppOrder(to workspace: Workspace) {
        workspace.columns = workspace.columns.enumerated()
            .sorted { (appRank(of: $0.element.window) ?? .max, $0.offset) < (appRank(of: $1.element.window) ?? .max, $1.offset) }
            .map(\.element)
    }

    private func forget(_ window: AXWindow) {
        dormant.remove(window)
        draggedWindows.remove(window)
        observedWindows.remove(window)
        removeFromLayout(window, refocus: true)
        parked.removeValue(forKey: window)
        placed.removeValue(forKey: window)
        floatingFrames.removeValue(forKey: window)
    }

    private func makeDormant(_ window: AXWindow) {
        removeFromLayout(window, refocus: false)
        parked.removeValue(forKey: window)
        floatingFrames.removeValue(forKey: window)
        dormant.insert(window)
    }

    private func revive(_ window: AXWindow) {
        guard dormant.contains(window), window.isTileable,
              NSRunningApplication(processIdentifier: window.pid)?.isHidden != true else { return }
        dormant.remove(window)
        insert(window)
    }

    private func removeFromLayout(_ window: AXWindow, refocus: Bool) {
        guard let (display, workspace) = location(of: window) else { return }
        let wasFocused = workspace.focused == window
        transition(display) {
            if let index = workspace.floating.firstIndex(of: window) {
                workspace.floating.remove(at: index)
                if wasFocused { workspace.focused = workspace.columns.first?.window }
            } else if let columnIndex = workspace.columnIndex(of: window) {
                workspace.columns.remove(at: columnIndex)
                if wasFocused {
                    let neighbour = columnIndex > 0 ? columnIndex - 1 : 0
                    workspace.focused = workspace.columns.indices.contains(neighbour)
                        ? workspace.columns[neighbour].window
                        : workspace.floating.last
                }
            }
            clampScroll(workspace, on: display)
            if let focused = workspace.focused, let index = workspace.columnIndex(of: focused), wasFocused {
                ensureVisible(index, in: workspace, on: display)
            }
        }
        if refocus, wasFocused, workspace === display.active, let focused = workspace.focused {
            suppressFollow()
            focused.focus()
        }
    }

    private func systemFocusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AX.focusedWindow(of: app.processIdentifier)
    }

    private func suppressFollow() {
        suppressFollowUntil = Date().addingTimeInterval(0.6)
    }

    private func focusChanged(_ pid: pid_t) {
        guard isRunning, !isSettlingSwipe, swipeDisplay == nil,
              let window = AX.focusedWindow(of: pid), !dormant.contains(window) else { return }
        guard let (display, workspace) = location(of: window) else {
            windowCreated(window, attempt: 3)
            return
        }
        if workspace !== display.active {
            guard Date() >= suppressFollowUntil,
                  let index = display.workspaces.firstIndex(where: { $0 === workspace }) else { return }
            cancelSettle()
            display.activeIndex = index
            workspace.focused = window
            if let columnIndex = workspace.columnIndex(of: window) {
                ensureVisible(columnIndex, in: workspace, on: display)
            }
            layout(display)
            return
        }
        workspace.focused = window
        if let columnIndex = workspace.columnIndex(of: window) {
            transition(display) { ensureVisible(columnIndex, in: workspace, on: display) }
        }
    }

    private func windowMovedOrResized(_ window: AXWindow, resized: Bool) {
        if resized, window.isFullScreen {
            if isManaged(window) { makeDormant(window) }
            return
        }
        if dormant.contains(window) {
            revive(window)
            return
        }
        guard NSEvent.pressedMouseButtons != 0, isManaged(window) else { return }
        draggedWindows.insert(window)
        guard dragTimer == nil else { return }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                self.dragTimer?.invalidate()
                self.dragTimer = nil
                let windows = self.draggedWindows
                self.draggedWindows = []
                windows.forEach(self.finishDrag)
            }
        }
    }

    private func finishDrag(_ window: AXWindow) {
        guard isRunning, parked[window] == nil, let (display, workspace) = location(of: window),
              let frame = window.frame else { return }
        let isFloating = workspace.floating.contains(window)
        if let expected = placed[window], !isFloating,
           abs(expected.minX - frame.minX) < 2, abs(expected.minY - frame.minY) < 2,
           abs(expected.width - frame.width) < 2, abs(expected.height - frame.height) < 2 {
            return
        }
        if workspace === display.active,
           let target = self.display(containing: CGPoint(x: frame.midX, y: frame.midY)), target !== display {
            let width = workspace.columns.first { $0.window == window }?.width ?? Self.newWindowWidth
            removeFromLayout(window, refocus: false)
            if isFloating {
                target.active.floating.append(window)
                target.active.focused = window
            } else {
                insert(window, on: target, width: width)
            }
            return
        }
        guard !isFloating, let columnIndex = workspace.columnIndex(of: window) else { return }
        let column = workspace.columns[columnIndex]
        let viewport = viewport(of: display)
        transition(display) {
            if abs(frame.width - pixelWidth(column.width, viewport)) > 2 {
                column.width = fraction(forWidth: frame.width, viewport)
            }
        }
    }

    func perform(_ command: Command) {
        if isSettlingSwipe { cancelSettle() }
        mover.restoreEnhancedUI()
        guard isRunning, let (display, workspace, window) = commandTarget() else { return }
        switch command {
        case .switchWorkspace(let number):
            switchWorkspace(number, on: display)
            return
        case .focus where window == nil || workspace.columnIndex(of: window!) == nil:
            focusNearestColumn(in: workspace, on: display)
            return
        default:
            break
        }
        guard let window else { return }
        let viewport = viewport(of: display)

        if command == .toggleFloat {
            toggleFloat(window, in: workspace, on: display)
            return
        }

        guard let columnIndex = workspace.columnIndex(of: window) else { return }
        let column = workspace.columns[columnIndex]

        switch command {
        case .focus(let direction):
            let next = columnIndex + (direction == .left ? -1 : 1)
            guard workspace.columns.indices.contains(next) else { return }
            focus(workspace.columns[next].window, in: workspace, on: display)

        case .move(let direction):
            let next = columnIndex + (direction == .left ? -1 : 1)
            guard workspace.columns.indices.contains(next) else { return }
            workspace.columns.swapAt(columnIndex, next)
            applyAppOrder(to: workspace)
            guard let moved = workspace.columnIndex(of: window), moved != columnIndex else { return }
            ensureVisible(moved, in: workspace, on: display)
            layout(display)

        case .widen:
            transition(display) {
                column.width = Self.widthPresets.first { $0 > column.width + 0.01 } ?? Self.widthPresets[0]
                ensureVisible(columnIndex, in: workspace, on: display)
            }

        case .narrow:
            guard let narrower = Self.widthPresets.last(where: { $0 < column.width - 0.01 }) else { return }
            transition(display) {
                column.width = narrower
                ensureVisible(columnIndex, in: workspace, on: display)
            }

        case .fill:
            transition(display) {
                column.width = 1
                ensureVisible(columnIndex, in: workspace, on: display)
            }

        case .center:
            transition(display) { workspace.scroll = columnCenters(workspace, viewport)[columnIndex] - viewport.width / 2 }

        default:
            break
        }
    }

    private func commandTarget() -> (Display, Workspace, AXWindow?)? {
        if let window = systemFocusedWindow(), let (display, workspace) = location(of: window), workspace === display.active {
            workspace.focused = window
            return (display, workspace, window)
        }
        guard let display = displayUnderMouse() else { return nil }
        let workspace = display.active
        return (display, workspace, workspace.focused)
    }

    private func focus(_ window: AXWindow, in workspace: Workspace, on display: Display) {
        workspace.focused = window
        transition(display) {
            if let index = workspace.columnIndex(of: window) { ensureVisible(index, in: workspace, on: display) }
        }
        window.focus()
    }

    private func focusNearestColumn(in workspace: Workspace, on display: Display) {
        let viewport = viewport(of: display)
        let centers = columnCenters(workspace, viewport)
        let center = workspace.scroll + viewport.width / 2
        let nearest = centers.indices.min { abs(centers[$0] - center) < abs(centers[$1] - center) }
        if let nearest { focus(workspace.columns[nearest].window, in: workspace, on: display) }
    }

    private func toggleFloat(_ window: AXWindow, in workspace: Workspace, on display: Display) {
        let viewport = viewport(of: display)
        if let columnIndex = workspace.columnIndex(of: window) {
            workspace.columns.remove(at: columnIndex)
            workspace.floating.append(window)
            let current = window.frame ?? viewport
            let size = CGSize(width: min(current.width, viewport.width * 0.8), height: min(current.height, viewport.height * 0.8))
            let frame = CGRect(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2, width: size.width, height: size.height)
            clampScroll(workspace, on: display)
            layout(display)
            place(window, frame.integral, in: nil, viewport)
        } else if let index = workspace.floating.firstIndex(of: window) {
            workspace.floating.remove(at: index)
            let center = (window.frame?.midX ?? viewport.midX) - viewport.minX + workspace.scroll
            let insertAt = columnCenters(workspace, viewport).filter { $0 < center }.count
            workspace.columns.insert(Column(window, width: Self.newWindowWidth), at: insertAt)
            applyAppOrder(to: workspace)
            ensureVisible(workspace.columnIndex(of: window) ?? insertAt, in: workspace, on: display)
            layout(display)
        }
        workspace.focused = window
        window.focus()
    }

    private func switchWorkspace(_ number: Int, on display: Display) {
        let index = number - 1
        guard display.workspaces.indices.contains(index), index != display.activeIndex else { return }
        cancelSettle()
        display.activeIndex = index
        suppressFollow()
        layout(display)
        display.active.focused?.focus()
    }

    func swipeBegan() {
        guard isRunning else { return }
        cancelSettle()
        swipeVelocity = 0
        pendingSwipe = 0
        lastSwipeTime = ProcessInfo.processInfo.systemUptime
        swipeDisplay = displayUnderMouse()
        swipeCanRevealDesktop = (swipeDisplay?.active.scroll ?? 1) <= 0.5
    }

    func swipeMoved(by delta: CGFloat) {
        guard isRunning, swipeDisplay != nil else { return }
        pendingSwipe += delta
        guard !swipeFlushScheduled else { return }
        swipeFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushSwipe() }
        }
    }

    private func flushSwipe() {
        swipeFlushScheduled = false
        guard isRunning, let display = swipeDisplay, pendingSwipe != 0 else { return }
        let workspace = display.active
        let viewport = viewport(of: display)
        guard let range = swipeRange(workspace, on: display) else { return }
        let previous = workspace.scroll
        workspace.scroll = min(max(previous - pendingSwipe * viewport.width * 1.5, range.lowerBound), range.upperBound)
        pendingSwipe = 0
        let current = workspace.scroll

        let now = ProcessInfo.processInfo.systemUptime
        let instant = (current - previous) / max(now - lastSwipeTime, 1.0 / 240)
        swipeVelocity = swipeVelocity * 0.4 + instant * 0.6
        lastSwipeTime = now

        if current != previous {
            if current == range.lowerBound || current == range.upperBound {
                haptic(.levelChange)
            } else if snapPoints(workspace, on: display).contains(where: { point in
                (previous - point) * (current - point) < 0 || current == point
            }) {
                haptic(.alignment)
            }
        }
        layout(display, sliding: true)
    }

    func swipeEnded() {
        guard isRunning, let display = swipeDisplay else { return }
        flushSwipe()
        swipeDisplay = nil
        pendingSwipe = 0
        let workspace = display.active
        if ProcessInfo.processInfo.systemUptime - lastSwipeTime > 0.08 { swipeVelocity = 0 }
        let scroll = workspace.scroll
        let points = snapPoints(workspace, on: display).filter { $0 >= (swipeRange(workspace, on: display)?.lowerBound ?? $0) }
        let nearest = { (to: CGFloat, among: [CGFloat]) in among.min { abs($0 - to) < abs($1 - to) } }
        var target = nearest(scroll, points) ?? scroll
        if abs(swipeVelocity) > 350 {
            let ahead = points.filter { swipeVelocity > 0 ? $0 > scroll + 1 : $0 < scroll - 1 }
            target = nearest(scroll + swipeVelocity * 0.18, ahead) ?? target
        }
        settle(display, to: target, velocity: swipeVelocity) { [weak self] in
            guard let self else { return }
            self.layout(display)
            self.mover.restoreEnhancedUI()
            self.focusVisibleColumn(in: display.active, on: display)
        }
    }

    private func desktopScroll(of display: Display) -> CGFloat {
        viewport(of: display).minX - display.frame.maxX
    }

    private func swipeRange(_ workspace: Workspace, on display: Display) -> ClosedRange<CGFloat>? {
        guard let bounds = scrollBounds(workspace, viewport(of: display)) else { return nil }
        let lower = swipeCanRevealDesktop ? min(desktopScroll(of: display), bounds.lowerBound) : bounds.lowerBound
        return lower...bounds.upperBound
    }

    private func snapPoints(_ workspace: Workspace, on display: Display) -> [CGFloat] {
        let viewport = viewport(of: display)
        guard let last = workspace.columns.indices.last else { return [0] }
        let lefts = columnLefts(workspace, viewport)
        let end = max(0, lefts[last] + pixelWidth(workspace.columns[last].width, viewport) - viewport.width)
        return [desktopScroll(of: display)] + lefts.filter { $0 < end } + [end]
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Critically damped spring seeded with the release velocity, capped so it never overshoots the target.
    private func settle(_ display: Display, to target: CGFloat, velocity: CGFloat, completion: @escaping @MainActor () -> Void) {
        cancelSettle()
        let workspace = display.active
        let offset = workspace.scroll - target
        guard abs(offset) > 0.5, !reduceMotion else {
            workspace.scroll = target
            completion()
            return
        }
        let omega: CGFloat = 26
        let limit = omega * abs(offset)
        let initialVelocity = offset > 0 ? min(0, max(velocity, -limit)) : max(0, min(velocity, limit))
        let slope = initialVelocity + omega * offset
        isSettlingSwipe = true
        animate(display) { t in
            let displacement = (offset + slope * t) * exp(-omega * t)
            let done = abs(displacement) < 0.5 || t > 0.8
            workspace.scroll = done ? target : target + displacement
            return done
        } completion: { [weak self] in
            self?.isSettlingSwipe = false
            completion()
        }
    }

    // Applies a layout change, then eases every window from where it is on screen to its new place.
    private func transition(_ display: Display, _ change: () -> Void) {
        let workspace = display.active
        let before = columnFrames(workspace, on: display)
        change()
        let after = columnFrames(workspace, on: display)
        guard workspace === display.active, after != before else { return }
        var starts: [AXWindow: CGFloat] = [:]
        for (window, frame) in after {
            guard let old = before[window] else { continue }
            let delta = old.minX + (offsets[window] ?? 0) - frame.minX
            if abs(delta) > 0.5 { starts[window] = delta }
        }
        cancelSettle()
        guard let distance = starts.values.map(abs).max(), !reduceMotion else {
            layout(display)
            return
        }
        let duration = min(0.38, 0.2 + distance / 8000)
        animate(display) { [weak self] t in
            let progress = min(1, t / duration)
            let eased = progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(2 - 2 * progress, 3) / 2
            self?.offsets = starts.mapValues { $0 * (1 - eased) }
            return progress >= 1
        } completion: { [weak self] in
            guard let self else { return }
            self.offsets = [:]
            self.layout(display)
            self.mover.restoreEnhancedUI()
        }
    }

    private func columnFrames(_ workspace: Workspace, on display: Display) -> [AXWindow: CGRect] {
        let viewport = viewport(of: display)
        let lefts = columnLefts(workspace, viewport)
        var frames: [AXWindow: CGRect] = [:]
        for (index, column) in workspace.columns.enumerated() {
            let x = (viewport.minX + lefts[index] - workspace.scroll).rounded()
            frames[column.window] = CGRect(x: x, y: viewport.minY, width: pixelWidth(column.width, viewport), height: viewport.height)
        }
        return frames
    }

    private func animate(
        _ display: Display,
        step: @escaping @MainActor (CGFloat) -> Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                let done = step(CGFloat(ProcessInfo.processInfo.systemUptime - began))
                self.layout(display, sliding: true)
                if done {
                    self.cancelSettle()
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func cancelSettle() {
        settleTimer?.invalidate()
        settleTimer = nil
        isSettlingSwipe = false
        offsets = [:]
    }

    private func focusVisibleColumn(in workspace: Workspace, on display: Display) {
        let viewport = viewport(of: display)
        let lefts = columnLefts(workspace, viewport)
        let fullyVisible = workspace.columns.indices.filter { index in
            let left = lefts[index] - workspace.scroll
            return left >= -0.5 && left + pixelWidth(workspace.columns[index].width, viewport) <= viewport.width + 0.5
        }
        if let focused = workspace.focused, let index = workspace.columnIndex(of: focused), fullyVisible.contains(index) {
            return
        }
        if let index = fullyVisible.first {
            focus(workspace.columns[index].window, in: workspace, on: display)
        }
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTime > 0.05 else { return }
        lastHapticTime = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func viewport(of display: Display) -> CGRect {
        display.visibleFrame.insetBy(dx: gap, dy: gap)
    }

    private func pixelWidth(_ fraction: CGFloat, _ viewport: CGRect) -> CGFloat {
        max(1, (fraction * (viewport.width + gap) - gap).rounded())
    }

    private func fraction(forWidth width: CGFloat, _ viewport: CGRect) -> CGFloat {
        min(1, max(0.1, (width + gap) / (viewport.width + gap)))
    }

    private func columnLefts(_ workspace: Workspace, _ viewport: CGRect) -> [CGFloat] {
        var x: CGFloat = 0
        return workspace.columns.map { column in
            defer { x += pixelWidth(column.width, viewport) + gap }
            return x
        }
    }

    private func columnCenters(_ workspace: Workspace, _ viewport: CGRect) -> [CGFloat] {
        zip(columnLefts(workspace, viewport), workspace.columns).map { left, column in
            left + pixelWidth(column.width, viewport) / 2
        }
    }

    private func ensureVisible(_ index: Int, in workspace: Workspace, on display: Display) {
        let viewport = viewport(of: display)
        let lefts = columnLefts(workspace, viewport)
        guard lefts.indices.contains(index) else { return }
        if let bounds = scrollBounds(workspace, viewport) { workspace.scroll = max(workspace.scroll, bounds.lowerBound) }
        let left = lefts[index]
        let width = pixelWidth(workspace.columns[index].width, viewport)
        let fullyVisible = left >= workspace.scroll && left + width <= workspace.scroll + viewport.width
        guard !fullyVisible || width >= viewport.width else { return }
        let last = workspace.columns.count - 1
        let end = max(0, lefts[last] + pixelWidth(workspace.columns[last].width, viewport) - viewport.width)
        workspace.scroll = width >= viewport.width ? left : min(left, end)
    }

    private func scrollBounds(_ workspace: Workspace, _ viewport: CGRect) -> ClosedRange<CGFloat>? {
        guard let lastIndex = workspace.columns.indices.last else { return nil }
        let lefts = columnLefts(workspace, viewport)
        let firstCenter = pixelWidth(workspace.columns[0].width, viewport) / 2
        let lastWidth = pixelWidth(workspace.columns[lastIndex].width, viewport)
        let lastRight = lefts[lastIndex] + lastWidth
        let lower = min(0, firstCenter - viewport.width / 2)
        let upper = max(lower, max(lastRight - viewport.width, lefts[lastIndex] + lastWidth / 2 - viewport.width / 2))
        return lower...upper
    }

    private func clampScroll(_ workspace: Workspace, on display: Display) {
        guard let bounds = scrollBounds(workspace, viewport(of: display)) else {
            workspace.scroll = 0
            return
        }
        if workspace.scroll < bounds.lowerBound {
            workspace.scroll = min(desktopScroll(of: display), bounds.lowerBound)
            return
        }
        workspace.scroll = min(workspace.scroll, bounds.upperBound)
    }

    private func layoutAll() {
        displays.forEach { layout($0) }
    }

    private func layout(_ display: Display, pass: Int = 0, sliding: Bool = false) {
        guard isRunning, displays.contains(where: { $0 === display }) else { return }
        let viewport = viewport(of: display)

        for (index, workspace) in display.workspaces.enumerated() where index != display.activeIndex && !sliding {
            for window in workspace.floating where parked[window] == nil {
                if let frame = window.frame { floatingFrames[window] = frame }
            }
            for window in workspace.allWindows { park(window, on: display, side: .corner) }
        }

        let workspace = display.active
        let lefts = columnLefts(workspace, viewport)
        var widthChanged = false
        for (index, column) in workspace.columns.enumerated() {
            let width = pixelWidth(column.width, viewport)
            let x = (viewport.minX + lefts[index] - workspace.scroll + (offsets[column.window] ?? 0)).rounded()
            let visible = x < display.frame.maxX && x + width > display.frame.minX
            let side: ParkSide = x + width <= display.frame.minX ? .left : .right
            let frame = CGRect(x: x, y: viewport.minY, width: width, height: viewport.height)
            let window = column.window
            if visible && sliding {
                slide(window, to: frame, in: column, viewport)
            } else if visible {
                widthChanged = place(window, frame, in: column, viewport) || widthChanged
            } else {
                park(window, on: display, side: side, size: frame.size, sliding: sliding)
            }
        }

        for window in workspace.floating where parked[window] != nil && !sliding {
            let restored = floatingFrames.removeValue(forKey: window)
                ?? CGRect(x: viewport.midX - viewport.width * 0.3, y: viewport.midY - viewport.height * 0.3,
                          width: viewport.width * 0.6, height: viewport.height * 0.6)
            place(window, restored, in: nil, viewport)
        }

        if widthChanged && pass == 0 {
            layout(display, pass: 1)
        }
    }

    @discardableResult
    private func place(_ window: AXWindow, _ frame: CGRect, in column: Column?, _ viewport: CGRect) -> Bool {
        mover.drain(window)
        parked.removeValue(forKey: window)
        placed[window] = frame
        let current = window.frame
        guard window.setFrame(frame, current: current), let column,
              let actual = window.size, let before = current?.size,
              actual.width > frame.width + 2, abs(actual.width - before.width) > 1 else { return false }
        column.width = max(column.width, fraction(forWidth: actual.width, viewport))
        return true
    }

    private func slide(_ window: AXWindow, to frame: CGRect, in column: Column, _ viewport: CGRect) {
        guard let known = parked[window] ?? placed[window], known.size == frame.size else {
            place(window, frame, in: column, viewport)
            return
        }
        parked.removeValue(forKey: window)
        placed[window] = frame
        if known.origin != frame.origin { mover.move(window, to: frame.origin) }
    }

    private enum ParkSide { case left, right, corner }

    private func park(_ window: AXWindow, on display: Display, side: ParkSide, size: CGSize? = nil, sliding: Bool = false) {
        guard let size = size ?? parked[window]?.size ?? window.size else { return }
        let screen = display.frame
        let top = viewport(of: display).minY
        let leftEdge = CGPoint(x: screen.minX - size.width + 1, y: top)
        let rightEdge = CGPoint(x: screen.maxX - 1, y: top)
        let bottomLeft = CGPoint(x: screen.minX - size.width + 1, y: screen.maxY - 1)
        let bottomRight = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        let candidates: [CGPoint]
        switch side {
        case .left: candidates = [leftEdge, bottomLeft, bottomRight]
        case .right: candidates = [rightEdge, bottomRight, bottomLeft]
        case .corner: candidates = [bottomRight, bottomLeft]
        }
        let others = displays.filter { $0 !== display }.map(\.frame)
        let origin = candidates.first { origin in
            let rect = CGRect(origin: origin, size: size).insetBy(dx: 2, dy: 2)
            return !others.contains { $0.intersects(rect) }
        } ?? candidates[0]
        let rect = CGRect(origin: origin, size: size)
        guard parked[window] != rect else { return }
        if sliding, placed[window]?.size == rect.size {
            mover.move(window, to: rect.origin)
        } else {
            mover.drain(window)
            window.setFrame(rect, current: window.frame)
        }
        parked[window] = rect
    }

    private func releaseParkedWindows() {
        var offset: CGFloat = 0
        for display in displays {
            let viewport = viewport(of: display)
            for workspace in display.workspaces {
                for window in workspace.allWindows where parked[window] != nil {
                    mover.drain(window)
                    if let frame = floatingFrames[window] {
                        window.setFrame(frame, current: nil)
                        continue
                    }
                    let size = window.size ?? CGSize(width: viewport.width / 2, height: viewport.height)
                    let fitted = CGSize(width: min(size.width, viewport.width - 200), height: min(size.height, viewport.height - 200))
                    let frame = CGRect(x: viewport.minX + offset, y: viewport.minY + offset, width: fitted.width, height: fitted.height)
                    window.setFrame(frame, current: nil)
                    offset = offset >= 180 ? 0 : offset + 30
                }
            }
        }
    }
}

private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated { body() }
    }
}
