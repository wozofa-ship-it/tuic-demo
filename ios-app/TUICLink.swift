import Foundation

/// Parsed TUIC v5 link. Only the 8 parameters the demo supports.
/// The link itself is never persisted: it lives only in memory while the
/// app runs, and the generated JSON is handed to sing-box and then dropped.
struct TUICConfig {
    let uuid: String
    let password: String
    let server: String
    let serverPort: Int
    /// tls.server_name, from the `sni` (or `server_name`) query parameter.
    /// nil = let sing-box default SNI to the server hostname.
    let serverName: String?
    let congestionControl: String?
    let udpRelayMode: String?
    /// tls.alpn, e.g. ["h3"]. Empty = omit.
    let alpn: [String]
    /// tls.insecure, from `allow_insecure` (or `insecure`).
    let insecure: Bool
}

enum TUICLinkError: LocalizedError {
    case notTUIC
    case missingUserinfo
    case missingHost
    case missingPort
    case invalidUUID
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .notTUIC: return "不是 tuic:// 链接"
        case .missingUserinfo: return "链接缺少 uuid:password"
        case .missingHost: return "链接缺少服务器地址"
        case .missingPort: return "链接缺少端口"
        case .invalidUUID: return "uuid 不是合法的 UUID（sing-box 要求 RFC 4122 格式）"
        case .invalidValue(let what): return "参数不合法：\(what)"
        }
    }
}

/// Parse a tuic:// link. Accepts both `sni` and `server_name` for the TLS
/// server name, and both `allow_insecure` and `insecure` for the flag.
/// alpn may be comma-separated ("h3") or repeated query items.
func parseTUICLink(_ raw: String) throws -> TUICConfig {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let comps = URLComponents(string: text),
          comps.scheme?.lowercased() == "tuic"
    else { throw TUICLinkError.notTUIC }

    // URLComponents.user/password 已经是 percent-decoded 后的值，
    // 直接用，不再二次 removingPercentEncoding（密码里若含 %XX 字样，
    // 二次解码会把它改写成别的字符，等于改了密码）。
    guard let rawUser = comps.user, !rawUser.isEmpty,
          let rawPassword = comps.password
    else { throw TUICLinkError.missingUserinfo }
    let uuid = rawUser
    let password = rawPassword
    guard UUID(uuidString: uuid) != nil else { throw TUICLinkError.invalidUUID }

    guard let host = comps.host, !host.isEmpty else { throw TUICLinkError.missingHost }
    guard let port = comps.port else { throw TUICLinkError.missingPort }
    guard (1...65535).contains(port) else { throw TUICLinkError.invalidValue("port") }

    var query: [String: [String]] = [:]
    for item in comps.queryItems ?? [] {
        guard let value = item.value else { continue }
        query[item.name, default: []].append(value)
    }
    func first(_ names: String...) -> String? {
        for name in names {
            if let value = query[name]?.first { return value }
        }
        return nil
    }

    let alpn = (query["alpn"] ?? [])
        .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        .filter { !$0.isEmpty }
    let insecureRaw = first("allow_insecure", "insecure")?.lowercased() ?? ""
    let insecure = insecureRaw == "1" || insecureRaw == "true" || insecureRaw == "yes"

    return TUICConfig(
        uuid: uuid,
        password: password,
        server: host,
        serverPort: port,
        serverName: first("sni", "server_name"),
        congestionControl: first("congestion_control"),
        udpRelayMode: first("udp_relay_mode"),
        alpn: alpn,
        insecure: insecure
    )
}

/// Build the sing-box JSON for the demo. JSONSerialization (not string
/// interpolation) so passwords with quotes/backslashes cannot break the JSON.
/// Shape: mixed inbound on loopback + single tuic outbound + route.final.
/// The `dns` section pins the system resolver; without it, sing-box still
/// resolves, but an explicit section removes one variable from the test.
/// The `log` section writes the core log to `logPath` (v08): libbox has
/// no log-capture API, but a config `log.output` file is opened by the
/// core (log/observable.go) — the only way to see the exact dial error
/// on device. The file holds dial progress only, never uuid/password
/// (sing-box never logs config secrets); the UI truncates it on every
/// new test so it never accumulates.
func singBoxJSON(config: TUICConfig, socksPort: Int, logPath: String) throws -> String {
    var tuic: [String: Any] = [
        "type": "tuic",
        "tag": "tuic-out",
        "server": config.server,
        "server_port": config.serverPort,
        "uuid": config.uuid,
        "password": config.password,
    ]
    if let cc = config.congestionControl, !cc.isEmpty {
        tuic["congestion_control"] = cc
    }
    if let mode = config.udpRelayMode, !mode.isEmpty {
        tuic["udp_relay_mode"] = mode
    }
    var tls: [String: Any] = [
        "enabled": true,
        "insecure": config.insecure,
    ]
    if let name = config.serverName, !name.isEmpty {
        tls["server_name"] = name
    }
    if !config.alpn.isEmpty {
        tls["alpn"] = config.alpn
    }
    tuic["tls"] = tls

    let root: [String: Any] = [
        "log": ["level": "info", "output": logPath],
        "dns": [
            "servers": [["tag": "local", "type": "local"]],
            "final": "local",
        ],
        "inbounds": [[
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": socksPort,
        ]],
        "outbounds": [tuic],
        "route": ["final": "tuic-out"],
    ]
    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
        throw TUICLinkError.invalidValue("JSON 编码失败")
    }
    return json
}

/// Redacted parse summary for the UI: server address and parameters only.
/// uuid/password are NEVER included (they stay in memory for sing-box).
func redactedSummary(config: TUICConfig) -> String {
    var lines = ["服务器：\(config.server):\(config.serverPort)"]
    lines.append("SNI：\(config.serverName ?? "默认（跟服务器地址）")")
    lines.append("ALPN：\(config.alpn.isEmpty ? "无" : config.alpn.joined(separator: ","))")
    lines.append("拥塞控制：\(config.congestionControl ?? "默认")")
    lines.append("UDP 中继：\(config.udpRelayMode ?? "默认")")
    lines.append("allow_insecure：\(config.insecure ? "是" : "否")")
    return lines.joined(separator: "\n")
}
