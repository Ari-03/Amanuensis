import Carbon
import Foundation

/// Emulates exclusive OS registrations without claiming real keyboard shortcuts.
@MainActor
private final class HotKeys {
    var active: [EventHotKeyRef: ShortcutBinding] = [:]
    var rejectedKey: UInt32?
    private var identifiers: [EventHotKeyRef: UInt32] = [:]
    private var next = 0

    var backend: GlobalShortcuts.Backend {
        GlobalShortcuts.Backend(
            register: { [self] identifier, binding in
                guard binding.keyCode != rejectedKey,
                    !active.values.contains(where: {
                        $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers
                    })
                else { return (OSStatus(eventHotKeyExistsErr), nil) }
                next += 1
                let reference = EventHotKeyRef(bitPattern: next)!
                active[reference] = binding
                identifiers[reference] = identifier
                return (noErr, reference)
            },
            unregister: { [self] in
                active.removeValue(forKey: $0)
                identifiers.removeValue(forKey: $0)
            }
        )
    }

    func press(_ binding: ShortcutBinding) {
        let reference = active.first(where: { $0.value == binding })!.key
        var identifier = EventHotKeyID(signature: 0x414D_414E, id: identifiers[reference]!)
        for kind in [kEventHotKeyPressed, kEventHotKeyReleased] {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0, 0, &event) == noErr)
            precondition(
                SetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
            ReleaseEvent(event)
        }
    }
}

@main
struct ShortcutChecks {
    @MainActor
    static func main() {
        let keys = HotKeys()
        let manager = GlobalShortcuts(backend: keys.backend)
        let toggle = ShortcutBinding(keyCode: 1, modifiers: UInt32(cmdKey), display: "Cmd S")
        let first = ShortcutBinding(keyCode: 2, modifiers: UInt32(cmdKey), display: "Cmd D")
        let refused = ShortcutBinding(keyCode: 3, modifiers: UInt32(cmdKey), display: "Cmd F")
        let mode = UUID()
        var invokedModes: [UUID] = []
        var toggles = 0
        @discardableResult func apply(_ binding: ShortcutBinding) -> Bool {
            manager.setBindings(
                toggle: toggle, pushToTalk: nil, changeMode: nil,
                onToggle: { toggles += 1 }, onPushToTalk: { _ in }, onChangeMode: {}, onCancel: {},
                modeBindings: [mode: binding], onModeRecording: { invokedModes.append($0) })
        }
        apply(first)
        precondition(manager.registrationErrors.isEmpty)
        let original = keys.active
        keys.rejectedKey = refused.keyCode
        precondition(!apply(refused))
        precondition(!manager.registrationErrors.isEmpty)
        guard keys.active == original else {
            print("FAIL: rejected mode shortcut removed the previous working registration")
            exit(1)
        }
        keys.press(first)
        precondition(invokedModes == [mode])

        // In-app duplicates and reserved Escape reject before modifying the active set.
        precondition(!apply(toggle))
        precondition(keys.active == original)
        precondition(!apply(ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "Escape")))
        precondition(keys.active == original)

        // Roll back newly staged chords when a later chord fails.
        let staged = ShortcutBinding(keyCode: 4, modifiers: UInt32(cmdKey), display: "Cmd H")
        precondition(
            !manager.setBindings(
                toggle: staged, pushToTalk: nil, changeMode: nil,
                onToggle: {}, onPushToTalk: { _ in }, onChangeMode: {}, onCancel: {},
                modeBindings: [mode: refused]))
        precondition(keys.active == original)
        keys.press(toggle)
        precondition(toggles == 1, "Failed edits must keep the previous callbacks")

        keys.rejectedKey = nil
        precondition(apply(refused))
        precondition(!keys.active.values.contains(first))
        precondition(keys.active.count == 2)
        keys.press(refused)
        precondition(invokedModes == [mode, mode])

        // Inserting an earlier mode shifts action IDs, while native chord IDs stay stable.
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        precondition(
            manager.setBindings(
                toggle: toggle, pushToTalk: nil, changeMode: nil,
                onToggle: {}, onPushToTalk: { _ in }, onChangeMode: {}, onCancel: {},
                modeBindings: [earlier: first, mode: refused],
                onModeRecording: { invokedModes.append($0) }))
        keys.press(refused)
        keys.press(first)
        precondition(Array(invokedModes.suffix(2)) == [mode, earlier])

        manager.setRecordingActive(true)
        precondition(keys.active.count == 4)
        manager.setRecordingActive(false)
        precondition(keys.active.count == 3)
        print(
            "Shortcut checks passed: rejection, conflicts, staging rollback, callbacks, mode ordering, Escape"
        )
    }
}
