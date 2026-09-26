import Testing

@testable import AmanuensisCore

struct CancellationConfirmationTests {
    @Test func firstPressPromptsAndSecondPressConfirms() {
        var confirmation = CancellationConfirmation()
        let first = confirmation.request(at: 100)
        #expect(!first)
        #expect(confirmation.isPending)
        let second = confirmation.request(at: 101)
        #expect(second)
        #expect(!confirmation.isPending)
    }

    @Test func expiredConfirmationRequiresAnotherPressEvenBeforeTimerRuns() {
        var confirmation = CancellationConfirmation()
        let first = confirmation.request(at: 100)
        #expect(!first)
        let expired = confirmation.request(at: 100 + CancellationConfirmation.timeout)
        #expect(!expired)
        #expect(confirmation.isPending)
        let confirmed = confirmation.request(at: 101 + CancellationConfirmation.timeout)
        #expect(confirmed)
    }

    @Test func dismissalClearsConfirmation() {
        var confirmation = CancellationConfirmation()
        let first = confirmation.request(at: 100)
        #expect(!first)
        confirmation.dismiss()
        #expect(!confirmation.isPending)
        let afterDismissal = confirmation.request(at: 101)
        #expect(!afterDismissal)
    }
}
