import Foundation

@main
struct PlankSessionStartupDeadlineTests {
    static func main() {
        let start = ContinuousClock.now

        // A lingering previous session gets a short wait, not an indefinite
        // takeover or a fresh 12-second budget after every busy reply.
        let releasing = PlankSessionStartupDeadline(now: start, waitingForRelease: true)
        assert(releasing.canRetry(at: start.advanced(by: .seconds(11))))
        assert(!releasing.canRetry(at: start.advanced(by: .seconds(12))))

        // Display transitions can use the original attempt's larger budget.
        var transition = PlankSessionStartupDeadline(now: start, waitingForRelease: true)
        transition.displayTransition()
        assert(transition.canRetry(at: start.advanced(by: .seconds(44))))
        assert(!transition.canRetry(at: start.advanced(by: .seconds(45))))

        // Repeated 425 progress replies, even near expiry, must not move the
        // deadline. This reproduces the previous unbounded extension defect.
        for second in 1...90 {
            transition.displayTransition()
            assert(transition.canRetry(at: start.advanced(by: .seconds(second))) == (second < 45))
        }

        let display = PlankSessionStartupDeadline(now: start, waitingForRelease: false)
        assert(display.canRetry(at: start.advanced(by: .seconds(44))))
        assert(!display.canRetry(at: start.advanced(by: .seconds(45))))

        // A separate user-initiated retry gets its own budget.
        let retryStart = start.advanced(by: .seconds(90))
        let retry = PlankSessionStartupDeadline(now: retryStart, waitingForRelease: true)
        assert(retry.canRetry(at: retryStart))
        assert(!retry.canRetry(at: retryStart.advanced(by: .seconds(12))))
        print("PASS: finite session startup and display-transition retry budgets")
    }
}
