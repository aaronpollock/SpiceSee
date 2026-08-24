import Testing
@testable import SpiceCore

@Test func holdsAtEightInFlightAndCoalesces() {
    var t = MotionThrottle()
    for i in 0 ..< 8 { #expect(t.offer(.motion(dx: 1, dy: Int32(i))) != nil) }
    #expect(t.offer(.motion(dx: 2, dy: 3)) == nil)
    #expect(t.offer(.motion(dx: 4, dy: 5)) == nil)
    #expect(t.pending == .motion(dx: 6, dy: 8))            // deltas sum while held
    #expect(t.acked() == .motion(dx: 6, dy: 8))            // one ack frees a bunch of 4 and flushes
    #expect(t.pending == nil && t.inFlight == 5)
}

@Test func positionReplacesInsteadOfSumming() {
    var t = MotionThrottle()
    for _ in 0 ..< 8 { _ = t.offer(.position(x: 0, y: 0, displayID: 0)) }
    _ = t.offer(.position(x: 10, y: 10, displayID: 0))
    _ = t.offer(.position(x: 20, y: 30, displayID: 0))
    #expect(t.pending == .position(x: 20, y: 30, displayID: 0))
    _ = t.offer(.motion(dx: 1, dy: 1))                      // mode switched mid-hold: newest wins
    #expect(t.pending == .motion(dx: 1, dy: 1))
}

@Test func ackWithNothingPendingJustDecrements() {
    var t = MotionThrottle()
    _ = t.offer(.motion(dx: 1, dy: 1))
    #expect(t.acked() == nil && t.inFlight == 0)           // never below zero
}
