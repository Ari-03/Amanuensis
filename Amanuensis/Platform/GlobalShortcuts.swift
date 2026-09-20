import AppKit
import Carbon
import Foundation

/// Registers ordinary global key chords without monitoring general keyboard input.
@MainActor
final class GlobalShortcuts {
    private enum Action: UInt32 {
        case toggle = 1
        case pushToTalk
        case changeMode
        case cancel
    }

    private let signature: OSType = 0x414D_414E
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var registeredBindings: [UInt32: ShortcutBinding] = [:]
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

    init() {
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
    }

    isolated deinit {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

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
    ) {
        if pressed.contains(Action.pushToTalk.rawValue) { self.onPushToTalk(false) }
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        registeredBindings.removeAll()
        modeActions.removeAll()
        pressed.removeAll()
        registrationErrors.removeAll()
        self.onToggle = onToggle
        self.onPushToTalk = onPushToTalk
        self.onChangeMode = onChangeMode
        self.onCancel = onCancel
        self.onInterruption = onInterruption
        self.onModeRecording = onModeRecording
        register(Action.toggle.rawValue, binding: toggle)
        if let pushToTalk {
            register(Action.pushToTalk.rawValue, binding: pushToTalk)
        }
        if let changeMode {
            register(Action.changeMode.rawValue, binding: changeMode)
        }
        // Stable ordering keeps mode identifiers deterministic within this registration.
        for (offset, entry) in modeBindings.sorted(by: { $0.key.uuidString < $1.key.uuidString }).enumerated()
        {
            let identifier = UInt32(offset) + 1000
            register(identifier, binding: entry.value)
            if registrations[identifier] != nil { modeActions[identifier] = entry.key }
        }
        if recordingActive { registerCancel() }
    }

    /// Keep this active through recording, transcription, and cleanup so Escape cancels the session.
    func setRecordingActive(_ active: Bool) {
        guard active != recordingActive else { return }
        recordingActive = active
        if active {
            registerCancel()
        } else if let reference = registrations.removeValue(forKey: Action.cancel.rawValue) {
            UnregisterEventHotKey(reference)
            registeredBindings.removeValue(forKey: Action.cancel.rawValue)
            pressed.remove(Action.cancel.rawValue)
        }
    }

    private func registerCancel() {
        register(
            Action.cancel.rawValue,
            binding: ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "Escape")
        )
    }

    private func interruptRecording() {
        pressed.removeAll()
        if recordingActive { (onInterruption ?? onCancel)() }
    }

    private func register(_ actionID: UInt32, binding: ShortcutBinding) {
        guard handler != nil else {
            registrationErrors.append("Global shortcuts are unavailable.")
            return
        }
        guard actionID == Action.cancel.rawValue || binding.keyCode != kVK_Escape || binding.modifiers != 0
        else {
            registrationErrors.append(
                "Escape is reserved for cancelling the active recording or processing session.")
            return
        }
        guard
            !registeredBindings.values.contains(where: {
                $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers
            })
        else {
            registrationErrors.append(
                "\(binding.display) conflicts with another Amanuensis shortcut. Choose a different combination."
            )
            return
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: actionID)
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            registrations[actionID] = reference
            registeredBindings[actionID] = binding
        } else {
            registrationErrors.append(
                "Could not register \(binding.display). It may already be in use (\(status)).")
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard status == noErr, identifier.signature == signature, registrations[identifier.id] != nil
        else { return OSStatus(eventNotHandledErr) }

        let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        if isDown {
            guard pressed.insert(identifier.id).inserted else { return noErr }
        } else {
            guard pressed.remove(identifier.id) != nil else { return noErr }
        }
        if let modeID = modeActions[identifier.id] {
            if isDown { onModeRecording(modeID) }
            return noErr
        }
        guard let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
        switch action {
        case .toggle: if isDown { onToggle() }
        case .pushToTalk: onPushToTalk(isDown)
        case .changeMode: if isDown { onChangeMode() }
        case .cancel: if isDown, recordingActive { onCancel() }
        }
        return noErr
    }
}
