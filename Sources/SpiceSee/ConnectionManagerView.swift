import SwiftUI
import UniformTypeIdentifiers

/// Artboard 01 — the connection manager window. Sidebar of saved hosts + detail pane for the
/// selected one, with the in-progress connect state taking over the detail pane inline.
struct ConnectionManagerView: View {
    let store: ConnectionStore
    let settings: AppSettings
    let session: SessionModel

    @Environment(\.openWindow) private var openWindow

    /// Set by the − button; non-nil is what presents the confirmation.
    @State private var pendingDeletion: SavedConnection?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .connectFailureSheet(session: session, onEditConnection: {}, onFetchVV: openVVFile)
        }
        .sizesWindow(to: Metric.Window.connectionManager)
        .opensSessionWindows(session: session, settings: settings)
        .alert(deletionTitle, isPresented: isConfirmingDeletion) {
            // Cancel is the default action: deleting a host is destructive and unrecoverable.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                if let pendingDeletion { store.remove(pendingDeletion.id) }
            }
        } message: {
            Text("This removes the saved connection from SpiceSee. The guest itself is not affected.")
        }
    }

    private var deletionTitle: String {
        "Delete “\(pendingDeletion?.name ?? "")”?"
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.connections.isEmpty {
                SidebarEmptyState()
            } else {
                List(selection: selectionBinding) {
                    ForEach(store.filtered) { connection in
                        ConnectionRowView(
                            connection: connection,
                            isSelected: connection.id == store.selection,
                            isConnecting: isConnecting(connection),
                            isConnected: isConnected(connection)
                        )
                        .tag(connection.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.sidebar)
            }
            sidebarBottomBar
        }
        .searchable(text: searchTextBinding, placement: .sidebar)
        .navigationSplitViewColumnWidth(min: Metric.Sidebar.minWidth, ideal: Metric.Sidebar.width, max: Metric.Sidebar.maxWidth)
    }

    private var sidebarBottomBar: some View {
        HStack(spacing: 2) {
            sidebarButton(systemName: "plus", action: store.add)
            sidebarButton(systemName: "minus", action: removeSelected, disabled: store.selection == nil)
            Spacer()
        }
        .padding(.leading, Metric.Sidebar.bottomBarInsetLeading)
        .padding(.trailing, Metric.Sidebar.bottomBarInsetTrailing)
        .frame(height: Metric.Sidebar.bottomBarHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
    }

    private func sidebarButton(systemName: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(SidebarButtonStyle())
        .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .secondaryLabelColor))
        .disabled(disabled)
    }

    private func removeSelected() {
        pendingDeletion = store.selected
    }

    private func isConnecting(_ connection: SavedConnection) -> Bool {
        guard session.connection?.id == connection.id else { return false }
        if case .connecting = session.phase { return true }
        return false
    }

    /// Closing the display windows leaves the session running, so this stays true until the user
    /// disconnects — it is what the sidebar dot and the detail pane's Disconnect button key off.
    private func isConnected(_ connection: SavedConnection) -> Bool {
        session.connection?.id == connection.id && session.phase == .connected
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selected = store.selected, isConnecting(selected) {
            ConnectingProgressView(
                vmName: selected.name,
                endpoint: selected.endpoint,
                usesTLS: selected.usesTLS,
                completed: session.completedSteps,
                onCancel: session.cancel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        } else if let selected = store.selected {
            let connectionBinding = Binding<SavedConnection>(
                get: { store.selected ?? selected },
                set: { store.selected = $0 }
            )
            ConnectionDetailView(
                connection: connectionBinding,
                session: session,
                settings: settings,
                onConnect: { password in session.connect(connectionBinding.wrappedValue, password: password) },
                onDuplicate: { store.duplicate(connectionBinding.wrappedValue) },
                onShowDisplays: { showAllDisplays(session, using: openWindow) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            DetailEmptyState(onAdd: store.add, onOpenFile: openVVFile)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func openVVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vvConnection]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importVV(at: url)
    }

    // MARK: Bindings

    private var searchTextBinding: Binding<String> {
        Binding(get: { store.searchText }, set: { store.searchText = $0 })
    }

    private var selectionBinding: Binding<SavedConnection.ID?> {
        Binding(get: { store.selection }, set: { store.selection = $0 })
    }
}

/// The +/− buttons. A bare `.plain` button hit-tests only where its label draws, so the 24×22pt
/// frame around the glyph was dead space — the button fired only on a direct hit on the `+` or `−`
/// itself. The content shape claims the whole frame, and the fill deepens while pressed so a click
/// is visibly acknowledged.
private struct SidebarButtonStyle: ButtonStyle {
    private let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(shape)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.20 : 0.06)))
    }
}

/// One sidebar row — 216×40 pt. Normal, selected (accent fill) and connecting (trailing spinner).
struct ConnectionRowView: View {
    let connection: SavedConnection
    let isSelected: Bool
    let isConnecting: Bool
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: Metric.Sidebar.rowTitle, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color(nsColor: .labelColor))
                Text(subtitle)
                    .font(.system(size: Metric.Sidebar.rowSubtitle))
                    .foregroundStyle(subtitleColor)
            }
            .lineLimit(1)
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: Metric.Sidebar.statusDot, height: Metric.Sidebar.statusDot)
            }
        }
        .padding(.vertical, Metric.Sidebar.rowInsetV)
        .padding(.horizontal, Metric.Sidebar.rowInsetH)
        .frame(maxWidth: .infinity, minHeight: Metric.Sidebar.rowSize.height, maxHeight: Metric.Sidebar.rowSize.height, alignment: .leading)
        .background(isSelected ? Color.chiliRed : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Metric.Sidebar.rowRadius))
    }

    private var subtitle: String {
        let endpoint = "\(connection.host):\(connection.port)"
        if isConnecting { return "\(endpoint) · Connecting…" }
        if isConnected { return "\(endpoint) · Connected" }
        return connection.sidebarSubtitle
    }

    private var subtitleColor: Color {
        isSelected ? Color.white.opacity(Metric.Sidebar.selectedSecondaryOpacity) : Color(nsColor: .secondaryLabelColor)
    }
}

/// First-launch state: replaces the sidebar's List entirely. Illustration is placeholder art —
/// three stacked window frames drawn in SwiftUI, since final assets aren't supplied yet.
struct SidebarEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            StackedWindowsIllustration()
            Text("No saved connections")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 26)
    }
}

private struct StackedWindowsIllustration: View {
    var body: some View {
        ZStack {
            windowGlyph.offset(x: -18, y: 12)
            windowGlyph.offset(x: 0, y: 0)
            windowGlyph.offset(x: 18, y: -12)
        }
        .frame(width: Metric.EmptyState.illustration.width, height: Metric.EmptyState.illustration.height)
    }

    private var windowGlyph: some View {
        let tertiary = Color(nsColor: .tertiaryLabelColor)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(tertiary, lineWidth: 1.5)
            .frame(width: 54, height: 36)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(tertiary)
                    .frame(height: 1.5)
                    .padding(.top, 8)
            }
    }
}

#Preview("Light · host selected") {
    ConnectionManagerView(store: .preview, settings: AppSettings(), session: SessionModel(backend: MockSessionBackend()))
        .frame(width: Metric.Window.connectionManager.width, height: Metric.Window.connectionManager.height)
}

#Preview("Dark · host selected") {
    ConnectionManagerView(store: .preview, settings: AppSettings(), session: SessionModel(backend: MockSessionBackend()))
        .frame(width: Metric.Window.connectionManager.width, height: Metric.Window.connectionManager.height)
        .preferredColorScheme(.dark)
}

#Preview("First launch · empty state") {
    ConnectionManagerView(store: ConnectionStore(connections: []), settings: AppSettings(), session: SessionModel(backend: MockSessionBackend()))
        .frame(width: Metric.Window.connectionManager.width, height: Metric.Window.connectionManager.height)
}
