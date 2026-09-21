import AppKit

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
        precondition(pasteboard.changeCount == changeCount)
        precondition(pasteboard.string(forType: .string) == "Existing clipboard")
        print("PASS: Missing permission produces an actionable result without changing the clipboard")

        let allowed = TextDelivery(pasteboard: pasteboard, hasAccessibilityAccess: { true })
        let missingTarget = await allowed.deliver(text: "A completed transcript", to: nil)
        guard case .held = missingTarget else {
            fatalError("An unknown destination must not receive a paste")
        }
        precondition(pasteboard.changeCount == changeCount)
        print("PASS: Permission alone never allows pasting to an unknown destination")

        var granted = false
        let changing = TextDelivery(pasteboard: pasteboard, hasAccessibilityAccess: { granted })
        let before = await changing.deliver(text: "A completed transcript", to: nil)
        precondition(before == .accessibilityRequired)
        granted = true
        let after = await changing.deliver(text: "A completed transcript", to: nil)
        precondition(after != .accessibilityRequired)
        print("PASS: Permission is rechecked for each paste attempt")
    }
}
