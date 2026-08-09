import SwiftUI

struct MeetingDetailView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @State private var selectedTab = "transcript"

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("View", selection: $selectedTab) {
                Text("Transcript").tag("transcript")
                Text("Summary").tag("summary")
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            if selectedTab == "transcript" {
                transcriptView
            } else {
                summaryView
            }
        }
    }

    // MARK: - Transcript Tab

    private var transcriptView: some View {
        Group {
            if appState.liveTranscriptSegments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.bubble",
                    description: Text("Record a meeting to see the transcript")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.liveTranscriptSegments) { segment in
                            TranscriptBubble(segment: segment)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Summary Tab

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let currentID = appState.currentRecordingID, appState.isGeneratingSummary(for: currentID) {
                    // Streaming summary
                    if !appState.summaryStreamedText.isEmpty {
                        Text(appState.summaryStreamedText)
                            .font(.cadenzaBody(.body, scale: uiScale))
                            .textSelection(.enabled)
                    }
                    ProgressView("Generating summary...")
                        .padding()
                } else {
                    // No summary yet during live recording
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "No Summary",
                            systemImage: "sparkles",
                            description: Text("Summary will be generated after recording stops")
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
                }
            }
            .padding()
        }
    }
}
