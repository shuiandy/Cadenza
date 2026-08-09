import Foundation
import Testing

@testable import Cadenza

@MainActor
@Suite("Automatic Recap Generation")
struct RecapAutomaticGenerationTests {
    @Test func automaticGenerationIsOffUntilExplicitlyEnabled() async {
        let defaults = makeDefaults()
        var generationCount = 0

        let didGenerate = await AutomaticRecapGeneration.runIfEnabled(defaults: defaults) {
            generationCount += 1
        }

        #expect(!didGenerate)
        #expect(generationCount == 0)
    }

    @Test func explicitEnablementRunsGeneration() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AutomaticRecapGeneration.defaultsKey)
        var generationCount = 0

        let didGenerate = await AutomaticRecapGeneration.runIfEnabled(defaults: defaults) {
            generationCount += 1
        }

        #expect(didGenerate)
        #expect(generationCount == 1)
    }

    @Test func disablingAgainStopsFutureStartupGeneration() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AutomaticRecapGeneration.defaultsKey)
        defaults.set(false, forKey: AutomaticRecapGeneration.defaultsKey)
        var generationCount = 0

        let didGenerate = await AutomaticRecapGeneration.runIfEnabled(defaults: defaults) {
            generationCount += 1
        }

        #expect(!didGenerate)
        #expect(generationCount == 0)
    }

    @Test func generatedRecapTitlesUseTheSelectedLocale() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let startDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        let endDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let locale = Locale(identifier: "zh-Hans")

        let weeklyTitle = RecapGenerator.weeklyTitle(
            startDate: startDate,
            endDate: endDate,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        let monthlyTitle = RecapGenerator.monthlyTitle(
            startDate: startDate,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )

        #expect(weeklyTitle.hasPrefix("每周回顾："))
        #expect(!weeklyTitle.contains("Weekly Recap"))
        #expect(monthlyTitle.hasPrefix("每月回顾："))
        #expect(!monthlyTitle.contains("Monthly Recap"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RecapAutomaticGenerationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
