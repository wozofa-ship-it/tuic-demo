# TUIC Demo — sing-box TUIC 真机连通测试

最小 demo：验证一条 TUIC v5 链接在真机上能不能通。Linux VM 测不了（出口 UDP
被丢），所以这一步必须在真机上做。

## 它做什么

1. 用户在机上粘贴 `tuic://` 链接（只留内存，不存盘、不记日志）。
2. App 把链接解析成 sing-box JSON：mixed 入站（127.0.0.1:10808）+ tuic 出站
   + `route.final` 指向 tuic 出站。
3. 起 sing-box 核心（纯 in-app SOCKS 模式，**不要任何 VPN entitlement、不要
   NetworkExtension**），走本地 SOCKS 抓 `https://example.com`。
4. 成功显示 HTTP 状态 + 延迟；失败显示 sing-box 原文错误（只显示在界面上，
   不落盘；错误里可能含服务器地址，绝不含 uuid/password）。

## 构建（CI，不在本地）

本机是 Linux、无 Go、无 Xcode，编不了。流程：

1. 把本目录内容放进一个 GitHub 仓库（**不要用本脚手架自动建，本任务明确
   不建仓库、不推、不触发构建**）。
2. 手动跑 Actions 里的 `Build TUIC Demo`（workflow_dispatch）。
3. 下载 `TUICDemo-unsigned` artifact，用 SideInstaller 🅥 签名安装。
4. 打开 App，粘贴链接，点“测试”。

`Libbox.xcframework` 是 CI 现场生成的构建产物，不要提交进仓库。

## 支持的链接参数（只这 8 个）

- userinfo：`uuid:password`
- host:port：`server` / `server_port`
- 查询参数：`sni`（= tls.server_name，也接受 `server_name`）、
  `congestion_control`、`udp_relay_mode`、`alpn`（逗号分隔或重复项）、
  `allow_insecure`（= tls.insecure，也接受 `insecure`，`1`/`true`/`yes` 为真）

不支持的参数会被忽略（不是报错）。uuid 必须合法 RFC 4122 格式，否则
sing-box 建出站时直接报错——这是 sing-box 自己的校验，不是本 demo 加的。

## 安全红线

- 仓库里绝不出现真实 TUIC 链接、uuid、password、服务器地址。
- 链接与生成的 JSON 只存在于 App 内存；退出即丢。
- 结果文本不写日志文件；不要把失败截图里的服务器地址再转发到别处。
