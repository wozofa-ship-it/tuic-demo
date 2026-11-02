import SwiftUI

struct ContentView: View {
    @State private var link = ""
    @State private var result = "粘贴 TUIC 链接，点“测试”。"
    @State private var testing = false
    @State private var running = false
    @State private var configSummary = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("TUIC 连通测试")
                    .font(.title2.bold())

                Text("只做一件事：起 sing-box（mixed 入站 + tuic 出站），走本地 SOCKS 抓 example.com（域名 + IP 双目标）。链接只留内存，不存盘、不记日志；下面只显示服务器地址与参数，不显示 uuid/密码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("粘贴 tuic:// 链接", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("粘贴") {
                        if let text = UIPasteboard.general.string {
                            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    Button("清空") {
                        link = ""
                    }
                    Spacer()
                }

                HStack {
                    Button("测试") { runTest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(testing || link.isEmpty)
                    Button("停止") { stopService() }
                        .buttonStyle(.bordered)
                        .disabled(testing || !running)
                }

                if !configSummary.isEmpty {
                    Text(configSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Spacer()
                Text("sing-box \(SingBoxBridge.version()) · 纯 in-app SOCKS，无 VPN entitlement")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("TUIC Demo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func runTest() {
        testing = true
        result = "正在解析链接…"
        Task {
            do {
                let parsed = try parseTUICLink(link)
                let json = try singBoxJSON(config: parsed, socksPort: SingBoxBridge.socksPort)
                await MainActor.run {
                    configSummary = redactedSummary(config: parsed)
                    result = "链接解析通过，正在启动核心…"
                }
                // Start on a background thread: StartService blocks until the
                // instance is up. Snapshot `running` first: @State must not be
                // read from inside the detached (nonisolated) task.
                let wasRunning = running
                try await Task.detached {
                    if wasRunning {
                        try? SingBoxBridge.stop()
                    }
                    try SingBoxBridge.start(configJSON: json)
                }.value
                await MainActor.run {
                    running = true
                    result = "核心已启动，正在通过 SOCKS 探测（域名 + IP 双目标）…"
                }
                let report = try await SingBoxBridge.probe()
                await MainActor.run {
                    result = report.display
                }
            } catch {
                await MainActor.run {
                    // Verbatim error, UI only, never persisted. sing-box dial
                    // errors may name the server address, never uuid/password.
                    // Domain + code pin down which layer failed: NSURLErrorDomain
                    // = URLSession/CFNetwork, anything else = Go/sing-box side.
                    // (2026-11-02: probe failed with bare "bad URL"; the domain
                    // and code are what tell those two apart.)
                    let ns = error as NSError
                    result = "失败：[\(ns.domain) \(ns.code)] \(error.localizedDescription)"
                }
            }
            await MainActor.run { testing = false }
        }
    }

    private func stopService() {
        testing = true
        Task {
            do {
                try await Task.detached { try SingBoxBridge.stop() }.value
                await MainActor.run {
                    running = false
                    result = "核心已停止。"
                }
            } catch {
                await MainActor.run { result = "停止失败：\(error.localizedDescription)" }
            }
            await MainActor.run { testing = false }
        }
    }
}
