import Testing
@testable import SpiceKit

@Test func wheelLinesEmitAtLeastOneClickPerEvent() {
    var w = WheelAccumulator()
    #expect(w.add(precise: false, delta: 0.1) == 1)
    #expect(w.add(precise: false, delta: -2.6) == -3)
    #expect(w.add(precise: false, delta: 0) == 0)
}

@Test func trackpadDeltasAccumulateToOneClickPerTenUnits() {
    var w = WheelAccumulator()
    #expect(w.add(precise: true, delta: 4) == 0)
    #expect(w.add(precise: true, delta: 4) == 0)
    #expect(w.add(precise: true, delta: 4) == 1)         // 12 → one click, 2 carried
    #expect(w.add(precise: true, delta: -12) == -1)      // 2 - 12 = -10 → one click down, 0 carried
    #expect(w.add(precise: true, delta: 25) == 2)
}
