import Testing

@testable import Cadenza

@Suite("SpeakerLabelFormatter")
struct SpeakerLabelFormatterTests {
    @Test func normalizesProviderSpeakerLabelsToOneBasedIndices() {
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "A") == 1)
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "B") == 2)
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "SPEAKER_00") == 1)
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "SPEAKER_01") == 2)
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "Speaker 1") == 1)
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "Speaker 2") == 2)
    }

    @Test func displayNameUsesFriendlyNumberWhenRecognized() {
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "C", localized: false) == "Speaker 3")
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_02", localized: false) == "Speaker 3")
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "Speaker 3", localized: false) == "Speaker 3")
    }

    @Test func displayNamePreservesUnrecognizedLabels() {
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: "Caleb") == nil)
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "Caleb", localized: false) == "Caleb")
    }

    // Gemini recordings transcribed before the ingest mapped its wire labels
    // still store `spk:0`, `spk:1`, …: zero-based, like SPEAKER_00. Every
    // separator reads the same index, as it does at ingest.
    @Test(arguments: [
        ("spk:0", 1),
        ("spk:1", 2),
        ("spk:12", 13),
        ("SPK:0", 1),
        (" spk:2 ", 3),
        ("spk_0", 1),
        ("spk_1", 2),
        ("spk3", 4),
    ])
    func storedGeminiWireLabelsAreZeroBased(_ raw: String, _ expected: Int) {
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: raw) == expected)
    }

    @Test func storedGeminiWireLabelsDisplayAsSpeakerNames() {
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "spk:0", localized: false) == "Speaker 1")
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: "spk:1", localized: false) == "Speaker 2")
    }

    // A sign, a non-ASCII digit, a fraction or an index whose shift to
    // one-based would overflow is not guessed at; SPEAKER_9223372036854775807
    // used to trap. "Speaker1" has no space and no known base, so it is left
    // alone too.
    @Test(arguments: [
        "spk:",
        "spk:a",
        "spk:-1",
        "spk::1",
        "spk:1.5",
        "spk:٣",
        "spk:9223372036854775807",
        "spk:99999999999999999999",
        "SPEAKER_",
        "SPEAKER_-1",
        "SPEAKER_+1",
        "SPEAKER_9223372036854775807",
        "Speaker 0",
        "Speaker -1",
        "Speaker1",
    ])
    func malformedIndicesAreLeftAsTheyAre(_ raw: String) {
        #expect(SpeakerLabelFormatter.speakerIndex(forRawLabel: raw) == nil)
        #expect(SpeakerLabelFormatter.displayName(forRawLabel: raw, localized: false) == raw)
    }

    // Gemini numbers voices from zero and SpeakerDiarizer from one, both in
    // order of first appearance, so a stored Gemini transcript reads the same
    // as a fresh local diarization of the same conversation.
    @Test func storedGeminiLabelsReadLikeAFreshDiarization() {
        let gemini = [
            TranscriptEntry(startTime: 0, endTime: 2, text: "Morning all.", speaker: "spk:0"),
            TranscriptEntry(startTime: 2, endTime: 4, text: "Hi.", speaker: "spk:1"),
            TranscriptEntry(startTime: 4, endTime: 6, text: "Hello.", speaker: "spk:2"),
            TranscriptEntry(startTime: 6, endTime: 8, text: "Let's start.", speaker: "spk:0"),
        ]
        // Cluster IDs out of order: the diarizer renumbers by first appearance.
        let spans = [
            SpeakerAssignmentSpan(speakerID: 7, startTime: 0, endTime: 2),
            SpeakerAssignmentSpan(speakerID: 3, startTime: 2, endTime: 4),
            SpeakerAssignmentSpan(speakerID: 5, startTime: 4, endTime: 6),
            SpeakerAssignmentSpan(speakerID: 7, startTime: 6, endTime: 8),
        ]
        let diarized = SpeakerDiarizer.assignSpeakers(gemini, spans: spans, replaceExistingSpeakers: true)

        #expect(diarized.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 1"])
        let stored = gemini.compactMap(\.speaker).map { SpeakerLabelFormatter.displayName(forRawLabel: $0, localized: false) }
        let fresh = diarized.compactMap(\.speaker).map { SpeakerLabelFormatter.displayName(forRawLabel: $0, localized: false) }
        #expect(stored == fresh)
    }

    // The cloud path diarizes with replaceExistingSpeakers, so an entry the
    // diarizer cannot place loses its label rather than keeping `spk:1`. One
    // transcript never holds both "spk:0" and "Speaker 1", which would show
    // two different voices under the same name.
    @Test func diarizationLeavesNoGeminiLabelBesideItsOwn() {
        let gemini = [
            TranscriptEntry(startTime: 0, endTime: 2, text: "Morning all.", speaker: "spk:0"),
            TranscriptEntry(startTime: 2, endTime: 4, text: "Hi.", speaker: "spk:1"),
            TranscriptEntry(startTime: 10, endTime: 12, text: "Anyone there?", speaker: "spk:1"),
        ]
        let spans = [
            SpeakerAssignmentSpan(speakerID: 0, startTime: 0, endTime: 2),
            SpeakerAssignmentSpan(speakerID: 1, startTime: 2, endTime: 4),
        ]
        let diarized = SpeakerDiarizer.assignSpeakers(gemini, spans: spans, replaceExistingSpeakers: true)

        #expect(diarized.map(\.speaker) == ["Speaker 1", "Speaker 2", nil])
    }

    // A speaker missing from the timeline falls back to a color read from
    // the label. Labels that display as the same "Speaker N" share it, and a
    // negative index cannot land on the reserved unknown or others colors.
    @Test func fallbackColorFollowsTheDisplayedSpeakerNumber() {
        let first = ["SPEAKER_00", "A", "spk:0", "Speaker 1"].map(SpeakerTimelineBuilder.fallbackColorIndex(for:))
        let second = ["SPEAKER_01", "B", "spk:1", "Speaker 2"].map(SpeakerTimelineBuilder.fallbackColorIndex(for:))

        #expect(Set(first) == [0])
        #expect(Set(second) == [1])
        #expect(SpeakerTimelineBuilder.fallbackColorIndex(for: "SPEAKER_-1") >= 0)
        #expect(SpeakerTimelineBuilder.fallbackColorIndex(for: "SPEAKER_-2") >= 0)
        #expect(
            SpeakerTimelineBuilder.fallbackColorIndex(for: SpeakerTimelineBuilder.unknownSpeakerKey)
                == SpeakerTimelineBuilder.unknownSpeakerColorIndex
        )
    }

    // MARK: - Per-transcript display labels

    @Test func storedGeminiLabelsGetSpeakerNamesInATranscript() {
        // Every segment carries its label, so repeats must not read as a
        // collision with themselves.
        let labels = SpeakerLabelFormatter.displayLabels(
            forRawLabels: ["spk:0", "spk:1", "spk:0", "spk:2", "spk:1"],
            localized: false
        )

        #expect(labels == ["spk:0": "Speaker 1", "spk:1": "Speaker 2", "spk:2": "Speaker 3"])
    }

    @Test func labelsThatWouldReadAlikeKeepTheirStoredForm() {
        // A stored spk:0 beside a diarized "Speaker 1" are two different
        // people as far as anyone can tell. Showing both as "Speaker 1"
        // would merge them, so both stay as stored; B has no rival.
        let labels = SpeakerLabelFormatter.displayLabels(
            forRawLabels: ["spk:0", "Speaker 1", "B", "Marisol"],
            localized: false
        )

        #expect(labels == [
            "spk:0": "spk:0",
            "Speaker 1": "Speaker 1",
            "B": "Speaker 2",
            "Marisol": "Marisol",
        ])
    }

    @Test func shownLabelsStayDistinctAcrossMixedProviders() {
        let raw = ["spk:0", "A", "SPEAKER_00", "spk_1", "SPEAKER_01", "C", "Speaker 4", "spk:4", "Wren"]
        let labels = SpeakerLabelFormatter.displayLabels(forRawLabels: raw, localized: false)

        #expect(labels.count == raw.count)
        #expect(Set(labels.values).count == raw.count)
        #expect(labels["C"] == "Speaker 3")
        #expect(labels["spk:4"] == "Speaker 5")
    }
}
