/// Mouse wheels report whole lines; trackpads report pixels. Both become SPICE wheel clicks:
/// a wheel event is at least one click, a trackpad emits one click per `unitsPerClick` points.
public struct WheelAccumulator: Sendable {
    public static let unitsPerClick = 10.0
    private var carry = 0.0
    public init() {}

    /// Positive = up (SPICE button 4), negative = down (button 5).
    public mutating func add(precise: Bool, delta: Double) -> Int {
        guard delta != 0 else { return 0 }
        if !precise {
            let clicks = Int(delta.rounded(.awayFromZero))
            return clicks == 0 ? (delta > 0 ? 1 : -1) : clicks
        }
        carry += delta
        let clicks = Int((carry / Self.unitsPerClick).rounded(.towardZero))
        carry -= Double(clicks) * Self.unitsPerClick
        return clicks
    }
}
