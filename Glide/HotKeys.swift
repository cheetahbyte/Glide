import Carbon.HIToolbox
import Foundation

final class HotKeys {
    private static let signature: OSType = 0x474C_4944 // "GLID"

    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: Command] = [:]
    private var handlerRef: EventHandlerRef?
    private let onCommand: (Command) -> Void

    init(onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKeys.fire(id: hotKeyID.id) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            NSLog("Glide: InstallEventHandler failed (\(status))")
        }
    }

    func register(_ shortcuts: [Shortcut], modifier: ModifierChoice) {
        unregisterAll()
        var base: Int
        switch modifier {
        case .controlOption: base = controlKey | optionKey
        case .option: base = optionKey
        case .commandOption: base = cmdKey | optionKey
        }
        for (index, shortcut) in shortcuts.enumerated() {
            let id = UInt32(index + 1)
            let modifiers = UInt32(base | (shortcut.shift ? shiftKey : 0))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.key.keyCode),
                modifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                commands[id] = shortcut.command
            } else {
                NSLog("Glide: could not register \(shortcut.label(modifier: modifier)) (\(status))")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        commands.removeAll()
    }

    private func fire(id: UInt32) {
        if let command = commands[id] {
            onCommand(command)
        }
    }
}
