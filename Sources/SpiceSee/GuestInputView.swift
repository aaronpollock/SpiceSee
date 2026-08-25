import AppKit
import SpiceKit

/// Receives every host event meant for the guest. Sits over the Metal surface, fills it, and is the
/// window's first responder while a session is on screen. Keyboard, pointer, and — in client mode —
/// the host pointer's shape; server mode composites the guest cursor in `MetalSurfaceView`.
final class GuestInputView: NSView {
    var onInput: (InputEvent) -> Void = { _ in }
    var onCaptureChange: (Bool) -> Void = { _ in }
    var keyboardMapping = KeyboardMapping()
    var sendLockKeys = true
    var pointerMode: PointerMode = .client {
        didSet {
            if pointerMode == .client, oldValue != .client { releaseCapture() }
            // `resetCursorRects` otherwise only re-runs on resize or scroll, so a mode flip would
            // leave the rect holding the other mode's cursor — possibly the hidden one.
            window?.invalidateCursorRects(for: self)
        }
    }
    var releaseChord: ReleaseChord = .controlOption
    var viewportID = 0
    /// Supplies the surface geometry; set by MetalSurfaceView.
    var transform: () -> ViewportTransform? = { nil }

    /// kVK_CapsLock. Caps lock is synced as lock state (INPUTS_KEY_MODIFIERS), never as a scancode — see SpiceKit.KeyMap.
    private static let capsLockKeyCode: UInt16 = 0x39

    /// Block observers and event monitors are not unregistered for you. A nonisolated `deinit` may
    /// not read main-actor storage in Swift 6, so the tokens live one level down: dropping the box
    /// with the view is what removes them.
    private final class Observers {
        private var tokens: [any NSObjectProtocol] = []
        private var monitors: [Any] = []
        func add(_ token: any NSObjectProtocol) { tokens.append(token) }
        func addMonitor(_ monitor: Any?) { if let monitor { monitors.append(monitor) } }
        func removeAll() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
            monitors.forEach(NSEvent.removeMonitor)
        }
    }

    private let observers = Observers()

    /// Matches `GuestSurfaceView`: `ViewportTransform` works in top-left view points, so the pointer
    /// location must arrive in the same space the surface is laid out in.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.removeAll()
        guard let window else { releaseCapture(); return }   // window closed while captured: give the pointer back
        window.makeFirstResponder(self)
        // The first responder does not resign when its window stops being key, so watch the window
        // and the app: a Cmd-Tab away must release every held key and let the pointer go.
        observers.add(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        })
        observers.add(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        })
        // The view never resigns first responder over a Cmd-Tab, so a caps-lock change made while we
        // were away would otherwise never reach the guest.
        observers.add(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sendLockKeys else { return }
                self.onInput(.capsLock(on: NSEvent.modifierFlags.contains(.capsLock)))
            }
        })
        // AppKit never routes a `keyUp` to the responder chain while ⌘ is held — `NSApplication`
        // receives it and drops it. Without this the guest keeps the letter made and auto-repeats it
        // forever (⌘V typing an endless "v"). A local monitor is the last place the event is visible.
        observers.addMonitor(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }
            MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return }
                self.keyUp(with: event)
            }
            return event
        })
    }

    override func becomeFirstResponder() -> Bool {
        if sendLockKeys { onInput(.capsLock(on: NSEvent.modifierFlags.contains(.capsLock))) }
        return true
    }

    override func resignFirstResponder() -> Bool { lostFocus(); return true }

    private func lostFocus() {
        onInput(.releaseAllKeys)
        releaseCapture()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Auto-repeat arrives as repeated keyDowns; the guest wants repeated makes with no break in between.
        onInput(.keyDown(keyCode: event.keyCode, mapping: keyboardMapping))
    }

    override func keyUp(with event: NSEvent) {
        onInput(.keyUp(keyCode: event.keyCode, mapping: keyboardMapping))
    }

    /// Menu key equivalents (⌘N, ⌘W, ⌘,…) keep their meaning; anything the menu bar declines falls
    /// through to keyDown and reaches the guest with ⌘ mapped per preference.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == Self.capsLockKeyCode {
            if sendLockKeys { onInput(.capsLock(on: event.modifierFlags.contains(.capsLock))) }
            return
        }
        if pointerCaptured, chordIsDown(event.modifierFlags) {
            releaseCapture()
            return
        }
        // Left and right variants share a device-independent flag; the device-dependent bits tell
        // them apart, so a held right ⌘ does not read as a second press of the left one.
        let pressed = event.modifierFlags.rawValue & Self.deviceMask(for: code) != 0
        onInput(pressed ? .keyDown(keyCode: code, mapping: keyboardMapping) : .keyUp(keyCode: code, mapping: keyboardMapping))
    }

    /// NX_DEVICE*KEYMASK bits from IOKit's IOLLEvent.h, keyed by kVK code.
    private static func deviceMask(for keyCode: UInt16) -> UInt {
        switch keyCode {
        case 0x3B: 0x0001   // left control
        case 0x38: 0x0002   // left shift
        case 0x3C: 0x0004   // right shift
        case 0x37: 0x0008   // left command
        case 0x36: 0x0010   // right command
        case 0x3A: 0x0020   // left option
        case 0x3D: 0x0040   // right option
        case 0x3E: 0x2000   // right control
        default: 0
        }
    }

    private func chordIsDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        var down: Set<ChordModifier> = []
        if flags.contains(.control) { down.insert(.control) }
        if flags.contains(.option) { down.insert(.option) }
        if flags.contains(.shift) { down.insert(.shift) }
        if flags.contains(.command) { down.insert(.command) }
        return down == releaseChord.modifiers
    }

    // MARK: Pointer

    private var tracking: NSTrackingArea?
    private var wheel = WheelAccumulator()
    private var motionCarry = CGPoint.zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Cursor (client mode)

    /// The guest's cursor shape, worn by the host pointer in client mode. nil = the guest hid it.
    var hostCursor: NSCursor? = .arrow {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard pointerMode == .client else { return }
        (hostCursor ?? CursorImage.hidden).set()
    }

    override func resetCursorRects() {
        guard pointerMode == .client else { return }
        addCursorRect(bounds, cursor: hostCursor ?? CursorImage.hidden)
    }

    // MARK: Motion

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    private func pointerMoved(_ event: NSEvent) {
        switch pointerMode {
        case .client:
            guard let t = transform() else { return }
            let p = convert(event.locationInWindow, from: nil)
            let g = t.guestPoint(fromView: p)
            onInput(.pointerPosition(x: g.x, y: g.y, viewportID: viewportID))
        case .server:
            guard pointerCaptured else { return }
            // Deltas are fractional on trackpads; carry the remainder so slow motion is not lost.
            motionCarry.x += event.deltaX; motionCarry.y += event.deltaY
            let dx = Int(motionCarry.x.rounded(.towardZero)), dy = Int(motionCarry.y.rounded(.towardZero))
            motionCarry.x -= CGFloat(dx); motionCarry.y -= CGFloat(dy)
            if dx != 0 || dy != 0 { onInput(.pointerMotion(dx: dx, dy: dy)) }
        }
    }

    // MARK: Buttons

    override func mouseDown(with event: NSEvent) { button(.left, down: true, event) }
    override func mouseUp(with event: NSEvent) { button(.left, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { button(.right, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { button(.right, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { button(.middle, down: true, event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { button(.middle, down: false, event) } }

    private func button(_ b: PointerButton, down: Bool, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        if pointerMode == .server, !pointerCaptured {
            // The grabbing click is swallowed, like spice-gtk: the user asked for the pointer, not a click.
            if down { capture() }
            return
        }
        if pointerMode == .client { pointerMoved(event) }   // the press lands where the pointer is
        onInput(down ? .buttonDown(b) : .buttonUp(b))
    }

    override func scrollWheel(with event: NSEvent) {
        guard pointerMode == .client || pointerCaptured else { return }
        let clicks = wheel.add(precise: event.hasPreciseScrollingDeltas, delta: event.scrollingDeltaY)
        if clicks != 0 { onInput(.wheel(clicks: clicks)) }
    }

    // MARK: Capture (server mode)

    private(set) var pointerCaptured = false

    /// Hide the host pointer and stop it moving; from here on the guest owns it and we forward deltas.
    private func capture() {
        guard !pointerCaptured, let window else { return }
        pointerCaptured = true
        motionCarry = .zero
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        // Park the (invisible) pointer mid-view so it stays over us however far the user moves.
        let centre = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        // CG's global space is top-left origin and is anchored to the *primary* display, not to the
        // one the window happens to be on, so the flip has to measure from `screens.first`.
        if let primary = NSScreen.screens.first {
            CGWarpMouseCursorPosition(CGPoint(x: centre.x, y: primary.frame.maxY - centre.y))
        }
        onCaptureChange(true)
    }

    func releaseCapture() {
        guard pointerCaptured else { return }
        pointerCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        onInput(.releaseAllKeys)     // the chord's own modifiers were forwarded on the way in
        onCaptureChange(false)
    }
}

extension CursorImage {
    /// BGRA straight alpha → `NSCursor`. `.first` + `byteOrder32Little` is the BGRA reading; `.last`
    /// would silently swap channels.
    var nsCursor: NSCursor? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSCursor(image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)),
                        hotSpot: NSPoint(x: hotX, y: hotY))
    }

    /// A 1×1 transparent cursor: what the pointer wears when the guest has hidden its own.
    @MainActor static let hidden = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
}
