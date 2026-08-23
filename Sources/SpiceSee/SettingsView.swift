import SwiftUI

struct SettingsView: View {
    let settings: AppSettings
    var body: some View { Text("Settings") }
}

struct KeycapPicker: View {
    @Binding var chord: ReleaseChord
    var body: some View { Text(chord.display) }
}
