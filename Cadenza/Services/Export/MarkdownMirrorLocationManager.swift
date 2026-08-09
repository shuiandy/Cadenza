import Foundation

enum MarkdownMirrorLocationManager {
    static var enabledDefaultsKey: String { ActiveProfileDefaults.key("markdownMirrorEnabled") }
    static var includeTranscriptDefaultsKey: String { ActiveProfileDefaults.key("markdownMirrorIncludeTranscript") }
    static var ledgerDefaultsKey: String { ActiveProfileDefaults.key("markdownMirrorLedger.v1") }
    private static var bookmarkKey: String { ActiveProfileDefaults.key("markdownMirrorDirectoryBookmark") }
    private static var pathKey: String { ActiveProfileDefaults.key("markdownMirrorDirectoryPath") }

    static var directory: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale,
           let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
           ) {
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }

    static var displayPath: String? {
        UserDefaults.standard.string(forKey: pathKey)?.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    static func setDirectory(_ url: URL) throws {
        let previousPath = UserDefaults.standard.string(forKey: pathKey)
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if previousPath != url.path {
            // Ledger hashes only describe files in the folder that produced
            // them. Reusing those hashes in a different folder would mark
            // every missing note as a permanent conflict.
            UserDefaults.standard.removeObject(forKey: ledgerDefaultsKey)
        }
    }

    static func clearDirectory() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
    }
}
