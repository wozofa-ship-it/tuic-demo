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

    /// Dual-target probe (v07): the v06 result was CONNECT rep=1 on
    /// example.com, which cannot tell a TUIC dial failure apart from
    /// an iOS DNS failure — the probe target is a domain, and sing-box
    /// must resolve it before dialing. So this probes two targets over
    /// two fresh SOCKS sessions: example.com:80 (domain) and
    /// 1.1.1.1:80 (literal IP, no DNS involved). Both share one
    /// absolute 30 s deadline. A TCP/greeting failure on the domain
    /// target still throws (local core problem, same as v06); anything
    /// else is reported per target.
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
    static func probe() async throws -> ProbeReport {
        try await Task.detached(priority: .userInitiated) {
            try Self.probeBlocking()
        }.value
    }

    private static func probeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "TUICDemoProbe", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Where one target's probe stopped: tcp/greeting = the local core
    /// isn't reachable (v06's stages 1/2); connect = SOCKS CONNECT was
    /// rejected (rep is in `detail`); http = CONNECT ok but the HTTP
    /// exchange failed; done = HTTP status received.
    enum ProbeStage {
        case tcp, greeting, connect, http, done
    }

    struct ProbeTargetResult {
        let label: String
        let detail: String
        let stage: ProbeStage
    }

    struct ProbeReport {
        let domain: ProbeTargetResult
        let ip: ProbeTargetResult

        /// Decisive patterns only; anything else gets no hint — the
        /// screenshot goes to a human for interpretation.
        var hint: String? {
            switch (domain.stage, ip.stage) {
            case (.connect, .done):
                return "IP 通、域名不通：iOS 侧 DNS 有问题，TUIC 本身是通的"
            case (.connect, .connect):
                return "两边都拒：TUIC 拨号/服务器问题，DNS 不是主因"
            case (.done, .done):
                return "TUIC 全通"
            default:
                return nil
            }
        }

        var display: String {
            var lines = ["\(domain.label)：\(domain.detail)", "\(ip.label)：\(ip.detail)"]
            if let hint {
                lines.append(hint)
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func probeBlocking() throws -> ProbeReport {
        let deadline = DispatchTime.now() + .seconds(30)
        let domain = probeTarget(
            label: "域名 example.com:80",
            connectBytes: [0x05, 0x01, 0x00, 0x03, UInt8("example.com".count)] + Array("example.com".utf8) + [0x00, 0x50],
            httpRequest: "GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n",
            deadline: deadline)
        // Local core problem: same behavior as v06, abort with the
        // staged error instead of reporting a misleading dual result.
        if domain.stage == .tcp || domain.stage == .greeting {
            throw probeError(domain.stage == .tcp ? 1 : 2, domain.detail)
        }
        let ip = probeTarget(
            label: "IP 1.1.1.1:80",
            connectBytes: [0x05, 0x01, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x50],
            httpRequest: "GET / HTTP/1.0\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n",
            deadline: deadline)
        return ProbeReport(domain: domain, ip: ip)
    }

    /// One full target probe on its own NWConnection. Never throws:
    /// every failure mode becomes a staged result, so the caller can
    /// decide what aborts and what gets reported.
    private static func probeTarget(label: String, connectBytes: [UInt8], httpRequest: String, deadline: DispatchTime) -> ProbeTargetResult {
        let targetStart = Date()
        var stage: ProbeStage = .tcp
        do {
            let conn = try openConnection(deadline: deadline)
            defer { conn.cancel() }
            stage = .greeting
            try socksGreeting(conn: conn, deadline: deadline)
            stage = .connect
            let rep = try socksConnect(conn: conn, bytes: connectBytes, deadline: deadline)
            guard rep == 0 else {
                return ProbeTargetResult(label: label, detail: "CONNECT 被拒 rep=\(rep)", stage: .connect)
            }
            stage = .http
            let code = try httpGet(conn: conn, request: httpRequest, deadline: deadline)
            let ms = Int(Date().timeIntervalSince(targetStart) * 1000)
            return ProbeTargetResult(label: label, detail: "成功 HTTP \(code)，\(ms)ms", stage: .done)
        } catch let error as NSError {
            return ProbeTargetResult(label: label, detail: error.localizedDescription, stage: stage)
        } catch {
            return ProbeTargetResult(label: label, detail: error.localizedDescription, stage: stage)
        }
    }

    private static func openConnection(deadline: DispatchTime) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
            throw probeError(1, "SOCKS 端口非法")
        }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var readyError: Error?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let error):
                readyError = error
                sem.signal()
            case .cancelled:
                readyError = probeError(1, "TCP 连接被取消")
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: .global())
        guard sem.wait(timeout: deadline) == .success else {
            conn.cancel()
            throw probeError(0, "TCP 连接超时（30 秒），本地 SOCKS 没在听？")
        }
        conn.stateUpdateHandler = nil
        if let error = readyError {
            throw probeError(1, "TCP 连不上本地 SOCKS（核心没在听？）：\(error.localizedDescription)")
        }
        return conn
    }

    private static func send(conn: NWConnection, bytes: [UInt8], deadline: DispatchTime) throws {
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

    private static func recv(conn: NWConnection, minimum: Int, maximum: Int, deadline: DispatchTime) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var recvError: Error?
        conn.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, _, error in
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

    private static func socksGreeting(conn: NWConnection, deadline: DispatchTime) throws {
        try send(conn: conn, bytes: [0x05, 0x01, 0x00], deadline: deadline)
        let greeting = try recv(conn: conn, minimum: 2, maximum: 2, deadline: deadline)
        guard greeting.count >= 2, greeting[0] == 0x05, greeting[1] == 0x00 else {
            throw probeError(2, "SOCKS 握手被拒（服务器没回 05 00）")
        }
    }

    /// Sends CONNECT, returns the reply REP byte. A malformed reply
    /// throws stage-3 (connect) so the caller attributes it correctly.
    private static func socksConnect(conn: NWConnection, bytes: [UInt8], deadline: DispatchTime) throws -> UInt8 {
        try send(conn: conn, bytes: bytes, deadline: deadline)
        let reply = try recv(conn: conn, minimum: 4, maximum: 64, deadline: deadline)
        guard reply.count >= 2, reply[0] == 0x05 else {
            throw probeError(3, "SOCKS CONNECT 无有效回复")
        }
        return reply[1]
    }

    private static func httpGet(conn: NWConnection, request: String, deadline: DispatchTime) throws -> Int {
        try send(conn: conn, bytes: Array(request.utf8), deadline: deadline)
        let response = try recv(conn: conn, minimum: 1, maximum: 4096, deadline: deadline)
        guard let text = String(data: response, encoding: .utf8) else {
            throw probeError(4, "HTTP 响应不是文本")
        }
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw probeError(4, "HTTP 无状态行（首行：\(firstLine)）")
        }
        return code
    }
}
