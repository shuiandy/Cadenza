import SwiftUI

struct RecordingsListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        RecordingsContentView(recordings: appState.recordings)
    }
}
