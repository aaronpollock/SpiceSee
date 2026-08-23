import AppKit
import SwiftUI

/// One guest viewport. The framebuffer *is* the content view — zero padding, no chrome, and nothing
/// over the pixels but the transient capture HUD and the persistent release cue.
struct SessionWindowView: View {
    let session: SessionModel
    let viewport: ViewportInfo

    @State private var hudVisible = false
    @State private var hudTimer: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            MetalSurfaceView(session: session, viewport: viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(alignment: .topTrailing) {
                    if session.pointerCaptured {
                        ReleaseChordCue(chord: session.releaseChord)
                            .padding(Metric.HUD.cueInset)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hudVisible {
                        CapturedPointerHUD(chord: session.releaseChord)
                            .padding(.bottom, Metric.HUD.bottomInset)
                            .transition(.opacity)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SessionToolbar(session: session,
                                       collapsed: proxy.size.width <= Metric.Toolbar.collapseWidth)
                            // Centre in whatever height the toolbar gives us. In full screen the
                            // revealed overlay bar is taller than the windowed band, and a fixed
                            // 22pt row sat high in it with the extra space falling below.
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
        }
        .background(WindowConfigurator())
        .migrationSheet(session: session, viewport: viewport)
        .navigationTitle(session.vmName)
        .navigationSubtitle(viewport.subtitle)
        .onAppear { if session.pointerCaptured { flashHUD() } }
        .onChange(of: session.pointerCaptured) { _, captured in
            if captured { flashHUD() } else { dismissHUD() }
        }
        .onDisappear { dismissHUD() }
    }

    /// Shown the moment the pointer is captured, held for 2 s, then faded out over 250 ms.
    private func flashHUD() {
        hudVisible = true
        hudTimer?.cancel()
        hudTimer = Task {
            try? await Task.sleep(for: Metric.HUD.visibleDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Metric.HUD.fadeDuration.seconds)) { hudVisible = false }
        }
    }

    private func dismissHUD() {
        hudTimer?.cancel()
        hudTimer = nil
        hudVisible = false
    }
}

// MARK: - Toolbar

private struct SessionToolbar: View {
    @Bindable var session: SessionModel
    let collapsed: Bool
    @State private var isFullScreen = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(alignment: .center, spacing: Metric.Toolbar.itemGap) {
            ctrlAltDel
            divider
            ToolbarGlyphButton(help: isFullScreen ? "Leave Full Screen" : "Full Screen") {
                NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            } glyph: {
                ToolbarGlyph(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(isFullScreen ? Color.chiliRed : Color.primary)
            }

            if collapsed {
                overflow
            } else {
                scaling
                hiDPI
                clipboard
                mute
            }

            divider
            AgentChip(state: session.agent, collapsed: collapsed)
        }
        .background(WindowReader { hostWindow = $0 })
        // Scoped to this window: a multi-monitor session has several, and an unscoped notification
        // would light up every toolbar when any one of them entered full screen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if isThisWindow(note) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if isThisWindow(note) { isFullScreen = false }
        }
    }

    private func isThisWindow(_ note: Notification) -> Bool {
        // If the host window could not be resolved, accept the event rather than never showing the
        // state at all — a single-window session is the common case and is still correct.
        guard let hostWindow else { return true }
        return (note.object as? NSWindow) === hostWindow
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: Metric.Toolbar.dividerHeight)
    }

    /// Spelled out rather than ⌃⌥⌦ — the glyphs read as a shortcut to press, not a button to click.
    private var ctrlAltDel: some View {
        Button { session.sendCtrlAltDel() } label: {
            Text("Ctrl-Alt-Del")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize()
                .padding(.horizontal, 8)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help("Send Ctrl-Alt-Del to the guest")
    }

    private var scaling: some View {
        Picker("Scaling", selection: $session.scaling) {
            ForEach(ScalingMode.allCases) { mode in
                Text(mode.label).font(.system(size: 11)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Scale the guest to fit the window, or show it 1:1")
    }

    private var hiDPI: some View {
        ToolbarGlyphButton(help: "Send backing pixels to the guest (HiDPI)") {
            session.hiDPI.toggle()
        } glyph: {
            Text("2×")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.hiDPI ? Color.chiliRed : Color.secondary)
        }
    }

    private var clipboard: some View {
        ToolbarGlyphButton(help: session.clipboardSync ? "Clipboard sync is on" : "Clipboard sync is off") {
            session.clipboardSync.toggle()
        } glyph: {
            ToolbarGlyph("doc.on.clipboard")
                .foregroundStyle(session.clipboardSync ? Color.green : Color.red)
                .overlay {
                    // SF Symbols has no `doc.on.clipboard.slash`, so the off state draws the slash.
                    if !session.clipboardSync {
                        Capsule()
                            .fill(Color.red)
                            .frame(width: Metric.Toolbar.glyph * 1.2, height: 1.2)
                            .rotationEffect(.degrees(-45))
                    }
                }
        }
    }

    private var mute: some View {
        ToolbarGlyphButton(help: session.muted ? "Guest audio is muted" : "Guest audio is playing") {
            session.muted.toggle()
        } glyph: {
            ToolbarGlyph(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
    }

    /// At ≤700 pt the four secondary controls fold into one menu; the rest never collapse.
    private var overflow: some View {
        Menu {
            Picker("Scaling", selection: $session.scaling) {
                ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("HiDPI (2×)", isOn: $session.hiDPI)
            Toggle("Clipboard Sync", isOn: $session.clipboardSync)
            Toggle("Mute Guest Audio", isOn: $session.muted)
        } label: {
            ToolbarGlyph("ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Metric.Toolbar.itemSize.width, height: Metric.Toolbar.itemSize.height)
        .help("More session controls")
    }

}

private struct ToolbarGlyph: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Metric.Toolbar.glyph, weight: .medium))
    }
}

/// Hands back the NSWindow hosting this SwiftUI content.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ToolbarGlyphButton<Glyph: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let glyph: Glyph

    var body: some View {
        Button(action: action) {
            glyph.frame(width: Metric.Toolbar.itemSize.width)
        }
        .buttonStyle(ToolbarButtonStyle())
        .help(help)
    }
}

/// Hover and pressed states are macOS's own: a toolbar item's native highlight is taller than the
/// design's 22pt control, so any background we drew ourselves sat inside it and the highlight
/// appeared to overhang. On/off state is carried by colour instead.
private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: Metric.Toolbar.itemSize.height)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// The session window wears the compact unified toolbar; the scene can't say so for us.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StyleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class StyleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.toolbarStyle = .unifiedCompact
        }
    }
}

// MARK: - Agent status

struct AgentChip: View {
    let state: AgentState
    let collapsed: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            dot
            if !collapsed {
                Text(state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(labelColor)
                    .fixedSize()
            }
        }
        .padding(.horizontal, collapsed ? 0 : 6)
        .frame(width: collapsed ? Metric.HUD.cueHeight : nil, height: Metric.Toolbar.itemSize.height)
        .fixedSize()
        .help(state.tooltip)
    }

    private var dot: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        return Group {
            switch state {
            case .absent: shape.strokeBorder(dotColor, lineWidth: 1.6)
            case .connected, .negotiating: shape.fill(dotColor)
            }
        }
        .frame(width: 9, height: 9)
        .overlay {
            if state == .connected {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(dotColor.opacity(0.18), lineWidth: 2)
                    .padding(-2)
            }
        }
    }

    /// `nil` for the negotiating state, which is intentionally colourless.
    private var base: NSColor? {
        switch state {
        case .connected: .systemGreen
        case .absent: .systemOrange
        case .negotiating: nil
        }
    }

    private var dotColor: Color {
        base.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.5)
    }

    /// System colours are too light against their own tinted fill in Aqua, so the text darkens there.
    private var labelColor: Color {
        guard let base else { return .secondary }
        guard colorScheme == .light else { return Color(nsColor: base) }
        return Color(nsColor: base.blended(withFraction: 0.4, of: .black) ?? base)
    }


}

// MARK: - Captured pointer

struct CapturedPointerHUD: View {
    let chord: ReleaseChord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 14, weight: .medium))
            Text("Pointer captured — press ")
                + Text(chord.display).font(.system(size: Metric.HUD.text, weight: .semibold))
                + Text(" to release")
        }
        .font(.system(size: Metric.HUD.text))
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: Metric.HUD.capsuleHeight)
        .background(.thickMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator, lineWidth: Metric.HUD.stroke) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .allowsHitTesting(false)
    }
}

/// Stays for as long as the pointer is captured, so the escape hatch is never more than a glance away.
private struct ReleaseChordCue: View {
    let chord: ReleaseChord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.chiliRed)
            Text(chord.display)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 9)
        .frame(height: Metric.HUD.cueHeight)
        .background(.thickMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator, lineWidth: Metric.HUD.stroke) }
        .opacity(Metric.HUD.cueOpacity)
        .allowsHitTesting(false)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - Previews

@MainActor
private func previewSession(_ scenario: MockSessionBackend.Scenario) -> SessionModel {
    let session = SessionModel(backend: MockSessionBackend(scenario: scenario))
    session.connect(SavedConnection(name: "win11-desk", host: "192.168.1.20"), password: nil)
    return session
}

private let previewViewport = ViewportInfo(id: 0, index: 0, total: 2, width: 1920, height: 1080)

#Preview("Windowed · agent connected") {
    SessionWindowView(session: previewSession(.desktop), viewport: previewViewport)
        .frame(width: Metric.Window.session.width, height: Metric.Window.session.height)
        .preferredColorScheme(.light)
}

#Preview("Captured pointer · no agent") {
    let session = previewSession(.noAgent)
    session.scaling = .oneToOne
    return SessionWindowView(session: session, viewport: previewViewport)
        .frame(width: Metric.Window.session.width, height: Metric.Window.session.height)
        .preferredColorScheme(.dark)
}

#Preview("Narrow · toolbar condensed") {
    SessionWindowView(session: previewSession(.noAgent),
                      viewport: ViewportInfo(id: 0, index: 0, total: 1, width: 720, height: 400))
        .frame(width: 640, height: 400)
}
