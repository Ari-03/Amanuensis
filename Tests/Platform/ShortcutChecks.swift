import AppKit
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

/// Replays AppKit events through the same monitor callback used by local and global input.
@MainActor
private final class ModifierKeys {
    private var handlers: [Int: (NSEvent) -> Void] = [:]
    var activeCount: Int { handlers.count }
    var available = true
    var starts = 0
    var stops = 0

    var monitor: GlobalShortcuts.ModifierMonitor {
        GlobalShortcuts.ModifierMonitor { [self] handler in
            guard available else { return nil }
            starts += 1
            let identifier = starts
            handlers[identifier] = handler
            return { [self] in
                stops += 1
                handlers.removeValue(forKey: identifier)
            }
        }
    }

    static func event(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: keyCode == nil ? .flagsChanged : .keyDown,
            location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: keyCode == nil ? "" : "a",
            charactersIgnoringModifiers: keyCode == nil ? "" : "a", isARepeat: false,
            keyCode: keyCode ?? 55)!
    }

    func flags(_ flags: NSEvent.ModifierFlags) {
        for handler in Array(handlers.values) { handler(Self.event(flags)) }
    }
    func key(_ flags: NSEvent.ModifierFlags) {
        for handler in Array(handlers.values) { handler(Self.event(flags, keyCode: 0)) }
    }

    func tap(_ flags: NSEvent.ModifierFlags) {
        self.flags(flags)
        self.flags([])
    }
}

@main
struct ShortcutChecks {
    @MainActor
    static func main() async throws {
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
        try await monitorReplacementChecks()
        try await modifierChecks()
        print(
            "Shortcut checks passed: registration rollback, modes, Escape, modifier capture/persistence, chord suppression, hold-to-talk, interruption, monitor recovery"
        )
    }

    @MainActor
    private static func monitorReplacementChecks() async throws {
        let keys = HotKeys()
        let modifiers = ModifierKeys()
        let manager = GlobalShortcuts(backend: keys.backend, modifierMonitor: modifiers.monitor)
        var toggles = 0
        var holds: [Bool] = []
        precondition(
            manager.setBindings(
                toggle: ShortcutBinding(keyCode: nil, modifiers: UInt32(cmdKey | optionKey), display: "⌥⌘"),
                pushToTalk: ShortcutBinding(
                    keyCode: nil, modifiers: UInt32(controlKey | optionKey), display: "⌃⌥"),
                changeMode: nil, onToggle: { toggles += 1 }, onPushToTalk: { holds.append($0) },
                onChangeMode: {}, onCancel: {}))
        modifiers.tap([.command, .option])
        precondition(toggles == 1)

        modifiers.available = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        modifiers.tap([.command, .option])
        precondition(toggles == 2, "Failed monitor replacement must keep modifier shortcuts working")
        precondition(modifiers.activeCount == 1 && modifiers.stops == 0)

        modifiers.flags([.control, .option])
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(240))
        modifiers.flags([])
        precondition(holds.isEmpty, "Failed monitor replacement must cancel a pending hold")

        modifiers.flags([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        precondition(holds == [true])
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        modifiers.flags([])
        precondition(holds == [true, false], "Failed monitor replacement must release active push-to-talk")

        modifiers.available = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        precondition(modifiers.activeCount == 1 && modifiers.starts == 2 && modifiers.stops == 1)
        modifiers.tap([.command, .option])
        precondition(toggles == 3, "A later successful replacement must invoke each shortcut once")
    }

    @MainActor
    private static func modifierChecks() async throws {
        let commandOption = ShortcutBinding(
            keyCode: nil, modifiers: UInt32(cmdKey | optionKey), display: "⌥⌘")
        let controlOption = ShortcutBinding(
            keyCode: nil, modifiers: UInt32(controlKey | optionKey), display: "⌃⌥")
        let keyChord = ShortcutBinding.recording
        let legacy = Data(#"{"keyCode":49,"modifiers":2304,"display":"⌥⌘Space"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ShortcutBinding.self, from: legacy)
        precondition(decodedLegacy == keyChord)
        let saved = try JSONEncoder().encode(commandOption)
        let decodedJSON = try JSONDecoder().decode(ShortcutBinding.self, from: saved)
        precondition(decodedJSON == commandOption)
        let plist = try PropertyListEncoder().encode(commandOption)
        let decodedPlist = try PropertyListDecoder().decode(ShortcutBinding.self, from: plist)
        precondition(decodedPlist == commandOption)

        let capture = KeyCapture.CaptureView()
        var captured: [ShortcutBinding] = []
        capture.onResult = { if let binding = $0 { captured.append(binding) } }
        capture.flagsChanged(with: ModifierKeys.event(.command))
        capture.flagsChanged(with: ModifierKeys.event([.command, .option]))
        capture.flagsChanged(with: ModifierKeys.event(.option))
        precondition(captured.isEmpty, "Capture must wait until every modifier has been released")
        capture.flagsChanged(with: ModifierKeys.event([]))
        precondition(captured == [commandOption])
        capture.flagsChanged(with: ModifierKeys.event(.shift))
        capture.flagsChanged(with: ModifierKeys.event([]))
        precondition(captured == [commandOption], "A lone modifier must not create a shortcut")
        capture.flagsChanged(with: ModifierKeys.event([.command, .option]))
        capture.keyDown(with: ModifierKeys.event([.command, .option], keyCode: 0))
        capture.flagsChanged(with: ModifierKeys.event([]))
        precondition(captured.count == 2 && captured.last?.keyCode == 0)

        let keys = HotKeys()
        let modifiers = ModifierKeys()
        let manager = GlobalShortcuts(backend: keys.backend, modifierMonitor: modifiers.monitor)
        var toggles = 0
        var holds: [Bool] = []
        var changes = 0
        var interruptions = 0
        @discardableResult func apply(_ toggle: ShortcutBinding = commandOption) -> Bool {
            manager.setBindings(
                toggle: toggle, pushToTalk: controlOption, changeMode: keyChord,
                onToggle: { toggles += 1 }, onPushToTalk: { holds.append($0) },
                onChangeMode: { changes += 1 }, onCancel: {},
                onInterruption: { interruptions += 1 })
        }
        precondition(apply())
        precondition(keys.active.count == 1, "Modifier-only shortcuts must not be sent to Carbon")
        modifiers.key([])
        modifiers.flags(.command)
        modifiers.flags([.command, .option])
        modifiers.flags([.command, .option])
        modifiers.flags(.option)
        precondition(toggles == 0)
        modifiers.flags([])
        precondition(toggles == 1, "Typing without modifiers must not cancel the next modifier gesture")
        modifiers.flags(.option)
        modifiers.flags([.command, .option])
        modifiers.flags(.command)
        modifiers.flags([])
        precondition(toggles == 2, "Either modifier order must work")
        modifiers.flags([.command, .option])
        modifiers.key([.command, .option])
        modifiers.flags([])
        precondition(toggles == 2, "Normal key chords must not toggle recording")
        modifiers.flags([.command, .option])
        keys.press(keyChord)
        modifiers.flags([])
        precondition(changes == 1 && toggles == 2, "Carbon chords must also suppress modifier taps")
        modifiers.flags([.command, .option, .shift])
        modifiers.flags([.command, .option])
        modifiers.flags([])
        precondition(toggles == 2, "Releasing a larger combination must not fire a subset")
        modifiers.flags([.command, .option])
        modifiers.flags(.command)
        modifiers.flags([.command, .option])
        modifiers.flags([])
        precondition(toggles == 2, "Re-adding modifiers during release must not trigger")

        let same = ShortcutBinding(
            keyCode: nil, modifiers: commandOption.modifiers, display: "Option Command")
        precondition(
            !manager.setBindings(
                toggle: commandOption, pushToTalk: same, changeMode: nil,
                onToggle: {}, onPushToTalk: { _ in }, onChangeMode: {}, onCancel: {}))
        modifiers.tap([.command, .option])
        precondition(toggles == 3, "Rejected edits must retain modifier callbacks")
        manager.setRecordingActive(true)
        manager.setRecordingActive(false)
        modifiers.tap([.command, .option])
        precondition(toggles == 4, "Registering Escape must preserve modifier bindings")

        modifiers.tap([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        precondition(holds.isEmpty, "A short tap must not start push-to-talk")
        modifiers.flags([.control, .option])
        modifiers.key([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        modifiers.flags([])
        precondition(holds.isEmpty, "Typing a normal key chord must cancel a pending hold")
        modifiers.flags([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        precondition(holds == [true])
        modifiers.flags(.control)
        precondition(holds == [true, false], "Push-to-talk must stop on the first modifier release")
        modifiers.flags([])

        modifiers.flags([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        precondition(holds == [true, false, true])
        manager.setRecordingActive(true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(holds == [true, false, true] && interruptions == 1)
        modifiers.flags([])
        manager.setRecordingActive(false)
        modifiers.tap([.command, .option])
        precondition(toggles == 5, "Sleep must clear modifier state before the next gesture")
        modifiers.flags([.control, .option])
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(240))
        modifiers.flags([])
        precondition(holds == [true, false, true], "Session interruption must cancel a pending hold")

        modifiers.flags([.command, .option])
        precondition(apply())
        modifiers.flags([])
        precondition(toggles == 5, "Saving a shortcut must not trigger it with keys already held")
        modifiers.tap([.command, .option])
        precondition(toggles == 6)
        modifiers.flags([.control, .option])
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        precondition(modifiers.starts == 2 && modifiers.stops == 1)
        try await Task.sleep(for: .milliseconds(240))
        modifiers.flags([])
        precondition(holds == [true, false, true], "Monitor replacement must cancel a pending hold")
        modifiers.tap([.command, .option])
        precondition(toggles == 7, "Monitoring must reconnect after returning from System Settings")
        modifiers.flags([.control, .option])
        try await Task.sleep(for: .milliseconds(240))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        modifiers.flags([])
        precondition(
            Array(holds.suffix(2)) == [true, false], "Replacing a monitor must release active push-to-talk")
        precondition(modifiers.starts == 3 && modifiers.stops == 2)

        let mode = UUID()
        var recordedModes: [UUID] = []
        precondition(
            manager.setBindings(
                toggle: keyChord, pushToTalk: nil, changeMode: controlOption,
                onToggle: {}, onPushToTalk: { _ in }, onChangeMode: { changes += 1 }, onCancel: {},
                modeBindings: [mode: commandOption], onModeRecording: { recordedModes.append($0) }))
        modifiers.tap([.command, .option])
        modifiers.tap([.control, .option])
        precondition(
            recordedModes == [mode] && changes == 2,
            "Modifier shortcuts must support mode recording and mode switching")

        precondition(
            manager.setBindings(
                toggle: keyChord, pushToTalk: nil, changeMode: nil,
                onToggle: {}, onPushToTalk: { _ in }, onChangeMode: {}, onCancel: {}))
        precondition(modifiers.activeCount == 0 && modifiers.stops == 3)
        modifiers.available = false
        precondition(!apply())
        precondition(
            keys.active.values.contains(keyChord), "Monitor startup failure must retain old key chords")
    }
}
