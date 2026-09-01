import Foundation

/// One dirty-rect framebuffer update, in guest pixels.
struct FrameUpdate: Sendable {
    var viewportID: Int
    var surfaceWidth: Int
    var surfaceHeight: Int
    var x: Int, y: Int, width: Int, height: Int
    /// Tightly packed BGRA, `width * 4` bytes per row.
    var pixels: [UInt8]
}

/// Which side owns the pointer position. Client = absolute (`MOUSE_POSITION`, host cursor shows
/// the guest's shape); server = relative (`MOUSE_MOTION`, pointer captured while working).
enum PointerMode: Equatable, Sendable { case client, server }

enum PointerButton: Sendable { case left, middle, right }

struct KeyboardMapping: Equatable, Sendable {
    var commandMapsTo: GuestModifier = .super
    var optionMapsTo: GuestModifier = .alt
}

/// Host input in the host's own terms; the adapter translates key codes and coordinates.
enum InputEvent: Sendable {
    case keyDown(keyCode: UInt16, mapping: KeyboardMapping)
    case keyUp(keyCode: UInt16, mapping: KeyboardMapping)
    /// Host caps-lock state — on change and on focus — so the guest's lock keys follow the Mac's.
    case capsLock(on: Bool)
    case releaseAllKeys
    /// Client mode: absolute guest pixels.
    case pointerPosition(x: Int, y: Int, viewportID: Int)
    /// Server mode: raw deltas while captured.
    case pointerMotion(dx: Int, dy: Int)
    case buttonDown(PointerButton), buttonUp(PointerButton)
    /// Positive = up, negative = down.
    case wheel(clicks: Int)
}

/// BGRA, straight alpha, `width * 4` bytes per row; hotspot in cursor pixels.
struct CursorImage: Sendable, Equatable {
    var width: Int, height: Int, hotX: Int, hotY: Int
    var pixels: [UInt8]
}

enum CursorChange: Sendable, Equatable {
    case shape(CursorImage?)          // nil hides the pointer
    case moved(x: Int, y: Int)        // server mode only
}

/// A rectangle in guest pixels, the seam's own geometry type — no SPICE type crosses into the views.
struct GuestRect: Sendable, Equatable { var x, y, width, height: Int }

/// One decoded video frame for a stream layer, in guest pixels. `dest` is where it composites;
/// `clip` (nil = whole `dest`) is intersected in the view. Pixels are `width`×`height` BGRA.
struct StreamFrameUpdate: Sendable {
    var viewportID: Int
    var streamID: UInt32
    var dest: GuestRect
    var clip: [GuestRect]?
    var width: Int, height: Int
    var pixels: [UInt8]
}

/// One head's requested state, in guest pixels. The seam's own type — no SPICE type crosses.
struct DisplayLayout: Sendable, Equatable {
    var viewportID: Int
    var width: Int
    var height: Int
    var enabled: Bool
}

/// What one viewport window consumes: pixels and the pointer drawn over them.
enum ViewportEvent: Sendable {
    case frame(FrameUpdate)
    case cursor(CursorChange)
    case stream(StreamFrameUpdate)
    /// nil streamID = all streams for this viewport (DESTROY_ALL, or the session ending).
    case streamDestroyed(UInt32?)
}

/// The clipboard content kinds SpiceSee exchanges: text, and PNG for images. The agent protocol
/// underneath is type-generic; the adapter narrows to what this seam speaks, dropping BMP/TIFF/JPG/file lists.
enum ClipboardKind: Sendable, Equatable { case text, png }

/// Clipboard sharing, widened from text-only to also carry PNG images.
enum ClipboardEvent: Sendable, Equatable {
    /// Whether the guest agent is up and has negotiated clipboard sharing.
    case available(Bool)
    /// The guest copied one or more of these kinds. Ask for one with `requestClipboard`.
    case guestOffers([ClipboardKind])
    /// The guest is pasting and wants this kind from the host; answer with `sendClipboardText`/`sendClipboardPNG`.
    case guestRequests(ClipboardKind)
    /// The guest's answer for `.text`, with LF line endings.
    case guestText(String)
    /// The guest's answer for `.png`.
    case guestImagePNG([UInt8])
    case guestReleased
}

/// Guest audio, decoded. `frames` are interleaved Float32 at the announced rate/channels.
enum AudioEvent: Sendable, Equatable {
    case started(sampleRate: Int, channels: Int, opus: Bool)
    case pcm(frames: [Float], mmTime: UInt32)
    case volume([Float])
    case mute(Bool)
    case stopped
}

enum BackendEvent: Sendable {
    case step(ConnectStep)
    case connected(viewports: [ViewportInfo])
    /// The guest's monitor layout changed mid-session (new heads, or a primary at a new size).
    case viewportsChanged([ViewportInfo])
    case agent(AgentState)
    case clipboard(ClipboardEvent)
    case audio(AudioEvent)
    case pointerMode(PointerMode)
    case frame(FrameUpdate)
    case cursor(viewportID: Int, CursorChange)
    case streamFrame(StreamFrameUpdate)
    /// nil streamID = all streams for this viewport (DESTROY_ALL).
    case streamDestroyed(viewportID: Int, streamID: UInt32?)
    case migrated(MigrationOffer)
    case failed(ConnectFailure)
    case disconnected
}

/// Everything needed to open one session. Grouped rather than passed as six arguments because a
/// `.vv` file supplies most of it at once.
struct ConnectionTarget: Sendable {
    var host: String
    var port: UInt16?
    var tlsPort: UInt16?
    var hostSubject: String?
    var caPEM: String?
    var password: String?
    /// The pveproxy endpoint (`host:port`) to CONNECT through — the Proxmox `host` above is an
    /// opaque token only that proxy can route.
    var proxy: String?

    /// "pve1.lan:61000" — the TLS port when there is one, matching `SavedConnection.endpoint`.
    var endpoint: String { "\(host):\(tlsPort ?? port ?? 0)" }
    var usesTLS: Bool { tlsPort != nil }
}

/// The seam between the UI and the SPICE engine.
///
/// `SpiceKitBackend` drives this with the real engine; `MockSessionBackend` still backs `--mock`, so
/// every screen stays reviewable without a server. Landing the engine needed no view changes — if one
/// ever seems to, the seam is wrong and the fix belongs in the adapter.
protocol SessionBackend: Sendable {
    func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
    /// Synchronous on purpose: the backend must preserve order, and a `Task` per event would not.
    func sendInput(_ event: InputEvent)
    /// Tells the guest the host clipboard holds these kinds, so it may ask for one.
    func offerClipboard(_ kinds: [ClipboardKind]) async
    /// Answers `.guestRequests(.text)`. Line endings are converted to the guest's convention below.
    func sendClipboardText(_ text: String) async
    /// Answers `.guestRequests(.png)`.
    func sendClipboardPNG(_ bytes: [UInt8]) async
    /// Asks for what `.guestOffers` announced; the answer arrives as `.guestText`/`.guestImagePNG`.
    func requestClipboard(_ kind: ClipboardKind) async
    /// Asks the guest to adopt this layout, one entry per known viewport, closed windows disabled.
    /// Silently ignored without an agent that does monitors-config.
    func requestDisplayLayout(_ layouts: [DisplayLayout]) async
}
