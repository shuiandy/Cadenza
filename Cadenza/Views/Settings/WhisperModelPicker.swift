import SwiftUI

/// Model selection picker for local Whisper transcription.
/// Shown inline when Whisper (Local) is selected as the transcription engine.
struct WhisperModelPicker: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var modelManager = WhisperModelManager.shared
    let externalAccessEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Larger models are more accurate, especially for non-English languages, but need more memory and may take longer to load.")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(WhisperModelManager.allModels) { model in
                    WhisperModelRow(
                        model: model,
                        modelManager: modelManager,
                        externalAccessEnabled: externalAccessEnabled
                    )

                    if model.name != WhisperModelManager.allModels.last?.name {
                        Divider()
                            .padding(.leading, 32)
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let error = modelManager.modelError {
                Text(error)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.red)
            }

            Text("Real-time transcription requires macOS 26 or a cloud API key.")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: modelManager.selectedModel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: modelManager.downloadProgress)
    }
}

// MARK: - Model Row

struct WhisperModelRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let model: WhisperModel
    @Bindable var modelManager: WhisperModelManager
    let externalAccessEnabled: Bool

    private var isSelected: Bool { modelManager.selectedModel == model.name }
    private var isAvailable: Bool { modelManager.isAvailable(model.name) }
    private var isDownloading: Bool { modelManager.isDownloading(model.name) }
    private var progress: Double? { modelManager.downloadProgress[model.name] }
    private var usesAccessibleLayout: Bool {
        uiScale >= CadenzaTextScale.factor(.accessibility1)
    }

    var body: some View {
        WhisperModelRowLayout(stacked: usesAccessibleLayout) {
            if isAvailable {
                WhisperModelSelectionButton(
                    model: model,
                    isSelected: isSelected,
                    action: selectModel
                )
            } else {
                WhisperModelIdentity(model: model, isSelected: isSelected)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        } actions: {
            if isDownloading, let progress {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        modelManager.cancelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .frame(minWidth: usesAccessibleLayout ? 44 : nil)
                    .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                    .accessibilityLabel("Cancel")
                }
            } else if isAvailable {
                HStack(spacing: 6) {
                    Text("Downloaded")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.green)

                    Button {
                        Task {
                            do {
                                try await LocalWhisperTranscriber.deleteModel(
                                    named: model.name
                                )
                                modelManager.modelError = nil
                            } catch is CancellationError {
                                // A cancelled release never reaches filesystem deletion.
                            } catch {
                                modelManager.modelError = String(
                                    localized: "Model could not be deleted. Please try again."
                                )
                                NSLog(
                                    "[WhisperModelPicker] model deletion failed for %@: %@",
                                    model.name,
                                    error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .font(.cadenza(.caption, scale: uiScale))
                    }
                    .buttonStyle(.cadenzaPlain)
                    .help("Delete model")
                    .frame(minWidth: usesAccessibleLayout ? 44 : nil)
                    .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                    .disabled(!externalAccessEnabled)
                    .accessibilityLabel("Delete model")
                }
            } else {
                Button {
                    guard externalAccessEnabled else { return }
                    modelManager.download(
                        model: model.name,
                        externalAccessEnabled: externalAccessEnabled
                    )
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.cadenza(.caption, scale: uiScale))
                }
                .buttonStyle(.cadenzaPlain)
                .foregroundColor(.accentColor)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .disabled(!externalAccessEnabled || modelManager.isDownloadInProgress)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func selectModel() {
        guard isAvailable else { return }
        modelManager.selectedModel = model.name
        Task {
            try? await LocalWhisperTranscriber.releasePipeline()
        }
    }
}

/// Reflows model identity above progress/actions once the effective UI scale
/// reaches an accessibility category. This keeps the Settings column bounded
/// at Cadenza's supported 3.105x maximum.
struct WhisperModelRowLayout<Identity: View, Actions: View>: View {
    let stacked: Bool
    private let identity: Identity
    private let actions: Actions

    init(
        stacked: Bool,
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder actions: () -> Actions
    ) {
        self.stacked = stacked
        self.identity = identity()
        self.actions = actions()
    }

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .trailing)
        }
    }
}

/// A real Button is required here: the former row-level tap gesture had no
/// keyboard activation and was not exposed as a selectable control to
/// VoiceOver.
struct WhisperModelSelectionButton: View {
    let model: WhisperModel
    let isSelected: Bool
    let action: () -> Void

    private var accessibilityPresentation: WhisperModelAccessibilityPresentation {
        .make(model: model, isSelected: isSelected)
    }

    var body: some View {
        Button(action: action) {
            WhisperModelIdentity(model: model, isSelected: isSelected)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityPresentation.label))
        .accessibilityValue(Text(verbatim: accessibilityPresentation.value))
        .accessibilityHint(Text(verbatim: accessibilityPresentation.hint))
    }
}

/// Complete VoiceOver copy for a downloaded model selection. The visible
/// identity is intentionally collapsed into one button, so its semantic label
/// must preserve every identifying detail hidden by `children: .ignore`.
struct WhisperModelAccessibilityPresentation: Equatable {
    let label: String
    let value: String
    let hint: String

    static func make(
        model: WhisperModel,
        isSelected: Bool,
        locale: Locale? = nil
    ) -> Self {
        var identity = [
            model.displayName,
            model.sizeDescription,
            model.description,
        ]
        if model.isDefault {
            identity.append(LocalizedBundle.string("Recommended", locale: locale))
        }

        return Self(
            label: identity.joined(separator: ", "),
            value: LocalizedBundle.string(
                isSelected ? "Selected" : "Downloaded",
                locale: locale
            ),
            hint: LocalizedBundle.string("Select", locale: locale)
        )
    }
}

struct WhisperModelIdentity: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let model: WhisperModel
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.cadenza(.body, scale: uiScale))

            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        modelName
                        recommendationBadge
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        modelName
                        recommendationBadge
                    }
                }

                Text("\(model.sizeDescription) · \(model.description)")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelName: some View {
        Text(model.displayName)
            .font(.cadenza(
                .body,
                weight: isSelected ? .semibold : .regular,
                scale: uiScale
            ))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var recommendationBadge: some View {
        if model.isDefault {
            Text("Recommended")
                .font(.cadenza(.caption2, weight: .medium, scale: uiScale))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
