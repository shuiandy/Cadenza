import Foundation

/// Every user-visible string the subscription surface renders.
///
/// The views call these and format nothing themselves, so the wording a user
/// actually sees is what a test can call directly. Each entry takes a locale so
/// a test can ask for a specific translation table; the views pass nil, which
/// is the running locale.
enum EntitlementsCopy {
    // MARK: - Card chrome

    static func cardTitle(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Subscription", locale: locale)
    }

    static func cardSubtitle(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Plan and usage for the account this profile is linked to", locale: locale)
    }

    static func syncUnavailable(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Sync is unavailable in this session.", locale: locale)
    }

    static func refresh(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Refresh", locale: locale)
    }

    static func manageSubscription(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Manage Subscription", locale: locale)
    }

    // MARK: - States

    static func unavailableTitle(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Plan status unavailable", locale: locale)
    }

    /// States exactly what is and is not known. New audio transfers do fail
    /// closed without authority, so this never claims sync is unaffected.
    static func unavailableDetail(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "This Mac has no usable plan or usage information for this account. Recordings on this Mac are unaffected.",
            locale: locale
        )
    }

    static func selfHostTitle(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Managed by this backend", locale: locale)
    }

    static func selfHostDetail(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "This account is on a self-hosted backend that does not report plan limits. Any limits are that server's own.",
            locale: locale
        )
    }

    // MARK: - Field labels

    static func planLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Plan", locale: locale)
    }

    static func statusLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Status", locale: locale)
    }

    static func textSyncLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Text sync", locale: locale)
    }

    static func audioStorageLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Audio storage", locale: locale)
    }

    static func audioUploadLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Audio upload", locale: locale)
    }

    // MARK: - Values

    static func lifecycle(
        _ lifecycle: EntitlementsPresentation.Known<EntitlementsPresentation.Lifecycle>,
        locale: Locale? = nil
    ) -> String {
        switch lifecycle {
        case .defined(.active):
            return LocalizedBundle.string("Active", locale: locale)
        case .defined(.grace(let until)):
            return LocalizedBundle.string(
                "Grace period until \(instant(until, locale: locale))", locale: locale
            )
        case .defined(.expired):
            return LocalizedBundle.string("Expired", locale: locale)
        case .unrecognized(let raw):
            return LocalizedBundle.string("Not recognized by this version (\(raw))", locale: locale)
        }
    }

    static func audioEntitlement(_ entitled: Bool, locale: Locale? = nil) -> String {
        entitled
            ? LocalizedBundle.string("Available", locale: locale)
            : LocalizedBundle.string("Not included right now", locale: locale)
    }

    static func textUsage(_ limits: EntitlementsPresentation.Limits, locale: Locale? = nil) -> String {
        "\(meter(limits.text, unit: limits.textUnit, locale: locale)) · \(window(limits.period, locale: locale))"
    }

    static func window(
        _ period: EntitlementsPresentation.Known<EntitlementsPresentation.Period>,
        locale: Locale? = nil
    ) -> String {
        switch period {
        case .defined(.allTime):
            return LocalizedBundle.string("all time", locale: locale)
        case .defined(.monthly(let resetsAt)):
            guard let resetsAt else { return LocalizedBundle.string("this month", locale: locale) }
            return LocalizedBundle.string("resets \(instant(resetsAt, locale: locale))", locale: locale)
        case .unrecognized(let raw):
            return LocalizedBundle.string("window not recognized (\(raw))", locale: locale)
        }
    }

    static func storageUsage(
        _ limits: EntitlementsPresentation.Limits, locale: Locale? = nil
    ) -> String {
        var text = meter(limits.storage, unit: .defined(.bytes), locale: locale)
        if limits.storageReserved > 0 {
            text += " · " + LocalizedBundle.string(
                "includes \(bytes(limits.storageReserved)) in progress", locale: locale
            )
        }
        if limits.storage.isOverLimit {
            text += " · " + LocalizedBundle.string("over limit", locale: locale)
        }
        return text
    }

    static func meter(
        _ meter: EntitlementsPresentation.Meter,
        unit: EntitlementsPresentation.Known<EntitlementsPresentation.TextUnit>,
        locale: Locale? = nil
    ) -> String {
        guard let used = meter.used else {
            // A total this build cannot state exactly is reported as such.
            return LocalizedBundle.string("Amount unavailable", locale: locale)
        }
        let usedText = amount(used, unit: unit, locale: locale)
        guard let limit = meter.limit else {
            return LocalizedBundle.string("\(usedText) used · unlimited", locale: locale)
        }
        return LocalizedBundle.string(
            "\(usedText) of \(amount(limit, unit: unit, locale: locale))", locale: locale
        )
    }

    static func amount(
        _ value: Int64,
        unit: EntitlementsPresentation.Known<EntitlementsPresentation.TextUnit>,
        locale: Locale? = nil
    ) -> String {
        switch unit {
        case .defined(.bytes):
            return bytes(value)
        case .defined(.recordings):
            return LocalizedBundle.string("\(value) recordings", locale: locale)
        case .unrecognized(let raw):
            // The count is real; the unit is not one this build knows, so it is
            // shown as the server spelled it.
            return "\(value) \(raw)"
        }
    }

    // MARK: - Warnings and the audio control

    static func warning(
        _ warning: EntitlementsPresentation.Warning, locale: Locale? = nil
    ) -> String {
        switch warning {
        case .textQuotaExceeded:
            return LocalizedBundle.string(
                "Text sync is paused: this account is at its quota.", locale: locale
            )
        case .audioUploadNotEntitled:
            return LocalizedBundle.string(
                "Audio upload is paused: this plan does not include it.", locale: locale
            )
        case .storageQuotaExceeded:
            return LocalizedBundle.string(
                "Audio upload is paused: this account is at its storage limit.", locale: locale
            )
        }
    }

    /// Why the audio switch cannot be operated, or nil when it can.
    static func audioControlDenial(
        _ control: EntitlementsPresentation.AudioControl, locale: Locale? = nil
    ) -> String? {
        switch control {
        case .available:
            return nil
        case .deniedNoAuthority:
            return LocalizedBundle.string(
                "This Mac cannot confirm whether this account may upload audio, so the switch is unavailable. Your choice is kept.",
                locale: locale
            )
        case .deniedByPlan:
            return LocalizedBundle.string(
                "This plan does not include audio upload right now, so the switch is unavailable. Your choice is kept.",
                locale: locale
            )
        case .deniedByPause(let paused):
            return pausedDenial(paused, locale: locale)
        }
    }

    private static func pausedDenial(
        _ warning: EntitlementsPresentation.Warning, locale: Locale?
    ) -> String {
        switch warning {
        case .storageQuotaExceeded:
            return LocalizedBundle.string(
                "This account is at its storage limit, so the switch is unavailable. Your choice is kept.",
                locale: locale
            )
        default:
            return LocalizedBundle.string(
                "This plan does not include audio upload right now, so the switch is unavailable. Your choice is kept.",
                locale: locale
            )
        }
    }

    /// Shown next to the switch when the preference is on but uploads are
    /// held. It names no cause: the same note covers a stated plan denial
    /// and an account this Mac holds no answer for.
    static func audioPausedNote(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "Audio upload stays switched on for this account. New uploads are currently paused; the saved choice will apply again when uploads become available.",
            locale: locale
        )
    }

    // MARK: - Formatting

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func instant(_ date: Date, locale: Locale? = nil) -> String {
        date.formatted(.dateTime.locale(locale ?? .current).year().month(.abbreviated).day()
            .hour().minute())
    }
}
