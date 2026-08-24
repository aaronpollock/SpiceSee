/// spice-server answers every 4 motion/position messages with MOUSE_MOTION_ACK. Sending without
/// bound floods a slow guest with stale positions, so like spice-gtk we hold at 8 in flight and
/// coalesce what arrives meanwhile: deltas add up, positions replace each other.
struct MotionThrottle: Sendable, Equatable {
    static let ackBunch = 4
    static let maxInFlight = ackBunch * 2

    enum Pending: Sendable, Equatable {
        case motion(dx: Int32, dy: Int32)
        case position(x: UInt32, y: UInt32, displayID: UInt8)
    }

    private(set) var inFlight = 0
    private(set) var pending: Pending?

    /// The message to send now, or nil if it was held.
    mutating func offer(_ p: Pending) -> Pending? {
        guard inFlight < Self.maxInFlight else {
            if case let .motion(dx, dy) = p, case let .motion(px, py)? = pending {
                pending = .motion(dx: px &+ dx, dy: py &+ dy)
            } else {
                pending = p
            }
            return nil
        }
        inFlight += 1
        return p
    }

    /// Call on MOUSE_MOTION_ACK; returns the held message to send now, if any.
    mutating func acked() -> Pending? {
        inFlight = max(0, inFlight - Self.ackBunch)
        guard let p = pending else { return nil }
        pending = nil
        inFlight += 1
        return p
    }
}
