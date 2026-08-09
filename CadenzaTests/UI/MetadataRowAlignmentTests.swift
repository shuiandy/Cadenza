import Foundation
import Testing
@testable import Cadenza

/// The recording detail header lines its metadata rows up by *sharing structure*,
/// never by hand-tuned padding.
///
/// Six earlier attempts corrected the visible offset with leading padding on one row or
/// the other, and every one of them failed: a `Menu` label is laid out by AppKit inside
/// its own button box and reports `minX == 0` to SwiftUI, so no SwiftUI-side offset can
/// reach it. The rows only align because they now use the same container, the same
/// `HStack` spacing, the same SF Symbol and the same button style.
///
/// These are source-level checks. They cannot measure rendered coordinates — that would
/// need a UI test — but they do lock the four structural properties the alignment rests
/// on, and they fail if anyone reintroduces a padding fudge.
@Suite struct MetadataRowAlignmentTests {
    private var detailSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/Views/Recordings/RecordingDetailView.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func section(_ source: String, from: String, to: String) throws -> String {
        let start = try #require(source.range(of: from), "anchor not found: \(from)")
        let rest = source[start.lowerBound...]
        let end = try #require(rest.range(of: to), "anchor not found: \(to)")
        return String(rest[..<end.lowerBound])
    }

    /// Both rows draw their icon the same way: same glyph, same HStack spacing.
    @Test func bothRowsShareTheSameIconStructure() throws {
        let source = try detailSource
        let header = try section(source, from: "private func headerSection", to: "// MARK: - Calendar Link")
        let calendarRow = try section(source, from: "private func calendarLinkRow", to: "private var calendarEventPickerPopover")

        for region in [header, calendarRow] {
            #expect(region.contains("HStack(spacing: 5)"))
            #expect(region.contains("Image(systemName: \"calendar\")"))
        }
        // `Label`'s icon column is wider than the glyph, so a row using it starts at a
        // different x than a row using a bare Image.
        #expect(!header.contains("Label(dateString"))
    }

    /// No row may nudge itself into place; matching structure is the only mechanism.
    @Test func rowsDoNotCompensateWithPadding() throws {
        let source = try detailSource
        let header = try section(source, from: "// Metadata rows share", to: "// MARK: - Calendar Link")
        let calendarRowChrome = try section(source, from: ".buttonStyle(.cadenzaPlain)\n        .popover(isPresented: $isPickingCalendarEvent", to: "private var calendarEventPickerPopover")

        for fudge in [".padding(.leading", ".padding(.trailing", ".padding(.horizontal", ".offset(x:"] {
            #expect(
                !header.contains(fudge),
                "Metadata rows must not use \(fudge) to line up — match the other row's structure instead."
            )
            #expect(!calendarRowChrome.contains(fudge))
        }
    }

    /// A `Menu` here is unfixable: AppKit positions its label out of SwiftUI's reach.
    @Test func calendarRowIsNotAMenu() throws {
        let calendarRow = try section(try detailSource, from: "private func calendarLinkRow", to: "private var calendarEventPickerPopover")

        #expect(!calendarRow.contains("menuStyle("))
        #expect(!calendarRow.contains("Menu {"))
        #expect(calendarRow.contains(".buttonStyle(.cadenzaPlain)"))
    }

    /// The candidate query returns a whole day of events, so the picker must scroll.
    @Test func eventPickerIsHeightBounded() throws {
        let picker = try section(try detailSource, from: "private var calendarEventPickerPopover", to: "private func loadCandidateEvents")

        #expect(picker.contains("ScrollView"))
        #expect(picker.contains("maxHeight:"))
        // Selection is announced through the trait, so the glyph must stay decorative.
        #expect(picker.contains(".accessibilityHidden(true)"))
        #expect(picker.contains(".isSelected"))
    }
}
