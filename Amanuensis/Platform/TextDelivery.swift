import AppKit
@preconcurrency import ApplicationServices

/// The app whose focused field can receive a paste right now.
struct InsertionTarget {
    fileprivate let processID: pid_t
    let applicationName: String
}

/// The system boundary keeps destination checks testable without posting real keystrokes.
@MainActor
struct TextDeliveryEnvironment {
    var frontmostApplication: () -> (processID: pid_t, name: String)? = {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return (application.processIdentifier, application.localizedName ?? "Destination app")
    }
    var attribute: (AXUIElement, String) -> CFTypeRef? = { element, name in
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
    var isAttributeSettable: (AXUIElement, String) -> Bool = { element, name in
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }
    var post: (CGEvent, pid_t) -> Void = { event, processID in event.postToPid(processID) }
}

enum DeliveryOutcome: Equatable {
    case commandPosted(app: String)
    case copied
    case accessibilityRequired
    case held(String)

    var message: String {
        switch self {
        case .commandPosted:
            "Paste command sent. Your transcript is also on the clipboard if you need to paste it manually."
        case .copied:
            "Copied to the clipboard."
        case .accessibilityRequired:
            "Copied to the clipboard. Allow Accessibility access for this copy of Amanuensis to paste automatically."
        case .held(let reason):
            reason
        }
    }
}

/// Pastes into whatever editable field has focus when the text is ready, and never moves focus.
@MainActor
final class TextDelivery {
    private let pasteboard: NSPasteboard
    private let hasAccessibilityAccess: () -> Bool
    private let environment: TextDeliveryEnvironment

    init(
        pasteboard: NSPasteboard = .general,
        hasAccessibilityAccess: @escaping () -> Bool = { TextDelivery.isAccessibilityTrusted },
        environment: TextDeliveryEnvironment = TextDeliveryEnvironment()
    ) {
        self.pasteboard = pasteboard
        self.hasAccessibilityAccess = hasAccessibilityAccess
        self.environment = environment
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// The focused editable field's app. Nil for Amanuensis itself, and for secure or read-only fields.
    func currentDestination() -> InsertionTarget? {
        guard hasAccessibilityAccess(),
            let application = environment.frontmostApplication(),
            application.processID != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processID)
        guard let field = element(appElement, attribute: kAXFocusedUIElementAttribute),
            isEditable(field),
            // Accessibility queries cross process boundaries; the app can lose foreground
            // focus while still returning its previously focused field.
            environment.frontmostApplication()?.processID == application.processID
        else { return nil }

        return InsertionTarget(processID: application.processID, applicationName: application.name)
    }

    func deliver(text: String) -> DeliveryOutcome {
        guard !Task.isCancelled else {
            return .held("Insertion was cancelled. Your transcript remains in History.")
        }
        guard !text.isEmpty else { return .held("There is no text to insert.") }
        // Keep a manual fallback even when AX cannot describe the editor or it ignores Command-V.
        // A posted event is not proof of insertion, so never restore the previous clipboard.
        guard copy(text: text) else {
            return .held("Could not copy to the clipboard. Your transcript remains in History.")
        }
        let ownedChangeCount = pasteboard.changeCount
        guard hasAccessibilityAccess() else {
            return .accessibilityRequired
        }
        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .copied }

        down.flags = .maskCommand
        up.flags = .maskCommand
        // Keep the check and posting synchronous. PID routing prevents a late app switch
        // from redirecting the transcript, but macOS does not make check-and-post atomic.
        guard let target = currentDestination() else { return .copied }
        guard pasteboard.changeCount == ownedChangeCount else {
            return .held("The clipboard changed before pasting. Copy your transcript from History.")
        }
        environment.post(down, target.processID)
        environment.post(up, target.processID)
        return .commandPosted(app: target.applicationName)
    }

    @discardableResult
    func copy(text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        environment.attribute(element, name)
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
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        if let enabled = attribute(field, kAXEnabledAttribute) as? Bool, !enabled { return false }
        // Rich text editors can allow selected-text replacement while denying replacement
        // of the entire AXValue. Pasting only needs the former capability.
        if environment.isAttributeSettable(field, kAXSelectedTextAttribute) { return true }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(where: { $0 == role })
            && environment.isAttributeSettable(field, kAXValueAttribute)
    }
}
