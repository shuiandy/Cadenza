import Foundation

/// Locale-injectable string lookup.
///
/// `String(localized:locale:)`'s locale parameter only affects interpolation
/// formatting; translation-table selection always follows the bundle. To
/// resolve a specific language, look up the matching `.lproj` sub-bundle
/// explicitly. A nil locale uses the normal main-bundle path.
enum LocalizedBundle {

    static func string(_ key: String.LocalizationValue, locale: Locale?) -> String {
        guard let locale else { return String(localized: key) }
        return String(localized: key, bundle: bundle(for: locale), locale: locale)
    }

    static func bundle(for locale: Locale) -> Bundle {
        var candidates = [
            locale.identifier,
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
        ]
        if let languageCode = locale.language.languageCode?.identifier {
            candidates.append(languageCode)
        }
        for name in candidates {
            if let path = Bundle.main.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }
}
