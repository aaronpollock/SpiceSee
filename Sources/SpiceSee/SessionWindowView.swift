import SwiftUI

struct SessionWindowView: View {
    let session: SessionModel
    let viewport: ViewportInfo
    var body: some View { Text("SessionWindowView") }
}

struct AgentChip: View {
    let state: AgentState
    let collapsed: Bool
    var body: some View { Text(state.label) }
}

struct CapturedPointerHUD: View {
    let chord: ReleaseChord
    var body: some View { Text("Pointer captured") }
}
