import SwiftUI
import UniformTypeIdentifiers

enum ImportRecordingLayoutMetrics {
    static func sheetSize(for effectiveScale: CGFloat) -> CGSize {
        let scale = effectiveScale.isFinite && effectiveScale > 0 ? effectiveScale : 1
        if scale >= CadenzaTextScale.factor(.accessibility1) {
            return CGSize(width: 720, height: 640)
        }
        return CGSize(width: 520, height: 480)
    }
}

struct AudioImportDropBatch: Equatable, Sendable {
    let urls: [URL]
    let failedCount: Int
}

/// Collects every asynchronous item-provider completion before starting one
/// import. A failed load occupies its original slot, so it remains part of the
/// user-visible batch total instead of disappearing behind a later success.
@MainActor
final class AudioImportDropBatchCollector {
    private var results: [URL?]
    private var resolvedIndices: Set<Int> = []
    private var completion: ((AudioImportDropBatch) -> Void)?

    init(itemCount: Int, completion: @escaping (AudioImportDropBatch) -> Void) {
        precondition(itemCount > 0)
        results = Array(repeating: nil, count: itemCount)
        self.completion = completion
    }

    func resolve(_ url: URL?, at index: Int) {
        guard results.indices.contains(index), resolvedIndices.insert(index).inserted else { return }
        results[index] = url
        guard resolvedIndices.count == results.count, let completion else { return }

        self.completion = nil
        let urls = results.compactMap { $0 }
        completion(AudioImportDropBatch(
            urls: urls,
            failedCount: results.count - urls.count
        ))
    }
}

struct ImportRecordingSheet: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = TranscriptionLanguage.auto.rawValue
    @AppStorage("summaryLanguage") private var summaryLanguage: String = TranscriptionLanguage.auto.rawValue

    @State private var isDragTargeted = false
    @State private var browseButtonHovered = false

    private nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "wav", "aiff", "flac", "m4a", "aac", "mp4", "mov", "caf"
    ]

    var body: some View {
        let sheetSize = ImportRecordingLayoutMetrics.sheetSize(for: uiScale)
        let closeControlSize = CadenzaControlMetrics.squareIconFrame(
            base: 26,
            symbolPointSize: 12,
            scale: uiScale,
            padding: 10
        )
        ScrollView {
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.cadenza(12, weight: .bold, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .frame(width: closeControlSize, height: closeControlSize)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.cadenzaPlain)
                }
                .padding(.top, 16)
                .padding(.trailing, 16)

                // Header
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.cadenza(40, scale: uiScale))
                        .foregroundStyle(Color.accentColor)

                    Text("Import Recording")
                        .font(.cadenza(20, weight: .bold, scale: uiScale))

                    Text("Import any audio file — we'll transcribe, identify speakers, and generate a structured meeting note.")
                        .font(.cadenza(13, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 20)

                settingsRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                // Drop zone
                dropZone
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Settings Picker

    private var settingsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                settingsPicker(label: "Language", icon: "globe", selection: $transcriptionLanguage)
                settingsPicker(label: "Summary Language", icon: "text.bubble", selection: $summaryLanguage)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(spacing: 12) {
                settingsPicker(label: "Language", icon: "globe", selection: $transcriptionLanguage)
                settingsPicker(label: "Summary Language", icon: "text.bubble", selection: $summaryLanguage)
            }
        }
    }

    private func settingsPicker(
        label: LocalizedStringKey,
        icon: String,
        selection: Binding<String>
    ) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.cadenza(11, weight: .semibold, scale: uiScale))
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)

                Picker("", selection: selection) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.cadenza(30, scale: uiScale))
                .foregroundStyle(isDragTargeted ? Color.accentColor : .secondary)

            Text("Drop audio or video file here")
                .font(.cadenza(13, weight: .medium, scale: uiScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openFilePicker()
            } label: {
                Label("Browse Files", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Text("MP3, WAV, AIFF, FLAC, M4A, AAC, MP4, MOV")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.accentColor.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: isDragTargeted ? [] : [8, 4])
                )
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDragTargeted ? Color.accentColor.opacity(0.06) : .clear)
        }
        .animation(.easeInOut(duration: 0.2), value: isDragTargeted)
        .onDrop(of: [.audio, .fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - File Picker

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
        panel.message = String(localized: "Select audio files to import")

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(urls: panel.urls)
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        let collector = AudioImportDropBatchCollector(itemCount: providers.count) { batch in
            importFiles(urls: batch.urls, rejectedCount: batch.failedCount)
        }
        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                collector.resolve(nil, at: index)
                continue
            }
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, error in
                let loadedURL: URL?
                if error != nil {
                    loadedURL = nil
                } else if let url = item as? URL {
                    loadedURL = url
                } else if let data = item as? Data {
                    loadedURL = URL(
                        dataRepresentation: data,
                        relativeTo: nil,
                        isAbsolute: true
                    )
                } else {
                    loadedURL = nil
                }

                let supportedURL = loadedURL.flatMap { url in
                    Self.supportedExtensions.contains(url.pathExtension.lowercased()) ? url : nil
                }
                Task { @MainActor in
                    collector.resolve(supportedURL, at: index)
                }
            }
        }
        return true
    }

    // MARK: - Import

    private func importFiles(urls: [URL], rejectedCount: Int = 0) {
        dismiss()
        appState.importAudioFiles(urls: urls, rejectedCount: rejectedCount)
    }
}
