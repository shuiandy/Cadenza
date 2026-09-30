import Foundation

/// Where joining two pieces of transcript needs a space. Chinese, Japanese
/// and Thai run words together; Korean does not, so Hangul is deliberately
/// absent from the no-space set.
enum TranscriptSpacing {
    /// Join without inventing spaces inside scripts that do not use them.
    static func joining(_ text: String, _ next: String) -> String {
        guard !text.isEmpty else { return next }
        let scalars = text.unicodeScalars
        guard let previous = scalars.last,
              let first = next.unicodeScalars.first else { return text + next }
        let space = needsSpace(after: previous, following: scalars.dropLast().last, before: first)
        return space ? text + " " + next : text + next
    }

    private static func needsSpace(
        after previous: Unicode.Scalar,
        following beforePrevious: Unicode.Scalar?,
        before next: Unicode.Scalar
    ) -> Bool {
        if previous.properties.isWhitespace || next.properties.isWhitespace { return false }
        if isScriptWithoutWordSpaces(previous) || isScriptWithoutWordSpaces(next) { return false }
        // ASCII punctuation that hugs the word it follows or precedes.
        if ",.!?;:%)]}".unicodeScalars.contains(next) { return false }
        if "([{".unicodeScalars.contains(previous) { return false }
        if next == "'" { return false }
        // An apostrophe after a letter is inside a word ("rock'" "n"); one
        // after punctuation closes a quote ("'go.'" "Then") and is spaced.
        if previous == "'", beforePrevious?.properties.isAlphabetic == true { return false }
        return true
    }

    private static func isScriptWithoutWordSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFF65,   // Full-width forms (excludes half-width kana)
             0x20000...0x2FA1F, // CJK Extensions B-F
             0x0E00...0x0E7F:   // Thai
            return true
        default:
            return false
        }
    }
}
