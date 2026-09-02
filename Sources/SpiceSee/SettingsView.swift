import SwiftUI
import Sparkle

struct SettingsView: View {
    let settings: AppSettings
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView {
            GeneralPane(settings: settings, openAcknowledgements: { openWindow(id: "acknowledgements") })
                .tabItem { Label("General", systemImage: "gearshape") }
                .frame(width: Metric.Window.preferences.width, height: Metric.Settings.generalHeight)

            KeyboardPane(settings: settings)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .frame(width: Metric.Window.preferences.width, height: Metric.Settings.keyboardHeight)

            UpdatesPane(settings: settings, updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.up.circle") }
                .frame(width: Metric.Window.preferences.width, height: Metric.Settings.updatesHeight)
        }
        .tabViewStyle(.automatic)
    }
}

// MARK: - Binding helper

private extension AppSettings {
    /// A saving binding for a settings property — every edit persists immediately.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0; self.save() }
        )
    }
}

// MARK: - Shared row layout

/// A 140pt trailing-aligned label paired with content, at the pane's row rhythm.
private struct SettingsRow<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .frame(width: Metric.Settings.labelColumn, alignment: .trailing)
            content()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    let settings: AppSettings
    let openAcknowledgements: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
            SettingsRow(label: "Default scaling:") {
                Picker(selection: settings.binding(\.defaultScaling)) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.settingsLabel).tag(mode)
                    }
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
            }

            SettingsRow(label: "HiDPI by default:", alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("", isOn: settings.binding(\.hiDPIByDefault))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Text("Off sends logical points, so the guest renders at 1×. On sends backing pixels — sharper, but the guest desktop gets very small unless it scales.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow(label: "On connect:", alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Open one window per guest monitor", isOn: settings.binding(\.openWindowPerMonitor))
                    Toggle("Sync clipboard when the agent is available", isOn: settings.binding(\.syncClipboardWhenAgentAvailable))
                    Toggle("Delete .vv files after connecting", isOn: settings.binding(\.deleteVVAfterConnecting))
                }
                .toggleStyle(.checkbox)
            }

            SettingsRow(label: "On disconnect:") {
                Toggle("Remove spent Proxmox connections without asking", isOn: settings.binding(\.removeSingleUseOnDisconnect))
                    .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)

            HStack {
                Text("Per-connection settings in Advanced override these defaults.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Acknowledgements…", action: openAcknowledgements)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
    }
}

// MARK: - Keyboard

private struct KeyboardPane: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
            SettingsRow(label: "Modifier mapping:", alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    ModifierMappingRow(hostGlyph: "⌘", mapsTo: settings.binding(\.commandMapsTo))
                    ModifierMappingRow(hostGlyph: "⌥", mapsTo: settings.binding(\.optionMapsTo))
                }
            }

            SettingsRow(label: "Release chord:", alignment: .top) {
                KeycapPicker(chord: settings.binding(\.releaseChord))
            }

            SettingsRow(label: "") {
                Toggle("Send lock keys (⇪, Num, Scroll) to the guest", isOn: settings.binding(\.sendLockKeys))
                    .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)

            Text("Mapping is positional and layout-independent (kVK_* → XT set-1 scancodes). macOS keeps system shortcuts such as ⌘Tab; use Ctrl-Alt-Del in the toolbar for the guest's secure attention sequence.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }
}

/// One "⌘ → Super / Ctrl / Alt" row: a static keycap for the host modifier, an arrow, and the guest choices.
private struct ModifierMappingRow: View {
    let hostGlyph: String
    @Binding var mapsTo: GuestModifier

    var body: some View {
        HStack(spacing: 8) {
            Keycap(label: hostGlyph, isSelected: false)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack(spacing: Metric.Settings.keycapGap) {
                ForEach(GuestModifier.allCases) { modifier in
                    Keycap(label: modifier.label, isSelected: mapsTo == modifier) {
                        mapsTo = modifier
                    }
                }
            }
        }
    }
}

/// Toggleable ⌃ ⌥ ⇧ ⌘ keycaps that build a `ReleaseChord`, enforcing its two-modifier minimum.
struct KeycapPicker: View {
    @Binding var chord: ReleaseChord

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: Metric.Settings.keycapGap) {
                ForEach(ChordModifier.allCases) { modifier in
                    Keycap(label: modifier.glyph, isSelected: chord.modifiers.contains(modifier)) {
                        toggle(modifier)
                    }
                }
            }
            Text("Click keycaps to build the chord — two modifiers minimum")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ modifier: ChordModifier) {
        var next = chord.modifiers
        if next.contains(modifier) {
            next.remove(modifier)
        } else {
            next.insert(modifier)
        }
        guard next.count >= 2 else { return }
        chord.modifiers = next
    }
}

/// A 34×26pt keycap: selected = chiliRed fill with a white glyph, unselected = controlBackground fill with a separator stroke.
/// A `nil` action renders a static, non-interactive keycap (used for the host-modifier glyph).
private struct Keycap: View {
    let label: String
    let isSelected: Bool
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(.plain)
        } else {
            face
        }
    }

    private var face: some View {
        Text(label)
            .font(.system(size: 12))
            .minimumScaleFactor(0.8)
            .lineLimit(1)
            .foregroundStyle(isSelected ? .white : Color.primary)
            .frame(width: Metric.Settings.keycapSize.width, height: Metric.Settings.keycapSize.height)
            .background(isSelected ? Color.chiliRed : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color(nsColor: .separatorColor))
            )
    }
}

// MARK: - Updates

/// The two automatic toggles are Sparkle's own persisted properties, mirrored into local state
/// and written back only on a user change (Sparkle's documented pattern — the updater must not be
/// poked on every render). Pre-release opt-in is ours; `UpdaterDelegate` reads it.
private struct UpdatesPane: View {
    let settings: AppSettings
    let updater: SPUUpdater
    @State private var checksAutomatically: Bool
    @State private var downloadsAutomatically: Bool

    init(settings: AppSettings, updater: SPUUpdater) {
        self.settings = settings
        self.updater = updater
        _checksAutomatically = State(initialValue: updater.automaticallyChecksForUpdates)
        _downloadsAutomatically = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .onChange(of: checksAutomatically) { _, on in updater.automaticallyChecksForUpdates = on }

            VStack(alignment: .leading, spacing: Metric.Settings.rowRhythm) {
                Toggle("Download and install in the background", isOn: $downloadsAutomatically)
                    .disabled(!checksAutomatically)
                    .onChange(of: downloadsAutomatically) { _, on in updater.automaticallyDownloadsUpdates = on }
                Toggle("Include pre-release builds", isOn: settings.binding(\.includePrereleases))
            }
            .padding(.leading, 20)

            Spacer(minLength: 0)

            HStack {
                Text(settings.versionSummary(lastChecked: updater.lastUpdateCheckDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }
}

// MARK: - Previews

#Preview("General") {
    GeneralPane(settings: AppSettings(), openAcknowledgements: {})
        .frame(width: Metric.Window.preferences.width, height: Metric.Settings.generalHeight)
        .preferredColorScheme(.light)
}

#Preview("Keyboard") {
    KeyboardPane(settings: AppSettings())
        .frame(width: Metric.Window.preferences.width, height: Metric.Settings.keyboardHeight)
        .preferredColorScheme(.dark)
}

#Preview("Updates") {
    UpdatesPane(settings: AppSettings(),
                updater: SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater)
        .frame(width: Metric.Window.preferences.width, height: Metric.Settings.updatesHeight)
        .preferredColorScheme(.light)
}
