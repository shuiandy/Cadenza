import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openai
    case claude
    case gemini
    case minimax
    case apple
    case whisperLocal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .claude: "Claude (Anthropic)"
        case .gemini: "Gemini (Google)"
        case .minimax: "MiniMax"
        case .apple: String(localized: "Apple (Local)")
        case .whisperLocal: String(localized: "Whisper (Local)")
        }
    }

    var iconName: String {
        switch self {
        case .openai: "openai-icon"
        case .claude: "claude-icon"
        case .gemini: "gemini-icon"
        case .minimax: "minimax-icon"
        case .apple: "apple.logo"
        case .whisperLocal: "waveform.circle"
        }
    }

    /// SF Symbol fallback when asset catalog icon is missing.
    var iconFallbackSymbol: String {
        switch self {
        case .openai: "brain"
        case .claude: "sparkle"
        case .gemini: "diamond"
        case .minimax: "m.circle.fill"
        case .apple: "apple.logo"
        case .whisperLocal: "waveform.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .openai: String(localized: "Transcription and summaries")
        case .claude: String(localized: "Summaries and AI chat")
        case .gemini: String(localized: "Transcription and summaries")
        case .minimax: String(localized: "Summaries and AI chat")
        case .apple: String(localized: "On-device processing")
        case .whisperLocal: String(localized: "On-device transcription · Free")
        }
    }

    var supportsTranscription: Bool {
        switch self {
        case .openai, .gemini, .apple, .whisperLocal: true
        case .claude, .minimax: false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .apple, .whisperLocal: false
        default: true
        }
    }

    /// Default model for summary (intelligence-heavy, accuracy-first).
    ///
    /// Rationale (2026-08):
    /// - OpenAI: GPT-5.6 Sol is the current accuracy-first flagship.
    /// - Claude: Sonnet 4.6 keeps the best speed/intelligence/price
    ///   trade-off for meeting summaries. Opus 4.7 is the most capable
    ///   model but ~5x more expensive and aimed at complex agentic work,
    ///   not chunked summary generation.
    /// - Gemini: 3.7 Flash is stable and supersedes 3.5 Flash as the
    ///   recommended Flash-tier default — more capable on multi-step work
    ///   and roughly half the price ($0.75/$3.75 per 1M vs $1.50/$9.00,
    ///   promotional through 2026-12-31).
    /// - MiniMax: M2.7 (April 2026) is the latest.
    var defaultModel: String {
        switch self {
        case .openai: "gpt-5.6-sol"
        case .claude: "claude-sonnet-4-6"
        case .gemini: "gemini-3.7-flash"
        case .minimax: "MiniMax-M2.7"
        case .apple: "default"
        case .whisperLocal: "base"
        }
    }

    /// Default model for chat (latency-first, lower-tier when available).
    /// Chat is high-frequency low-complexity — every provider with a
    /// cheaper/faster small-model tier maps to it here. Currently:
    /// - OpenAI: gpt-5.6-terra balances capability, latency, and cost.
    /// - Claude: Haiku 4.5 (~5x cheaper, ~3-5x faster than Sonnet 4.6)
    /// - Gemini: 3.7 Flash (stable, current Flash-tier default)
    /// - MiniMax: M2.7-highspeed (identical results, faster latency variant)
    /// - Apple / Whisper Local: fall through to defaultModel.
    var defaultChatModel: String {
        switch self {
        case .openai: "gpt-5.6-terra"
        case .claude: "claude-haiku-4-5"
        case .gemini: "gemini-3.7-flash"
        case .minimax: "MiniMax-M2.7-highspeed"
        default: defaultModel
        }
    }

    var defaultTranscriptionModel: String {
        switch self {
        // gpt-4o-transcribe-diarize remains OpenAI's only diarizing
        // transcription model: gpt-transcribe (2026-07-28) is more accurate
        // but emits no speaker labels, and the speech-to-text guide still
        // routes diarized workloads here.
        case .openai: "gpt-4o-transcribe-diarize"
        // gemini-3.5-transcribe (2026-08-27) is a purpose-built ASR reached
        // through the Interactions API, not generateContent: native
        // diarization (<=8 speakers), word timestamps, 85+ languages with
        // code-switching. GeminiTranscriber routes transcribe-family models
        // to /v1beta/interactions and everything else to the legacy
        // prompt-driven generateContent path.
        case .gemini: "gemini-3.5-transcribe"
        case .apple: "default"
        case .whisperLocal: "base"
        case .claude, .minimax: ""
        }
    }

    /// Default model for realtime (live-caption) transcription sessions.
    ///
    /// Rationale (2026-08):
    /// - OpenAI: gpt-live-transcribe (2026-07-28) is the model the Realtime
    ///   transcription guide now recommends; gpt-4o-transcribe is demoted to
    ///   "only when you need turn-committed transcription or detected-language
    ///   output". Cadenza never consumed the detected language from a realtime
    ///   delta (batch transcription sets it), so the trade is free.
    /// - Gemini: gemini-3.5-transcribe-live is the dedicated live ASR the old
    ///   comment here was waiting for. It replaces the 3.1 dialogue model,
    ///   whose captions were a side channel of a conversational model. It
    ///   emits whole-hypothesis interim text plus an authoritative final, so
    ///   GeminiRealtimeTranscriber marks its deltas replacesHypothesis. Live
    ///   sessions cap at 10 minutes; the RecordingEngine reconnect path
    ///   rotates them (its budget refills on every healthy stream).
    var defaultRealtimeModel: String {
        switch self {
        case .openai: "gpt-live-transcribe"
        case .gemini: "gemini-3.5-transcribe-live"
        case .apple: "default"
        case .claude, .minimax, .whisperLocal: ""
        }
    }

    // MARK: - Configured models (UserDefaults override ?? code default)
    //
    // Model IDs churn fast. Every model the app talks to resolves through one
    // of these four accessors so a stale ID can be fixed from Settings (or
    // `defaults write`) without a rebuild. An empty/missing override falls
    // back to the code default. Keys (one per provider):
    //   model.<provider>              — summary (and chat, which shares the
    //                                   key but falls back to defaultChatModel)
    //   transcriptionModel.<provider> — post-recording batch transcription
    //   realtimeModel.<provider>      — live-caption realtime transcription

    /// UserDefaults override helper — treats missing AND empty string as "use default".
    private func configuredModel(key: String, default defaultModel: String) -> String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModel
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Summary model: `model.<provider>` override, else `defaultModel`.
    var summaryModel: String {
        configuredModel(key: "model.\(rawValue)", default: defaultModel)
    }

    /// Chat model: shares the `model.<provider>` override key with summary
    /// (pre-existing behavior — one knob steers both), but falls back to the
    /// cheaper/faster `defaultChatModel` when unset.
    var chatModel: String {
        configuredModel(key: "model.\(rawValue)", default: defaultChatModel)
    }

    /// Batch transcription model: `transcriptionModel.<provider>` override,
    /// else `defaultTranscriptionModel`. (whisperLocal resolves through
    /// WhisperModelManager instead — see TranscriptionManager.)
    var transcriptionModel: String {
        configuredModel(key: "transcriptionModel.\(rawValue)", default: defaultTranscriptionModel)
    }

    /// Realtime transcription model: `realtimeModel.<provider>` override,
    /// else `defaultRealtimeModel`.
    var realtimeModel: String {
        configuredModel(key: "realtimeModel.\(rawValue)", default: defaultRealtimeModel)
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openai: "sk-..."
        case .claude: "sk-ant-..."
        case .gemini: "AIza..."
        case .minimax: "eyJhb..."
        case .apple, .whisperLocal: ""
        }
    }

    /// Base URL for OpenAI-compatible chat completion endpoint.
    var chatBaseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1/chat/completions"
        case .minimax: "https://api.minimax.io/v1/chat/completions"
        default: ""
        }
    }

    /// Token budget for AI context assembly. Conservative to leave room for model thinking.
    var contextTokenBudget: Int {
        switch self {
        case .openai: 30_000
        case .claude: 30_000
        case .gemini: 20_000
        case .minimax: 8_000
        case .apple: 2_000
        case .whisperLocal: 8_000
        }
    }
}

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto = "auto"
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case thai = "th"
    case vietnamese = "vi"
    case dutch = "nl"
    case turkish = "tr"
    case polish = "pl"
    case swedish = "sv"
    case indonesian = "id"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: String(localized: "Auto Detect")
        case .english: "English"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .thai: "ไทย"
        case .vietnamese: "Tiếng Việt"
        case .dutch: "Nederlands"
        case .turkish: "Türkçe"
        case .polish: "Polski"
        case .swedish: "Svenska"
        case .indonesian: "Bahasa Indonesia"
        }
    }
}
