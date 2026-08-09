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
}
