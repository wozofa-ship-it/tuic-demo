# NOTES — 已实证 vs 未确定

写脚手架时对照 sing-box **v1.14.4** 源码逐项核过。凡是没核到的，下面明说，
不许当成已验证。

## 已实证（源码原文，v1.14.4）

- `libbox.Setup(options *SetupOptions) error`，SetupOptions 含 BasePath /
  WorkingPath / TempPath 等字段。出处：`experimental/libbox/setup.go`。
- `libbox.CheckConfig(configContent string) error`。出处：
  `experimental/libbox/config.go`。
- `libbox.NewCommandServer(handler CommandServerHandler, platformInterface
  PlatformInterface) (*CommandServer, error)`，以及
  `(*CommandServer).Start() / StartOrReloadService(configContent, *OverrideOptions)
  / CloseService() / Close()`。出处：`experimental/libbox/command_server.go`。
- `CommandServerHandler` 接口 7 个方法：ServiceStop、ServiceReload、
  GetSystemProxyStatus（返回 `*SystemProxyStatus`）、SetSystemProxyEnabled、
  TriggerNativeCrash、WriteDebugMessage、ConnectSSHAgent。出处同上。
- `SystemProxyStatus` 字段：Available、Enabled（bool）。出处：pkg.go.dev 的
  libbox 包文档 + `command_server.go` 里的 daemon 映射。
- `PlatformInterface` 接口完整方法表（本 demo 的 minimalPlatform 照抄）。
  出处：`experimental/libbox/platform.go`。
- `LocalDNSTransport` 是 interface 类型，返回 nil 合法；`baseContext` 只在
  非 nil 时注册 local transport。出处：`experimental/libbox/dns.go`、
  `experimental/libbox/config.go`。
- `StringIterator` 接口：Len / HasNext / Next；`iteratorToArray(nil)` 返回
  nil，所以空 `OverrideOptions{}` 安全。出处：
  `experimental/libbox/iterator.go`。
- **旧 `BoxService` / `NewService` API 在 v1.14.4 已不存在**（命令系统重构后
  改走 CommandServer）。凡是凭记忆写 `libbox.NewService` 的都是过期记忆，
  本脚手架没用它。
- `with_quic` 门控：不带该 tag 编译时走 `include/quic_stub.go`，tuic /
  hysteria2 出站构造函数被静默省略。直接证据来自 sing-box v1.14.0 的第三方
  审计（gemsub 文档），1.14.4 的 include 目录未逐文件核对；但工作流已加
  `-tags with_quic`，且 `CheckConfig` 会在缺构造函数时报未知出站类型，
  失败是响亮的、不是静默的。
- TUIC 出站 JSON 字段：type "tuic"、server、server_port、uuid、password、
  congestion_control、udp_relay_mode、tls{enabled, server_name, alpn,
  insecure}，tls 必填。出处：sing-box 官方文档 + v1.14 时期的第三方源码审计
  （`option.TUICOutboundOptions`、`protocol/tuic/outbound.go` 的 UUID 校验）。
  `CheckConfig` 会在真机上再验一遍字段。
- SideInstaller 同款 CI 套路：xcodegen 生成工程 → xcodebuild
  `CODE_SIGNING_ALLOWED=NO` 归档 → Payload 打包 → upload-artifact。出处：
  SideInstaller 仓库的 `build-unsigned-ipa.yml`。

## 未确定（首次 CI 构建 / 真机运行时必须核）

1. **gomobile 生成的 Swift 符号名（已实证，不再是不确定）**。2026-11-02 第二版
   构建的编译器 note 直接贴出了生成头文件 `Libbox.objc.h`：名字就是
   `LibboxSetup` / `LibboxCheckConfig` / `LibboxStartService` /
   `LibboxStopService` / `LibboxVersion`。但关键一点之前猜错了：gomobile
   生成的是普通 C 函数（`BOOL LibboxXxx(..., NSError** error)`），不是
   ObjC 方法，所以 Swift 不会把它转成 `throws`——调用处必须传
   `&error` 并查 BOOL（见 SingBoxBridge.swift）。无 error 返回的
   `LibboxVersion()` 直接调，没问题。
2. **go.mod 的 Go 版本**。暂写 `go 1.24`。若 CI 报 `requires go >= x.y`，
   改成对应版本；`setup-go` 用 stable，一般够新。
3. **go.sum 缺失**。本机无 Go，无法预生成；CI 的 `go mod tidy` 会现场生成。
   若 CI 在 `go mod tidy` 前就要求 go.sum，先在有 Go 的机器上跑一次
   `go mod tidy` 再提交。
4. **gomobile bind 能否顺利编过 libbox**。libbox 依赖含 grpc 等重型库，
   且 darwin 侧可能有 cgo；SFA（sing-box 官方 Apple 客户端）就是这条路，
   理论上通，但本脚手架没在 CI 跑过，第一次构建即验证点。
5. **无默认接口监控时出站拨号是否受影响**。minimalPlatform 的
   StartDefaultInterfaceMonitor 是空实现；SOCKS-only 配置不绑特定接口，
   预期走系统路由，但未验证。若拨号失败且错误指向接口/路由，先排查此点。
6. **DNS 一节是否多余/缺字段**。JSON 里写了 `dns: {servers: [{tag: local,
   type: local}], final: local}`；若 CheckConfig 报 dns 字段错，删掉 dns 一节
   再试（无 dns 时 sing-box 仍有默认解析路径）。
7. **URLSession SOCKS 键（已实证）**。`kCFNetworkProxiesSOCKS*` 三个常量在
   iOS SDK 里标 macOS-only（CF_AVAILABLE(10_6, NA)），第二版构建直接编不过。
   改法：用原始字符串键 `"SOCKSEnable"` / `"SOCKSProxy"` / `"SOCKSPort"`
   （就是这三个常量的值），URLSession 在 iOS 上读的就是这些键。若真机上
   握手失败，再排查是否要显式指定版本或改走 mixed 入站的 HTTP 模式探。
8. **Info.plist / project.yml 未经 xcodegen 实测**。xcodegen 生成与归档只在
   CI 验证；bundle id `com.example.tuicdemo` 是占位，签名安装时按实际账号
   规则改（SideInstaller 签名时会重签，不依赖此 id）。

## 刻意没做的事

- 没建 git 仓库、没推、没触发构建（任务硬约束）。
- 没加 VPN entitlement、没加 NetworkExtension 靶（纯 in-app SOCKS 就是要
  证明不靠它们也能通）。
- 没做“失败自动换参数重试”——测试 demo 失败要响亮，不要猜。
- 没写任何真实链接、uuid、password、服务器地址进仓库（任务硬约束）。
