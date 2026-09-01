import SpiceWire

/// One guest monitor's rectangle carved out of a display channel's primary surface, in surface
/// pixels. With no DISPLAY_MONITORS_CONFIG a display has one implicit head covering its primary.
public struct HeadRect: Sendable, Equatable {
    public var id: UInt32
    public var x, y, width, height: Int
    public init(id: UInt32, x: Int, y: Int, width: Int, height: Int) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Viewport-worthy heads from a DISPLAY_MONITORS_CONFIG: only heads on the primary surface
    /// (surface 0) are windows; zero-area heads are disabled.
    public static func heads(from cfg: MonitorsConfig) -> [HeadRect] {
        cfg.heads.filter { $0.surfaceID == 0 && $0.width > 0 && $0.height > 0 }
            .map { HeadRect(id: $0.id, x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height)) }
    }
}
