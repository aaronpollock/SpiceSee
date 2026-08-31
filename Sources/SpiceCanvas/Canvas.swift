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
    private var palettes = PaletteCache()
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
        case let .invalPalette(id): palettes.remove(id)
        case .invalAllPalettes: palettes.removeAll()
        case let .fill(f):
            let source: PixelSource
            switch f.brush {
            case .none: throw CanvasError.unsupported("empty brush")
            case let .solid(color): source = .solid(color)
            case let .pattern(image, pos): source = .pattern(try resolve(image), seed: pos)
            }
            let mask = try resolveMask(f.mask, for: f.base.box)
            try forEachClipRect(f.base) { s, r in Tier2.draw(s, rect: r, source: source, rop: f.rop, mask: mask) }
        case let .copy(c), let .blend(c):
            var src = try resolve(c.source)
            let scaled = c.sourceArea.width != c.base.box.width || c.sourceArea.height != c.base.box.height
            var originBase = SpicePoint(x: c.sourceArea.left, y: c.sourceArea.top)
            if scaled {
                src = Tier2.scaled(src, from: c.sourceArea, toWidth: Int(c.base.box.width), toHeight: Int(c.base.box.height), nearest: c.scaleMode == 1)
                originBase = SpicePoint(x: 0, y: 0)
            }
            let mask = try resolveMask(c.mask, for: c.base.box)
            try forEachClipRect(c.base) { s, r in
                let origin = SpicePoint(x: originBase.x + (r.left - c.base.box.left), y: originBase.y + (r.top - c.base.box.top))
                Tier2.draw(s, rect: r, source: .image(src, origin: origin), rop: c.rop, mask: mask)
            }
        case let .opaque(o):
            guard let dstSurface = surfaces[o.base.surfaceID] else { throw CanvasError.noSurface(o.base.surfaceID) }
            guard let box = o.base.box.intersection(dstSurface.bounds) else { break }
            var src = try resolve(o.source)
            let scaled = o.sourceArea.width != box.width || o.sourceArea.height != box.height
            var originBase = SpicePoint(x: o.sourceArea.left, y: o.sourceArea.top)
            if scaled {
                src = Tier2.scaled(src, from: o.sourceArea, toWidth: Int(box.width), toHeight: Int(box.height), nearest: o.scaleMode == 1)
                originBase = SpicePoint(x: 0, y: 0)
            }
            // Combine source and brush via `rop` in an off-surface scratch, then PUT the result
            // through the mask — DRAW_OPAQUE's two-input combine has no dedicated destination
            // until the mask/clip stage, so it can't be done directly against `s`.
            let temp = Surface(id: .max, width: Int(box.width), height: Int(box.height), isPrimary: false)
            let tempRect = SpiceRect(top: 0, left: 0, bottom: box.height, right: box.width)
            Tier1.copy(into: temp, rect: tempRect, src: src, srcOrigin: originBase)
            let brushSource: PixelSource
            switch o.brush {
            case .none: brushSource = .solid(0)
            case let .solid(color): brushSource = .solid(color)
            case let .pattern(image, pos):
                brushSource = .pattern(try resolve(image), seed: SpicePoint(x: pos.x - box.left, y: pos.y - box.top))
            }
            Tier2.draw(temp, rect: tempRect, source: brushSource, rop: o.rop, mask: nil)
            let combined = temp.snapshot()
            let mask = try resolveMask(o.mask, for: box)
            try forEachClipRect(o.base) { s, r in
                let origin = SpicePoint(x: r.left - box.left, y: r.top - box.top)
                Tier2.draw(s, rect: r, source: .image(combined, origin: origin), rop: ROPD.opPut, mask: mask)
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
        let img = try decoder.decode(image, cache: cache, palettes: &palettes)
        if image.descriptor.flags & (ImageFlags.cacheMe | ImageFlags.cacheReplaceMe) != 0 { cache.store(img, id: image.descriptor.id) }
        return img
    }

    /// Decodes the mask bitmap (nil when the command carries no mask) and thresholds it to 8-bit
    /// coverage: any non-black pixel covers, inverted when `MaskFlags.invers` is set.
    private func resolveMask(_ mask: SpiceQMask, for rect: SpiceRect) throws -> ResolvedMask? {
        guard let bitmap = mask.bitmap else { return nil }
        let img = try resolve(bitmap)
        let invert = mask.flags & MaskFlags.invers != 0
        var coverage = [UInt8](repeating: 0, count: img.width * img.height)
        for y in 0 ..< img.height {
            for x in 0 ..< img.width {
                let nonBlack = img.pixel(x: x, y: y) & 0xFFFFFF != 0
                coverage[y * img.width + x] = (nonBlack != invert) ? 0xFF : 0
            }
        }
        return ResolvedMask(width: img.width, height: img.height, origin: mask.pos, coverage: coverage)
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
