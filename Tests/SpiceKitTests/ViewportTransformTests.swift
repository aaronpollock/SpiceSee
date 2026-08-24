import Testing
@testable import SpiceKit

@Test func fitLetterboxesAndMapsBothWays() {
    // 800×600 view, 1600×600 surface → scale 0.5, surface 800×300 centred vertically (origin y = 150).
    let t = ViewportTransform(viewSize: .init(width: 800, height: 600), surfaceSize: .init(width: 1600, height: 600), scaling: .fit)
    #expect(t.scale == 0.5 && t.origin == .init(x: 0, y: 150))
    #expect(t.guestPoint(fromView: .init(x: 400, y: 300)) == .init(x: 800, y: 300))
    #expect(t.guestPoint(fromView: .init(x: 0, y: 0)) == .init(x: 0, y: 0))          // clamped into the surface
    #expect(t.guestPoint(fromView: .init(x: 799.9, y: 599)) == .init(x: 1599, y: 599))
    #expect(t.viewRect(forGuest: .init(x: 100, y: 50, width: 32, height: 32)) == .init(x: 50, y: 175, width: 16, height: 16))
}

@Test func oneToOneCentresAndClips() {
    let t = ViewportTransform(viewSize: .init(width: 400, height: 400), surfaceSize: .init(width: 800, height: 200), scaling: .oneToOne)
    #expect(t.scale == 1 && t.origin == .init(x: -200, y: 100))
    #expect(t.guestPoint(fromView: .init(x: 0, y: 100)) == .init(x: 200, y: 0))
}

@Test func degenerateSizesDoNotDivideByZero() {
    let t = ViewportTransform(viewSize: .zero, surfaceSize: .init(width: 10, height: 10), scaling: .fit)
    #expect(t.scale == 1)
    #expect(t.guestPoint(fromView: .zero) == .init(x: 0, y: 0))

    let empty = ViewportTransform(viewSize: .init(width: 400, height: 400), surfaceSize: .zero, scaling: .fit)
    #expect(empty.guestPoint(fromView: .init(x: 5, y: 5)) == .init(x: 0, y: 0))
}
