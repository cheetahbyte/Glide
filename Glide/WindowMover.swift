import ApplicationServices
import Foundation

// Moves run on a per-app queue so one slow app can't stall the main thread or other windows.
nonisolated final class WindowMover: @unchecked Sendable {
    static let shared = WindowMover()

    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]
    private var pending: [AXWindow: CGPoint] = [:]
    private var suspended: Set<pid_t> = []

    func move(_ window: AXWindow, to origin: CGPoint) {
        lock.lock()
        let alreadyScheduled = pending.updateValue(origin, forKey: window) != nil
        let queue = queue(for: window.pid)
        lock.unlock()
        guard !alreadyScheduled else { return }
        queue.async { [self] in
            lock.lock()
            let latest = pending.removeValue(forKey: window)
            lock.unlock()
            guard let latest else { return }
            suspendEnhancedUI(window.pid)
            AX.setPoint(window.element, latest)
        }
    }

    func drain(_ window: AXWindow) {
        lock.lock()
        pending.removeValue(forKey: window)
        let queue = queues[window.pid]
        lock.unlock()
        queue?.sync {}
    }

    // Restores what suspendEnhancedUI turned off; call once the slide is over.
    func restoreEnhancedUI() {
        lock.lock()
        let pids = suspended
        let targets = pids.compactMap { pid in queues[pid].map { (pid, $0) } }
        lock.unlock()
        for (pid, queue) in targets {
            queue.async { [self] in
                lock.lock()
                let wasSuspended = suspended.remove(pid) != nil
                lock.unlock()
                if wasSuspended { AX.set(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface", kCFBooleanTrue) }
            }
        }
    }

    func forget(_ pid: pid_t) {
        lock.lock()
        queues.removeValue(forKey: pid)
        suspended.remove(pid)
        lock.unlock()
    }

    // Chromium and Electron apps rebuild their accessibility tree on every move while this is on.
    private func suspendEnhancedUI(_ pid: pid_t) {
        lock.lock()
        let already = suspended.contains(pid)
        lock.unlock()
        guard !already else { return }
        let app = AXUIElementCreateApplication(pid)
        guard AX.bool(app, "AXEnhancedUserInterface") == true else { return }
        AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse)
        lock.lock()
        suspended.insert(pid)
        lock.unlock()
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let existing = queues[pid] { return existing }
        let created = DispatchQueue(label: "glide.window-mover.\(pid)", qos: .userInteractive)
        queues[pid] = created
        return created
    }
}
