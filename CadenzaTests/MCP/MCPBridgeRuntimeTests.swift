import Foundation
import Testing
@testable import Cadenza

@Suite("MCPBridgeRuntime")
struct MCPBridgeRuntimeTests {

    private func makeRuntime() throws -> MCPBridgeRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-runtime-\(UUID().uuidString)/mcp", isDirectory: true)
        return MCPBridgeRuntime(root: root)
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Endpoint

    @Test func endpointRoundTripsAndOverwrites() throws {
        let runtime = try makeRuntime()
        #expect(runtime.readEndpointURL() == nil)

        try runtime.writeEndpoint(url: "http://127.0.0.1:8585/mcp")
        #expect(runtime.readEndpointURL() == "http://127.0.0.1:8585/mcp")

        // Port change rewrites in place — the bridge converges on next read.
        try runtime.writeEndpoint(url: "http://127.0.0.1:9000/mcp")
        #expect(runtime.readEndpointURL() == "http://127.0.0.1:9000/mcp")
    }

    @Test func endpointFileIsPrivate() throws {
        let runtime = try makeRuntime()
        try runtime.writeEndpoint(url: "http://127.0.0.1:8585/mcp")
        #expect(try posixPermissions(at: runtime.endpointFileURL) == 0o600)
        #expect(try posixPermissions(at: runtime.root) == 0o700)
    }

    @Test func endpointRejectsGarbageContent() throws {
        let runtime = try makeRuntime()
        try FileManager.default.createDirectory(at: runtime.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: runtime.endpointFileURL)
        #expect(runtime.readEndpointURL() == nil)
    }

    // MARK: - Credentials

    @Test func credentialRoundTripRemoveAndPermissions() throws {
        let runtime = try makeRuntime()
        #expect(runtime.credential(for: "claude-desktop") == nil)

        try runtime.writeCredential("tok-1", for: "claude-desktop")
        #expect(runtime.credential(for: "claude-desktop") == "tok-1")
        let file = try runtime.credentialFileURL(for: "claude-desktop")
        #expect(try posixPermissions(at: file) == 0o600)
        #expect(try posixPermissions(at: runtime.credentialsDirectoryURL) == 0o700)

        // Reconnect overwrites in place.
        try runtime.writeCredential("tok-2", for: "claude-desktop")
        #expect(runtime.credential(for: "claude-desktop") == "tok-2")

        try runtime.removeCredential(for: "claude-desktop")
        #expect(runtime.credential(for: "claude-desktop") == nil)
        // Removing an absent credential is a no-op, not an error.
        try runtime.removeCredential(for: "claude-desktop")
    }

    @Test func clientIDsBecomeFileNamesSoUnsafeOnesAreRefused() throws {
        let runtime = try makeRuntime()
        for bad in ["", "UPPER", "with space", "../escape", "dot.dot", String(repeating: "a", count: 129)] {
            #expect(throws: MCPBridgeRuntime.RuntimeError.self, "should refuse: \(bad)") {
                try runtime.writeCredential("t", for: bad)
            }
            #expect(runtime.credential(for: bad) == nil)
        }
        // Every real connector access ID passes.
        for client in MCPClientConnector.Client.allCases {
            #expect(MCPBridgeRuntime.isValidClientID(client.accessID), "rejected: \(client.accessID)")
        }
    }

    @Test func credentialTrimsTrailingNewline() throws {
        let runtime = try makeRuntime()
        try FileManager.default.createDirectory(at: runtime.credentialsDirectoryURL,
                                                withIntermediateDirectories: true)
        let file = try runtime.credentialFileURL(for: "codex-cli")
        try Data("tok-3\n".utf8).write(to: file)
        #expect(runtime.credential(for: "codex-cli") == "tok-3")
    }
}
