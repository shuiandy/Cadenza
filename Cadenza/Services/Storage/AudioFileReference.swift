import Foundation

/// Storage-layer reference to an audio file or segments directory.
///
/// The database column stays a plain String; this enum is the typed view of
/// that value: a leading "/" classifies it as `legacyAbsolute`, anything else
/// as `relative` (a POSIX path under the profile audio root). Classification
/// is total — every stored string maps to exactly one case, so old data can
/// never fail to decode. Malformed relative paths (e.g. containing "..") are
/// rejected at resolve time by `ProfileStorageResolver`, not at init.
///
/// `legacyAbsolute` has no removal timeline: users may upgrade from any old
/// version directly, and decoding their absolute paths is a required part of
/// that path.
enum AudioFileReference: Equatable, Hashable, Sendable {
    case relative(String)
    case legacyAbsolute(String)

    init(storageValue: String) {
        self = storageValue.hasPrefix("/")
            ? .legacyAbsolute(storageValue)
            : .relative(storageValue)
    }

    /// Empty database values map to a nil reference at the store boundary.
    init?(storageValue: String?) {
        guard let storageValue, !storageValue.isEmpty else { return nil }
        self.init(storageValue: storageValue)
    }

    var storageValue: String {
        switch self {
        case .relative(let path), .legacyAbsolute(let path): path
        }
    }

    var isLegacy: Bool {
        if case .legacyAbsolute = self { return true }
        return false
    }

    /// Filename without resolving against a root — safe for display, mirror
    /// naming, and filename-based date parsing.
    var lastPathComponent: String {
        (storageValue as NSString).lastPathComponent
    }
}

extension AudioFileReference: Codable {
    /// Encoded as the bare storage string so DTO JSON stays a single value
    /// and follows the same classification rule as the database column.
    init(from decoder: Decoder) throws {
        self.init(storageValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}
