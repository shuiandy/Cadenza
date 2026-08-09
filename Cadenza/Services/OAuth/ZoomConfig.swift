import Foundation

/// Zoom OAuth public client configuration.
///
/// Cadenza is a Zoom Marketplace **public PKCE** OAuth app: there is no client
/// secret embedded anywhere in the binary. The Public Client ID below is a
/// public identifier — safe to ship in the bundle. Security relies on PKCE
/// (RFC 7636) and the user's explicit consent at zoom.us/oauth/authorize.
///
/// To enable a different ID for development/staging, override at build time
/// via the `ZOOM_PUBLIC_CLIENT_ID` user-defined build setting. When unset,
/// we fall back to the production Public Client ID.
enum ZoomConfig {
    /// Production Public Client ID (Marketplace → Cadenza → Public client).
    /// Issued 2026-05-02 by Zoom Marketplace (no secret).
    static let defaultPublicClientID = "YGYL9BE7SA22zA0G9k7rLQ"

    /// Resolved Public Client ID, with optional Info.plist override.
    static var publicClientID: String {
        if let override = Bundle.main.object(forInfoDictionaryKey: "ZoomPublicClientID") as? String,
           !override.isEmpty {
            return override
        }
        return defaultPublicClientID
    }
}
