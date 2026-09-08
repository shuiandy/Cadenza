import AppKit
import SwiftUI

enum LocalizedDateFormatting {
    static func string(
        from date: Date,
        style baseStyle: Date.FormatStyle,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = baseStyle.locale(locale)
        style.calendar = calendar
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func interval(
        from startDate: Date,
        to endDate: Date,
        dateStyle: DateIntervalFormatter.Style,
        timeStyle: DateIntervalFormatter.Style,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: startDate, to: endDate)
    }
}

struct CalendarToolbarView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.locale) private var locale

    @Binding var viewMode: CalendarViewMode
    @Binding var selectedDate: Date

    var body: some View {
        CalendarToolbarAdaptiveLayout(spacing: 8) {
            navigationControls
        } today: {
            CalendarToolbarNativeButton(
                title: LocalizedBundle.string("Today", locale: locale),
                accessibilityIdentifier: "calendar-toolbar-today",
                minimumDimension: controlDimension,
                horizontalPadding: 12,
                fontPointSize: CalendarToolbarControlMetrics.fontPointSize(scale: uiScale),
                isProminent: true
            ) {
                withAnimation {
                    selectedDate = Date()
                }
            }
            .background {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
            }
        } dateTitle: {
            Text(dateTitle)
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(uiScale >= CadenzaTextScale.factor(.accessibility1) ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppStyle.ColorToken.softFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 1)
                )
        } modePicker: {
            CalendarToolbarModeSelector(
                selection: $viewMode,
                scale: uiScale,
                locale: locale
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The AppKit-bridged buttons report low content-hugging, so they accept
        // any proposed height. Without pinning the toolbar to its ideal height
        // it competes with the calendar grid for the container's vertical space
        // and the VStack splits the window between them.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controlDimension: CGFloat {
        CalendarToolbarControlMetrics.controlDimension(scale: uiScale)
    }

    /// Joined previous/next pair in one bordered capsule-corner box, per the
    /// concept, instead of two loose buttons on a glass rail.
    private var navigationControls: some View {
        HStack(spacing: 0) {
            CalendarToolbarNativeButton(
                systemName: "chevron.left",
                accessibilityIdentifier: "calendar-toolbar-previous",
                minimumDimension: controlDimension,
                fontPointSize: CalendarToolbarControlMetrics.fontPointSize(scale: uiScale)
            ) {
                goBack()
            }

            Rectangle()
                .fill(AppStyle.ColorToken.mutedCapsuleStroke)
                .frame(width: 1, height: controlDimension * 0.6)

            CalendarToolbarNativeButton(
                systemName: "chevron.right",
                accessibilityIdentifier: "calendar-toolbar-next",
                minimumDimension: controlDimension,
                fontPointSize: CalendarToolbarControlMetrics.fontPointSize(scale: uiScale)
            ) {
                goForward()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppStyle.ColorToken.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppStyle.ColorToken.mutedCapsuleStroke, lineWidth: 1)
        )
    }

    private var dateTitle: String {
        Self.dateTitle(
            for: selectedDate,
            viewMode: viewMode,
            locale: locale
        )
    }

    static func dateTitle(
        for selectedDate: Date,
        viewMode: CalendarViewMode,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        switch viewMode {
        case .day:
            return LocalizedDateFormatting.string(
                from: selectedDate,
                style: .dateTime.weekday(.wide).year().month(.wide).day(),
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )

        case .week:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? selectedDate
            return LocalizedDateFormatting.interval(
                from: weekStart,
                to: weekEnd,
                dateStyle: .medium,
                timeStyle: .none,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )

        case .month:
            return LocalizedDateFormatting.string(
                from: selectedDate,
                style: .dateTime.year().month(.wide),
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
        }
    }

    private func goBack() {
        let calendar = Calendar.current
        withAnimation {
            switch viewMode {
            case .day:
                selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            case .week:
                selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
            case .month:
                selectedDate = calendar.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate
            }
        }
    }

    private func goForward() {
        let calendar = Calendar.current
        withAnimation {
            switch viewMode {
            case .day:
                selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            case .week:
                selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
            case .month:
                selectedDate = calendar.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate
            }
        }
    }
}

enum CalendarToolbarControlMetrics {
    private static func safeScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    /// Compact 24pt controls at scale 1 — the earlier 32pt base read as
    /// oversized chrome next to the grid; accessibility scaling still grows
    /// the frame through the symbol probe.
    static func controlDimension(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 11,
            scale: safeScale(scale),
            padding: 8
        )
    }

    static func fontPointSize(scale: CGFloat) -> CGFloat {
        12 * safeScale(scale)
    }
}

/// A narrow AppKit bridge for toolbar controls whose full visual frame must be
/// the real interaction frame. Applying `.frame(minHeight:)` around SwiftUI's
/// standard Button/Picker only enlarged a layout shell while their native
/// control remained about 24pt high.
struct CalendarToolbarNativeButton: NSViewRepresentable {
    private enum Content {
        case symbol(String)
        case title(String)
    }

    private let content: Content
    private let accessibilityIdentifier: String
    private let minimumDimension: CGFloat
    private let horizontalPadding: CGFloat
    private let fontPointSize: CGFloat
    private let isProminent: Bool
    private let isSelected: Bool
    private let action: @MainActor () -> Void

    init(
        systemName: String,
        accessibilityIdentifier: String,
        minimumDimension: CGFloat,
        fontPointSize: CGFloat,
        action: @escaping @MainActor () -> Void
    ) {
        content = .symbol(systemName)
        self.accessibilityIdentifier = accessibilityIdentifier
        self.minimumDimension = minimumDimension
        horizontalPadding = 0
        self.fontPointSize = fontPointSize
        isProminent = false
        isSelected = false
        self.action = action
    }

    init(
        title: String,
        accessibilityIdentifier: String,
        minimumDimension: CGFloat,
        horizontalPadding: CGFloat,
        fontPointSize: CGFloat,
        isProminent: Bool = false,
        isSelected: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        content = .title(title)
        self.accessibilityIdentifier = accessibilityIdentifier
        self.minimumDimension = minimumDimension
        self.horizontalPadding = horizontalPadding
        self.fontPointSize = fontPointSize
        self.isProminent = isProminent
        self.isSelected = isSelected
        self.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> CalendarToolbarNativeButtonView {
        let button = CalendarToolbarNativeButtonView(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.focusRingType = .default
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: CalendarToolbarNativeButtonView, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(
        _ button: CalendarToolbarNativeButtonView,
        coordinator: Coordinator
    ) {
        coordinator.action = action
        button.minimumDimension = minimumDimension
        button.horizontalPadding = horizontalPadding
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilitySelected(isSelected)

        switch content {
        case .symbol(let systemName):
            let configuration = NSImage.SymbolConfiguration(
                pointSize: fontPointSize,
                weight: .semibold
            )
            button.title = ""
            button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor

        case .title(let title):
            button.image = nil
            button.title = title
            button.font = .systemFont(
                ofSize: fontPointSize,
                weight: isSelected ? .semibold : .medium
            )
            button.contentTintColor = isProminent
                ? .alternateSelectedControlTextColor
                : (isSelected ? .labelColor : .secondaryLabelColor)
            button.setAccessibilityLabel(title)
        }

        button.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

final class CalendarToolbarNativeButtonView: NSButton {
    var minimumDimension: CGFloat = 32
    var horizontalPadding: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled,
              !isHidden,
              alphaValue > 0,
              bounds.contains(point) else {
            return nil
        }
        return self
    }

    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(
            width: ceil(max(minimumDimension, native.width + horizontalPadding * 2)),
            height: ceil(max(minimumDimension, native.height))
        )
    }
}

struct CalendarToolbarModeSelector: View {
    @Binding var selection: CalendarViewMode
    let scale: CGFloat
    let locale: Locale

    private var controlDimension: CGFloat {
        CalendarToolbarControlMetrics.controlDimension(scale: scale)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                CalendarToolbarNativeButton(
                    title: localizedTitle(for: mode),
                    accessibilityIdentifier: "calendar-toolbar-mode-\(mode.rawValue)",
                    minimumDimension: controlDimension,
                    horizontalPadding: 10,
                    fontPointSize: CalendarToolbarControlMetrics.fontPointSize(scale: scale),
                    isSelected: selection == mode
                ) {
                    selection = mode
                }
                .frame(maxWidth: .infinity)
                .background {
                    // Selected segment reads as a raised white chip, matching
                    // the concept's segmented control.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            selection == mode
                                ? Color(nsColor: .controlBackgroundColor)
                                : .clear
                        )
                        .shadow(
                            color: .black.opacity(selection == mode ? 0.12 : 0),
                            radius: 2, y: 1
                        )
                }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func localizedTitle(for mode: CalendarViewMode) -> String {
        switch mode {
        case .day:
            LocalizedBundle.string("Day", locale: locale)
        case .week:
            LocalizedBundle.string("Week", locale: locale)
        case .month:
            LocalizedBundle.string("Month", locale: locale)
        }
    }
}

/// Keeps the calendar toolbar on its existing single row when every control
/// fits at its intrinsic width. At larger text sizes the long localized date
/// moves onto a wrapping row; the navigation, Today button, and segmented
/// picker can then split once more instead of clipping inside the 800pt
/// minimum window.
struct CalendarToolbarAdaptiveLayout<Navigation: View, Today: View, DateTitle: View, ModePicker: View>: View {
    private let spacing: CGFloat
    private let navigation: Navigation
    private let today: Today
    private let dateTitle: DateTitle
    private let modePicker: ModePicker

    init(
        spacing: CGFloat = 12,
        @ViewBuilder navigation: () -> Navigation,
        @ViewBuilder today: () -> Today,
        @ViewBuilder dateTitle: () -> DateTitle,
        @ViewBuilder modePicker: () -> ModePicker
    ) {
        self.spacing = spacing
        self.navigation = navigation()
        self.today = today()
        self.dateTitle = dateTitle()
        self.modePicker = modePicker()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                navigation.fixedSize(horizontal: true, vertical: false)
                today.fixedSize(horizontal: true, vertical: false)
                dateTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                modePicker.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        navigation.fixedSize(horizontal: true, vertical: false)
                        today.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        modePicker.fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            navigation.fixedSize(horizontal: true, vertical: false)
                            today.fixedSize(horizontal: true, vertical: false)
                        }
                        modePicker.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                dateTitle.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    CalendarToolbarView(
        viewMode: .constant(.week),
        selectedDate: .constant(Date())
    )
    .frame(width: 700)
}
