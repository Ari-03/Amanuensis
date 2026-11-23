import AppKit
import ApplicationServices

@main
struct DeliveryChecks {
    @MainActor static func main() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("amanuensis-delivery-check-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Existing clipboard", forType: .string)
        let changeCount = pasteboard.changeCount

        let denied = TextDelivery(pasteboard: pasteboard, hasAccessibilityAccess: { false })
        let deniedOutcome = denied.deliver(text: "A completed transcript")
        precondition(deniedOutcome == .accessibilityRequired)
        precondition(deniedOutcome.message.contains("Allow Accessibility access"))
        precondition(pasteboard.changeCount > changeCount)
        precondition(
            pasteboard.string(forType: .string) == "A completed transcript",
            "A transcript that cannot be pasted must be available on the clipboard")
        print("PASS: Missing permission copies the transcript and explains how to enable automatic paste")

        // Never reach the real focused app: on a Mac with access granted, that would paste into it.
        let nothingFocused = TextDeliveryEnvironment(
            frontmostApplication: { nil }, post: { _, _ in fatalError("Nothing is focused") })
        let allowed = TextDelivery(
            pasteboard: pasteboard, hasAccessibilityAccess: { true }, environment: nothingFocused)
        let missingTarget = allowed.deliver(text: "A completed transcript")
        precondition(missingTarget == .copied)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        print("PASS: An unknown destination falls back to the clipboard even with permission granted")

        var granted = false
        let changing = TextDelivery(
            pasteboard: pasteboard, hasAccessibilityAccess: { granted }, environment: nothingFocused)
        let before = changing.deliver(text: "A completed transcript")
        precondition(before == .accessibilityRequired)
        granted = true
        let after = changing.deliver(text: "A completed transcript")
        precondition(after != .accessibilityRequired)
        print("PASS: Permission is rechecked for each paste attempt")

        let editor = PasteEditor()
        let delivery = TextDelivery(
            pasteboard: pasteboard, hasAccessibilityAccess: { true }, environment: editor.environment)
        let outcome = delivery.deliver(text: "A completed transcript")
        precondition(
            outcome == .commandPosted(app: "Test editor"),
            "A paste-capable editor must receive the transcript")
        precondition(editor.events.count == 2)
        precondition(editor.events.map(\.type) == [.keyDown, .keyUp])
        precondition(editor.events.allSatisfy { $0.flags == .maskCommand })
        precondition(editor.eventTargets == [7001, 7001])
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        print("PASS: Posting to an editor that never consumes the paste leaves a manual clipboard fallback")

        editor.role = kAXGroupRole
        precondition(delivery.currentDestination() != nil)
        editor.selectedTextIsSettable = false
        precondition(delivery.currentDestination() == nil)
        editor.role = kAXTextAreaRole
        precondition(delivery.currentDestination() == nil)
        editor.valueIsSettable = true
        precondition(delivery.currentDestination() != nil)
        editor.subrole = kAXSecureTextFieldSubrole
        precondition(delivery.currentDestination() == nil)
        editor.subrole = nil
        editor.isEnabled = false
        precondition(delivery.currentDestination() == nil)
        editor.isEnabled = true
        print("PASS: Native and rich text are supported; read-only, secure, and disabled fields are rejected")

        // Recording may start in one field, or nowhere at all. Only the focus at delivery counts.
        editor.events = []
        editor.field = AXUIElementCreateApplication(7004)
        precondition(
            delivery.deliver(text: "A completed transcript") == .commandPosted(app: "Test editor"),
            "Moving to another field must paste there")
        precondition(editor.eventTargets.suffix(2) == [7001, 7001])
        precondition(editor.events.count == 2)
        print("PASS: Changing fields pastes into the field that has focus now")

        editor.appElement = AXUIElementCreateApplication(7010)
        editor.frontmostProcessID = 7010
        editor.name = "Another editor"
        precondition(
            delivery.deliver(text: "A completed transcript") == .commandPosted(app: "Another editor"),
            "Moving to another app must paste there and report that app")
        precondition(editor.eventTargets.suffix(2) == [7010, 7010])
        editor.subrole = kAXSecureTextFieldSubrole
        editor.events = []
        precondition(delivery.deliver(text: "A completed transcript") == .copied)
        editor.subrole = nil
        editor.frontmostProcessID = ProcessInfo.processInfo.processIdentifier
        editor.appElement = AXUIElementCreateApplication(editor.frontmostProcessID)
        precondition(delivery.deliver(text: "A completed transcript") == .copied)
        precondition(editor.events.isEmpty)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        editor.appElement = AXUIElementCreateApplication(7001)
        editor.frontmostProcessID = 7001
        editor.name = "Test editor"
        print("PASS: Changing apps pastes there, unless focus is in a secure field or Amanuensis")

        precondition(delivery.deliver(text: "First") == .commandPosted(app: "Test editor"))
        precondition(delivery.deliver(text: "Second") == .commandPosted(app: "Test editor"))
        precondition(editor.events.count == 4)
        editor.events = []
        print("PASS: A second dictation can paste right after the first")

        var editableChecks = 0
        editor.onEditableCheck = {
            editableChecks += 1
            if editableChecks == 1 {
                editor.frontmostProcessID = 7006
            }
        }
        let changedDuringCheck = delivery.deliver(text: "A completed transcript")
        guard case .copied = changedDuringCheck else {
            fatalError(
                "An app that loses foreground focus during the final AX check must not receive a paste")
        }
        precondition(editor.events.isEmpty)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        editor.frontmostProcessID = 7001
        editor.onEditableCheck = {}
        print("PASS: App switches during the final Accessibility query abort with a clipboard fallback")

        editor.onEditableCheck = {
            pasteboard.clearContents()
            pasteboard.setString("A newer copy", forType: .string)
        }
        let replacedClipboard = delivery.deliver(text: "A completed transcript")
        guard case .held = replacedClipboard else { fatalError("Never paste a newer clipboard item") }
        precondition(editor.events.isEmpty)
        precondition(pasteboard.string(forType: .string) == "A newer copy")
        editor.onEditableCheck = {}
        print("PASS: A copy during destination verification is preserved and is not pasted automatically")

        var observedTranscript = false
        editor.onPost = { event in
            if event.type == .keyDown {
                observedTranscript = pasteboard.string(forType: .string) == "A completed transcript"
                pasteboard.clearContents()
                pasteboard.setString("Copied during paste", forType: .string)
            }
        }
        let afterCopy = delivery.deliver(text: "A completed transcript")
        precondition(afterCopy == .commandPosted(app: "Test editor"))
        precondition(observedTranscript)
        precondition(pasteboard.string(forType: .string) == "Copied during paste")
        print("PASS: The transcript is available when posted, and a later user copy is preserved")

        editor.onPost = { _ in }
        let richData = Data("{\\rtf1 Original clipboard}".utf8)
        let originalItem = NSPasteboardItem()
        originalItem.setString("Original clipboard", forType: .string)
        originalItem.setData(richData, forType: .rtf)
        pasteboard.clearContents()
        pasteboard.writeObjects([originalItem])
        let richOutcome = delivery.deliver(text: "A completed transcript")
        precondition(richOutcome == .commandPosted(app: "Test editor"))
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        precondition(pasteboard.data(forType: .rtf) == nil)
        print("PASS: The fallback replaces older clipboard formats with the completed transcript")

        let beforeEmpty = pasteboard.changeCount
        _ = delivery.deliver(text: "")
        precondition(pasteboard.changeCount == beforeEmpty)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return delivery.deliver(text: "Cancelled transcript")
        }
        _ = await cancelled.value
        precondition(pasteboard.changeCount == beforeEmpty)
        print("PASS: Empty and cancelled deliveries do not replace the clipboard")
    }
}

@MainActor
private final class PasteEditor {
    var appElement = AXUIElementCreateApplication(7001)
    var name = "Test editor"
    var frontmostProcessID: pid_t = 7001
    var field = AXUIElementCreateApplication(7002)
    var role = kAXTextAreaRole
    var subrole: String?
    var isEnabled = true
    var valueIsSettable = false
    var selectedTextIsSettable = true
    var events: [CGEvent] = []
    var eventTargets: [pid_t] = []
    var onPost: (CGEvent) -> Void = { _ in }
    var onEditableCheck: () -> Void = {}

    var environment: TextDeliveryEnvironment {
        TextDeliveryEnvironment(
            frontmostApplication: { [self] in (frontmostProcessID, name) },
            attribute: { [self] element, name in
                if CFEqual(element, appElement) {
                    if name == kAXFocusedUIElementAttribute { return field }
                }
                if CFEqual(element, field) {
                    if name == kAXRoleAttribute { return role as CFString }
                    if name == kAXSubroleAttribute { return subrole.map { $0 as CFString } }
                    if name == kAXEnabledAttribute { return isEnabled ? kCFBooleanTrue : kCFBooleanFalse }
                }
                return nil
            },
            isAttributeSettable: { [self] _, name in
                onEditableCheck()
                if name == kAXSelectedTextAttribute { return selectedTextIsSettable }
                return name == kAXValueAttribute && valueIsSettable
            },
            post: { [self] event, processID in
                events.append(event)
                eventTargets.append(processID)
                onPost(event)
            })
    }
}
