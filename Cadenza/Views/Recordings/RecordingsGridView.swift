import SwiftUI

struct RecordingsGridView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        RecordingsContentView(recordings: appState.recordings)
    }
}
