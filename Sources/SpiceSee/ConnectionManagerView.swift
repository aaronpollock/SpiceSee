import SwiftUI
import UniformTypeIdentifiers

/// Artboard 01 — the connection manager window. Sidebar of saved hosts + detail pane for the
/// selected one, with the in-progress connect state taking over the detail pane inline.
struct ConnectionManagerView: View {
    let store: ConnectionStore
    let settings: AppSettings
    let session: SessionModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .connectFailureSheet(session: session, onEditConnection: {}, onFetchVV: openVVFile)
        }
        .opensSessionWindows(session: session, settings: settings)
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
                            isConnecting: isConnecting(connection)
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
        .padding(.horizontal, 6)
        .frame(height: 30)
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
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .secondaryLabelColor))
        .disabled(disabled)
    }

    private func removeSelected() {
        guard let id = store.selection else { return }
        store.remove(id)
    }

    private func isConnecting(_ connection: SavedConnection) -> Bool {
        guard session.connection?.id == connection.id else { return false }
        if case .connecting = session.phase { return true }
        return false
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
                onDuplicate: { store.duplicate(connectionBinding.wrappedValue) }
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

/// One sidebar row — 216×40 pt. Normal, selected (accent fill) and connecting (trailing spinner).
struct ConnectionRowView: View {
    let connection: SavedConnection
    let isSelected: Bool
    let isConnecting: Bool

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
            }
        }
        .padding(.vertical, Metric.Sidebar.rowInsetV)
        .padding(.horizontal, Metric.Sidebar.rowInsetH)
        .frame(maxWidth: .infinity, minHeight: Metric.Sidebar.rowSize.height, maxHeight: Metric.Sidebar.rowSize.height, alignment: .leading)
        .background(isSelected ? Color.chiliRed : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Metric.Sidebar.rowRadius))
    }

    private var subtitle: String {
        isConnecting ? "\(connection.host):\(connection.port) · Connecting…" : connection.sidebarSubtitle
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
