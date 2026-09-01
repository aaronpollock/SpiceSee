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

public struct ViewportLayout: Sendable, Equatable {
    public var displayID: UInt8
    public var headIndex: Int
    public var rect: HeadRect
    public var viewportID: Int { Int(displayID) << 8 | headIndex }
    public init(displayID: UInt8, headIndex: Int, rect: HeadRect) {
        self.displayID = displayID; self.headIndex = headIndex; self.rect = rect
    }
}

/// Normalises both server shapes — N display channels, or one channel carved by
/// DISPLAY_MONITORS_CONFIG — into one list of viewports, and slices dirty rects per head.
/// A value type on purpose: snapshots of it can cross into the input FIFO without shared state.
/// Order-tolerant: headsChanged may arrive before primaryCreated, and destroy/create/config may
/// arrive in any order; layouts converge to the same result regardless.
public struct ViewportMapper: Sendable, Equatable {
    private struct DisplayState: Sendable, Equatable {
        var width: Int?, height: Int?      // nil until the primary exists
        var heads: [HeadRect] = []
    }
    private var displays: [UInt8: DisplayState] = [:]

    public init() {}

    public mutating func primaryCreated(displayID: UInt8, width: Int, height: Int) {
        displays[displayID, default: DisplayState()].width = width
        displays[displayID]!.height = height
    }

    public mutating func primaryDestroyed(displayID: UInt8) {
        displays[displayID]?.width = nil
        displays[displayID]?.height = nil
    }

    public mutating func headsChanged(displayID: UInt8, heads: [HeadRect]) {
        displays[displayID, default: DisplayState()].heads = heads
    }

    /// Heads clamped to the surface; zero-area survivors dropped; the full surface when none apply.
    private func effectiveHeads(_ s: DisplayState) -> [HeadRect] {
        guard let w = s.width, let h = s.height else { return [] }
        let clamped = s.heads.compactMap { head -> HeadRect? in
            let left = max(0, head.x), top = max(0, head.y)
            let right = min(w, head.x + head.width), bottom = min(h, head.y + head.height)
            guard right > left, bottom > top else { return nil }
            return HeadRect(id: head.id, x: left, y: top, width: right - left, height: bottom - top)
        }
        return clamped.isEmpty ? [HeadRect(id: 0, x: 0, y: 0, width: w, height: h)] : clamped
    }

    public var layouts: [ViewportLayout] {
        displays.sorted { $0.key < $1.key }.flatMap { id, state in
            effectiveHeads(state).enumerated().map { i, rect in
                ViewportLayout(displayID: id, headIndex: i, rect: rect)
            }
        }
    }

    public struct Slice: Sendable, Equatable {
        public var viewportID: Int
        public var headWidth: Int, headHeight: Int
        public var destX: Int, destY: Int
        public var srcX: Int, srcY: Int
        public var width: Int, height: Int
        public init(viewportID: Int, headWidth: Int, headHeight: Int, destX: Int, destY: Int,
                    srcX: Int, srcY: Int, width: Int, height: Int) {
            self.viewportID = viewportID; self.headWidth = headWidth; self.headHeight = headHeight
            self.destX = destX; self.destY = destY; self.srcX = srcX; self.srcY = srcY
            self.width = width; self.height = height
        }
    }

    public func slices(displayID: UInt8, dirtyX: Int, dirtyY: Int, width: Int, height: Int) -> [Slice] {
        guard let state = displays[displayID] else { return [] }
        return effectiveHeads(state).enumerated().compactMap { i, head in
            let left = max(dirtyX, head.x), top = max(dirtyY, head.y)
            let right = min(dirtyX + width, head.x + head.width)
            let bottom = min(dirtyY + height, head.y + head.height)
            guard right > left, bottom > top else { return nil }
            return Slice(viewportID: Int(displayID) << 8 | i,
                         headWidth: head.width, headHeight: head.height,
                         destX: left - head.x, destY: top - head.y,
                         srcX: left - dirtyX, srcY: top - dirtyY,
                         width: right - left, height: bottom - top)
        }
    }

    public func origin(of viewportID: Int) -> (displayID: UInt8, x: Int, y: Int)? {
        guard let layout = layouts.first(where: { $0.viewportID == viewportID }) else { return nil }
        return (layout.displayID, layout.rect.x, layout.rect.y)
    }

    public static func extract(_ pixels: [UInt8], rowPixels: Int, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(width * height * 4)
        for row in y ..< y + height {
            let start = (row * rowPixels + x) * 4
            out.append(contentsOf: pixels[start ..< start + width * 4])
        }
        return out
    }
}

public enum MonitorTiling {
    public static func compose(_ requests: [(width: Int, height: Int, enabled: Bool)]) -> [AgentMonitorConfig] {
        var x: Int32 = 0
        return requests.map { r in
            guard r.enabled else { return AgentMonitorConfig(width: 0, height: 0, depth: 0, x: 0, y: 0) }
            defer { x += Int32(r.width) }
            return AgentMonitorConfig(width: UInt32(r.width), height: UInt32(r.height), depth: 32, x: x, y: 0)
        }
    }
}
