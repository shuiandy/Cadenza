import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@Suite("Calendar toolbar adaptive layout")
struct CalendarToolbarLayoutTests {
    private let contentWidth: CGFloat = 800
    private let localeIdentifiers = ["de", "es", "fr", "ja", "ko", "zh-Hans"]

    @MainActor @Test func legacyFixedPickerOverflowsForLongestSupportedLocalizedDayTitles() throws {
        let scale = maximumEffectiveScale

        for fixture in try longestDayTitleFixtures(scale: scale) {
            let host = intrinsicHost(
                legacyToolbar(fixture: fixture, scale: scale)
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .environment(\.uiScale, scale)
                    .environment(\.locale, fixture.locale)
            )

            NSLog(
                "[CalendarToolbarLayoutProbe] legacy %@ %.1fx%.1f limit=%.1f title=%@",
                fixture.locale.identifier,
                host.fittingSize.width,
                host.fittingSize.height,
                contentWidth,
                fixture.title
            )
            #expect(
                host.fittingSize.width > contentWidth,
                "Legacy toolbar must reproduce overflow for \(fixture.locale.identifier)"
            )
        }
    }

    @MainActor @Test func nativeControlsOwnTheirDefaultAndMaximumHitFrames() throws {
        let fixture = try #require(longestDayTitleFixtures(scale: 1).first)

        for configuration in [
            CalendarToolbarScaleConfiguration(scale: 1, dynamicTypeSize: .large),
            CalendarToolbarScaleConfiguration(
                scale: maximumEffectiveScale,
                dynamicTypeSize: .accessibility5
            ),
        ] {
            let state = CalendarToolbarInteractionState(
                viewMode: .day,
                selectedDate: fixture.date
            )
            let surface = actualToolbarSurface(
                fixture: fixture,
                configuration: configuration,
                state: state
            )
            let buttons = try nativeButtonsByIdentifier(in: surface.host)
            let expectedDimension = CalendarToolbarControlMetrics.controlDimension(
                scale: configuration.scale
            )

            for identifier in expectedButtonIdentifiers {
                let button = try #require(buttons[identifier])
                try assertRealHitFrame(
                    button,
                    identifier: identifier,
                    minimumDimension: expectedDimension,
                    host: surface.host
                )
            }
        }
    }

    @MainActor @Test func nativeControlEdgesDispatchRealNavigationTodayAndModeActions() throws {
        let fixture = try #require(longestDayTitleFixtures(scale: maximumEffectiveScale).first)
        let state = CalendarToolbarInteractionState(
            viewMode: .day,
            selectedDate: fixture.date
        )
        let surface = actualToolbarSurface(
            fixture: fixture,
            configuration: CalendarToolbarScaleConfiguration(
                scale: maximumEffectiveScale,
                dynamicTypeSize: .accessibility5
            ),
            state: state
        )
        let buttons = try nativeButtonsByIdentifier(in: surface.host)
        let originalDate = state.selectedDate

        #expect(try activate(buttons, "calendar-toolbar-previous", edge: .bottomLeading))
        #expect(state.selectedDate < originalDate)

        #expect(try activate(buttons, "calendar-toolbar-next", edge: .topTrailing))
        #expect(abs(state.selectedDate.timeIntervalSince(originalDate)) < 1)

        #expect(try activate(buttons, "calendar-toolbar-mode-week", edge: .bottomTrailing))
        #expect(state.viewMode == .week)
        #expect(try activate(buttons, "calendar-toolbar-mode-month", edge: .topLeading))
        #expect(state.viewMode == .month)
        #expect(try activate(buttons, "calendar-toolbar-mode-day", edge: .bottomLeading))
        #expect(state.viewMode == .day)

        #expect(try activate(buttons, "calendar-toolbar-today", edge: .topTrailing))
        #expect(abs(state.selectedDate.timeIntervalSinceNow) < 2)
    }

    @MainActor @Test func defaultScaleKeepsLongestLocalizedToolbarOnOneLine() throws {
        let fixtures = try longestDayTitleFixtures(scale: 1)
        let fixture = try #require(fixtures.max(by: { $0.titleWidth < $1.titleWidth }))
        let state = CalendarToolbarInteractionState(viewMode: .day, selectedDate: fixture.date)
        let surface = actualToolbarSurface(
            fixture: fixture,
            configuration: CalendarToolbarScaleConfiguration(scale: 1, dynamicTypeSize: .large),
            state: state
        )
        let buttons = try nativeButtonsByIdentifier(in: surface.host)
        let frames = try expectedButtonIdentifiers.map { identifier in
            try frame(of: #require(buttons[identifier]), in: surface.host)
        }
        let midYValues = frames.map(\.midY)

        #expect(surface.host.fittingSize.width <= contentWidth + 0.5)
        #expect((midYValues.max() ?? 0) - (midYValues.min() ?? 0) < 1)
    }

    @MainActor @Test func maximumScaleReflowsEveryLongestLocalizedToolbarInsideMinimumWidth() throws {
        let scale = maximumEffectiveScale
        let expectedDimension = CalendarToolbarControlMetrics.controlDimension(scale: scale)

        for fixture in try longestDayTitleFixtures(scale: scale) {
            let state = CalendarToolbarInteractionState(viewMode: .day, selectedDate: fixture.date)
            let surface = actualToolbarSurface(
                fixture: fixture,
                configuration: CalendarToolbarScaleConfiguration(
                    scale: scale,
                    dynamicTypeSize: .accessibility5
                ),
                state: state
            )
            let buttons = try nativeButtonsByIdentifier(in: surface.host)

            NSLog(
                "[CalendarToolbarLayoutProbe] repaired %@ %.1fx%.1f limit=%.1f scale=%.3f",
                fixture.locale.identifier,
                surface.host.fittingSize.width,
                surface.host.fittingSize.height,
                contentWidth,
                scale
            )
            #expect(surface.host.fittingSize.width <= contentWidth + 0.5)
            #expect(surface.host.fittingSize.height > 100)
            for mode in CalendarViewMode.allCases {
                let identifier = "calendar-toolbar-mode-\(mode.rawValue)"
                let button = try #require(buttons[identifier])
                let expectedTitle = localizedModeTitle(mode, locale: fixture.locale)
                #expect(button.title == expectedTitle)
                #expect(button.accessibilityLabel() == expectedTitle)
            }
            for identifier in expectedButtonIdentifiers {
                let button = try #require(buttons[identifier])
                try assertRealHitFrame(
                    button,
                    identifier: identifier,
                    minimumDimension: expectedDimension,
                    host: surface.host
                )
            }
        }
    }

    @Test func productionToolbarUsesNativeHitTargetsWithoutFixedPickerWidth() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Cadenza/Views/Calendar/CalendarToolbarView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("CalendarToolbarAdaptiveLayout"))
        #expect(source.contains("CalendarToolbarNativeButton"))
        #expect(source.contains("CalendarToolbarModeSelector"))
        #expect(!source.contains(".frame(width: 220)"))
        #expect(!source.contains(".pickerStyle(.segmented)"))
    }

    private var maximumEffectiveScale: CGFloat {
        CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
    }

    private var expectedButtonIdentifiers: [String] {
        [
            "calendar-toolbar-previous",
            "calendar-toolbar-next",
            "calendar-toolbar-today",
            "calendar-toolbar-mode-day",
            "calendar-toolbar-mode-week",
            "calendar-toolbar-mode-month",
        ]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func longestDayTitleFixtures(scale: CGFloat) throws -> [CalendarDayTitleFixture] {
        let font = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))

        return try localeIdentifiers.map { identifier in
            let locale = Locale(identifier: identifier)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            calendar.timeZone = timeZone
            let start = try #require(calendar.date(from: DateComponents(year: 2028, month: 1, day: 1)))
            let dayCount = try #require(calendar.range(of: .day, in: .year, for: start)?.count)
            var longest: CalendarDayTitleFixture?

            for offset in 0..<dayCount {
                let date = try #require(calendar.date(byAdding: .day, value: offset, to: start))
                let title = CalendarToolbarView.dateTitle(
                    for: date,
                    viewMode: .day,
                    locale: locale,
                    calendar: calendar,
                    timeZone: timeZone
                )
                let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
                if longest == nil || width > (longest?.titleWidth ?? 0) {
                    longest = CalendarDayTitleFixture(
                        locale: locale,
                        date: date,
                        title: title,
                        titleWidth: width
                    )
                }
            }

            return try #require(longest)
        }
    }

    @MainActor
    private func actualToolbarSurface(
        fixture: CalendarDayTitleFixture,
        configuration: CalendarToolbarScaleConfiguration,
        state: CalendarToolbarInteractionState
    ) -> CalendarToolbarHostedSurface {
        let viewMode = Binding(
            get: { state.viewMode },
            set: { state.viewMode = $0 }
        )
        let selectedDate = Binding(
            get: { state.selectedDate },
            set: { state.selectedDate = $0 }
        )
        let root = CalendarToolbarView(viewMode: viewMode, selectedDate: selectedDate)
            .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
            .environment(\.uiScale, configuration.scale)
            .environment(\.locale, fixture.locale)
            .frame(width: contentWidth, alignment: .leading)
        let host = intrinsicHost(root)
        let fittingSize = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fittingSize)
        host.layoutSubtreeIfNeeded()
        return CalendarToolbarHostedSurface(host: host)
    }

    @MainActor
    private func nativeButtonsByIdentifier(
        in host: NSHostingView<AnyView>
    ) throws -> [String: CalendarToolbarNativeButtonView] {
        let visibleButtons = nativeButtons(in: host).filter { button in
            let buttonFrame = frame(of: button, in: host)
            return !button.isHidden
                && button.alphaValue > 0
                && buttonFrame.width > 0
                && buttonFrame.height > 0
                && host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(buttonFrame)
        }
        let grouped = Dictionary(grouping: visibleButtons) { button -> String in
            button.accessibilityIdentifier()
        }

        var result: [String: CalendarToolbarNativeButtonView] = [:]
        for identifier in expectedButtonIdentifiers {
            let candidates = grouped[identifier] ?? []
            let button = try #require(
                candidates.max { lhs, rhs in
                    frame(of: lhs, in: host).width * frame(of: lhs, in: host).height
                        < frame(of: rhs, in: host).width * frame(of: rhs, in: host).height
                }
            )
            result[identifier] = button
        }
        return result
    }

    @MainActor
    private func nativeButtons(in view: NSView) -> [CalendarToolbarNativeButtonView] {
        let own = (view as? CalendarToolbarNativeButtonView).map { [$0] } ?? []
        return own + view.subviews.flatMap(nativeButtons(in:))
    }

    @MainActor
    private func assertRealHitFrame(
        _ button: CalendarToolbarNativeButtonView,
        identifier: String,
        minimumDimension: CGFloat,
        host: NSHostingView<AnyView>
    ) throws {
        let frame = frame(of: button, in: host)
        let accessibilityFrame = button.accessibilityFrame()

        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityIdentifier() == identifier)
        #expect(frame.width >= minimumDimension - 0.5)
        #expect(frame.height >= minimumDimension - 0.5)
        #expect(accessibilityFrame.width >= minimumDimension - 0.5)
        #expect(accessibilityFrame.height >= minimumDimension - 0.5)
        #expect(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))

        for edge in CalendarToolbarControlEdge.allCases {
            #expect(button.hitTest(edge.point(in: button.bounds)) === button)
        }
    }

    @MainActor
    private func activate(
        _ buttons: [String: CalendarToolbarNativeButtonView],
        _ identifier: String,
        edge: CalendarToolbarControlEdge
    ) throws -> Bool {
        let button = try #require(buttons[identifier])
        guard button.hitTest(edge.point(in: button.bounds)) === button,
              let action = button.action else {
            return false
        }
        return NSApp.sendAction(action, to: button.target, from: button)
    }

    @MainActor
    private func frame(
        of button: CalendarToolbarNativeButtonView,
        in host: NSHostingView<AnyView>
    ) -> NSRect {
        button.convert(button.bounds, to: host)
    }

    @MainActor
    private func legacyToolbar(
        fixture: CalendarDayTitleFixture,
        scale: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button(action: {}) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Button(action: {}) { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .appToolbarRail(cornerRadius: 10)

            Button(localized("Today", locale: fixture.locale), action: {})
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .clipShape(Capsule(style: .continuous))

            Text(fixture.title)
                .font(.cadenza(.headline, scale: scale))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .appToolbarRail(cornerRadius: 10)

            Spacer(minLength: 0)

            Picker(localized("View", locale: fixture.locale), selection: .constant(CalendarViewMode.day)) {
                Text(localized("Day", locale: fixture.locale)).tag(CalendarViewMode.day)
                Text(localized("Week", locale: fixture.locale)).tag(CalendarViewMode.week)
                Text(localized("Month", locale: fixture.locale)).tag(CalendarViewMode.month)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func localized(_ key: String.LocalizationValue, locale: Locale) -> String {
        LocalizedBundle.string(key, locale: locale)
    }

    private func localizedModeTitle(_ mode: CalendarViewMode, locale: Locale) -> String {
        switch mode {
        case .day:
            localized("Day", locale: locale)
        case .week:
            localized("Week", locale: locale)
        case .month:
            localized("Month", locale: locale)
        }
    }

    @MainActor
    private func intrinsicHost<Content: View>(_ content: Content) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host
    }
}

private struct CalendarDayTitleFixture {
    let locale: Locale
    let date: Date
    let title: String
    let titleWidth: CGFloat
}

private struct CalendarToolbarScaleConfiguration {
    let scale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
}

@MainActor
private final class CalendarToolbarInteractionState {
    var viewMode: CalendarViewMode
    var selectedDate: Date

    init(viewMode: CalendarViewMode, selectedDate: Date) {
        self.viewMode = viewMode
        self.selectedDate = selectedDate
    }
}

@MainActor
private struct CalendarToolbarHostedSurface {
    let host: NSHostingView<AnyView>
}

private enum CalendarToolbarControlEdge: CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing

    func point(in bounds: NSRect) -> NSPoint {
        switch self {
        case .bottomLeading:
            NSPoint(x: bounds.minX + 1, y: bounds.minY + 1)
        case .bottomTrailing:
            NSPoint(x: bounds.maxX - 1, y: bounds.minY + 1)
        case .topLeading:
            NSPoint(x: bounds.minX + 1, y: bounds.maxY - 1)
        case .topTrailing:
            NSPoint(x: bounds.maxX - 1, y: bounds.maxY - 1)
        }
    }
}
