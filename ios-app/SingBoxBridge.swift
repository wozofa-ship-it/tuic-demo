import Foundation
import Libbox

/// Thin Swift wrapper over the gomobile-generated Libbox bindings.
///
/// SYMBOL NAMES ARE AN ASSUMPTION — READ NOTES.md BEFORE BUILDING:
/// gomobile bind names package-level Go functions as
/// <CapitalizedPackageName><FuncName> (here: LibboxSetup, LibboxCheckConfig,
/// LibboxStartService, LibboxStopService, LibboxVersion), with Go `error`
/// returns surfacing as Swift `throws`. After the first CI build, confirm
/// against Libbox.xcframework's generated headers and fix the names here if
/// they differ — that is a one-line-per-call fix, not a redesign.
///
/// Security: the TUIC config JSON (which contains uuid/password) is passed
/// to sing-box and never written to disk, never logged, and never included
/// in the result text. sing-box dial errors shown on screen may contain the
/// server address, but never uuid/password; they are displayed only in the
/// UI, never persisted.
enum SingBoxBridge {
    static let socksPort = 10808

    private static var setupDone = false

    /// One-time libbox init. All three paths point at Documents/singbox.
    static func setupIfNeeded() throws {
        guard !setupDone else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("singbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        try LibboxSetup(path, path, path)
        setupDone = true
    }

    static func version() -> String {
        LibboxVersion()
    }

    /// Validate the config, then start the core. Throws the sing-box error
    /// verbatim on failure.
    static func start(configJSON: String) throws {
        try setupIfNeeded()
        try LibboxCheckConfig(configJSON)
        try LibboxStartService(configJSON)
    }

    static func stop() throws {
        try LibboxStopService()
    }

    /// Probe https://example.com through the local SOCKS inbound.
    /// Returns (HTTP status, milliseconds). Throws the URLSession error.
    static func probe() async throws -> (status: Int, milliseconds: Int) {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: socksPort,
        ]
        let session = URLSession(configuration: sessionConfig)
        var request = URLRequest(
            url: URL(string: "https://example.com")!,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        let start = Date()
        let (_, response) = try await session.data(for: request)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, elapsed)
    }
}
