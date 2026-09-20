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

    struct Backend {
        var register: (UInt32, ShortcutBinding) -> (OSStatus, EventHotKeyRef?)
        var unregister: (EventHotKeyRef) -> Void

        static var carbon: Backend {
            Backend(
                register: { identifier, binding in
                    var reference: EventHotKeyRef?
                    let status = RegisterEventHotKey(
                        binding.keyCode, binding.modifiers,
                        EventHotKeyID(signature: GlobalShortcuts.signature, id: identifier),
                        GetApplicationEventTarget(), 0, &reference)
                    return (status, reference)
                },
                unregister: { UnregisterEventHotKey($0) }
            )
        }
    }

    nonisolated private static let signature: OSType = 0x414D_414E
    private let backend: Backend
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

    init(backend: Backend = .carbon) {
        self.backend = backend
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
        for registration in registrations.values { backend.unregister(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
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
        var desired = registrations.mapValues(\.binding)
        desired[Action.cancel.rawValue] = active ? Self.cancelBinding : nil
        if applyBindings(desired), !active { pressed.remove(Action.cancel.rawValue) }
    }

    private static var cancelBinding: ShortcutBinding {
        ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "Escape")
    }

    private func interruptRecording() {
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
            guard action == Action.cancel.rawValue || binding.keyCode != kVK_Escape || binding.modifiers != 0
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
        for (action, binding) in desired.sorted(by: { $0.key < $1.key }) {
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
        let retained = Set(staged.values.map(\.eventID))
        for registration in registrations.values where !retained.contains(registration.eventID) {
            backend.unregister(registration.reference)
        }
        registrations = staged
        return true
    }

    private static func sameChord(_ lhs: ShortcutBinding, _ rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
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
            guard pressed.insert(actionID).inserted else { return noErr }
        } else {
            guard pressed.remove(actionID) != nil else { return noErr }
        }
        if let modeID = modeActions[actionID] {
            if isDown { onModeRecording(modeID) }
            return noErr
        }
        guard let action = Action(rawValue: actionID) else { return OSStatus(eventNotHandledErr) }
        switch action {
        case .toggle: if isDown { onToggle() }
        case .pushToTalk: onPushToTalk(isDown)
        case .changeMode: if isDown { onChangeMode() }
        case .cancel: if isDown, recordingActive { onCancel() }
        }
        return noErr
    }
}
