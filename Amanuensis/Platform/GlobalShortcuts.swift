import AppKit
import Carbon
import Foundation

/// Converts AppKit flags to the Carbon modifier values persisted in shortcut settings.
enum ShortcutModifiers {
    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    static func label(_ modifiers: UInt32) -> String {
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
        return label
    }

    static func isValidCombination(_ modifiers: UInt32) -> Bool {
        let supported = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return modifiers & ~supported == 0 && modifiers.nonzeroBitCount >= 2
    }
}

/// Remembers the complete combination until all modifiers are released. A key press or
/// adding modifiers after release begins cancels the gesture, so normal shortcuts still work.
struct ModifierShortcutGesture {
    private(set) var modifiers: UInt32 = 0
    private(set) var candidate: UInt32 = 0
    private(set) var isReleasing = false
    private(set) var interrupted = false

    mutating func update(_ flags: UInt32) -> UInt32? {
        let previous = modifiers
        modifiers = flags
        if previous & ~flags != 0 { isReleasing = true }
        if flags & ~previous != 0 {
            if isReleasing { interrupted = true } else { candidate = flags }
        }
        guard flags == 0 else { return nil }
        let result = !interrupted && ShortcutModifiers.isValidCombination(candidate) ? candidate : nil
        self = ModifierShortcutGesture()
        return result
    }

    mutating func interrupt() {
        if modifiers != 0 { interrupted = true }
    }
}

/// Uses Carbon for ordinary key chords and observes modifier gestures only when configured.
@MainActor
final class GlobalShortcuts {
    private enum Action: UInt32 {
        case toggle = 1
        case pushToTalk
        case changeMode
        case cancel
    }

    struct Backend {
        var register: (UInt32, ShortcutBinding) -> (OSStatus, EventHotKeyRef?)
        var unregister: (EventHotKeyRef) -> Void

        static var carbon: Backend {
            Backend(
                register: { identifier, binding in
                    guard let keyCode = binding.keyCode else { return (OSStatus(paramErr), nil) }
                    var reference: EventHotKeyRef?
                    let status = RegisterEventHotKey(
                        keyCode, binding.modifiers,
                        EventHotKeyID(signature: GlobalShortcuts.signature, id: identifier),
                        GetApplicationEventTarget(), 0, &reference)
                    return (status, reference)
                },
                unregister: { UnregisterEventHotKey($0) }
            )
        }
    }

    struct ModifierMonitor {
        var start: (@escaping (NSEvent) -> Void) -> (() -> Void)?

        static var appKit: ModifierMonitor {
            ModifierMonitor { handler in
                let events: NSEvent.EventTypeMask = [
                    .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                ]
                guard let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler)
                else { return nil }
                guard
                    let local = NSEvent.addLocalMonitorForEvents(
                        matching: events,
                        handler: { event in
                            handler(event)
                            return event
                        })
                else {
                    NSEvent.removeMonitor(global)
                    return nil
                }
                return {
                    NSEvent.removeMonitor(global)
                    NSEvent.removeMonitor(local)
                }
            }
        }
    }

    nonisolated private static let signature: OSType = 0x414D_414E
    private let backend: Backend
    private let modifierMonitor: ModifierMonitor
    private var stopModifierMonitor: (() -> Void)?
    private var modifierBindings: [UInt32: ShortcutBinding] = [:]
    private var modifierGesture = ModifierShortcutGesture()
    private var modifierHoldTask: Task<Void, Never>?
    private var modifierHoldStarted = false
    private var handler: EventHandlerRef?
    private struct Registration {
        let reference: EventHotKeyRef
        let eventID: UInt32
        let binding: ShortcutBinding
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextEventID: UInt32 = 0
    private var modeActions: [UInt32: UUID] = [:]
    private var pressed: Set<UInt32> = []
    private var onToggle: () -> Void = {}
    private var onPushToTalk: (Bool) -> Void = { _ in }
    private var onChangeMode: () -> Void = {}
    private var onCancel: () -> Void = {}
    private var onInterruption: (() -> Void)?
    private var onModeRecording: (UUID) -> Void = { _ in }
    private(set) var registrationErrors: [String] = []
    private var recordingActive = false
    private var sessionObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?

    init(backend: Backend = .carbon, modifierMonitor: ModifierMonitor = .appKit) {
        self.backend = backend
        self.modifierMonitor = modifierMonitor
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let manager = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                    return manager.handle(event)
                }
            },
            eventTypes.count, &eventTypes, context, &handler
        )
        if status != noErr { registrationErrors = ["Global shortcuts could not start (\(status))."] }
        for notification in [
            NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
        ] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptRecording() }
            }
            sessionObservers.append(observer)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Recreate monitors when returning from System Settings after an Accessibility grant.
                guard let self, !self.modifierBindings.isEmpty else { return }
                self.stopModifierHold()
                self.resetModifierGesture()
                // Keep the working monitor if AppKit cannot install its replacement.
                guard let replacement = self.startModifierMonitor() else { return }
                self.stopModifierMonitor?()
                self.stopModifierMonitor = replacement
            }
        }
    }

    isolated deinit {
        modifierHoldTask?.cancel()
        stopModifierMonitor?()
        for registration in registrations.values { backend.unregister(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    @discardableResult
    func setBindings(
        toggle: ShortcutBinding,
        pushToTalk: ShortcutBinding?,
        changeMode: ShortcutBinding?,
        onToggle: @escaping () -> Void,
        onPushToTalk: @escaping (Bool) -> Void,
        onChangeMode: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        modeBindings: [UUID: ShortcutBinding] = [:],
        onModeRecording: @escaping (UUID) -> Void = { _ in },
        onInterruption: (() -> Void)? = nil
    ) -> Bool {
        var desired = [Action.toggle.rawValue: toggle]
        desired[Action.pushToTalk.rawValue] = pushToTalk
        desired[Action.changeMode.rawValue] = changeMode
        var desiredModes: [UInt32: UUID] = [:]
        for (offset, entry) in modeBindings.sorted(by: { $0.key.uuidString < $1.key.uuidString }).enumerated()
        {
            let identifier = UInt32(offset) + 1000
            desired[identifier] = entry.value
            desiredModes[identifier] = entry.key
        }
        if recordingActive { desired[Action.cancel.rawValue] = Self.cancelBinding }
        guard applyBindings(desired) else { return false }
        resetModifierGesture()
        if pressed.contains(Action.pushToTalk.rawValue) { self.onPushToTalk(false) }
        pressed.removeAll()
        modeActions = desiredModes
        self.onToggle = onToggle
        self.onPushToTalk = onPushToTalk
        self.onChangeMode = onChangeMode
        self.onCancel = onCancel
        self.onInterruption = onInterruption
        self.onModeRecording = onModeRecording
        return true
    }

    /// Keep this active through recording, transcription, and cleanup so Escape cancels the session.
    func setRecordingActive(_ active: Bool) {
        guard active != recordingActive else { return }
        recordingActive = active
        var desired = registrations.mapValues(\.binding).merging(modifierBindings) { first, _ in first }
        desired[Action.cancel.rawValue] = active ? Self.cancelBinding : nil
        if applyBindings(desired), !active { pressed.remove(Action.cancel.rawValue) }
    }

    private static var cancelBinding: ShortcutBinding {
        ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "Escape")
    }

    private func interruptRecording() {
        resetModifierGesture()
        // The session callback preserves unfinished audio. A normal release would start
        // transcription before that asynchronous recovery gets a chance to run.
        if !recordingActive, pressed.contains(Action.pushToTalk.rawValue) { onPushToTalk(false) }
        pressed.removeAll()
        if recordingActive { (onInterruption ?? onCancel)() }
    }

    /// Stage new chords while retaining the working set. Failed edits never release old shortcuts.
    private func applyBindings(_ desired: [UInt32: ShortcutBinding]) -> Bool {
        registrationErrors.removeAll()
        guard handler != nil else {
            registrationErrors = ["Global shortcuts are unavailable."]
            return false
        }
        var seen: [ShortcutBinding] = []
        for (action, binding) in desired.sorted(by: { $0.key < $1.key }) {
            guard !binding.isModifierOnly || ShortcutModifiers.isValidCombination(binding.modifiers) else {
                registrationErrors = ["Use at least two modifier keys for a modifier-only shortcut."]
                return false
            }
            guard
                action == Action.cancel.rawValue || binding.keyCode != UInt32(kVK_Escape)
                    || binding.modifiers != 0
            else {
                registrationErrors = [
                    "Escape is reserved for cancelling the active recording or processing session."
                ]
                return false
            }
            guard !seen.contains(where: { Self.sameChord($0, binding) }) else {
                registrationErrors = [
                    "\(binding.display) conflicts with another Amanuensis shortcut. Choose a different combination."
                ]
                return false
            }
            seen.append(binding)
        }
        var staged: [UInt32: Registration] = [:]
        var added: [EventHotKeyRef] = []
        for (action, binding) in desired.sorted(by: { $0.key < $1.key }) where !binding.isModifierOnly {
            if let existing = registrations.values.first(where: { Self.sameChord($0.binding, binding) }) {
                // Native event IDs stay attached to their chords, even when mode ordering changes.
                staged[action] = Registration(
                    reference: existing.reference, eventID: existing.eventID, binding: binding)
                continue
            }
            nextEventID += 1
            let (status, reference) = backend.register(nextEventID, binding)
            guard status == noErr, let reference else {
                for reference in added { backend.unregister(reference) }
                registrationErrors = [
                    "Could not register \(binding.display). It may already be in use (\(status))."
                ]
                return false
            }
            staged[action] = Registration(reference: reference, eventID: nextEventID, binding: binding)
            added.append(reference)
        }
        let desiredModifiers = desired.filter { $0.value.isModifierOnly }
        if !desiredModifiers.isEmpty, stopModifierMonitor == nil {
            guard let stop = startModifierMonitor() else {
                for reference in added { backend.unregister(reference) }
                registrationErrors = [
                    "Modifier shortcuts could not start. Check Accessibility access in Settings."
                ]
                return false
            }
            stopModifierMonitor = stop
        }
        let retained = Set(staged.values.map(\.eventID))
        for registration in registrations.values where !retained.contains(registration.eventID) {
            backend.unregister(registration.reference)
        }
        registrations = staged
        modifierBindings = desiredModifiers
        if desiredModifiers.isEmpty {
            stopModifierMonitor?()
            stopModifierMonitor = nil
        }
        return true
    }

    private static func sameChord(_ lhs: ShortcutBinding, _ rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    private func startModifierMonitor() -> (() -> Void)? {
        modifierMonitor.start { [weak self] event in
            MainActor.assumeIsolated { self?.handleModifierEvent(event) }
        }
    }

    private func resetModifierGesture() {
        let heldModifiers = modifierGesture.modifiers | ShortcutModifiers.carbonFlags(NSEvent.modifierFlags)
        modifierHoldTask?.cancel()
        modifierHoldTask = nil
        modifierHoldStarted = false
        modifierGesture = ModifierShortcutGesture()
        // A binding change or interruption must wait for a fresh, complete gesture.
        if heldModifiers != 0 {
            _ = modifierGesture.update(heldModifiers)
            modifierGesture.interrupt()
        }
    }

    private func stopModifierHold() {
        modifierHoldTask?.cancel()
        modifierHoldTask = nil
        if modifierHoldStarted, pressed.remove(Action.pushToTalk.rawValue) != nil {
            onPushToTalk(false)
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            _ = modifierGesture.update(ShortcutModifiers.carbonFlags(event.modifierFlags))
            modifierGesture.interrupt()
            stopModifierHold()
            return
        }
        let modifiers = ShortcutModifiers.carbonFlags(event.modifierFlags)
        let completed = modifierGesture.update(modifiers)
        if modifierBindings[Action.pushToTalk.rawValue]?.modifiers != modifiers {
            stopModifierHold()
        }
        if let completed, !modifierHoldStarted,
            let action = modifierBindings.first(where: { $0.value.modifiers == completed })?.key
        {
            if action != Action.pushToTalk.rawValue { invoke(action, isDown: true) }
        }
        if modifiers == 0 {
            modifierHoldStarted = false
        } else if !modifierGesture.interrupted, !modifierGesture.isReleasing, !modifierHoldStarted,
            modifierHoldTask == nil,
            modifierBindings[Action.pushToTalk.rawValue]?.modifiers == modifiers
        {
            // Give normal key chords time to arrive before starting a modifier-only hold.
            modifierHoldTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self, !modifierGesture.interrupted, !modifierGesture.isReleasing,
                    modifierGesture.modifiers == modifiers
                else { return }
                modifierHoldTask = nil
                modifierHoldStarted = true
                pressed.insert(Action.pushToTalk.rawValue)
                invoke(Action.pushToTalk.rawValue, isDown: true)
            }
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard status == noErr, identifier.signature == Self.signature,
            let actionID = registrations.first(where: { $0.value.eventID == identifier.id })?.key
        else { return OSStatus(eventNotHandledErr) }

        let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        if isDown {
            // Carbon consumes registered chords before an AppKit monitor necessarily sees them.
            modifierGesture.interrupt()
            stopModifierHold()
            guard pressed.insert(actionID).inserted else { return noErr }
        } else {
            guard pressed.remove(actionID) != nil else { return noErr }
        }
        invoke(actionID, isDown: isDown)
        return noErr
    }

    private func invoke(_ actionID: UInt32, isDown: Bool) {
        if let modeID = modeActions[actionID] {
            if isDown { onModeRecording(modeID) }
            return
        }
        guard let action = Action(rawValue: actionID) else { return }
        switch action {
        case .toggle: if isDown { onToggle() }
        case .pushToTalk: onPushToTalk(isDown)
        case .changeMode: if isDown { onChangeMode() }
        case .cancel: if isDown, recordingActive { onCancel() }
        }
    }
}
