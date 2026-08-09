import Foundation

struct GeminiEphemeralToken: Equatable, Sendable {
    private static let prefix = "auth_tokens/"
    private static let maximumByteCount = 1_024

    let name: String
    let newSessionExpireTime: Date

    static func isValidName(_ token: String) -> Bool {
        guard token.hasPrefix(prefix),
              token.utf8.count <= maximumByteCount else {
            return false
        }
        let suffix = token.dropFirst(prefix.count)
        guard !suffix.isEmpty else { return false }
        return suffix.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
        }
    }
}

enum GeminiEphemeralTokenError: Error, LocalizedError {
    case invalidResponse
    case invalidToken
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Gemini returned an invalid ephemeral token response"
        case .invalidToken:
            "Gemini returned an invalid ephemeral token"
        case .requestFailed:
            "Gemini ephemeral token request failed"
        }
    }
}
