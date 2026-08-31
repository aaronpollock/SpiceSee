import os
import SpiceWire

public struct SurfaceUpdate: Sendable {
    public var surfaceID: UInt32, surfaceWidth: Int, surfaceHeight: Int
    public var rect: SpiceRect, pixels: [UInt8], isPrimary: Bool
}
public struct SurfaceDescriptor: Sendable, Equatable { public var surfaceID: UInt32, width: Int, height: Int, isPrimary: Bool }
public enum CanvasEvent: Sendable {
    case surfaceCreated(SurfaceDescriptor), surfaceDestroyed(UInt32), updated(SurfaceUpdate), unsupported(String)
}

public actor Canvas {
    public nonisolated let events: AsyncStream<CanvasEvent>
    private let cont: AsyncStream<CanvasEvent>.Continuation
    private var surfaces: [UInt32: Surface] = [:]
    private var cache = ImageCache()
    private var decoder = ImageDecoder()
    private let log = Logger(subsystem: "com.spicesee", category: "canvas")
    public private(set) var primarySurfaceID: UInt32?

    public init() { (events, cont) = AsyncStream.makeStream(of: CanvasEvent.self, bufferingPolicy: .unbounded) }

    public func snapshot(surfaceID: UInt32) -> DecodedImage? { surfaces[surfaceID]?.snapshot() }

    /// Ends `events`. Call once no further messages will be applied, so a consumer draining the
    /// stream terminates instead of hanging.
    public func finish() { cont.finish() }

    public func apply(_ m: DisplayMessage) {
        do { try applyThrowing(m) } catch {
            log.error("canvas: \(String(describing: error), privacy: .public)")
            cont.yield(.unsupported(String(describing: error)))
        }
    }

    private func applyThrowing(_ m: DisplayMessage) throws {
        switch m {
        case let .surfaceCreate(s):
            let surf = Surface(id: s.surfaceID, width: Int(s.width), height: Int(s.height), isPrimary: s.isPrimary)
            surfaces[s.surfaceID] = surf
            if s.isPrimary { primarySurfaceID = s.surfaceID }
            cont.yield(.surfaceCreated(SurfaceDescriptor(surfaceID: s.surfaceID, width: surf.width, height: surf.height, isPrimary: s.isPrimary)))
            emit(surf, surf.bounds)
        case let .surfaceDestroy(id):
            surfaces[id] = nil
            if primarySurfaceID == id { primarySurfaceID = nil }
            cont.yield(.surfaceDestroyed(id))
        case .mode, .mark, .reset, .monitorsConfig: break
        case .invalAllPixmaps: cache.removeAll()
        case let .invalList(list): list.forEach { cache.remove($0.id) }
        case .invalPalette, .invalAllPalettes: break
        case let .fill(f):
            guard case let .solid(color) = f.brush else { throw CanvasError.unsupported("pattern brush") }
            try forEachClipRect(f.base) { s, r in Tier1.fill(s, rect: r, color: color) }
            if f.rop != ROPD.opPut || f.mask.bitmap != nil { cont.yield(.unsupported("fill rop \(f.rop)/mask → drawn as PUT")) }
        case let .copy(c), let .blend(c):
            let src = try resolve(c.source)
            try forEachClipRect(c.base) { s, r in
                let origin = SpicePoint(x: c.sourceArea.left + (r.left - c.base.box.left), y: c.sourceArea.top + (r.top - c.base.box.top))
                Tier1.copy(into: s, rect: r, src: src, srcOrigin: origin)
            }
            if c.rop != ROPD.opPut || c.mask.bitmap != nil || c.sourceArea.width != c.base.box.width { cont.yield(.unsupported("copy rop/mask/scale → drawn as PUT")) }
        case let .opaque(o):
            let src = try resolve(o.source)
            try forEachClipRect(o.base) { s, r in
                let origin = SpicePoint(x: o.sourceArea.left + (r.left - o.base.box.left), y: o.sourceArea.top + (r.top - o.base.box.top))
                Tier1.copy(into: s, rect: r, src: src, srcOrigin: origin)
            }
        case let .blackness(b): try forEachClipRect(b.base) { s, r in Tier1.fill(s, rect: r, color: 0) }
        case let .whiteness(w): try forEachClipRect(w.base) { s, r in Tier1.fill(s, rect: r, color: 0xFFFFFF) }
        case let .invers(i): try forEachClipRect(i.base) { s, r in Tier1.invert(s, rect: r) }
        case let .copyBits(c):
            try forEachClipRect(c.base) { s, r in
                Tier1.copyBits(s, rect: r, from: SpicePoint(x: c.sourcePos.x + (r.left - c.base.box.left), y: c.sourcePos.y + (r.top - c.base.box.top)))
            }
        case let .alphaBlend(a):
            let src = try resolve(a.source)
            try forEachClipRect(a.base) { s, r in
                let origin = SpicePoint(x: a.sourceArea.left + (r.left - a.base.box.left), y: a.sourceArea.top + (r.top - a.base.box.top))
                Tier1.alphaBlend(into: s, rect: r, src: src, srcOrigin: origin, alpha: a.alpha)
            }
        case let .rop3(r): throw CanvasError.unsupported("rop3 \(r.rop3) (task 5)")
        case let .transparent(t): _ = t; throw CanvasError.unsupported("transparent (task 5)")
        case .stroke: throw CanvasError.unsupported("stroke (task 6)")
        case .text: throw CanvasError.unsupported("text (task 7)")
        case let .unsupported(type, _):
            throw CanvasError.unsupported("display message \(type)")
        }
    }

    /// Decodes, honouring cache flags and surface-as-image.
    private func resolve(_ image: SpiceImage?) throws -> DecodedImage {
        guard let image else { throw CanvasError.decode("missing source image") }
        if case let .surface(id) = image.payload {
            guard let s = surfaces[id] else { throw CanvasError.noSurface(id) }
            return s.snapshot()
        }
        let img = try decoder.decode(image, cache: cache)
        if image.descriptor.flags & (ImageFlags.cacheMe | ImageFlags.cacheReplaceMe) != 0 { cache.store(img, id: image.descriptor.id) }
        return img
    }

    /// Runs `body` for each (surface, clipped rect) and emits one update per rect.
    private func forEachClipRect(_ base: DrawBase, _ body: (Surface, SpiceRect) -> Void) throws {
        guard let s = surfaces[base.surfaceID] else { throw CanvasError.noSurface(base.surfaceID) }
        guard let box = base.box.intersection(s.bounds) else { return }
        let rects: [SpiceRect]
        switch base.clip {
        case .none: rects = [box]
        case let .rects(list): rects = list.compactMap { $0.intersection(box) }
        }
        for r in rects { body(s, r); emit(s, r) }
    }

    private func emit(_ s: Surface, _ r: SpiceRect) {
        cont.yield(.updated(SurfaceUpdate(surfaceID: s.id, surfaceWidth: s.width, surfaceHeight: s.height,
                                          rect: r, pixels: s.extract(r), isPrimary: s.isPrimary)))
    }
}
