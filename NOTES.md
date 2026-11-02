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
7. **URLSession SOCKS 键（v04 真机已推翻）**。`kCFNetworkProxiesSOCKS*` 三个常量在
   iOS SDK 里标 macOS-only（CF_AVAILABLE(10_6, NA)），第二版构建直接编不过。
   曾以为原始字符串键 `"SOCKSEnable"` / `"SOCKSProxy"` / `"SOCKSPort"`
   就是这些常量的值、URLSession 在 iOS 上读的就是这些键——错。v04 真机
   实证：键值类型全对（SOCKSPort 是 Int 10808），请求仍在构造层被毙，
   报 NSURLErrorDomain -1000 bad URL，根本没出 SOCKS 流量。结论：iOS
   的 CFNetwork 不接受 SOCKS 代理字典这配置，探测必须自己讲 SOCKS5
   （见第 13 条），别再往 URLSession 代理字典这条路走。
8. **Info.plist / project.yml 未经 xcodegen 实测**。xcodegen 生成与归档只在
   CI 验证；bundle id `com.example.tuicdemo` 是占位，签名安装时按实际账号
   规则改（SideInstaller 签名时会重签，不依赖此 id）。
9. **链接要补两个系统库（第三版构建实证）**。Swift 编过后卡在 ld：
   Libbox 的 Apple TLS 客户端要 `nw_*`（Network.framework），Go 运行时
   的 DNS 解析要 `res_9_*`（libresolv.tbd）。project.yml 里以
   `- sdk: Network.framework` / `- sdk: libresolv.tbd` 补上，不用
   entitlement。UIUtilities / SwiftUICore 那两条只是警告，不是失败原因。
10. **手写 Info.plist 缺 CFBundleExecutable，SideInstaller 企业签名失败
    （第六版修复，2026-11-02 真机实证）**。构建能过、归档能过，但
    isideload 签名时要读 Info.plist 找可执行文件，缺这个键直接报
    `Info.plist is missing string key CFBundleExecutable`（sign.rs:71）。
    修法：补 `<key>CFBundleExecutable</key><string>TUICDemo</string>`
    （值必须等于包内二进制名 `TUICDemo.app/TUICDemo`）。同批顺手把
    `UIRequiredDeviceCapabilities` 的 `armv7` 改成 `arm64`：二进制本
    就是 arm64-only，armv7 是旧值，留着可能在安装时被能力检查拦下。
11. **libbox command server 的 unix socket 路径超长，bind EINVAL
    （第七版修复，2026-11-02 真机实证）**。真机点测试报
    `listen command server: listen unix .../Documents/singbox/
    command.sock: bind: invalid argument`。根因不在 TUIC、不在
    链接：1.14.4 command_server.go:142 拼的是
    basePath + "/command.sock"，而 Darwin AF_UNIX sun_path 上限
    104 字节；App 沙盒前缀本身 76 字节，Documents/singbox 再加
    上去是 107 字节，bind 直接 EINVAL。修法：basePath 改传
    Documents 根目录（99 字节），workingPath/tempPath 仍走
    Documents/singbox；sBasePath 在 libbox 里只用来拼这个
    socket 路径，改 basePath 不影响其他状态。
12. **探测报 bad URL（2026-11-02 真机，原因待查）**。v03 核心能启动，
    探测那步报 `失败：bad URL`，且用户确认每次都复现。已排除：
    链接解析（报错全是中文）、核心启动（19:17 亲眼见“核心已启动”）、
    sing-box 本体源码（1.14.4 里没有 bad URL 这句）。头号嫌疑是
    URLSession 那组原始字符串 SOCKS 代理键（NOTES 里本来就标着
    运行时未验）。定位手段：失败输出现带 `[domain code]`
    （NSURLErrorDomain = URLSession/CFNetwork，其余 = Go 那边），
    下一版凭它定性。
13. **探测改手动 SOCKS5 + HTTP（v05，2026-11-02）**。v04 的
    [NSURLErrorDomain -1000] 定性后，探测不再碰 URLSession：NWConnection
    直连 127.0.0.1:10808，手动发 SOCKS5 问候（05 01 00）→ CONNECT
    example.com:80（域名形）→ 明文 HTTP GET（HTTP/1.0，不走 TLS，
    问的只是隧道通不通）。失败分四档报（TUICDemoProbe 域：1 TCP /
    2 握手 / 3 CONNECT rep / 4 HTTP，0 超时），每档都说明卡在哪层；
    全部等待共用一个 30 秒绝对 deadline，核心挂起也不会卡住 UI。

## 刻意没做的事

- 没建 git 仓库、没推、没触发构建（任务硬约束）。
- 没加 VPN entitlement、没加 NetworkExtension 靶（纯 in-app SOCKS 就是要
  证明不靠它们也能通）。
- 没做“失败自动换参数重试”——测试 demo 失败要响亮，不要猜。
- 没写任何真实链接、uuid、password、服务器地址进仓库（任务硬约束）。
