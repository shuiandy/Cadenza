import Foundation

enum SpeakerLabelFormatter {
    /// The one-based speaker number a raw label stands for, or nil for a name
    /// or anything else that is not a recognized provider label.
    ///
    /// - `A`, `B`, … are one-based by letter.
    /// - `SPEAKER_00` is zero-based.
    /// - `spk:0`, `spk_0` and `spk0` are Gemini's zero-based wire labels,
    ///   numbered in order of first appearance like SpeakerDiarizer's
    ///   "Speaker N". Recordings made before the ingest mapped them still
    ///   store them raw.
    /// - `Speaker 1` is already one-based; there is no "Speaker 0".
    static func speakerIndex(forRawLabel rawLabel: String) -> Int? {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let uppercased = trimmed.uppercased()
        if uppercased.count == 1,
           let scalar = uppercased.unicodeScalars.first,
           scalar >= "A" && scalar <= "Z" {
            return Int(scalar.value - Unicode.Scalar("A").value) + 1
        }

        if uppercased.hasPrefix("SPEAKER_") {
            return oneBased(fromZeroBased: uppercased.dropFirst(8))
        }

        if uppercased.hasPrefix("SPK") {
            var digits = uppercased.dropFirst(3)
            if digits.first == ":" || digits.first == "_" {
                digits = digits.dropFirst()
            }
            return oneBased(fromZeroBased: digits)
        }

        if uppercased.hasPrefix("SPEAKER "),
           let number = decimal(uppercased.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)),
           number > 0 {
            return number
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

    /// Display labels for one transcript's raw labels, keyed by raw label.
    /// Each label gets its `displayName` unless another raw label in the same
    /// transcript reaches the same display string (a stored `spk:0` next to a
    /// diarized "Speaker 1", or OpenAI's `A` next to it). Every label in such
    /// a collision keeps its raw form, so the shown labels stay distinct and
    /// each one still leads back to exactly one stored label. A canonical
    /// "Speaker N" formats to itself, so a raw fallback can never equal
    /// another label's display form.
    static func displayLabels(
        forRawLabels rawLabels: some Sequence<String>,
        localized: Bool = true
    ) -> [String: String] {
        var displayByRaw: [String: String] = [:]
        for raw in rawLabels where displayByRaw[raw] == nil {
            displayByRaw[raw] = displayName(forRawLabel: raw, localized: localized)
        }
        let rawCountByDisplay = Dictionary(
            displayByRaw.values.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return displayByRaw.reduce(into: [:]) { labels, pair in
            labels[pair.key] = rawCountByDisplay[pair.value] == 1 ? pair.value : pair.key
        }
    }

    /// ASCII digits only, so a sign or a non-decimal numeral cannot pass as
    /// an index.
    private static func decimal(_ digits: some StringProtocol) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits, radix: 10)
    }

    /// Int.max is refused so the shift to one-based cannot trap on a hostile
    /// label.
    private static func oneBased(fromZeroBased digits: Substring) -> Int? {
        guard let index = decimal(digits), index < Int.max else { return nil }
        return index + 1
    }
}
