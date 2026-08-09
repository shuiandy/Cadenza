import Foundation

/// Notion OAuth configuration for the Cadenza Mac app.
///
/// Notion does NOT support public PKCE: token exchange requires HTTP Basic
/// auth with `client_id:client_secret`. To keep the secret out of the
/// shipping binary, the Mac app sends only the authorization code to
/// `cadenzapp.com/api/v1/oauth/notion/exchange`, which holds the secret
/// server-side and proxies the token call.
///
/// The `clientID` below IS public (it appears in the authorize URL the
/// user sees in their browser anyway). Override at build time via the
/// Info.plist key `NotionClientID` if a non-default integration is needed.
enum NotionConfig {
    /// Cadenza's public Notion integration client_id.
    /// Issued by Notion → "OAuth & domains" tab on the integration page.
    static let defaultClientID = "30dd872b-594c-810f-bccc-00378c1c64ae"

    static var clientID: String {
        if let override = Bundle.main.object(forInfoDictionaryKey: "NotionClientID") as? String,
           !override.isEmpty {
            return override
        }
        return defaultClientID
    }
}
