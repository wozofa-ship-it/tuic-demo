import Foundation
import Libbox

/// Thin Swift wrapper over the gomobile-generated Libbox bindings.
///
/// VERIFIED against the CI-generated header (Libbox.objc.h, 2026-11-02):
/// gomobile bind emits plain C functions, NOT ObjC methods, so Swift does
/// NOT convert them to `throws`. A Go function returning only `error`
/// becomes `BOOL LibboxXxx(..., NSError** error)` — the call site must pass
/// an NSErrorPointer (`&error`) and check the BOOL. Names are confirmed:
/// LibboxSetup / LibboxCheckConfig / LibboxStartService / LibboxStopService /
/// LibboxVersion (no-error functions like Version import cleanly).
///
/// Security: the TUIC config JSON (which contains uuid/password) is passed
/// to sing-box and never written to disk, never logged, and never included
/// in the result text. sing-box dial errors shown on screen may contain the
/// server address, but never uuid/password; they are displayed only in the
/// UI, never persisted.
enum SingBoxBridge {
    static let socksPort = 10808

    private static var setupDone = false

    /// One-time libbox init. basePath MUST be Documents root, not
    /// Documents/singbox: libbox binds its command server at
    /// basePath + "/command.sock" (1.14.4 command_server.go:142),
    /// and Darwin AF_UNIX sun_path caps at 104 bytes. The app
    /// container prefix alone is 76 bytes, so Documents/singbox
    /// + "/command.sock" = 107 bytes and bind fails EINVAL
    /// ("invalid argument") on device. Documents root gives
    /// 99 bytes. workingPath/tempPath stay Documents/singbox.
    static func setupIfNeeded() throws {
        guard !setupDone else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("singbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var error: NSError?
        guard LibboxSetup(docs.path, dir.path, dir.path, &error) else {
            throw error ?? NSError(domain: "TUICDemo", code: -1, userInfo: [NSLocalizedDescriptionKey: "libbox setup failed"])
        }
        setupDone = true
    }

    static func version() -> String {
        LibboxVersion()
    }

    /// Validate the config, then start the core. Throws the sing-box error
    /// verbatim on failure.
    static func start(configJSON: String) throws {
        try setupIfNeeded()
        var error: NSError?
        guard LibboxCheckConfig(configJSON, &error) else {
            throw error ?? NSError(domain: "TUICDemo", code: -1, userInfo: [NSLocalizedDescriptionKey: "config check failed"])
        }
        guard LibboxStartService(configJSON, &error) else {
            throw error ?? NSError(domain: "TUICDemo", code: -1, userInfo: [NSLocalizedDescriptionKey: "service start failed"])
        }
    }

    static func stop() throws {
        var error: NSError?
        guard LibboxStopService(&error) else {
            throw error ?? NSError(domain: "TUICDemo", code: -1, userInfo: [NSLocalizedDescriptionKey: "service stop failed"])
        }
    }

    /// Probe https://example.com through the local SOCKS inbound.
    /// Returns (HTTP status, milliseconds). Throws the URLSession error.
    ///
    /// The kCFNetworkProxiesSOCKS* constants are macOS-only in the SDK
    /// (CF_AVAILABLE(10_6, NA)); the raw string keys below carry the same
    /// values ("SOCKSEnable" / "SOCKSProxy" / "SOCKSPort") and are what
    /// URLSession reads on iOS.
    static func probe() async throws -> (status: Int, milliseconds: Int) {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [
            "SOCKSEnable": true,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort,
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
