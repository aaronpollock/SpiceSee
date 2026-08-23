import SwiftUI

struct ConnectionDetailView: View {
    @Binding var connection: SavedConnection
    let session: SessionModel
    let settings: AppSettings
    var onConnect: (String) -> Void
    var onDuplicate: () -> Void

    @State private var password = ""
    @AppStorage private var advancedExpanded: Bool

    init(connection: Binding<SavedConnection>, session: SessionModel, settings: AppSettings,
         onConnect: @escaping (String) -> Void, onDuplicate: @escaping () -> Void) {
        self._connection = connection
        self.session = session
        self.settings = settings
        self.onConnect = onConnect
        self.onDuplicate = onDuplicate
        self._advancedExpanded = AppStorage(wrappedValue: false, "ConnectionDetailView.advancedExpanded.\(connection.wrappedValue.id.uuidString)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { fields.padding(20) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: connection.id) { password = "" }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(connection.name)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tagText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Metric.Window.titlebar)
    }

    private var tagText: String {
        connection.tlsPort != nil ? "SPICE · TLS" : "SPICE"
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Metric.Form.rowRhythm) {
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("Host:")
                FormTextField(text: $connection.host)
            }
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("Port:")
                FormTextField(text: portBinding)
                    .frame(width: 84)
                FormLabel("TLS:", width: 52)
                FormTextField(text: tlsPortBinding, placeholder: "port")
                    .frame(width: 84)
                    .help(tlsHelp)
            }
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("Password:")
                FormTextField(text: $password, isSecure: true)
            }
            HStack(spacing: Metric.Form.labelGap) {
                Color.clear.frame(width: Metric.Form.labelColumn, height: 1)
                Toggle("Save password in Keychain", isOn: $connection.savePasswordInKeychain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }

            Divider()

            DisclosureGroup(isExpanded: $advancedExpanded) {
                AdvancedSection(settings: $connection.advanced)
                    .padding(.leading, 14)
                    .padding(.top, 11)
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                        .font(.system(size: 13, weight: .semibold))
                    if !advancedExpanded {
                        Text(advancedSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

        }
    }

    private var footer: some View {
            HStack(alignment: .center, spacing: Metric.Form.labelGap) {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Duplicate", action: onDuplicate)
                    .buttonStyle(.bordered)
                    .frame(height: 28)
                Button("Connect") { onConnect(password) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.chiliRed)
                    .keyboardShortcut(.defaultAction)
                    .frame(height: 28)
            }
    }

    private let tlsHelp = "Encrypted SPICE port. Proxmox .vv files supply this — leave it empty to connect without TLS."

    private var portBinding: Binding<String> {
        Binding(
            get: { String(connection.port) },
            set: { if let value = UInt16($0) { connection.port = value } }
        )
    }

    private var tlsPortBinding: Binding<String> {
        Binding(
            get: { connection.tlsPort.map(String.init) ?? "" },
            set: { connection.tlsPort = $0.isEmpty ? nil : UInt16($0) }
        )
    }

    private var advancedSummary: String {
        let a = connection.advanced
        return "HiDPI \(a.hiDPI ? "on" : "off") · ⌘→\(a.commandMapsTo.label) · ⌥→\(a.optionMapsTo.label) · release \(a.releaseChord.display)"
    }

    private var footerText: String {
        guard let lastConnected = connection.lastConnected else { return "Never connected" }
        let formatter = DateFormatter()
        let when: String
        if Calendar.current.isDateInToday(lastConnected) {
            formatter.dateFormat = "HH:mm"
            when = "Today \(formatter.string(from: lastConnected))"
        } else if Calendar.current.isDateInYesterday(lastConnected) {
            formatter.dateFormat = "HH:mm"
            when = "Yesterday \(formatter.string(from: lastConnected))"
        } else {
            formatter.dateFormat = "d MMM"
            when = formatter.string(from: lastConnected)
        }
        let agentClause = connection.agentWasPresent ? " · agent was present" : ""
        return "Last connected \(when)\(agentClause)"
    }
}

struct AdvancedSection: View {
    @Binding var settings: AdvancedSettings

    private let labelWidth: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("HiDPI:", width: labelWidth)
                Toggle("", isOn: $settings.hiDPI)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Send backing pixels · guest renders at 2×")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("⌘ maps to:", width: labelWidth)
                ModifierPicker(selection: $settings.commandMapsTo, options: [.super, .ctrl])
                FormLabel("⌥ maps to:", width: 74)
                ModifierPicker(selection: $settings.optionMapsTo, options: [.alt, .super])
            }
            HStack(spacing: Metric.Form.labelGap) {
                FormLabel("Release chord:", width: labelWidth)
                HStack(spacing: 4) {
                    ForEach(ChordModifier.allCases.filter { settings.releaseChord.modifiers.contains($0) }) { modifier in
                        Keycap(glyph: modifier.glyph)
                    }
                    Text("Releases a captured pointer in server mode")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }
}

struct DetailEmptyState: View {
    var onAdd: () -> Void
    var onOpenFile: () -> Void

    var body: some View {
        VStack(spacing: Metric.EmptyState.gap) {
            AppIconGlyph(size: Metric.EmptyState.glyph)
            Text("No Connection Selected")
                .font(.system(size: Metric.EmptyState.title, weight: .semibold))
            bodyText
                .font(.system(size: Metric.EmptyState.body))
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metric.EmptyState.maxBodyWidth)
            HStack(spacing: 10) {
                Button("Add Connection…", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.chiliRed)
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open .vv File…", action: onOpenFile)
                    .buttonStyle(.bordered)
                    .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.top, 2)
            Text("⌘N   ⌘O")
                .font(.mono(10.5))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var bodyText: Text {
        Text("Add a QEMU or Proxmox host to connect directly — or open a ")
            .foregroundColor(.secondary)
        + Text(".vv")
            .fontWeight(.bold)
            .foregroundColor(.primary)
        + Text(" file downloaded from the Proxmox web console and SpiceSee will connect straight away.")
            .foregroundColor(.secondary)
    }
}

/// A trailing-aligned form label, sized to `Metric.Form.labelColumn` by default.
private struct FormLabel: View {
    var text: String
    var width: CGFloat = Metric.Form.labelColumn

    init(_ text: String, width: CGFloat = Metric.Form.labelColumn) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .frame(width: width, alignment: .trailing)
    }
}

/// A 24pt-tall, 6pt-radius text field matching the form's field styling.
private struct FormTextField: View {
    @Binding var text: String
    var isSecure = false
    var placeholder = ""

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: Metric.Form.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Metric.Form.fieldRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.Form.fieldRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

/// Two-option pill picker used for the ⌘/⌥ guest-modifier mappings.
private struct ModifierPicker: View {
    @Binding var selection: GuestModifier
    var options: [GuestModifier]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .font(.system(size: 12))
        .frame(width: 108)
    }
}

/// One glyph of the release chord, drawn as a keycap.
private struct Keycap: View {
    var glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 12))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }
}

/// The app-icon concept, drawn with shapes: a dark screen with a chili pepper on it.
/// The real app icon, so this never drifts from Assets.xcassets/AppIcon.
private struct AppIconGlyph: View {
    var size: CGFloat = 56

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private struct DetailPreviewHost: View {
    @State var connection: SavedConnection

    var body: some View {
        ConnectionDetailView(
            connection: $connection,
            session: SessionModel(backend: MockSessionBackend(scenario: .desktop)),
            settings: AppSettings(),
            onConnect: { _ in },
            onDuplicate: {}
        )
    }
}

#Preview("Light · Advanced expanded") {
    let connection = ConnectionStore.preview.connections[0]
    UserDefaults.standard.set(true, forKey: "ConnectionDetailView.advancedExpanded.\(connection.id.uuidString)")
    return DetailPreviewHost(connection: connection)
        .frame(width: 528, height: 468)
}

#Preview("Dark · Advanced collapsed") {
    let connection = ConnectionStore.preview.connections[0]
    return DetailPreviewHost(connection: connection)
        .frame(width: 528, height: 468)
        .preferredColorScheme(.dark)
}

#Preview("No Connection Selected") {
    DetailEmptyState(onAdd: {}, onOpenFile: {})
        .frame(width: 528, height: 468)
}
