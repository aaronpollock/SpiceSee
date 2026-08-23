import SwiftUI

struct ConnectingProgressView: View {
    let vmName: String
    let endpoint: String
    let usesTLS: Bool
    let completed: Set<ConnectStep>
    var onCancel: () -> Void
    var body: some View { Text("Connecting…") }
}

struct FailureSheet: View {
    let failure: ConnectFailure
    @Binding var password: String
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onSecondary: () -> Void
    var body: some View { Text(failure.title) }
}

struct MigrationSheet: View {
    let offer: MigrationOffer
    @Binding var reconnectAutomatically: Bool
    var onCancel: () -> Void
    var onReconnect: () -> Void
    var body: some View { Text("Migrated") }
}
