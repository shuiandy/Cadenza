import Foundation

/// Fallback handler for `com.shuiandy.cadenza://` URLs that arrive via
/// `View.onOpenURL`. Under the normal Phase 1 flow,
/// `ASWebAuthenticationSession` consumes these directly — anything reaching
/// this router indicates the system delivered the URL to the app instead.
/// We log and no-op for v1; future phases may route to coordinators here.
@MainActor
final class CadenzaURLSchemeRouter {
    static let shared = CadenzaURLSchemeRouter()
    private static let acceptedScheme = "com.shuiandy.cadenza"

    private init() {}

    func handle(_ url: URL) {
        guard url.scheme == CadenzaURLSchemeRouter.acceptedScheme else {
            NSLog("[URLScheme] ignoring url with scheme: %@",
                  String(describing: url.scheme) as NSString)
            return
        }
        // Don't log the full URL — query may contain attempt IDs.
        let host = url.host ?? "<no-host>"
        let path = url.path
        NSLog("[URLScheme] received fallback %@%@", host as NSString, path as NSString)
    }
}
