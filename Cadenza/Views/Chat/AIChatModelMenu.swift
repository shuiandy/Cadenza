import AppKit
import SwiftUI

struct AIChatModelMenu: View {
    enum LabelKind {
        case title
        case providerIcon(iconSize: CGFloat, frameSize: CGFloat, cornerRadius: CGFloat)
    }

    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    let availableProviders: [AIProvider]
    @Binding var selectedProvider: AIProvider
    @Binding var selectedModel: String
    var labelKind: LabelKind = .title

    @State private var fetchedPresets: [String: [AIChatModelPreset]] = [:]
    @State private var loadingProviderIDs: Set<String> = []
    @State private var showIconModelMenu = false

    var body: some View {
        Group {
            switch labelKind {
            case .title:
                titleMenu
            case .providerIcon(let iconSize, let frameSize, let cornerRadius):
                iconModelButton(iconSize: iconSize, frameSize: frameSize, cornerRadius: cornerRadius)
            }
        }
        .disabled(!appState.startupPolicy.allowsContentGeneration)
        .task(id: loadIdentity) {
            guard appState.startupPolicy.allowsContentGeneration else { return }
            await refreshAvailableProviderModels()
        }
    }

    // MARK: - Menu Content

    private var titleMenu: some View {
        Menu {
            providerMenuContent
        } label: {
            Label(modelMenuLabel, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var providerMenuContent: some View {
        ForEach(availableProviders) { provider in
            let providerPresets = presets(for: provider)
            if providerPresets.isEmpty {
                Toggle(isOn: providerSelectionBinding(provider)) {
                    Text(provider.displayName)
                }
            } else {
                providerSubmenu(provider, presets: providerPresets)
            }
        }
    }

    private func providerSubmenu(_ provider: AIProvider, presets: [AIChatModelPreset]) -> some View {
        Menu {
            if loadingProviderIDs.contains(provider.rawValue) {
                Text("Refreshing models...")
            }

            ForEach(presets) { preset in
                Toggle(isOn: modelSelectionBinding(provider: provider, modelID: preset.modelID)) {
                    Text(preset.modelID)
                }
            }
        } label: {
            HStack {
                Text(provider.displayName)
                if selectedProvider == provider {
                    Text(AIChatModelCatalog.displayTitle(for: provider, modelID: selectedModel))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func iconModelButton(iconSize: CGFloat, frameSize: CGFloat, cornerRadius: CGFloat) -> some View {
        let controlSize = max(frameSize, providerFallbackFrame(baseSize: iconSize))
        return Button {
            showIconModelMenu.toggle()
        } label: {
            providerIcon(selectedProvider, size: iconSize)
                .frame(width: controlSize, height: controlSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.cadenzaPlain(in: RoundedRectangle(cornerRadius: cornerRadius)))
        .popover(isPresented: $showIconModelMenu) {
            iconModelPopover
        }
    }

    private var iconModelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(availableProviders) { provider in
                providerPopoverSection(provider, presets: presets(for: provider))
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private func providerPopoverSection(_ provider: AIProvider, presets: [AIChatModelPreset]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectChatProvider(provider)
                if presets.isEmpty {
                    showIconModelMenu = false
                }
            } label: {
                HStack(spacing: 8) {
                    providerIcon(provider, size: 16)
                    Text(provider.displayName)
                        .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    Spacer()
                    if selectedProvider == provider {
                        Image(systemName: "checkmark")
                            .font(.cadenza(12, weight: .semibold, scale: uiScale))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)

            if loadingProviderIDs.contains(provider.rawValue) {
                Text("Refreshing models...")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 4)
            }

            ForEach(presets) { preset in
                Button {
                    selectChatModel(provider: provider, modelID: preset.modelID)
                    showIconModelMenu = false
                } label: {
                    HStack(spacing: 8) {
                        Text(preset.modelID)
                            .font(.cadenza(12, scale: uiScale))
                            .lineLimit(1)
                        Spacer()
                        if selectedProvider == provider && selectedModel == preset.modelID {
                            Image(systemName: "checkmark")
                                .font(.cadenza(11, weight: .semibold, scale: uiScale))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.cadenzaPlain)
            }
        }
    }

    @ViewBuilder
    private func providerIcon(_ provider: AIProvider, size: CGFloat) -> some View {
        if NSImage(named: provider.iconName) != nil {
            Image(provider.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            let fallbackFrame = providerFallbackFrame(baseSize: size)
            Image(systemName: provider.iconFallbackSymbol)
                .font(.cadenza(size, weight: .medium, scale: uiScale))
                .frame(width: fallbackFrame, height: fallbackFrame)
        }
    }

    /// Provider fallback symbols such as `brain` are about 1.5x their nominal
    /// point size in the wide axis. Asset icons deliberately keep their
    /// authored size; only the semantic SF Symbol fallback gets this frame.
    private func providerFallbackFrame(baseSize: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: ceil(baseSize * 1.5),
            symbolPointSize: baseSize * 1.15,
            scale: uiScale,
            padding: 0
        )
    }

    // MARK: - Model Loading

    private var loadIdentity: String {
        availableProviders.map(\.rawValue).joined(separator: "|")
    }

    private var modelMenuLabel: String {
        let modelTitle = AIChatModelCatalog.displayTitle(for: selectedProvider, modelID: selectedModel)
        return "\(selectedProvider.displayName) · \(modelTitle)"
    }

    private func presets(for provider: AIProvider) -> [AIChatModelPreset] {
        fetchedPresets[provider.rawValue] ?? AIChatModelCatalog.fallbackPresets(for: provider)
    }

    @MainActor
    private func refreshAvailableProviderModels() async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        for provider in availableProviders where provider.requiresAPIKey {
            await refreshModels(for: provider)
        }
    }

    @MainActor
    private func refreshModels(for provider: AIProvider) async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard fetchedPresets[provider.rawValue] == nil,
              !loadingProviderIDs.contains(provider.rawValue),
              let apiKey = KeychainManager.shared.apiKey(for: provider),
              !apiKey.isEmpty else { return }

        loadingProviderIDs.insert(provider.rawValue)
        defer { loadingProviderIDs.remove(provider.rawValue) }

        do {
            let modelListService = AIChatModelListService()
            let presets = try await modelListService.fetchPresets(for: provider, apiKey: apiKey)
            guard !presets.isEmpty else { return }
            fetchedPresets[provider.rawValue] = presets

            if selectedProvider == provider {
                let preferred = AIChatModelCatalog.preferredModel(
                    for: provider,
                    presets: presets,
                    currentModel: selectedModel
                )
                if selectedModel != preferred {
                    selectedModel = preferred
                    AIChatModelCatalog.persist(modelID: preferred, for: provider)
                }
            }
        } catch {
            NSLog("[AIChat] Model list fetch failed for %@: %@", provider.rawValue, error.localizedDescription)
        }
    }

    // MARK: - Selection

    private func providerSelectionBinding(_ provider: AIProvider) -> Binding<Bool> {
        Binding(
            get: { selectedProvider == provider },
            set: { isSelected in
                guard isSelected else { return }
                selectChatProvider(provider)
            }
        )
    }

    private func modelSelectionBinding(provider: AIProvider, modelID: String) -> Binding<Bool> {
        Binding(
            get: { selectedProvider == provider && selectedModel == modelID },
            set: { isSelected in
                guard isSelected else { return }
                selectChatModel(provider: provider, modelID: modelID)
            }
        )
    }

    private func selectChatModel(provider: AIProvider, modelID: String) {
        selectedProvider = provider
        selectedModel = modelID
        AIChatModelCatalog.persist(provider: provider)
        AIChatModelCatalog.persist(modelID: modelID, for: provider)
    }

    private func selectChatProvider(_ provider: AIProvider) {
        selectedProvider = provider
        selectedModel = AIChatModelCatalog.configuredModel(for: provider)
        AIChatModelCatalog.persist(provider: provider)
    }
}
