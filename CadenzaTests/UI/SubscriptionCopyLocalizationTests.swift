import Foundation
import Testing
@testable import Cadenza

/// Runtime proof that the production wording actually resolves to a translation
/// table. These call the same methods the views call; a bare English return
/// fails here, which a catalogue inventory alone cannot detect.
@Suite("Subscription Copy Localization")
struct SubscriptionCopyLocalizationTests {
    private static let zh = Locale(identifier: "zh-Hans")

    private static func isChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func expectTranslated(
        _ produced: String, _ english: String, _ label: String
    ) {
        #expect(produced != english, "\(label) returned the English source")
        #expect(Self.isChinese(produced), "\(label) produced no Chinese: \(produced)")
    }

    private static func limits(
        lifecycle: EntitlementsPresentation.Known<EntitlementsPresentation.Lifecycle> = .defined(.active),
        unit: EntitlementsPresentation.Known<EntitlementsPresentation.TextUnit> = .defined(.recordings),
        period: EntitlementsPresentation.Known<EntitlementsPresentation.Period> = .defined(.allTime),
        text: EntitlementsPresentation.Meter = .init(used: 13, limit: 200),
        storage: EntitlementsPresentation.Meter = .init(used: 1_200, limit: 5_000),
        reserved: Int64 = 0,
        audioEntitled: Bool = true
    ) -> EntitlementsPresentation.Limits {
        .init(
            plan: "pro", lifecycle: lifecycle, textUnit: unit, period: period, text: text,
            audioUploadEntitled: audioEntitled, storage: storage, storageReserved: reserved
        )
    }

    @Test func cardChromeAndStateCopyIsTranslated() {
        Self.expectTranslated(EntitlementsCopy.cardTitle(locale: Self.zh), "Subscription", "card title")
        Self.expectTranslated(
            EntitlementsCopy.cardSubtitle(locale: Self.zh),
            "Plan and usage for the account this profile is linked to", "card subtitle"
        )
        Self.expectTranslated(
            EntitlementsCopy.syncUnavailable(locale: Self.zh),
            "Sync is unavailable in this session.", "sync unavailable"
        )
        Self.expectTranslated(EntitlementsCopy.refresh(locale: Self.zh), "Refresh", "refresh")
        Self.expectTranslated(
            EntitlementsCopy.manageSubscription(locale: Self.zh), "Manage Subscription", "manage"
        )
    }

    @Test func unavailableAndSelfHostCopyIsTranslated() {
        Self.expectTranslated(
            EntitlementsCopy.unavailableTitle(locale: Self.zh), "Plan status unavailable", "unavailable title"
        )
        let detail = EntitlementsCopy.unavailableDetail(locale: Self.zh)
        Self.expectTranslated(
            detail,
            "This Mac has no usable plan or usage information for this account. Recordings on this Mac are unaffected.",
            "unavailable detail"
        )
        Self.expectTranslated(
            EntitlementsCopy.selfHostTitle(locale: Self.zh), "Managed by this backend", "self host title"
        )
        Self.expectTranslated(
            EntitlementsCopy.selfHostDetail(locale: Self.zh),
            "This account is on a self-hosted backend that does not report plan limits. Any limits are that server's own.",
            "self host detail"
        )
    }

    @Test func fieldLabelsAreTranslated() {
        for (produced, english, label) in [
            (EntitlementsCopy.planLabel(locale: Self.zh), "Plan", "plan"),
            (EntitlementsCopy.statusLabel(locale: Self.zh), "Status", "status"),
            (EntitlementsCopy.textSyncLabel(locale: Self.zh), "Text sync", "text sync"),
            (EntitlementsCopy.audioStorageLabel(locale: Self.zh), "Audio storage", "audio storage"),
            (EntitlementsCopy.audioUploadLabel(locale: Self.zh), "Audio upload", "audio upload"),
        ] {
            Self.expectTranslated(produced, english, label)
        }
    }

    @Test func lifecycleCopyIsTranslatedIncludingUnknownAndGrace() {
        Self.expectTranslated(
            EntitlementsCopy.lifecycle(.defined(.active), locale: Self.zh), "Active", "active"
        )
        Self.expectTranslated(
            EntitlementsCopy.lifecycle(.defined(.expired), locale: Self.zh), "Expired", "expired"
        )

        // The raw value stays visible inside translated wording.
        let unknown = EntitlementsCopy.lifecycle(.unrecognized(raw: "suspended"), locale: Self.zh)
        #expect(unknown.contains("suspended"))
        #expect(Self.isChinese(unknown))
        #expect(!unknown.hasPrefix("Not recognized"))

        let deadline = Date(timeIntervalSince1970: 1_788_000_000)
        let grace = EntitlementsCopy.lifecycle(.defined(.grace(until: deadline)), locale: Self.zh)
        #expect(Self.isChinese(grace))
        #expect(!grace.hasPrefix("Grace period"))
        // The argument is rendered, not dropped.
        #expect(grace.contains(EntitlementsCopy.instant(deadline, locale: Self.zh)))
    }

    @Test func meterAndWindowCopyIsTranslatedForEveryShape() {
        let unlimited = EntitlementsCopy.meter(
            .init(used: 13, limit: nil), unit: .defined(.recordings), locale: Self.zh
        )
        #expect(Self.isChinese(unlimited))
        #expect(!unlimited.contains("unlimited"))

        let bounded = EntitlementsCopy.meter(
            .init(used: 13, limit: 200), unit: .defined(.recordings), locale: Self.zh
        )
        #expect(Self.isChinese(bounded))
        #expect(!bounded.contains(" of "))

        Self.expectTranslated(
            EntitlementsCopy.meter(.init(used: nil, limit: 10), unit: .defined(.bytes), locale: Self.zh),
            "Amount unavailable", "unstatable amount"
        )
        Self.expectTranslated(
            EntitlementsCopy.window(.defined(.allTime), locale: Self.zh), "all time", "all time"
        )
        Self.expectTranslated(
            EntitlementsCopy.window(.defined(.monthly(resetsAt: nil)), locale: Self.zh),
            "this month", "monthly without a reset"
        )
        let unknownWindow = EntitlementsCopy.window(.unrecognized(raw: "weekly"), locale: Self.zh)
        #expect(unknownWindow.contains("weekly"))
        #expect(Self.isChinese(unknownWindow))

        // An unrecognized unit keeps the server's own spelling beside the count.
        let opaqueUnit = EntitlementsCopy.amount(7, unit: .unrecognized(raw: "minutes"), locale: Self.zh)
        #expect(opaqueUnit == "7 minutes")
    }

    @Test func usageLinesAreTranslated() {
        let text = EntitlementsCopy.textUsage(Self.limits(), locale: Self.zh)
        #expect(Self.isChinese(text))
        let storage = EntitlementsCopy.storageUsage(
            Self.limits(storage: .init(used: 6_000, limit: 5_000), reserved: 500), locale: Self.zh
        )
        #expect(Self.isChinese(storage))
        // Each appended clause is translated, not only the leading meter.
        #expect(!storage.contains("over limit"))
        #expect(!storage.contains("in progress"))
        #expect(!storage.contains(" of "))
    }

    @Test func warningCopyIsTranslated() {
        for warning in EntitlementsPresentation.Warning.allCases {
            let produced = EntitlementsCopy.warning(warning, locale: Self.zh)
            #expect(Self.isChinese(produced), "\(warning) produced no Chinese: \(produced)")
            #expect(!produced.contains("paused:"))
        }
    }

    @Test func audioControlDenialCopyIsTranslatedAndAbsentWhenAvailable() {
        #expect(EntitlementsCopy.audioControlDenial(.available, locale: Self.zh) == nil)
        for control: EntitlementsPresentation.AudioControl in [
            .deniedNoAuthority, .deniedByPlan,
            .deniedByPause(.audioUploadNotEntitled), .deniedByPause(.storageQuotaExceeded),
        ] {
            let produced = try! #require(EntitlementsCopy.audioControlDenial(control, locale: Self.zh))
            #expect(Self.isChinese(produced), "\(control) produced no Chinese: \(produced)")
            #expect(!produced.contains("switch is unavailable"))
        }
        let note = EntitlementsCopy.audioPausedNote(locale: Self.zh)
        Self.expectTranslated(
            note,
            "Audio upload stays switched on for this account. New uploads are currently paused; the saved choice will apply again when uploads become available.",
            "paused note"
        )
        // The same note covers a state where no plan conclusion exists, so
        // neither language may attribute the pause to a plan.
        #expect(!note.contains("套餐"))
        #expect(!EntitlementsCopy.audioPausedNote().contains("plan"))
        Self.expectTranslated(
            EntitlementsCopy.audioEntitlement(false, locale: Self.zh),
            "Not included right now", "not entitled"
        )
        Self.expectTranslated(EntitlementsCopy.audioEntitlement(true, locale: Self.zh), "Available", "entitled")
    }
}
