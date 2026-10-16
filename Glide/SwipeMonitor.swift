import AppKit
import CoreGraphics

final class SwipeMonitor {
    private static let gestureEventType: UInt32 = 29

    var fingers = 4
    var onBegan: () -> Void = {}
    var onMoved: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastX: CGFloat?
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var lastY: CGFloat = 0
    private var state = State.idle

    private enum State { case idle, deciding, swiping, ignoring }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << CGEventMask(Self.gestureEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<SwipeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        finish()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type.rawValue == Self.gestureEventType, let nsEvent = NSEvent(cgEvent: event) else { return }
        let touches = nsEvent.allTouches().filter { !$0.phase.isDisjoint(with: .touching) && !$0.isResting }
        guard touches.count == fingers else {
            finish()
            return
        }
        let x = touches.map(\.normalizedPosition.x).reduce(0, +) / CGFloat(touches.count)
        let y = touches.map(\.normalizedPosition.y).reduce(0, +) / CGFloat(touches.count)
        guard let previousX = lastX else {
            lastX = x
            lastY = y
            travelX = 0
            travelY = 0
            state = .deciding
            return
        }
        let dx = x - previousX
        let dy = y - lastY
        lastX = x
        lastY = y

        switch state {
        case .deciding:
            travelX += dx
            travelY += dy
            if abs(travelY) > 0.03, abs(travelY) > abs(travelX) {
                state = .ignoring
            } else if abs(travelX) > 0.015 {
                state = .swiping
                onBegan()
                onMoved(travelX)
            }
        case .swiping:
            onMoved(dx)
        case .idle, .ignoring:
            break
        }
    }

    private func finish() {
        if state == .swiping { onEnded() }
        state = .idle
        lastX = nil
    }
}
