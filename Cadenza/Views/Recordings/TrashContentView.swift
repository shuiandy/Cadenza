import SwiftUI

struct TrashContentView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    @Environment(AppState.self) private var appState
    @AppStorage("contentViewMode") private var viewModeRaw: String = "waterfall"
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 7

    @State private var showEmptyTrashAlert = false
    @State private var recordingToDelete: RecordingDTO?

    private var viewMode: ContentViewMode {
        ContentViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var recordings: [RecordingDTO] {
        appState.trashedRecordings
    }

    static func emptyTrashMessage(
        recordingCount: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let key: String.LocalizationValue = recordingCount == 1
            ? "This permanently removes %lld recording from the active library, including its Cadenza-owned audio and derived data. Existing automatic recovery backups may retain a copy until rotation or explicit deletion. This cannot be undone in the active library."
            : "This permanently removes all %lld recordings from the active library, including their Cadenza-owned audio and derived data. Existing automatic recovery backups may retain copies until rotation or explicit deletion. This cannot be undone in the active library."
        return String(
            format: LocalizedBundle.string(key, locale: locale),
            Int64(recordingCount)
        )
    }

    static func permanentDeleteMessage(
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        LocalizedBundle.string(
            "This permanently removes the recording from the active library, including its Cadenza-owned audio and derived data. Existing automatic recovery backups may retain a copy until rotation or explicit deletion. This cannot be undone in the active library.",
            locale: locale
        )
    }

    static func retentionDescription(
        retentionDays: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let format = LocalizedBundle.string(
            "Deleted recordings stay here for %lld days. After that, they are removed from the active library and their Cadenza-owned audio and derived data are deleted. Automatic recovery backups may retain copies until rotation or explicit deletion.",
            locale: locale
        )
        let effectiveDays = retentionDays > 0 ? retentionDays : 7
        return String(format: format, Int64(effectiveDays))
    }

    var body: some View {
        VStack(spacing: 0) {
            trashTopBar
                .padding(.bottom, 10)

            if recordings.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    ContentUnavailableView(
                        "Trash is Empty",
                        systemImage: "trash",
                        description: Text(Self.retentionDescription(
                            retentionDays: trashRetentionDays,
                            locale: locale
                        ))
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    trashLayout
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .alert("Empty Trash?", isPresented: $showEmptyTrashAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) {
                appState.emptyTrash()
            }
        } message: {
            Text(Self.emptyTrashMessage(recordingCount: recordings.count, locale: locale))
        }
        .alert("Delete Permanently?", isPresented: Binding(
            get: { recordingToDelete != nil },
            set: { if !$0 { recordingToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                recordingToDelete = nil
            }
            Button("Delete Permanently", role: .destructive) {
                if let recording = recordingToDelete {
                    appState.permanentlyDeleteRecording(recordingID: recording.id)
                    recordingToDelete = nil
                }
            }
        } message: {
            Text(Self.permanentDeleteMessage(locale: locale))
        }
    }

    // MARK: - Top Bar

    private var trashTopBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.secondary)

                Text("Trash")
                    .font(.cadenza(.title3, weight: .semibold, scale: uiScale))

                if !recordings.isEmpty {
                    Text("\(recordings.count)")
                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }

            Spacer(minLength: 10)

            CadenzaGlassContainer(spacing: 8) {
                HStack(spacing: 2) {
                    viewModeButton("rectangle.grid.2x2", mode: .waterfall, help: "Waterfall")
                    viewModeButton("square.grid.2x2", mode: .grid, help: "Grid")
                    viewModeButton("list.bullet", mode: .list, help: "List")
                }
                .padding(4)
                .cadenzaGlass(in: Capsule(), interactive: true)

                if !recordings.isEmpty {
                    Button {
                        showEmptyTrashAlert = true
                    } label: {
                        Text("Empty Trash")
                            .font(.cadenza(12, weight: .medium, scale: uiScale))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .cadenzaGlass(in: Capsule(), interactive: true)
                }
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Layout

    @ViewBuilder
    private var trashLayout: some View {
        switch viewMode {
        case .waterfall:
            WaterfallLayout(minColumnWidth: 220, spacing: 12) {
                ForEach(recordings) { recording in
                    trashCard(recording) {
                        RecordingCardView(recording: recording, viewMode: .waterfall)
                    }
                }
            }
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(recordings) { recording in
                    trashCard(recording) {
                        RecordingCardView(recording: recording, viewMode: .grid)
                    }
                }
            }
        case .list:
            VStack(spacing: 4) {
                ForEach(recordings) { recording in
                    trashCard(recording) {
                        RecordingListRow(recording: recording)
                    }
                }
            }
        }
    }

    // MARK: - Trash Card

    @ViewBuilder
    private func trashCard<Content: View>(_ recording: RecordingDTO, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(0.7)
            .contextMenu {
                Button {
                    appState.restoreRecording(recordingID: recording.id)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }

                Divider()

                Button(role: .destructive) {
                    recordingToDelete = recording
                } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
            }
    }

    // MARK: - View Mode Button

    private func viewModeButton(
        _ icon: String,
        mode: ContentViewMode,
        help: LocalizedStringKey
    ) -> some View {
        let controlSize = CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 14,
            scale: uiScale,
            padding: 4
        )
        return Button {
            viewModeRaw = mode.rawValue
        } label: {
            Image(systemName: icon)
                .font(.cadenza(14, weight: .medium, scale: uiScale))
                .foregroundStyle(viewModeRaw == mode.rawValue ? .primary : .tertiary)
                .frame(width: controlSize, height: controlSize)
                .background(
                    Capsule()
                        .fill(viewModeRaw == mode.rawValue ? Color.primary.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.cadenzaPlain)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityValue(viewModeRaw == mode.rawValue ? Text("Selected") : Text("Not selected"))
    }
}
