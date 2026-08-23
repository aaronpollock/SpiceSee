import SwiftUI

struct ConnectionDetailView: View {
    @Binding var connection: SavedConnection
    let session: SessionModel
    let settings: AppSettings
    var onConnect: (String) -> Void
    var onDuplicate: () -> Void
    var body: some View { Text("ConnectionDetailView") }
}

struct AdvancedSection: View {
    @Binding var settings: AdvancedSettings
    var body: some View { Text("Advanced") }
}

struct DetailEmptyState: View {
    var onAdd: () -> Void
    var onOpenFile: () -> Void
    var body: some View { Text("No Connection Selected") }
}
