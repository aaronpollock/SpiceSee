import AppKit

/// Receives every host event meant for the guest. Sits over the Metal surface, fills it, and is the
/// window's first responder while a session is on screen. Keyboard here; pointer in the extension
/// below (Task 11); cursor shape in `MetalSurfaceView` (Task 12).
final class GuestInputView: NSView {
    var onInput: (InputEvent) -> Void = { _ in }
    var onCaptureChange: (Bool) -> Void = { _ in }
    var keyboardMapping = KeyboardMapping()
    var sendLockKeys = true
    var pointerMode: PointerMode = .client { didSet { if pointerMode == .client { releaseCapture() } } }
    var releaseChord: ReleaseChord = .controlOption

    /// kVK_CapsLock. Caps lock is synced as lock state (INPUTS_KEY_MODIFIERS), never as a scancode — see SpiceKit.KeyMap.
    private static let capsLockKeyCode: UInt16 = 0x39

    /// Block observers are not unregistered for you. A nonisolated `deinit` may not read main-actor
    /// storage in Swift 6, so the tokens live one level down: dropping the box with the view is what
    /// removes them.
    private final class Observers {
        private var tokens: [any NSObjectProtocol] = []
        func add(_ token: any NSObjectProtocol) { tokens.append(token) }
        func removeAll() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    private let observers = Observers()

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

    // MARK: Capture state (behaviour in Task 11)

    private(set) var pointerCaptured = false
    func releaseCapture() {}   // replaced in Task 11
}
