import CoreGraphics
import Foundation

// Slides the row with scroll events while the shortcut modifier is held. The tap runs on its own thread
// because an active tap holds every scroll event until it returns, and the main thread is busy moving windows.
nonisolated final class ScrollMonitor: @unchecked Sendable {
    private static let wheelIdleEnd: TimeInterval = 0.15
    private static let wheelBoost: CGFloat = 4

    var onBegan: @MainActor () -> Void = {}
    var onMoved: @MainActor (CGFloat) -> Void = { _ in }
    var onEnded: @MainActor () -> Void = {}

    private let lock = NSLock()
    private var requiredFlags: CGEventFlags = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    private var active = false
    private var swallowingMomentum = false
    private var wheelEndTimer: Timer?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    func setModifier(_ flags: CGEventFlags) {
        lock.lock()
        requiredFlags = flags
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ScrollMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        lock.lock()
        self.tap = tap
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            lock.lock()
            runLoop = CFRunLoopGetCurrent()
            lock.unlock()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "glide.scroll-monitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        lock.lock()
        let tap = self.tap
        let runLoop = self.runLoop
        self.tap = nil
        self.runLoop = nil
        lock.unlock()
        guard let tap, let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            wheelEndTimer?.invalidate()
            wheelEndTimer = nil
            if active { end() }
            swallowingMomentum = false
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    // Runs on the tap thread; returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .scrollWheel else { return false }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        if momentum != 0 {
            guard swallowingMomentum else { return false }
            if momentum == Int64(CGMomentumScrollPhase.end.rawValue) { swallowingMomentum = false }
            return true
        }

        let began = phase == Int64(CGScrollPhase.began.rawValue)
        let finished = phase == Int64(CGScrollPhase.ended.rawValue) || phase == Int64(CGScrollPhase.cancelled.rawValue)
        let phaseless = phase == 0

        if !active {
            guard began || phaseless, modifierHeld(event) else { return false }
            active = true
            swallowingMomentum = false
            DispatchQueue.main.async { [onBegan] in MainActor.assumeIsolated { onBegan() } }
        }

        let delta = self.delta(of: event) * (continuous ? 1 : Self.wheelBoost)
        if delta != 0 {
            DispatchQueue.main.async { [onMoved] in MainActor.assumeIsolated { onMoved(delta) } }
        }

        if finished {
            swallowingMomentum = true
            end()
        } else if phaseless {
            wheelEndTimer?.invalidate()
            wheelEndTimer = Timer.scheduledTimer(withTimeInterval: Self.wheelIdleEnd, repeats: false) { [weak self] _ in
                self?.end()
            }
        }
        return true
    }

    private func end() {
        wheelEndTimer?.invalidate()
        wheelEndTimer = nil
        active = false
        DispatchQueue.main.async { [onEnded] in MainActor.assumeIsolated { onEnded() } }
    }

    private func modifierHeld(_ event: CGEvent) -> Bool {
        lock.lock()
        let required = requiredFlags
        lock.unlock()
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return !required.isEmpty && event.flags.intersection(relevant) == required
    }

    // Positive slides toward the windows on the left, matching the trackpad swipe.
    private func delta(of event: CGEvent) -> CGFloat {
        let horizontal = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let vertical = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        return abs(horizontal) >= abs(vertical) ? horizontal : vertical
    }
}
