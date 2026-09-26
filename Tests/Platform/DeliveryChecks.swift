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
        let deniedOutcome = await denied.deliver(text: "A completed transcript", to: nil)
        precondition(deniedOutcome == .accessibilityRequired)
        precondition(deniedOutcome.message.contains("Allow Accessibility access"))
        precondition(pasteboard.changeCount > changeCount)
        precondition(
            pasteboard.string(forType: .string) == "A completed transcript",
            "A transcript that cannot be pasted must be available on the clipboard")
        print("PASS: Missing permission copies the transcript and explains how to enable automatic paste")

        let allowed = TextDelivery(pasteboard: pasteboard, hasAccessibilityAccess: { true })
        let missingTarget = await allowed.deliver(text: "A completed transcript", to: nil)
        precondition(missingTarget == .copied)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        print("PASS: An unknown destination falls back to the clipboard even with permission granted")

        var granted = false
        let changing = TextDelivery(pasteboard: pasteboard, hasAccessibilityAccess: { granted })
        let before = await changing.deliver(text: "A completed transcript", to: nil)
        precondition(before == .accessibilityRequired)
        granted = true
        let after = await changing.deliver(text: "A completed transcript", to: nil)
        precondition(after != .accessibilityRequired)
        print("PASS: Permission is rechecked for each paste attempt")

        let editor = PasteEditor()
        let delivery = TextDelivery(
            pasteboard: pasteboard, hasAccessibilityAccess: { true }, environment: editor.environment)
        let target = delivery.captureDestination()
        let outcome = await delivery.deliver(text: "A completed transcript", to: target)
        precondition(outcome == .commandPosted, "A paste-capable editor must receive the transcript")
        precondition(editor.events.count == 2)
        precondition(editor.events.map(\.type) == [.keyDown, .keyUp])
        precondition(editor.events.allSatisfy { $0.flags == .maskCommand })
        precondition(editor.eventTargets == [7001, 7001])
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        print("PASS: Posting to an editor that never consumes the paste leaves a manual clipboard fallback")

        editor.role = kAXGroupRole
        precondition(delivery.captureDestination() != nil)
        editor.selectedTextIsSettable = false
        precondition(delivery.captureDestination() == nil)
        editor.role = kAXTextAreaRole
        precondition(delivery.captureDestination() == nil)
        editor.valueIsSettable = true
        precondition(delivery.captureDestination() != nil)
        editor.subrole = kAXSecureTextFieldSubrole
        precondition(delivery.captureDestination() == nil)
        editor.subrole = nil
        editor.isEnabled = false
        precondition(delivery.captureDestination() == nil)
        editor.isEnabled = true
        print("PASS: Native and rich text are supported; read-only, secure, and disabled fields are rejected")

        editor.events = []
        editor.field = AXUIElementCreateApplication(7004)
        let changedField = await delivery.deliver(text: "A completed transcript", to: target)
        precondition(changedField == .copied)
        precondition(editor.events.isEmpty)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        print("PASS: Changing fields prevents the paste and copies the transcript")

        let currentTarget = delivery.captureDestination()
        editor.window = AXUIElementCreateApplication(7005)
        let changedWindow = await delivery.deliver(text: "A completed transcript", to: currentTarget)
        precondition(changedWindow == .copied)
        precondition(editor.events.isEmpty)
        print("PASS: Changing windows prevents the paste")

        let foregroundTarget = delivery.captureDestination()
        var editableChecks = 0
        editor.onEditableCheck = {
            editableChecks += 1
            if editableChecks == 2 {
                editor.frontmostProcessID = 7006
            }
        }
        let changedDuringCheck = await delivery.deliver(
            text: "A completed transcript", to: foregroundTarget)
        guard case .copied = changedDuringCheck else {
            fatalError(
                "An app that loses foreground focus during the final AX check must not receive a paste")
        }
        precondition(editor.events.isEmpty)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        editor.frontmostProcessID = 7001
        editor.onEditableCheck = {}
        print("PASS: App switches during the final Accessibility query abort with a clipboard fallback")

        let clipboardTarget = delivery.captureDestination()
        editor.onEditableCheck = {
            pasteboard.clearContents()
            pasteboard.setString("A newer copy", forType: .string)
        }
        let replacedClipboard = await delivery.deliver(text: "A completed transcript", to: clipboardTarget)
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
        let afterCopy = await delivery.deliver(
            text: "A completed transcript", to: delivery.captureDestination())
        precondition(afterCopy == .commandPosted)
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
        let richOutcome = await delivery.deliver(
            text: "A completed transcript", to: delivery.captureDestination())
        precondition(richOutcome == .commandPosted)
        precondition(pasteboard.string(forType: .string) == "A completed transcript")
        precondition(pasteboard.data(forType: .rtf) == nil)
        print("PASS: The fallback replaces older clipboard formats with the completed transcript")

        let beforeEmpty = pasteboard.changeCount
        _ = await delivery.deliver(text: "", to: nil)
        precondition(pasteboard.changeCount == beforeEmpty)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await delivery.deliver(text: "Cancelled transcript", to: nil)
        }
        _ = await cancelled.value
        precondition(pasteboard.changeCount == beforeEmpty)
        print("PASS: Empty and cancelled deliveries do not replace the clipboard")
    }
}

@MainActor
private final class PasteEditor {
    let app = AXUIElementCreateApplication(7001)
    var frontmostProcessID: pid_t = 7001
    var field = AXUIElementCreateApplication(7002)
    var window = AXUIElementCreateApplication(7003)
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
            frontmostApplication: { [self] in (frontmostProcessID, "Test editor") },
            attribute: { [self] element, name in
                if CFEqual(element, app) {
                    if name == kAXFocusedUIElementAttribute { return field }
                    if name == kAXFocusedWindowAttribute { return window }
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
