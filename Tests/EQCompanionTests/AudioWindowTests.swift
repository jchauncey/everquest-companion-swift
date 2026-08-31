import XCTest
@testable import EQCompanion

/// The audio coalescing window. It had NO tests, and shipped a crash that fired the first time the
/// app ever played an alert: "no window yet" was spelled `Int64.min`, and the first thing the
/// window did with it was subtract it from a wall-clock millisecond, which overflows Int64 and
/// traps. Every alert went through that line.
final class AudioWindowTests: XCTestCase {
    /// A real wall-clock stamp, the kind `AlertPlayer` passes: ~1.79e12 ms since 1970.
    private let now = Int64(Date().timeIntervalSince1970 * 1000)

    /// THE REGRESSION. This does not "fail" if it breaks again - it traps and takes the run with
    /// it, exactly as it took the app.
    func testTheVeryFirstAlertPlaysInsteadOfTrapping() {
        var w = AudioWindow()
        XCTAssertTrue(w.admit("bell|", now: now, bypass: false), "the first alert after launch")

        // The far ends of the clock, since the arithmetic is what broke: a log replayed from epoch
        // zero, and a stamp large enough that a careless sentinel would overflow the other way.
        var epoch = AudioWindow()
        XCTAssertTrue(epoch.admit("bell|", now: 0, bypass: false))
        var far = AudioWindow()
        XCTAssertTrue(far.admit("bell|", now: Int64.max / 2, bypass: false))
    }

    func testABurstOfTheSameThingIsHeardOnce() {
        var w = AudioWindow()
        XCTAssertTrue(w.admit("bell|You have gained", now: now, bypass: false))
        XCTAssertFalse(w.admit("bell|You have gained", now: now + 1, bypass: false))
        XCTAssertFalse(w.admit("bell|You have gained", now: now + audioCoalesceMs, bypass: false))
        // Past the window, the same thing is a new thing to hear.
        XCTAssertTrue(w.admit("bell|You have gained", now: now + audioCoalesceMs + 1, bypass: false))
    }

    func testDifferentThingsInOneBurstAreAllHeardUpToTheCap() {
        var w = AudioWindow()
        for i in 0..<audioDistinctCap {
            XCTAssertTrue(w.admit("sound\(i)|", now: now + Int64(i), bypass: false),
                          "\(i) distinct alerts are \(i) facts")
        }
        // The cap holds the channel to something a person can actually take in.
        XCTAssertFalse(w.admit("one-too-many|", now: now + 10, bypass: false))
        // And it lifts with the window.
        XCTAssertTrue(w.admit("one-too-many|", now: now + audioCoalesceMs + 1, bypass: false))
    }

    /// The documented rule: first arrival owns the window, and a suppressed firing never extends it.
    func testASuppressedFiringDoesNotExtendTheWindow() {
        var w = AudioWindow()
        XCTAssertTrue(w.admit("bell|", now: now, bypass: false))
        // Suppressed repeats right up to the edge...
        for t in stride(from: Int64(100), through: audioCoalesceMs, by: 100) {
            XCTAssertFalse(w.admit("bell|", now: now + t, bypass: false))
        }
        // ...and the window still closes 1500ms after the FIRST one, not after the last attempt.
        XCTAssertTrue(w.admit("bell|", now: now + audioCoalesceMs + 1, bypass: false))
    }

    func testBypassAlwaysPlaysAndNeitherOpensNorClosesAWindow() {
        var w = AudioWindow()
        XCTAssertTrue(w.admit("bell|", now: now, bypass: true))
        XCTAssertTrue(w.admit("bell|", now: now, bypass: true), "four buffs fading is four sounds")

        // Bypassing did not open a window, so a normal firing still gets the first word...
        XCTAssertTrue(w.admit("bell|", now: now + 1, bypass: false))
        // ...and bypassing inside a window does not reset it either.
        XCTAssertTrue(w.admit("other|", now: now + 2, bypass: true))
        XCTAssertFalse(w.admit("bell|", now: now + 3, bypass: false))
    }

    /// A clock that steps backwards (a log replay, an NTP correction) must not trap or wedge.
    func testAClockThatGoesBackwardsIsSurvivable() {
        var w = AudioWindow()
        XCTAssertTrue(w.admit("bell|", now: now, bypass: false))
        XCTAssertFalse(w.admit("bell|", now: now - 5_000, bypass: false), "still inside the window")
        XCTAssertTrue(w.admit("other|", now: now - 5_000, bypass: false), "and still admitting news")
    }
}
