import Foundation

/// Shared filename/directory naming for local file exports and the Markdown mirror.
enum ExportFileNaming {
    static let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        .union(.controlCharacters)

    /// Replaces filesystem-hostile characters, trims, and bounds length;
    /// falls back to "Recording". Bounds BOTH characters and UTF-8 bytes —
    /// APFS caps filenames at 255 bytes, and 80 CJK/emoji characters alone
    /// can blow past it once the date prefix and UUID suffix are added.
    static func sanitizedTitle(_ title: String, maxLength: Int = 80, maxUTF8Bytes: Int = 180) -> String {
        let safe = title.components(separatedBy: invalidCharacters).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = String((safe.isEmpty ? "Recording" : safe).prefix(maxLength))
        while bounded.utf8.count > maxUTF8Bytes {
            bounded.removeLast()
        }
        return bounded
    }

    /// "yyyy-MM-dd" (UTC, same convention as the Markdown mirror filenames).
    static func dateComponent(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle.iso8601.year().month().day())
    }

    /// Directory name for one exported recording: "yyyy-MM-dd - <title>".
    static func exportDirectoryName(title: String, startDate: Date) -> String {
        "\(dateComponent(for: startDate)) - \(sanitizedTitle(title))"
    }
}
