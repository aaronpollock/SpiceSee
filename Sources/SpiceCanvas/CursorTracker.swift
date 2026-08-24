import os
import SpiceWire

public enum CursorChange: Sendable, Equatable {
    /// The pointer's shape; nil hides it.
    case shape(CursorShape?)
    /// Server-mode pointer position in surface pixels (client mode ignores it).
    case moved(x: Int, y: Int)
}

/// Turns the cursor channel's message stream into shape/position changes, owning the cursor cache
/// (CACHE_ME / FROM_CACHE / INVAL_ONE / INVAL_ALL). Pure value type: a session keeps one per channel.
public struct CursorTracker: Sendable {
    private var cache: [UInt64: CursorShape] = [:]
    private static let log = Logger(subsystem: "com.spicesee", category: "cursor")
    public init() {}

    public mutating func apply(_ m: CursorMessage) -> [CursorChange] {
        switch m {
        case let .`init`(position, visible, cursor), let .set(position, visible, cursor):
            var out: [CursorChange] = []
            if !visible {
                out.append(.shape(nil))
            } else if let shape = resolve(cursor) {
                out.append(.shape(shape))
            }
            out.append(.moved(x: Int(position.x), y: Int(position.y)))
            return out
        case let .move(p): return [.moved(x: Int(p.x), y: Int(p.y))]
        case .hide: return [.shape(nil)]
        case .reset: cache.removeAll(); return [.shape(nil)]
        case let .invalOne(id): cache[id] = nil; return []
        case .invalAll: cache.removeAll(); return []
        case .trail, .other: return []
        }
    }

    /// nil when there is nothing to show yet: flags NONE, a cache miss, or a shape we cannot decode.
    private mutating func resolve(_ c: SpiceCursor) -> CursorShape? {
        guard let header = c.header else { return nil }
        if c.flags & CursorFlags.fromCache != 0 { return cache[header.unique] }
        do {
            let shape = try CursorDecoder.decode(header, data: c.data)
            if c.flags & CursorFlags.cacheMe != 0 { cache[header.unique] = shape }
            return shape
        } catch {
            Self.log.error("cursor: \(String(describing: error))")
            return nil
        }
    }
}
