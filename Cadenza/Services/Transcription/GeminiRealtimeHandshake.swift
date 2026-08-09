import CryptoKit
import Foundation

enum GeminiRealtimeHandshakeError: Error, LocalizedError {
    case invalidCredential
    case invalidModel
    case invalidRequest
    case upgradeRejected
    case setupRejected

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "Gemini realtime authentication failed"
        case .invalidModel:
            "The Gemini realtime model is invalid"
        case .invalidRequest:
            "The Gemini realtime upgrade request is invalid"
        case .upgradeRejected:
            "Gemini rejected the realtime connection"
        case .setupRejected:
            "Gemini rejected the realtime setup"
        }
    }
}

enum GeminiRealtimeHandshake {
    static let host = "generativelanguage.googleapis.com"
    static let path = "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"

    private static let allowedModelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func validateModel(_ model: String) throws {
        guard !model.isEmpty,
              model.utf8.count <= 256,
              model.unicodeScalars.allSatisfy(allowedModelCharacters.contains) else {
            throw GeminiRealtimeHandshakeError.invalidModel
        }
    }

    static func makeUpgradeRequest(
        token: String,
        webSocketKey: String
    ) throws -> Data {
        guard GeminiEphemeralToken.isValidName(token) else {
            throw GeminiRealtimeHandshakeError.invalidCredential
        }
        guard !webSocketKey.isEmpty,
              webSocketKey.utf8.count <= 128,
              !webSocketKey.contains("\r"),
              !webSocketKey.contains("\n") else {
            throw GeminiRealtimeHandshakeError.invalidRequest
        }

        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(host)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(webSocketKey)\r
        Sec-WebSocket-Version: 13\r
        Authorization: Token \(token)\r
        User-Agent: Cadenza/1.0\r
        \r

        """
        guard let data = request.data(using: .utf8) else {
            throw GeminiRealtimeHandshakeError.invalidRequest
        }
        return data
    }

    static func validateUpgradeResponseHeader(
        _ data: Data,
        webSocketKey: String
    ) throws {
        guard let response = String(data: data, encoding: .utf8) else {
            throw GeminiRealtimeHandshakeError.upgradeRejected
        }

        let lines = response.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw GeminiRealtimeHandshakeError.upgradeRejected
        }
        let statusParts = statusLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1",
              statusParts[1] == "101" else {
            throw GeminiRealtimeHandshakeError.upgradeRejected
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw GeminiRealtimeHandshakeError.upgradeRejected
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else {
                throw GeminiRealtimeHandshakeError.upgradeRejected
            }
            headers[name, default: []].append(value)
        }

        guard headers["upgrade"]?.count == 1,
              headers["upgrade"]?.first?.lowercased() == "websocket",
              let connectionValues = headers["connection"],
              connectionValues.flatMap(commaSeparatedTokens).contains("upgrade"),
              headers["sec-websocket-accept"]?.count == 1,
              headers["sec-websocket-accept"]?.first == expectedAcceptValue(for: webSocketKey) else {
            throw GeminiRealtimeHandshakeError.upgradeRejected
        }
    }

    static func validateSetupAcknowledgement(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              message.count == 1,
              message["error"] == nil,
              (message["setupComplete"] ?? message["setup_complete"]) is [String: Any] else {
            throw GeminiRealtimeHandshakeError.setupRejected
        }
    }

    private static func commaSeparatedTokens(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func expectedAcceptValue(for webSocketKey: String) -> String {
        let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((webSocketKey + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }
}
