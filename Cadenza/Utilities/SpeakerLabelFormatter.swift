import Foundation

enum SpeakerLabelFormatter {
    static func speakerIndex(forRawLabel rawLabel: String) -> Int? {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let uppercased = trimmed.uppercased()
        if uppercased.count == 1,
           let scalar = uppercased.unicodeScalars.first,
           scalar >= "A" && scalar <= "Z" {
            return Int(scalar.value - Unicode.Scalar("A").value) + 1
        }

        if uppercased.hasPrefix("SPEAKER_"),
           let zeroBased = Int(uppercased.dropFirst(8)) {
            return zeroBased + 1
        }

        if uppercased.hasPrefix("SPEAKER "),
           let oneBased = Int(uppercased.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)),
           oneBased > 0 {
            return oneBased
        }

        return nil
    }

    static func displayName(forRawLabel rawLabel: String, localized: Bool = true) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = speakerIndex(forRawLabel: trimmed) else { return trimmed }
        if localized {
            return String(localized: "Speaker \(index)")
        }
        return "Speaker \(index)"
    }
}
