import os
import SpiceWire

/// A drop skips decode entirely once a frame is judged late, so the cost the drop is meant to
/// avoid (VideoToolbox work) is never paid.
private let maxLatenessMs: Int64 = 80

public struct StreamFrame: Sendable {
    public var streamID: UInt32, surfaceID: UInt32
    public var dest: SpiceRect, clip: SpiceClip
    public var width: Int, height: Int
    public var pixels: [UInt8]                        // BGRA

    public init(streamID: UInt32, surfaceID: UInt32, dest: SpiceRect, clip: SpiceClip, width: Int, height: Int, pixels: [UInt8]) {
        self.streamID = streamID; self.surfaceID = surfaceID
        self.dest = dest; self.clip = clip
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum StreamPlayerEvent: Sendable {
    case frame(StreamFrame)
    case destroyed(streamID: UInt32)
    case allDestroyed
    case report(StreamReport)
}

/// Per-stream bookkeeping for `STREAM_REPORT`. Opens when `activateReport` arrives (or after the
/// previous window closes) and closes — emitting a report — either once `maxWindowSize` arrivals
/// have been counted or once a new arrival lands more than `timeoutMs` after the window opened.
/// There is no timer: a stalled stream simply reports late, on its next frame, which is the first
/// moment the server can act on it anyway.
private struct ReportWindow {
    var uniqueID: UInt32
    var maxWindowSize: UInt32
    var timeoutMs: UInt32
    var opened: ContinuousClock.Instant
    var firstMM: UInt32?
    var lastMM: UInt32 = 0
    var frames: UInt32 = 0
    var drops: UInt32 = 0
}

/// Holds a `~Copyable` `VideoDecoder`, so this is a class rather than a struct — actor-confined,
/// never escapes `StreamPlayer`, not `Sendable`.
private final class StreamState {
    let id: UInt32
    let surfaceID: UInt32
    let codec: VideoCodecType
    let flags: UInt8
    var dest: SpiceRect
    var clip: SpiceClip
    var decoder: VideoDecoder
    var report: ReportWindow?

    init(create: StreamCreate) {
        id = create.id
        surfaceID = create.surfaceID
        codec = create.codec
        flags = create.flags
        dest = create.dest
        clip = create.clip
        decoder = VideoDecoder(codec: create.codec)
    }
}

public actor StreamPlayer {
    public nonisolated let events: AsyncStream<StreamPlayerEvent>
    private let cont: AsyncStream<StreamPlayerEvent>.Continuation
    private var streams: [UInt32: StreamState] = [:]
    private var mmBase: (serverTime: UInt32, at: ContinuousClock.Instant)?
    private let log = Logger(subsystem: "com.spicesee", category: "stream")
    private var loggedUnsupportedCodecs = Set<VideoCodecType>()

    /// Test-only visibility into whether the decoder was actually invoked — `internal`, never
    /// `public`, reachable from tests only via `@testable import`. Exists because frame-count
    /// alone can't tell "dropped before decode" from "decoded, threw, counted as a drop": both
    /// yield zero frames. This makes that distinction observable.
    private(set) var decodeAttempts: UInt32 = 0

    public init() {
        (events, cont) = AsyncStream.makeStream(of: StreamPlayerEvent.self, bufferingPolicy: .unbounded)
    }

    /// Ends `events`. Mirrors `Canvas.finish()`.
    public func finish() { cont.finish() }

    /// `MAIN_INIT` and `MSG_MAIN_MULTI_MEDIA_TIME` seed the mm clock this player paces against.
    public func setMMTime(_ serverTime: UInt32) {
        mmBase = (serverTime, .now)
    }

    /// Server-now in mm-time units, or `nil` before the clock is ever seeded — in which case
    /// nothing is late, since there is no base to be late against.
    private func serverNow() -> UInt32? {
        guard let mmBase else { return nil }
        let elapsedMs = mmBase.at.duration(to: .now).milliseconds
        return mmBase.serverTime &+ UInt32(clamping: elapsedMs)
    }

    public func handle(create: StreamCreate) {
        // Ruling 4: VP8/VP9/H265 are never advertised as a client capability, so a server sending
        // one of these codecs is misbehaving. Logged once and ignored — no stream state, no
        // decoder that would throw on every frame.
        guard create.codec == .mjpeg || create.codec == .h264 else {
            if loggedUnsupportedCodecs.insert(create.codec).inserted {
                log.error("stream \(create.id, privacy: .public): unsupported codec \(String(describing: create.codec), privacy: .public), ignoring")
            }
            return
        }
        streams[create.id] = StreamState(create: create)
    }

    public func handle(clipChange id: UInt32, clip: SpiceClip) {
        streams[id]?.clip = clip
    }

    public func handle(destroy id: UInt32) {
        guard streams.removeValue(forKey: id) != nil else { return }
        cont.yield(.destroyed(streamID: id))
    }

    public func handleDestroyAll() {
        streams.removeAll()
        cont.yield(.allDestroyed)
    }

    public func handle(activateReport: StreamActivateReport) {
        guard let state = streams[activateReport.streamID] else { return }
        state.report = ReportWindow(uniqueID: activateReport.uniqueID, maxWindowSize: activateReport.maxWindowSize,
                                     timeoutMs: activateReport.timeoutMs, opened: .now)
    }

    public func handle(data: StreamData) {
        // A destroy racing data is normal, not an error — drop silently.
        guard let state = streams[data.id] else { return }

        if let sized = data.sized { state.dest = sized.dest }

        let now = serverNow()
        let isLate = now.map { Int64($0) - Int64(data.mmTime) > maxLatenessMs } ?? false   // base unknown: assume on time

        // Late is classified and counted without ever touching the decoder — that's the whole
        // point of dropping before decode.
        guard !isLate else {
            recordArrival(state: state, mmTime: data.mmTime, dropped: true, now: now)
            return
        }

        // Stamped onto the event, not queried back: dest/clip are read here, before decode, so a
        // later STREAM_CLIP cannot retroactively change what this frame reports.
        let dest = state.dest, clip = state.clip, surfaceID = state.surfaceID, streamID = data.id
        let flip = state.codec == .mjpeg && state.flags & StreamFlags.topDown == 0

        // Every arrival is classified exactly once — late / decode-failed / success — and recorded
        // exactly once with that final classification. An earlier version counted this arrival as
        // a success optimistically, ahead of decode, then corrected the window on failure; when
        // that correction landed on an already-closed (reset-to-zero) window, `UInt32` underflow
        // on `frames -= 1` trapped the process. Decode first, classify once, record once.
        decodeAttempts += 1
        var frame: StreamFrame?
        do {
            var decoded = try state.decoder.decode(data.data)
            if flip { decoded.pixels = Self.flipRows(decoded.pixels, width: decoded.width, height: decoded.height) }
            frame = StreamFrame(streamID: streamID, surfaceID: surfaceID, dest: dest, clip: clip,
                                 width: decoded.width, height: decoded.height, pixels: decoded.pixels)
        } catch {
            log.error("stream \(streamID, privacy: .public): decode failed: \(String(describing: error), privacy: .public)")
        }

        recordArrival(state: state, mmTime: data.mmTime, dropped: frame == nil, now: now)
        if let frame { cont.yield(.frame(frame)) }
    }

    /// Counts an arrival into the stream's report window (if reporting is active), emitting and
    /// resetting the window when it fills or times out. Called exactly once per arrival, with its
    /// final classification — never optimistically ahead of decode.
    private func recordArrival(state: StreamState, mmTime: UInt32, dropped: Bool, now: UInt32?) {
        guard var window = state.report else { return }
        window = closeWindowIfTimedOut(window, state: state)
        if window.firstMM == nil { window.firstMM = mmTime }
        window.lastMM = mmTime
        if dropped { window.drops += 1 } else { window.frames += 1 }
        state.report = window
        emitIfWindowFull(state: state, lastMMTime: mmTime, now: now)
    }

    private func closeWindowIfTimedOut(_ window: ReportWindow, state: StreamState) -> ReportWindow {
        guard window.opened.duration(to: .now).milliseconds > Int64(window.timeoutMs) else { return window }
        emit(window, state: state)
        return ReportWindow(uniqueID: window.uniqueID, maxWindowSize: window.maxWindowSize, timeoutMs: window.timeoutMs, opened: .now)
    }

    private func emitIfWindowFull(state: StreamState, lastMMTime: UInt32, now: UInt32?) {
        guard let window = state.report, window.frames + window.drops >= window.maxWindowSize else { return }
        emit(window, state: state)
        state.report = ReportWindow(uniqueID: window.uniqueID, maxWindowSize: window.maxWindowSize, timeoutMs: window.timeoutMs, opened: .now)
    }

    private func emit(_ window: ReportWindow, state: StreamState) {
        let now = serverNow()
        let lastFrameDelay: Int32 = now.map { Int32(clamping: Int64($0) - Int64(window.lastMM)) } ?? 0
        cont.yield(.report(StreamReport(
            streamID: state.id, uniqueID: window.uniqueID,
            startFrameMMTime: window.firstMM ?? 0, endFrameMMTime: window.lastMM,
            numFrames: window.frames, numDrops: window.drops,
            lastFrameDelay: lastFrameDelay, audioDelay: .max)))
    }

    static func flipRows(_ px: [UInt8], width: Int, height: Int) -> [UInt8] {
        let stride = width * 4
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0 ..< height { out.replaceSubrange(y * stride ..< (y + 1) * stride, with: px[(height - 1 - y) * stride ..< (height - y) * stride]) }
        return out
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
