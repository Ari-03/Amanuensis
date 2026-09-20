import AppKit
@preconcurrency import ApplicationServices

/// The editable destination that was focused when recording began.
struct InsertionTarget {
    fileprivate let processID: pid_t
    fileprivate let field: AXUIElement
    fileprivate let window: AXUIElement
    let applicationName: String
}

enum DeliveryOutcome: Equatable {
    case commandPosted
    case copied
    case held(String)

    var message: String {
        switch self {
        case .commandPosted:
            "Paste command sent. Your transcript remains in History."
        case .copied:
            "Copied to the clipboard."
        case .held(let reason):
            reason
        }
    }
}

/// Serializes clipboard insertion and never changes the destination's focus.
@MainActor
final class TextDelivery {
    private let pasteboard: NSPasteboard
    private let sessionType = NSPasteboard.PasteboardType("dev.amanuensis.paste-session")
    private var isDelivering = false
    private var pendingClipboard: PendingClipboard?

    private struct PendingClipboard {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
        let session: String
    }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func captureDestination() -> InsertionTarget? {
        guard Self.isAccessibilityTrusted,
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let field = element(appElement, attribute: kAXFocusedUIElementAttribute),
            let window = element(appElement, attribute: kAXFocusedWindowAttribute),
            isEditable(field)
        else { return nil }

        return InsertionTarget(
            processID: application.processIdentifier,
            field: field,
            window: window,
            applicationName: application.localizedName ?? "Destination app"
        )
    }

    func deliver(text: String, to target: InsertionTarget?) async -> DeliveryOutcome {
        guard !Task.isCancelled else {
            return .held("Insertion was cancelled. Your transcript remains in History.")
        }
        guard !text.isEmpty else { return .held("There is no text to insert.") }
        guard !isDelivering else {
            return .held("Another paste is finishing. Copy this transcript from History.")
        }
        guard Self.isAccessibilityTrusted else {
            return .held("Allow Accessibility access to paste automatically, or copy your transcript.")
        }
        guard let target, matchesCurrentDestination(target) else {
            return .held(
                "The destination changed or could not be verified. Your transcript is ready to copy.")
        }

        isDelivering = true
        defer {
            restorePendingClipboard()
            isDelivering = false
        }

        // Abort if any representation cannot be preserved, including deferred data.
        let originalChangeCount = pasteboard.changeCount
        guard let snapshot = clipboardSnapshot(),
            pasteboard.changeCount == originalChangeCount,
            matchesCurrentDestination(target)
        else {
            return .held("The destination or clipboard changed. Your transcript is ready to copy.")
        }

        let session = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(session, forType: sessionType)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .held("Could not create the paste command. Copy your transcript instead.") }

        let clearedChangeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            let failureChangeCount = pasteboard.changeCount
            if failureChangeCount == clearedChangeCount {
                restore(snapshot)
            } else {
                // A partial write may already carry our marker. Never overwrite a later copy.
                restoreIfOwned(snapshot, changeCount: failureChangeCount, session: session)
            }
            return .held("Could not prepare the clipboard. Your transcript remains in History.")
        }
        let ownedChangeCount = pasteboard.changeCount
        pendingClipboard = PendingClipboard(
            snapshot: snapshot, changeCount: ownedChangeCount, session: session)

        // No suspension between the final focus check and the keyboard events.
        guard matchesCurrentDestination(target) else {
            return .held("The destination changed. Your transcript is ready to copy.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // macOS provides no paste-consumed acknowledgment. Retain History as recovery.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) {
                continuation.resume()
            }
        }
        return .commandPosted
    }

    /// Call during normal shutdown, before the pending asynchronous paste delay can finish.
    func restorePendingClipboard() {
        guard let pending = pendingClipboard else { return }
        pendingClipboard = nil
        restoreIfOwned(pending.snapshot, changeCount: pending.changeCount, session: pending.session)
    }

    @discardableResult
    func copy(text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func matchesCurrentDestination(_ target: InsertionTarget) -> Bool {
        guard let current = captureDestination(), current.processID == target.processID else { return false }
        return CFEqual(current.field, target.field) && CFEqual(current.window, target.window)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ parent: AXUIElement, attribute name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func isEditable(_ field: AXUIElement) -> Bool {
        let role = attribute(field, kAXRoleAttribute) as? String
        let subrole = attribute(field, kAXSubroleAttribute) as? String
        guard subrole != kAXSecureTextFieldSubrole,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(where: { $0 == role })
        else { return false }
        if let enabled = attribute(field, kAXEnabledAttribute) as? Bool, !enabled { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private func clipboardSnapshot() -> ClipboardSnapshot? {
        var snapshot: ClipboardSnapshot = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append((type, data))
            }
            snapshot.append(representations)
        }
        return snapshot
    }

    private func restoreIfOwned(_ snapshot: ClipboardSnapshot, changeCount: Int, session: String) {
        guard pasteboard.changeCount == changeCount,
            pasteboard.string(forType: sessionType) == session
        else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: ClipboardSnapshot) {
        let items = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
