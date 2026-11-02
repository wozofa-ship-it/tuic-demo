import Foundation
import Libbox
import Network

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

    /// Probe example.com through the local SOCKS inbound WITHOUT URLSession.
    /// Returns (HTTP status, milliseconds). Stage errors carry domain
    /// "TUICDemoProbe": 1 = TCP, 2 = SOCKS greeting, 3 = SOCKS CONNECT,
    /// 4 = HTTP, 0 = timeout, so the UI line tells which layer failed.
    ///
    /// v04 overturned the old assumption (NOTES item 7): iOS CFNetwork
    /// rejects a SOCKS connectionProxyDictionary outright — the probe died
    /// at request construction with NSURLErrorDomain -1000 bad URL, before
    /// any SOCKS traffic, even though the keys/values were well-formed
    /// (socksPort is a plain Int 10808). The SOCKS keys are macOS-only for
    /// a reason: on iOS they are not a supported configuration. So this
    /// probe speaks SOCKS5 itself over NWConnection, then plain HTTP
    /// through the tunnel. Plain HTTP (not TLS) is enough: the question is
    /// whether the tunnel carries traffic at all.
    static func probe() async throws -> (status: Int, milliseconds: Int) {
        try await Task.detached(priority: .userInitiated) {
            try Self.probeBlocking()
        }.value
    }

    private static func probeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "TUICDemoProbe", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Blocking SOCKS5 + HTTP probe. Runs on a detached task's thread;
    /// every wait shares one absolute 30 s deadline, so a hung core can't
    /// stall the UI forever.
    private static func probeBlocking() throws -> (status: Int, milliseconds: Int) {
        let deadline = DispatchTime.now() + .seconds(30)
        let start = Date()
        guard let port = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
            throw probeError(1, "SOCKS 端口非法")
        }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)

        // --- TCP connect ---
        let readySem = DispatchSemaphore(value: 0)
        var readyError: Error?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySem.signal()
            case .failed(let error):
                readyError = error
                readySem.signal()
            case .cancelled:
                readyError = probeError(1, "TCP 连接被取消")
                readySem.signal()
            default:
                break
            }
        }
        conn.start(queue: .global())
        guard readySem.wait(timeout: deadline) == .success else {
            conn.cancel()
            throw probeError(0, "TCP 连接超时（30 秒），本地 SOCKS 没在听？")
        }
        conn.stateUpdateHandler = nil
        if let error = readyError {
            throw probeError(1, "TCP 连不上本地 SOCKS（核心没在听？）：\(error.localizedDescription)")
        }
        defer { conn.cancel() }

        func send(_ bytes: [UInt8]) throws {
            let sem = DispatchSemaphore(value: 0)
            var sendError: Error?
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                sendError = error
                sem.signal()
            })
            guard sem.wait(timeout: deadline) == .success else {
                throw probeError(0, "发送超时（30 秒）")
            }
            if let error = sendError {
                throw probeError(1, "TCP 发送失败：\(error.localizedDescription)")
            }
        }

        func recv(minimum: Int, maximum: Int) throws -> Data {
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            var recvError: Error?
            conn.receive(minimumLength: minimum, maximumLength: maximum) { data, _, _, error in
                out = data
                recvError = error
                sem.signal()
            }
            guard sem.wait(timeout: deadline) == .success else {
                throw probeError(0, "接收超时（30 秒）")
            }
            if let error = recvError {
                throw probeError(1, "TCP 接收失败：\(error.localizedDescription)")
            }
            guard let data = out, !data.isEmpty else {
                throw probeError(1, "TCP 连接被对方关闭")
            }
            return data
        }

        // --- SOCKS5 greeting: VER=5, 1 method, NO AUTH ---
        try send([0x05, 0x01, 0x00])
        let greeting = try recv(minimum: 2, maximum: 2)
        guard greeting.count >= 2, greeting[0] == 0x05, greeting[1] == 0x00 else {
            throw probeError(2, "SOCKS 握手被拒（服务器没回 05 00）")
        }

        // --- SOCKS5 CONNECT example.com:80 (domain form) ---
        var connect: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8("example.com".count)]
        connect += Array("example.com".utf8)
        connect += [0x00, 0x50]
        try send(connect)
        let reply = try recv(minimum: 4, maximum: 64)
        guard reply.count >= 2, reply[0] == 0x05 else {
            throw probeError(3, "SOCKS CONNECT 无有效回复")
        }
        guard reply[1] == 0x00 else {
            throw probeError(3, "SOCKS CONNECT 被拒（rep=\(reply[1])）：TUIC 隧道/服务器不通")
        }

        // --- Plain HTTP through the tunnel ---
        try send(Array("GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8))
        let response = try recv(minimum: 1, maximum: 4096)
        guard let text = String(data: response, encoding: .utf8) else {
            throw probeError(4, "HTTP 响应不是文本")
        }
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw probeError(4, "HTTP 无状态行（首行：\(firstLine)）")
        }
        return (code, Int(Date().timeIntervalSince(start) * 1000))
    }
}
