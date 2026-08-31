import Metal
import QuartzCore
import SpiceKit
import SwiftUI

/// The guest framebuffer. Keeps one texture the size of the guest surface, patches dirty rects into
/// it as they arrive, and presents it to a `CAMetalLayer` — scaled to fit, or 1:1 with letterboxing.
struct MetalSurfaceView: NSViewRepresentable {
    let session: SessionModel
    let viewport: ViewportInfo

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GuestSurfaceView {
        let view = GuestSurfaceView()
        view.scaling = session.scaling
        let input = GuestInputView(frame: view.bounds)
        input.autoresizingMask = [.width, .height]
        view.addSubview(input)
        view.inputView = input
        configure(input, in: view)
        context.coordinator.pump(session.viewportEvents(for: viewport.id), into: view)
        return view
    }

    func updateNSView(_ nsView: GuestSurfaceView, context: Context) {
        nsView.scaling = session.scaling
        nsView.inputView.map { configure($0, in: nsView) }
    }

    /// Reading the model's observable properties here is what subscribes `updateNSView` to them.
    private func configure(_ input: GuestInputView, in view: GuestSurfaceView) {
        input.onInput = { [session] in session.sendInput($0) }
        input.onCaptureChange = { [session] in session.setPointerCaptured($0) }
        input.keyboardMapping = session.keyboardMapping
        input.sendLockKeys = session.sendLockKeys
        input.pointerMode = session.pointerMode
        input.releaseChord = session.releaseChord
        input.viewportID = viewport.id
        input.transform = { [weak view] in view?.transform }
        view.showsCursorOverlay = session.pointerMode == .server
    }

    static func dismantleNSView(_ nsView: GuestSurfaceView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private var task: Task<Void, Never>?

        func pump(_ events: AsyncStream<ViewportEvent>, into view: GuestSurfaceView) {
            task?.cancel()
            task = Task { [weak view] in
                for await event in events {
                    guard let view else { return }
                    switch event {
                    case let .frame(update): view.apply(update)
                    case let .cursor(change): view.apply(change)
                    case let .stream(update): view.apply(streamUpdate: update)
                    case let .streamDestroyed(id): view.removeStream(id)
                    }
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}

/// A `CAMetalLayer`-backed view. Every Metal resource is optional: a machine without a usable device,
/// or a moment without a drawable, draws nothing rather than trapping.
final class GuestSurfaceView: NSView {
    private let device = MTLCreateSystemDefaultDevice()
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let overlayPipeline: MTLRenderPipelineState?
    private let smoothSampler: MTLSamplerState?
    private let sharpSampler: MTLSamplerState?
    private var texture: MTLTexture?

    /// Dirty rects are patched into the texture as they arrive, but presented once per refresh:
    /// `nextDrawable()` blocks until vsync frees one of the layer's three drawables, so presenting
    /// per rect pinned the main thread at ~60 rects/s and every animation crawled behind it.
    private var displayLink: CADisplayLink?
    private var needsPresent = false

    /// The event-taking view layered over the surface; owned as a subview, held here to reconfigure.
    var inputView: GuestInputView?

    var scaling: ScalingMode = .fit {
        didSet { if scaling != oldValue { setNeedsPresent() } }
    }

    /// Guest ↔ view geometry for the current scaling; nil until the surface size is known.
    var transform: ViewportTransform? {
        guard let texture else { return nil }
        return ViewportTransform(viewSize: bounds.size, surfaceSize: CGSize(width: texture.width, height: texture.height),
                                 scaling: scaling == .fit ? .fit : .oneToOne, backingScale: backingScale)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? metalLayer?.contentsScale ?? 1 }

    override init(frame frameRect: NSRect) {
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap { Self.makePipeline($0, blended: false) }
        overlayPipeline = device.flatMap { Self.makePipeline($0, blended: true) }
        smoothSampler = device.flatMap { Self.makeSampler($0, filter: .linear) }
        sharpSampler = device.flatMap { Self.makeSampler($0, filter: .nearest) }
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.allowsNextDrawableTimeout = true
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    // MARK: Sizing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The link retains its target; drop it when the view leaves its window or neither is freed.
        if window == nil { displayLink?.invalidate(); displayLink = nil }
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDrawable()
    }

    private func resizeDrawable() {
        guard let metalLayer else { return }
        let scale = backingScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        render()
    }

    // MARK: Frames

    /// Patches one dirty rect into the guest texture, re-creating it when the surface size changes.
    func apply(_ update: FrameUpdate) {
        guard update.surfaceWidth > 0, update.surfaceHeight > 0 else { return }
        if texture?.width != update.surfaceWidth || texture?.height != update.surfaceHeight {
            texture = makeTexture(width: update.surfaceWidth, height: update.surfaceHeight)
            // A mode change invalidates stream geometry, and the server destroys and recreates
            // streams around it anyway.
            streams.removeAll()
        }
        guard let texture,
              update.width > 0, update.height > 0, update.x >= 0, update.y >= 0,
              update.x + update.width <= texture.width,
              update.y + update.height <= texture.height,
              update.pixels.count >= update.width * update.height * 4
        else { return }

        update.pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(update.x, update.y, update.width, update.height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: update.width * 4)
        }
        setNeedsPresent()
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Cursor

    private var cursorTexture: MTLTexture?
    private var cursorHotspot = (x: 0, y: 0)
    private var cursorPosition: (x: Int, y: Int)?

    /// Server mode draws the guest's cursor into the surface; client mode leaves it to the host
    /// pointer's shape (`GuestInputView.hostCursor`).
    var showsCursorOverlay = false {
        didSet { if showsCursorOverlay != oldValue { setNeedsPresent() } }
    }

    func apply(_ change: CursorChange) {
        switch change {
        case let .shape(image):
            cursorTexture = image.flatMap(makeCursorTexture)
            cursorHotspot = image.map { ($0.hotX, $0.hotY) } ?? (0, 0)
            inputView?.hostCursor = image?.nsCursor
        case let .moved(x, y):
            cursorPosition = (x, y)
        }
        setNeedsPresent()
    }

    private func makeCursorTexture(_ image: CursorImage) -> MTLTexture? {
        guard let device, image.width > 0, image.height > 0,
              image.pixels.count >= image.width * image.height * 4
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: image.width * 4)
        }
        return texture
    }

    // MARK: Stream layers

    private final class StreamLayer {
        var texture: MTLTexture?
        var dest = CGRect.zero
        var clip: [CGRect]?          // guest coords; nil = whole dest
        let order: Int               // creation order = z-order, oldest underneath
        init(order: Int) { self.order = order }
    }
    private var streams: [UInt32: StreamLayer] = [:]
    private var streamOrder = 0

    func apply(streamUpdate u: StreamFrameUpdate) {
        let layer = streams[u.streamID] ?? {
            let l = StreamLayer(order: streamOrder); streamOrder += 1; streams[u.streamID] = l; return l
        }()
        if layer.texture?.width != u.width || layer.texture?.height != u.height {
            layer.texture = makeTexture(width: u.width, height: u.height)
        }
        guard let tex = layer.texture, u.width > 0, u.height > 0,
              u.pixels.count >= u.width * u.height * 4
        else { return }
        u.pixels.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, u.width, u.height), mipmapLevel: 0,
                        withBytes: base, bytesPerRow: u.width * 4)
        }
        layer.dest = CGRect(x: CGFloat(u.dest.x), y: CGFloat(u.dest.y), width: CGFloat(u.dest.width), height: CGFloat(u.dest.height))
        layer.clip = u.clip.map { $0.map { CGRect(x: CGFloat($0.x), y: CGFloat($0.y), width: CGFloat($0.width), height: CGFloat($0.height)) } }
        setNeedsPresent()
    }

    func removeStream(_ id: UInt32?) {
        if let id { streams[id] = nil } else { streams.removeAll() }
        setNeedsPresent()
    }

    // MARK: Presentation

    /// Coalesces every change since the last refresh into one present. The link runs only while
    /// there is something to show: a tick with nothing pending pauses it.
    private func setNeedsPresent() {
        needsPresent = true
        if displayLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(present(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func present(_ link: CADisplayLink) {
        guard needsPresent else { link.isPaused = true; return }
        needsPresent = false
        render()
    }

    private func render() {
        guard let metalLayer, let queue, let pipeline, let texture, let t = transform,
              let sampler = scaling == .fit ? smoothSampler : sharpSampler,
              bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let buffer = queue.makeCommandBuffer()
        else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            buffer.commit()
            return
        }
        let r = t.viewRect(forGuest: CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
        var extent = Self.clipSpace(r, in: bounds.size)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Stream layers: video is composited here, never drawn into the surface (design spec §4).
        // Scissor rects are in drawable (device) pixels; clamp against the drawable and skip empty
        // rects — an out-of-bounds MTLScissorRect is API misuse, not a soft clip.
        let scale = backingScale
        let drawableBounds = CGRect(origin: .zero, size: metalLayer.drawableSize)
        for layer in streams.values.sorted(by: { $0.order < $1.order }) {
            guard let streamTexture = layer.texture else { continue }
            let viewRect = t.viewRect(forGuest: layer.dest)
            var placement = Self.clipSpace(viewRect, in: bounds.size)
            let clips = layer.clip ?? [layer.dest]
            for clipRect in clips {
                let v = t.viewRect(forGuest: clipRect)
                let dev = CGRect(x: v.origin.x * scale, y: v.origin.y * scale,
                                 width: v.width * scale, height: v.height * scale)
                    .intersection(drawableBounds)
                guard dev.width >= 1, dev.height >= 1 else { continue }
                encoder.setScissorRect(MTLScissorRect(x: Int(dev.minX), y: Int(dev.minY),
                                                      width: Int(dev.width), height: Int(dev.height)))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&placement, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentTexture(streamTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        // Reset the scissor before the cursor overlay draws, or it clips to the last stream's rect.
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(metalLayer.drawableSize.width),
                                              height: Int(metalLayer.drawableSize.height)))

        // The shape is never smoothed: a cursor is authored at guest resolution and reads as mush
        // under a linear filter.
        if showsCursorOverlay, let cursorTexture, let overlayPipeline, let position = cursorPosition {
            let rect = t.viewRect(forGuest: CGRect(x: position.x - cursorHotspot.x, y: position.y - cursorHotspot.y,
                                                   width: cursorTexture.width, height: cursorTexture.height))
            var placement = Self.clipSpace(rect, in: bounds.size)
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBytes(&placement, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(cursorTexture, index: 0)
            encoder.setFragmentSamplerState(sharpSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Centre and half-extent of a view rect in Metal clip space (y up).
    static func clipSpace(_ r: CGRect, in view: CGSize) -> SIMD4<Float> {
        let cx = Float((r.midX / view.width) * 2 - 1), cy = Float(1 - (r.midY / view.height) * 2)
        return SIMD4(cx, cy, Float(r.width / view.width), Float(r.height / view.height))
    }

    // MARK: Pipeline

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { float4 position [[position]]; float2 uv; };

    vertex Vertex surface_vertex(uint id [[vertex_id]], constant float4 &placement [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 coords[4]  = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
        Vertex out;
        out.position = float4(placement.xy + corners[id] * placement.zw, 0, 1);
        out.uv = coords[id];
        return out;
    }

    fragment float4 surface_fragment(Vertex in [[stage_in]],
                                     texture2d<float> surface [[texture(0)]],
                                     sampler surfaceSampler [[sampler(0)]]) {
        return surface.sample(surfaceSampler, in.uv);
    }
    """

    /// `blended` gives the cursor overlay straight-alpha compositing over the surface quad.
    private static func makePipeline(_ device: MTLDevice, blended: Bool) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "surface_vertex"),
              let fragmentFunction = library.makeFunction(name: "surface_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.pixelFormat = .bgra8Unorm
        if blended {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeSampler(_ device: MTLDevice, filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}
