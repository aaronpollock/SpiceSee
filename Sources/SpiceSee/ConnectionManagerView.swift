import SwiftUI

struct ConnectionManagerView: View {
    let store: ConnectionStore
    let settings: AppSettings
    let session: SessionModel
    var body: some View { Text("ConnectionManagerView") }
}

struct ConnectionRowView: View {
    let connection: SavedConnection
    let isSelected: Bool
    let isConnecting: Bool
    var body: some View { Text(connection.name) }
}

struct SidebarEmptyState: View {
    var body: some View { Text("No saved connections") }
}
