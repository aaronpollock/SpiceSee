import Metal
import QuartzCore
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
        configure(input)
        context.coordinator.pump(session.viewportEvents(for: viewport.id), into: view)
        return view
    }

    func updateNSView(_ nsView: GuestSurfaceView, context: Context) {
        nsView.scaling = session.scaling
        nsView.inputView.map(configure)
    }

    /// Reading the model's observable properties here is what subscribes `updateNSView` to them.
    private func configure(_ input: GuestInputView) {
        input.onInput = { [session] in session.sendInput($0) }
        input.onCaptureChange = { [session] in session.setPointerCaptured($0) }
        input.keyboardMapping = session.keyboardMapping
        input.sendLockKeys = session.sendLockKeys
        input.pointerMode = session.pointerMode
        input.releaseChord = session.releaseChord
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
                    case .cursor: break            // Task 12
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
    private let smoothSampler: MTLSamplerState?
    private let sharpSampler: MTLSamplerState?
    private var texture: MTLTexture?

    /// The event-taking view layered over the surface; owned as a subview, held here to reconfigure.
    var inputView: GuestInputView?

    var scaling: ScalingMode = .fit {
        didSet { if scaling != oldValue { render() } }
    }

    override init(frame frameRect: NSRect) {
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
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
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
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
        render()
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Presentation

    private func render() {
        guard let metalLayer, let queue, let pipeline, let texture,
              let sampler = scaling == .fit ? smoothSampler : sharpSampler,
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
        var extent = clipExtent(drawable: metalLayer.drawableSize, texture: texture)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Half-extent of the presented surface in clip space, centred. `.fit` preserves aspect ratio and
    /// letterboxes; `.oneToOne` maps one guest pixel to one device pixel and lets the edges clip.
    private func clipExtent(drawable: CGSize, texture: MTLTexture) -> SIMD2<Float> {
        let drawableWidth = Float(drawable.width), drawableHeight = Float(drawable.height)
        let surfaceWidth = Float(texture.width), surfaceHeight = Float(texture.height)
        guard drawableWidth > 0, drawableHeight > 0, surfaceWidth > 0, surfaceHeight > 0 else {
            return SIMD2(1, 1)
        }
        switch scaling {
        case .fit:
            let scale = min(drawableWidth / surfaceWidth, drawableHeight / surfaceHeight)
            return SIMD2(surfaceWidth * scale / drawableWidth, surfaceHeight * scale / drawableHeight)
        case .oneToOne:
            return SIMD2(surfaceWidth / drawableWidth, surfaceHeight / drawableHeight)
        }
    }

    // MARK: Pipeline

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { float4 position [[position]]; float2 uv; };

    vertex Vertex surface_vertex(uint id [[vertex_id]], constant float2 &extent [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 coords[4]  = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
        Vertex out;
        out.position = float4(corners[id] * extent, 0, 1);
        out.uv = coords[id];
        return out;
    }

    fragment float4 surface_fragment(Vertex in [[stage_in]],
                                     texture2d<float> surface [[texture(0)]],
                                     sampler surfaceSampler [[sampler(0)]]) {
        return surface.sample(surfaceSampler, in.uv);
    }
    """

    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "surface_vertex"),
              let fragmentFunction = library.makeFunction(name: "surface_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
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
