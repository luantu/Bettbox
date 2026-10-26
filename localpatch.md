# Bettbox SG 分支本地补丁记录

本文件记录 `codex/feilian-android` 相对 fork 的 `main` 所做的改动，供后续同步 Bettbox 上游时辨认哪些行为必须保留。比较基线是 `f71482f`，合并上游前的分支提交是 `8a31b6f`；该区间有 136 个提交，涉及 143 个跟踪文件。以下按功能归纳，不逐条重复提交历史。

## 产品行为

- Android 测试包使用独立的 `com.appshub.bettbox.sg` applicationId，与原版 `com.appshub.bettbox` 并存。它使用固定的公开测试签名，支持同包名保留数据覆盖升级；这个签名不能用于生产发布。启动图标保留三条前景形状，配色改为鲜橙到橙红渐变；右上角 `PRE` 视觉角标在 SG 构建中隐藏。相关文件：`android/app/build.gradle.kts`、`android/app/sg-test.keystore`、`android/app/src/main/res/drawable/ic_launcher_foreground_*.xml`、`lib/manager/app_manager.dart`。
- “更多 → 飞连 SG-Node”提供独立设置和状态页。用户只输入飞连用户名、密码、上游 HTTPS 地址；应用管理 Cookie、设备身份、WireGuard 密钥与 OTP 所需材料。密码放在平台安全存储，不写入普通 Profile。页面显示 Android VPN、握手阶段、隧道地址及连接检查，并提供保存连接、检查、刷新恢复、重连操作。相关文件：`lib/views/corplink_sg.dart`、`lib/services/corplink_sg.dart`、`lib/views/tools.dart`、`lib/views/config/general.dart`。
- 没有机场订阅时可创建最小 SG Profile；有订阅时继续使用原有配置、节点和脚本。配置合并按名称幂等注入 `SG-Node` 和 `SG-OpenAI`，OpenAI/ChatGPT 规则指向该组；没有有效授权时，SG 组以 `REJECT` 收束，避免意外直连。脚本添加的 `rule-providers` 和 `RULE-SET` 予以保留，不再因二次合并被误删。若 SG 节点使核心配置失败，应用会暂时不注入该节点，尝试保住普通代理。相关文件：`lib/controller.dart`、`lib/state.dart`、`lib/services/corplink_sg.dart`、`lib/services/corplink_sg_bootstrap.dart`。
- 首页首次升级默认添加可删除、可重排的 SG 半宽磁贴。它复用普通磁贴的标题和底部状态布局，实时读取隧道状态；刷新按钮按状态恢复连接，卡片主体进入飞连页面。相关文件：`lib/enum/enum.dart`、`lib/models/config.dart`、`lib/views/dashboard/widgets/sg_node_status.dart`。

## 授权、隧道和恢复

- Android 集成 `corplink-rs-login` machine helper，并实现飞连密码登录、授权材料持久化和异常诊断。针对服务端返回的登录方式、VPN 节点别名、Cookie 存储和设备 ID／设备名做兼容；授权失败不能伪报成功。相关文件：`lib/services/corplink_sg.dart`、`android/app/src/main/kotlin/com/appshub/bettbox/plugins/AppPlugin.kt`、`android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnPlugin.kt`。
- Mihomo-SG 内核加入 CorpLink 控制面与 WireGuard over TCP 出站。TCP 数据帧使用 4 字节小端长度前缀；建连时查询节点列表和管理会话，再使用服务端下发的节点、端口、隧道地址及 peer 信息。DNS 解析器走隧道内 DoH；Android 对控制面和外层隧道套接字使用受保护的底层物理网络，避免被自身 VPN 捕获。相关文件：`core/Clash.Meta/adapter/outbound/wireguard.go`、`wireguard_corplink.go`、`wireguard_tcp_bind.go`、`core/hub.go`。
- 配置重载先关闭旧的 CorpLink WireGuard 实例；隧道地址变化时重建虚拟网卡而非原地替换单个 peer。Android 以底层网络对象识别切网，短时间内的事件合并处理，待物理网络稳定后定向重连；后台以受限频率检查健康状态，区分握手、业务探测和需要重建，不因单个探测站点失败立即强制重新登录。相关文件：`android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnPlugin.kt`、`core/Clash.Meta/adapter/outbound/wireguard_corplink.go`、`lib/services/sg_network_handoff.dart`、`lib/services/corplink_sg_status.dart`、`lib/services/corplink_sg_recovery.dart`。
- `core/third_party/wireguard-go/` 是本分支内置的 WireGuard Go 实现及平台适配源码，不是 Git submodule。同步上游时不要把它当作临时构建产物删除。

## 构建与测试

- `.github/workflows/android-sg-apk.yml` 在 GitHub Actions 构建 Android arm64 APK：Flutter 单测、Go 出站测试、`corplink-rs` Android helper、Mihomo-SG 原生库和 APK 顺序执行。Helper 固定来源提交并检查 SHA；Go、Flutter、NDK 版本受工作流约束。Android NDK 版本也在 `plugins/flutter_qjs/android/build.gradle` 固定，避免插件单独下载另一版 NDK。另有 `.github/workflows/android-sg-apk-retry.yml`，但它只监听旧功能分支且步骤少于主工作流，不能把它的结果当作本分支完整验收。
- Windows 打包加入相应的 CorpLink helper 放置逻辑；`setup.dart` 支持 SG 内核及 Android 交叉构建。`pubspec.yaml` 增加安全存储、密码学依赖和 Android helper 资源，锁文件及各平台生成的插件注册文件随之更新；`analysis_options.yaml` 排除了生成和平台目录的分析。相关文件：`windows/packaging/exe/package_windows.dart`、`.github/workflows/build.yaml`、`setup.dart`、`pubspec.yaml`、`pubspec.lock`。
- 回归测试覆盖授权设置与节点注入、设备身份、幂等规则合并、恢复策略、首页磁贴、网络切换序列化、预发布角标和布局；Go 测试覆盖 TCP Bind、CorpLink 出站、连接生命周期、重连和核心状态。主要目录：`test/`、`core/Clash.Meta/adapter/outbound/*test.go`、`core/corplink_status_test.go`。
- 构建与安装步骤见 `docs/01-Bettbox飞连Android构建与部署说明.md`；设计和集成背景见 `docs/02-SG网络切换与首页磁贴设计-2026-09-29.md`、`readme/CORPLINK_SG_INTEGRATION.md`。

## 已验证与未验证

截至本分支上游合并前，最新测试 APK 对应代码提交 `090add0`，Actions run `36523518856` 成功。该包已保留数据安装到真机；系统应用信息页显示青绿图标，磁贴刷新后 `tun0` 恢复，SG 代理请求得到 HTTPS 响应。此前真机验证包括 Wi-Fi／蜂窝双向切换后的自动恢复、`SG-OpenAI → SG-Node` 请求链和 `RuleSet(sg-node-overseas)` 命中；详细时间序列保存在父目录的 `work/集成飞连Mihomo-SG/status.md`。

这些结果不等于跨天 Cookie 续期、厂商长期后台保活或 ChatGPT 登录后实际对话已经通过。公开测试签名也不适合生产分发。另一个需要单独评估的安全边界是 `wireguard_corplink.go` 的控制面 HTTP 客户端设置了 `InsecureSkipVerify: true`，当前不会验证上游 TLS 证书；本次同步上游不顺带改变这一行为。`outputs/` 内 APK 是本地交付产物，未纳入 Git 跟踪；文档与源码不包含账号、Cookie、OTP 或私钥。

## 上游同步记录

上游为 `appshubcc/Bettbox` 的 `main` 分支，2026-09-28 的提交 `3189346611caeba73aa87feaf708e4fd65115d16`；合并提交为 `d0983e68e9612223ea58e7b0ad9cab4cef6c6a1e`。本地补丁范围固定按合并前的 `f71482f..8a31b6f` 口径；引入的上游代码不算本地补丁。合并在外置盘独立工作树中进行，原分支及其未跟踪的 APK、过程文件没有参与冲突处理。

两条历史自 `6291ab3` 分叉后都有大量提交，本次合并涉及 35 个文本冲突。处理时保留上游的配置模型、运行配置文件写入方式、首页启动开关、跨平台窗口及本地化更新，同时接回 SG 授权、节点/代理组注入、DNS 隧道路由、状态磁贴与 Android 网络切换能力。特别复核了 `SetupParams` 新接口：最终配置先写入运行文件，随后调用核心初始化；脚本覆写后的 SG 规则仍使用上游的 `rules` 字段。生成模型文件以新上游为基底，仅补入 `DashboardWidget.sgNode` 的序列化项。

合并候选已通过冲突标记扫描和 `git diff --cached --check`。低并发 Go 测试中，`core` 模块全部通过；Mihomo 的出站、配置执行器、Sudoku 传输测试通过。首轮 Sudoku 本地回环测试返回 502，查明是测试进程继承了本机 `ALL_PROXY`，清除代理环境后该测试通过。Mihomo 入站测试持续占用近两个 CPU 核心，已主动中止，因此不记作通过；完整 Mihomo 测试套件也没有通过验证。

合并提交 `d0983e6` 的 [Android SG APK 工作流](https://github.com/luantu/Bettbox/actions/runs/36530262119) 已成功：Flutter 单测、Go 出站测试、`corplink-rs` Android helper、Mihomo-SG Android 原生库及 APK 打包和上传均通过。产物名为 `Bettbox-android-arm64-sg`，GitHub artifact ID 为 `11016508997`。上游把 Android 核心库由 `libclash.so` 改名为 `libmeta.so`；APK 同时包含 `libmeta.so` 与登录 helper。下面记录该 APK 的真机复测，不沿用旧包的结果。

## 合并版真机复测（2026-09-29）

APK 已下载到本地 `outputs/android-sg-arm64-2026-09-29-upstream-merge/app-release.apk`，SHA-256 为 `8eaa596c0d3125bbe3be277dad7a2234ea50c17e9b5b0612661bcc0db840b931`。它以保留数据方式覆盖安装到 Android 手机，包名仍为 `com.appshub.bettbox.sg`，版本为 1.19.4；安装前后的应用数据目录标识相同。原版 Bettbox 包未被覆盖。

- 手机保存的设置可用。“重新授权”实际返回“已授权”，此后 Android VPN 启动、WireGuard 握手就绪。重新授权使隧道 IP 变化一次，随后连续请求期间未再变化。首页磁贴刷新时也没有让健康隧道掉线。
- `SG-OpenAI` 组和 `SG-Node` 节点均出现在代理页。连续 5 次节点延迟测试为 175–204 ms，没有复现第三次即超时。Wi-Fi 下连续 5 次经手机代理访问 `chatgpt.com/cdn-cgi/trace` 均返回 200；重新授权后又连续 3 次返回 200。普通 HTTPS 站点经同一代理端口返回 200。
- 临时启用蜂窝数据并关闭 Wi-Fi 后，首次请求正处于切换窗口，第二次约在第 7 秒恢复为 200，此后连续 3 次成功；切回 Wi-Fi 时同样从第二次起恢复，随后连续 3 次成功。两次切换后握手均就绪，隧道 IP 未变化。测试结束已确认 Wi-Fi 恢复开启，两张 SIM 的蜂窝数据恢复为原先的关闭状态。
- 手机 Chrome 已打开 ChatGPT 页面并显示可输入界面。Bettbox“请求”历史中有 3 条 Chrome 发往 `chatgpt.com` 或 `ws.chatgpt.com` 的记录；逐条检查其节点链，均含 `SG-OpenAI` 与 `SG-Node`。命令行请求 ChatGPT 首页时，直连和经 SG 都收到 403，因此不把这个状态码单独判为隧道失败；经 SG 访问公开 trace 页为 200。

边界：这次复测使用手机原有设置，没有清空数据模拟首次安装；“重新授权”已验证保存的凭据可再次登录。DNS 路径已核对到实际拨号实现：覆写脚本执行后再次注入的 SG 节点启用 `remote-dns-resolve`，DoH 上游使用数字 IP；WireGuard 解析器把每个上游绑定到自身出站，DoH 的 TCP 拨号由该出站交给 WireGuard IP 栈。对应 Go 回归测试通过。不过本次没有取得可单独证明手机上真实 DNS 包路径的运行时日志或抓包；跨天 Cookie 续期、长期后台保活和实际发送 ChatGPT 对话也未测试。`outputs/` 是本地未跟踪产物，不包含在 Git 提交里。

## 多服务器节点增量（`codex/corplink-multi-node-impl`，待设备验收）

- 在不改变现有公开测试签名、包名和 release 的前提下，控制面新增只返回 TCP 服务器名称的发现动作；设置页可以多选上游节点或手动补充准确名称。账号只登录一次，Cookie、OTP 和设备身份共用；WireGuard 密钥按账号、上游和服务器名分别保存在安全存储，并迁移旧 INTL 密钥。每节点可单独设置 HTTPS 探针，留空时只检查握手。主要代码：`lib/services/corplink_sg_nodes.dart`、`lib/services/corplink_sg.dart`、`core/Clash.Meta/adapter/outbound/wireguard_corplink.go`。
- 覆盖层生成 `<服务器名称>-WG` 代理及与上游服务器同名的组；旧 `SG-Node` 保留为隐藏别名，`SG-OpenAI` 和原自动规则继续指向 INTL。脚本新增的 `RULE-SET` 保持原样；订阅里已有同名组（包括指向 `REJECT` 的组）会触发冲突，不被静默覆盖。首次注入与脚本处理后的二次注入通过可信的托管名称交接。主要代码：`lib/services/corplink_sg_overlay.dart`、`lib/state.dart`。
- Mihomo-SG 返回每节点状态，支持定向重连、无公网网站的握手检查与单节点 IP 栈重建。一个节点在配置载入时无法连接飞连控制面，会留作不可直连、可重试的占位出站，不再令机场代理和另一健康节点整份配置失效。首页磁贴显示已连接数量，设置页显示每节点 IP、端点及变化次数；Wi‑Fi/蜂窝切换后只对未就绪节点补偿重连。主要代码：`core/Clash.Meta/adapter/outbound/wireguard.go`、`core/hub.go`、`lib/services/corplink_sg_runtime.dart`、`lib/controller.dart`、`lib/main.dart`、`lib/views/corplink_sg.dart`、`lib/views/dashboard/widgets/sg_node_status.dart`。
- 新增回归用例覆盖双节点密钥/令牌/IP 隔离、单节点 401 时完整配置仍加载、同名组与同名代理保护、脚本改写或部分删除托管名称时的失败关闭、IP 变化只替换一个设备、并发重建/关闭及网络切换补偿。Go 低并发测试和重建路径的竞态检测已通过。提交 `e7295e8` 的 [Android SG APK 工作流](https://github.com/luantu/Bettbox/actions/runs/36555032514) 全部成功；该包 SHA-256 为 `4ec0db639ce8a2dace869082d1ec59cc5b4282262b5e886993e98efb1ba4a95f`，现作为预览包保存。外置盘空白模拟器验证了授权失败时的 `REJECT` 占位组和 VPN 启动；保留旧授权的 AVD 发现节点时暴露 `_TypeError`，已在 `b0e75fc` 修复并通过云端构建，但设备复测仍未完成。
- 独立复核后，`3e2ebb3` 将脚本二次合并的组名与代理名分开捕获；其 [Actions run](https://github.com/luantu/Bettbox/actions/runs/36562257686) 已成功，但还可能因误删脚本新增机场代理留下悬空规则。`eebeb52` 改为来源无法判定时回退整次脚本、保留原机场配置并阻断飞连组；被抑制 `-WG` 代理的直指规则改为 `REJECT`。该版的 [Actions run 36563900839](https://github.com/luantu/Bettbox/actions/runs/36563900839) 已成功，但不能代替后续安全修订的构建。真机双节点和真实路由均未验收。逐项结果见 `docs/03-Bettbox飞连多节点验证用例与结果.md`，不能沿用上文单节点真机结果判定多节点完成。
- 后续复核发现异常脚本回退时删除 `-WG` 代理名称会使下载配置中的组、子规则或 `dialer-proxy` 引用悬空。`da32aba` 改为保留同名 `type: reject` 代理，并用 Mihomo 完整配置解析测试覆盖这三类引用。进一步检查又发现普通停用和未授权状态有相同缺口：测试先行的 [run 36568251383](https://github.com/luantu/Bettbox/actions/runs/36568251383) 在旧逻辑下出现两处预期失败，`25a5a04` 将拒绝占位扩展到所有未生成真实 WireGuard 出站的已配置节点。最新完整构建为 [run 36568584470](https://github.com/luantu/Bettbox/actions/runs/36568584470)，仍需 APK 和设备验收；旧包不能作为双节点测试结论。

## 2026-09-30 当前多节点方案

用户随后明确缩小配置生成范围：只有勾选且授权成功的服务器才创建同名组和 `-WG` 出站；不再生成 `SG-Node`、`SG-OpenAI` 或未选节点的拒绝占位。误填为 URL 的手动节点会被拒绝并从旧保存项中过滤。ChatGPT 自动规则直指已选 INTL；INTL 未选时不生成。若脚本仍引用未选节点，相关规则改指 Mihomo 内置 `REJECT`，以免落入后续 `MATCH,DIRECT`，但不创建新的拒绝节点或组。这一版在过渡包 `ba6dc8d` 的真实账号模拟器上已确认只出现两组和两条 WG，ChatGPT 请求经 INTL WG 返回 HTTP 200；福州内网 HTTPS 当时仍超时。

提交 `224338c` 进一步处理福州 DNS：同次 `/vpn/conn` 下发的私网 DNS 留在该节点会话内，受保护域名走福州 WireGuard 的 UDP/TCP 53，其他域名仍走隧道内 DoH。最终域名规则、服务端分域与设备探针共用动态匹配范围；fake-IP 不吞掉这些域名，单节点重建后更新 DNS 并清缓存。其他 TCP 服务器不默认使用福州私网 DNS。页面新增各节点最近 HTTPS 探针结果和时间。低并发 Go 目标、core、CorpLink 定向及重建竞态测试已通过；[Actions run 36648138256](https://github.com/luantu/Bettbox/actions/runs/36648138256) 正在构建。新 APK 尚未安装设备，DNS 隧道路径、福州业务、脚本实流量和真机切网仍需验证。

`bd492fc` 后的模拟器和真机阶段验证显示：只生成已勾选且已授权的两个同名组与两条 WG，旧 `SG-Node`/`SG-OpenAI` 组不再出现。手机原脚本仍指旧 `SG-OpenAI`，已保留原件并启用修订副本 `CorpLinkMultiNode`。脚本修订前，一条福州内网请求记录显示 `DIRECT → BASE`；修订后的对应请求记录显示福州组/WG 和双向字节，证明后者经代理转发。手机 Wi‑Fi 本身也能访问该内网站点，因此 HTTP 200、飞连页“有响应”都不是隧道证据。Wi‑Fi／蜂窝互切时双节点保持就绪、隧道地址未见漂移，但未为每个阶段留存同一请求的出口链，切网后的业务路由仍未闭环。内网 DNS UDP 53 经福州 WG 有双向流量；公网域名的 DoH 路径仍按逐项验证记录判断。长时间稳态、单节点故障隔离和订阅更新也未通过验收，详见 `docs/03-Bettbox飞连多节点验证用例与结果.md`。

2026-09-30 曾对飞连下发的两台内网 DNS 尝试标准 HTTPS `/dns-query`，均未完成 TLS 握手；但失败连接未进入手机请求历史，无法确认是否走福州 WG。手机 Wi‑Fi 又在公司内网，所以这轮测试不具备判定 DoH 能力的条件，不能据此说服务器不支持 DoH。当前保持福州 WG 内的 UDP/TCP 53，不自动切换。代理页专属测速第一次修订 `8a84d85` 虽全链构建成功，真机福州 WG 卡片仍 `Timeout`；同版本飞连页专属 HTTPS 探针有响应，也不能单独证明转发路径。脱敏诊断提交 `bafd362` 的 Actions 已成功，APK 尚未装机；后续需核对代理页选址、内核返回和对应请求出口。fork `main` 与现有 Release 未更新。

## 2026-09-30 专属探针覆写修复与设备验证

诊断包 `bafd362` 在真实账号 AVD 复现“设置和最终 YAML 有探针，但代理卡片没有 URL”。根因在 `core/common.go`：开启全局测速覆写后，核心载入配置时再次把所有组 URL 改成全局值，前端无法恢复原值。`7c8a76b` 根据 WG 出站已有的 CorpLink 服务器元数据识别同名 select 组，保留明确配置的专属探针；机场组继续遵循全局地址。配合 `lib/services/corplink_node_delay_url.dart` 的卡片、批量测试和结果展示选址，这次 AVD 中福州连续五次测速为 32、24、94、53、35 ms，INTL 手动测试也有响应。core 全套及 Mihomo config/dns/outbound/executor 本地测试通过，回归测试重现旧覆盖时出现预期断言失败。

`7c8a76b` 的 [Actions run 36667371047](https://github.com/luantu/Bettbox/actions/runs/36667371047) 全链成功，APK SHA-256 `90aa99636554645231e488717d8bf96f53ffc1eeb84dfeaed0e373e998258298`；已同签名保留数据安装 AVD，数据目录标识未变。普通混合端口请求的实际链证实 ChatGPT 走 INTL WG、内网 RuleSet 走福州 WG，机场普通请求正常。只阻断福州外层 TCP 约 24 秒时，福州三次请求失败、页面 `1/2`，INTL 两次和机场一次请求成功；解除后约 5.1 秒自动恢复为 `2/2`。恢复时仅福州隧道地址改变，INTL 地址及两个节点端点保持不变。

真实授权空 Profile 也完成验证：应用自动创建两个选中组和 WG、ChatGPT 规则，实际请求链分别命中各自 WG。恢复原订阅并下载一次更新后，两个 SG 组仍自动注入，普通代理和 ChatGPT 可用。两台下发内网 DNS 的 UDP 53 都有福州 WG 往返记录；通过固定福州入口向标准 IP/443 DoH 端点发送 RFC 8484 查询均在 TLS 握手阶段超时，因此没有启用未经验证的内网 DoH。

`test/fixtures/corplink_android_validation.js`、`test/fixtures/corplink_empty_profile.yaml` 保存了不含真实域名或授权信息的复测夹具。Android SG 主工作流补充 core 与 config/dns/executor 测试，`ce7da2a` 的 run `36674462671` 全链通过。模拟器的临时配置、脚本、监听端口、ADB 转发、阻断规则和下载副本已撤销，原订阅恢复，Bettbox AVD 已关闭。真机后续安装与验收进度见下节。`main` 和 Release 未更新。

## 2026-09-30 真机复测与只读下发路由

真机已保留数据安装 `7c8a76b`，从手机只读计算的 APK SHA-256 与 CI 产物一致。保存的账号、两节点和探针沿用，状态 `2/2`。福州代理卡片连续五次为 27、44、46、28、47 ms，日志确认使用专属组探针。Wi‑Fi／蜂窝双向切换后，两组的代理请求都返回 200，并有对应 WG/同名组及双向字节；切回 Wi‑Fi 后约 7.4 秒内两条并行请求完成，无需手动重连。切回的立即地址比较仍缺失，后续脚本重载发生的地址变化不能算作切网漂移。另一次约 52 秒的取样中，双组共 20 次请求全部返回 200，但没有逐条补路由链及末次地址读回，不能据此声称长期稳定。

企业域后缀按用户要求只在手机覆写脚本中维护。原脚本先导出备份，修订副本 `CorpLinkCorporate` 已启用，原副本保留停用；HTTP Provider 和其他规则不丢失。内网请求实际命中新增 DomainSuffix，经福州 WG 传流；ChatGPT trace 也正常。真实地址及 Provider URL 只保留在手机和私有本地脚本，不提交仓库。测试端口、网络开关、亮屏及输入法已恢复。

为取得服务器实际下发网段，`9c8405f` 在核心增加通用只读路由遥测，`6fb6580` 在 Android 状态模型和状态页接收。IPv4/IPv6 split 与 full 分开，不修改 AllowedIPs、转发策略或程序默认规则；缺字段、空列表和无效条目分别处理，返回数组副本，重建未初始化时不展示旧会话为当前数据。Go 与 Android 回归测试通过，run `36682634237` 全链成功，真机保留数据安装后读到 7 条 IPv4 split 前缀和 6 条 full 路由。只把实际 split 加到私有 `CorpLinkCorporateRoutes` 脚本，保留原域规则、Provider 及本机／回环排除。内网 IP 请求为 HTTP 403，实际命中 IPCIDR 经福州 WG，有 76 B 上行、28.18 KB 下行；验证的是路由与连通，不是业务授权。本机排除仍为地址快照，需要在地址改变后更新。

用户已确认鲜橙／橙红图标及状态优先管理页。`9060dd3` 新增 `CorplinkManagementPanel`，首屏摘要／节点卡片／唯一日常检查恢复按钮；账号、节点选择及探针编辑默认折叠，手动节点输入独立收起，高级重连／授权有中断确认。控制器分离已应用配置与草稿，发现节点不隐式保存，取消修改不重写运行配置。图标只改 Android 两个 foreground XML 的六个填充色，原路径和背景保持。5 个组件交互测试通过，run `36692302053` 全链成功。

`9060dd3` 已在外置盘单核 AVD 保留数据安装，实际验证首屏、折叠、草稿关闭不停止现有 VPN、高级按钮禁用、取消草稿及重连确认取消。该包一键启动仍失败：WG TCP 拨号早于原生 TUN 就绪，几秒后两节点降到 `0/2`；先确认 `tun0` 再刷新，双节点固定出口的 20 次请求均返回 200。已添加共享启动／原生就绪门槛的回归测试，修复和新 APK 复测未完成。当前包捕获 INTL 隧道内 DoH 的运行标记，内网 DNS 故障反例结果见下节；其他 DNS、浏览器与稳态用例继续验证。按用户最新顺序，本轮只操作模拟器，通过后才通知接入手机；main 和现有 Release 均未更新。逐项证据和未通过项见 `docs/03-Bettbox飞连多节点验证用例与结果.md`。

启动修复实现 `f098a58` 使用共享启动 Future 和原生 `getRunTime` 门槛，getter 与 `startTUN` 加锁同步。管理页、首页共同节点刷新和高级重连均等待原生就绪，超时不开始握手。其 run `36698356635` 的 Flutter、Go 两套均通过，新 APK 尚未安装。`9060dd3` 另完成内网 DNS 故障反例：精确阻断福州外层 TCP 并清缓存，内网查询失败且零答案，INTL 仍传流；撤销后 DNS 自恢复，两节点地址及端点均未变。这个反例不等于全部 DNS、长期稳态或新 APK 验收完成。

## 2026-09-30 原生启动边界加固与真机 `375afb5`

`f098a58` 的模拟器取样曾出现一批多数超时、另一批全部成功，不能据后一批认定稳态。`375afb5` 使用严格 native VPN ready 动作及序列化、共享启动 Future 和真实截止时间；取消授权、TUN 构造失败及 JNI bool 链同步到失败状态。Android CorpLink TCP 在原子 admission 状态未就绪时拒绝建连，软错误透传且不累计端点退避；显式 proxy-only、普通机场、普通 WG 和其他平台不受此门槛影响。TCP transport reset 增加代次隔离，迟到的旧拨号不能重新登记。已删除可能在截止后继续重连健康节点的 Dart 后置循环。

回归测试先在旧实现出现预期失败，修复后 Go、Flutter 和竞态测试通过，完整 CI 及 arm64 APK 已成功。同签名保留数据安装真机后，实际 base.apk SHA-256 为 `1e905285d0663c10d0d8c161ef6cae5a388bf68e7a1bacbdc9b6ae304a3fcc2e`，与候选一致。复用保存账号和脚本，无需重输凭据。

真机两个 WG 各连续五次测速无 Timeout；两类 HTTPS 请求有各自 WG／同名组及双向流量。首页停止 VPN 后只点 SG 刷新，三轮都恢复到 2/2，后续请求共 30/30 成功；首轮前后两节点地址和端点不变。Wi‑Fi→蜂窝的十次请求成功；蜂窝→Wi‑Fi 的即时首轮两请求超时约五秒，下一轮自动恢复，后续八次成功，未手动重连。此失败窗口保留在验证记录，不以八次成功掩盖，也不冒充长期稳态验收。完整用例、缺项和构建证据见 `docs/03-Bettbox飞连多节点验证用例与结果.md`。

用户于 2026-09-30 接受已知限制及未测项，明确授权将当前多节点版本和验证记录合入 fork 的 main。合入范围包括上述源码、自动化测试、构建流程和说明，不包含手机授权材料、企业私有覆写脚本或本地诊断原件。现有 Release、手机数据和保存账号保持不变；未测项目不改标为通过。

同日浏览器访问内网 HTTPS 出现 `ERR_CONNECTION_ABORTED`，而 HTTP 代理对照请求成功。系统 VPN 路由未接管检查的私网地址；用户关闭 Bettbox“绕过私有网络”后确认页面恢复，按配置问题闭环。部署说明已补充内网访问需关闭该项，不改程序默认值、节点代码或私有分流脚本。关闭后的浏览器 DNS 答案和 WG 双向链未补读，不据此将完整浏览器验收改标为通过。

## 2026-10-21 合并上游 1.19.7

本轮以真机已验证基线 `10832ae1` 为本地历史，将 `upstream/main@7006a026` 通过双亲 merge commit `0ebf7230` 合入。计划初始按“上游 1.19.6”命名，但该上游提交的实际版本已是 `1.19.7+2026101601`；分支名不再重写，以免破坏已有追溯链。`10832ae1` 和 `7006a026` 都是当前候选的祖先，没有 rebase、squash 或丢弃旧提交。

合并后的通用代码以上游 1.19.7 架构为主：Flutter 工具链对齐 3.47.7，Freezed、Riverpod、JSON 和多语言生成物全部重新生成，并在 CI 中增加“重生成后 Git 必须无差异”门禁。`flutter_secure_storage` 升到 11.2.0 以兼容上游 `win32` 6 依赖，锁文件来自 Flutter 3.47.7 实际解析结果，没有手工修改校验和。Linux 不支持 Downloads 目录 API 时回退到应用数据目录，避免脚本和 Profile 文件测试被未处理的异步错误中断。

SG 配置没有恢复已被上游替换的整段 Dart 补丁，而是接入新的 `ProfilePath + ScriptedConfig + Patch` 管线。当 SG 或覆写脚本启用时，应用把已解析 Profile 导出到临时 JSON：先注入已勾选的同名 CorpLink 节点，再运行用户脚本，随后执行来源校验、失效引用阻断和二次注入，最后交给上游 Go patch 处理 TUN、DNS 和通用设置。这保留了空 Profile、机场订阅、`rule-provider`、INTL/Fuzhou 独立节点和脚本 fail-closed 语义；未勾选节点仍不生成代理、组或占位对象。

Android 侧同时保留上游前台服务和本地三态运行意图、底层网络路径指纹、授权临时 TUN bypass、手动停止抑制自启、应用双开和局域网排除网段。Mihomo 侧恢复了上游 `SetupParams`/export 结构，同时保留 CorpLink TCP Bind、节点独立 DNS、状态动作和定向重建。WireGuard 设备按上游 1.19.7 延迟初始化，对应重建测试先创建真实 device 再验证旧资源只关闭一次。本地 `core go test -p 1 ./...`、Mihomo outbound/config/dns/executor 以及 CorpLink `-race` 专项全部通过。

SG 发布包的独立 applicationId、橙红图标、测试签名与 arm64 原生库保持不变。上游新增的首页 `PRE` 小徽标和旧环境角标现在共用 `SHOW_APP_ENV_BANNER`，SG release 构建两处都不显示。Code Forge 的 Rust host 库在 Flutter 测试前编译，完整工作流包含生成物、所有 Flutter 分片、Android 恢复策略、Go 内核、Rust 登录 helper、Mihomo-SG Android 原生库和 APK 打包。

候选 HEAD `535b3464` 的 [Actions run 39561559970](https://github.com/luantu/Bettbox/actions/runs/39561559970) 已全链成功。APK 保存于 `outputs/android-sg-upstream-1.19.7-2026-10-21/app-release.apk`，SHA-256 为 `b9e5a7eb4fed62998ef10422b1c476bf489901d7fc323252193ed28d719d5e9c`；静态检查为包名 `com.appshub.bettbox.sg`、版本 `1.19.7 (2026101601)`，包含 arm64 `libmeta.so`、`libcorplink-rs-login.so` 和 `libcode_forge.so`。本节落盘时手机 ADB 已断开，因此不把覆盖安装、保留数据、真实授权、双节点、切网恢复或业务分流标为本候选已通过。

## 2026-10-21 上游合并最终闭环

真机覆盖安装暴露了两个合并后问题。首先，`flutter_secure_storage` 从 9.2.4 直接跨到 11.x 不支持旧 Android 数据的直接迁移。最终固定在 10.3.x 迁移桥，实际锁定版本为 10.3.4，同时兼容上游 `win32` 6。既有文件授权和 Cookie 也可在密码不可读时继续生成节点；首页和后台恢复不再仅以密码是否存在判断会话可用性。

其次，飞连页面误用 Flutter 原生 Material 的折叠卡和表单，而 Bettbox 1.19.7 主应用使用 `material_ui`。两套组件的本地化上下文不兼容，发布包会把构建异常渲染成大块灰白 ErrorWidget，看起来就像“下半页空白”。`corplink_management_panel.dart` 和 `corplink_sg.dart` 现已统一使用应用组件库，全屏背景恢复为当前主题 `surface`。节点详情只渲染前 8 条下发路由预览，完整列表仍可一键复制，避免大路由集在收起状态也参与整体测量。测试门禁要求两个飞连页面不得再引入 `package:flutter/material.dart`。

最终代码候选为 `e2d5a465`，[Actions run 39591979191](https://github.com/luantu/Bettbox/actions/runs/39591979191) 全链成功。本地 APK 位于 `outputs/android-sg-upstream-1.19.7-material-e2d5a465/app-release.apk`，SHA-256 为 `0dd4a8334361d01f431d9686e194fb436f03242b14cb9b8b8e9480451332a563`。外置盘 AVD 从 1.19.4 保留数据升级到 1.19.7，`firstInstallTime` 不变，安全存储成功迁移 10 项旧数据。节点卡、完整配置、双开关、三个输入框、发现节点、手动节点和操作区都可见，浅色主题下无灰白异常占位。

同一 APK 已保留数据覆盖安装到原真机，`firstInstallTime` 不变。深色主题下节点卡、配置和高级操作均正常显示；完整配置中的开关、账号、密码、上游服务器、五个发现节点和两个已选节点均可见。安装启动后无手动操作，状态在约 8 秒内从 1/2 收敛到 2/2。通过手机本地混合代理端口访问 ChatGPT 公开检查页和福州内网 HTTPS 域名均返回 HTTP 200；本轮日志未出现 `CorpLink native transport not ready` 或握手发送失败。本轮未重做 Wi-Fi／蜂窝双向切换和长时间稳态，这些边界仍沿用前一候选的验证记录，不在本次补充验收中扩大结论。

功能分支可以在最终真机验收后 fast-forward 到 fork `main`：`origin/main` 当前仍是该分支祖先，`10832ae1`、上游双亲合并 `0ebf7230` 及后续修复的完整历史均可保留，不需要 rebase 或 squash。此处只记录可合入拓扑，不把尚未执行的 main 推送写成既成事实。

## 2026-10-21 雅迪兼容、探针直存与构建提速

“更多 → 兼容应用”新增雅迪智行兼容入口。它读取雅迪安装包的真实图标创建桌面快捷方式，打开前先暂停 Bettbox VPN/TUN；UsageStats 监测雅迪是否仍在前台，离开宽限期后仅在原先有运行意图时恢复。兼容暂停拥有独立状态，智能启停、native recovery 和 SG 恢复都不能中途夺回 VPN。用户点“保持停止”会清除 SmartStop 状态并写入明确停止意图，应用重启或网络变化也不自动恢复。无 UsageStats 且兼容通知频道不可用时，入口拒绝启动，避免暂停后没有恢复通道。

飞连节点的健康探针可在节点弹窗中直接“保存并应用”，不再依赖页面底部按钮、密码可读性或再次登录。地址禁止携带 userinfo、query 或 fragment；安全存储之外的恢复记录按账号与上游作用域隔离，账号／上游变化会清除旧探针。保存成功但 Profile 重载失败时，页面会明确区分两种结果。

Android SG 工作流增加 Flutter／Gradle、Go、Code Forge、登录 helper 和 Mihomo-SG 原生库缓存。命中原生缓存后仍检查文件非空、AArch64 架构及 `startTUN`、`androidTunReady` 等关键符号，最终 APK 还会核对四个 arm64 原生库。原先 setup 脚本中的中间 APK 打包已取消，只在最后执行一次 `flutter build apk`。冷缓存 run `39602651169` 第一次耗时 17分28秒，热缓存重跑 10分12秒；后续热缓存候选为 9分04秒至 10分19秒。最终 `01efca2a` 的 [run 39707246212](https://github.com/luantu/Bettbox/actions/runs/39707246212) 全链成功。

最终候选 APK 位于 `outputs/android-sg-yadea-compat-2026-10-22/01efca2a/app-release.apk`，SHA-256 为 `fd6fcfa3185d4cdfbd40810d57975d0ed854491f92d344b61eb4c3be12766bef`。包名 `com.appshub.bettbox.sg`，版本 `1.19.7 (2026101601)`，v2 测试签名，包含 `libmeta.so`、`libcore.so`、`libcorplink-rs-login.so` 与 `libcode_forge.so`。外置盘单核 AVD 保留数据覆盖安装后，雅迪未安装状态正确禁用两个操作；福州探针弹窗直接保存并关闭，“取消修改”保持禁用，核心日志确认最终代理配置含探针，fatal/panic 为 0。

真机先暴露 HyperOS 旧广播假支持和旧 shortcut token 缺失；测试提交 `3907bd3a` 的 run `39703638716` 精确红灯，`835253da` 改为现代 pin 优先并刷新已有 shortcut。新包中 shortcut 含 targetPackage 与 UUID token，使用雅迪 icon bitmap。雅迪前台 20 秒内 VPN/TUN 始终关闭，离开第 10 秒恢复；“保持停止”跨 18 秒、网络切换、重开应用和覆盖安装均不自启。随后手动启动恢复 SG 2/2 与双业务 200，最后恢复 Wi-Fi 智能暂停和原设备设置。

最终 `01efca2a` 再加入 token commit 失败回滚与纯行为策略测试；测试先在 run `39706506560` 红灯，最终 run 转绿，独立复核无剩余问题。exact APK 真机安装后 base.apk 哈希一致，firstInstallTime 与 shortcut token/bitmap 保留；兼容打开和 Home 恢复冒烟通过，双业务 200，设备设置及 ADB 转发清理完成。该候选具备 fast-forward fork `main` 的设备证据，main 推送状态见后续提交记录。

## 2026-10-23 SSID 智能启停

增加独立地点规则，支持精确 SSID、可选 IP／网关条件，同一条内同时满足、不同条任一命中。新规则按选中的物理网络匹配，不混用 Wi-Fi、蜂窝或 TUN 地址。原 `smartAutoStopNetworks` 字段不改写，继续独立生效，并在界面明确警告旧规则的同网段误判风险。新规则保存在 `smartAutoStopRules`，不触碰授权、机场订阅及脚本。

Android 后台服务成为唯一启停执行方；前台持久化设置后请求检查，后台重读原配置，使用与页面共用的三态判定器。SSID 未知或断网时保持状态，不降级为仅 IP；删除最后规则、关闭总开关可以释放智能暂停，但手动停止和雅迪兼容暂停优先。SSID／能力变化事件只检查规则，不因此重连健康 WireGuard 或刷新 DNS。

页面提供当前网络与启停状态、地点规则增删改、当前 Wi-Fi 预填、显式保存和位置权限引导。只读取已连接网络，不扫描邻居；后台 SSID 识别需要的权限不足时明确显示，不伪报成功。新增规则、配置往返、编辑器、原生 SSID 归属及权限行为测试。构建与设备验证进度记录在 `docs/04-SSID智能启停使用与验证.md`，未完成的设备用例不沿用旧版结果。

独立复核补上暂停归属／启动代次、真实默认物理出口、未知 SSID 保持状态、配置串行保存和损坏新字段隔离。设备操作发现首条规则修改不可变空列表，先补完整父页面测试复现，再用可增长副本修复。事件监听按快照派发，避免页面卸载期间并发修改。CI 修复早期依赖安装改变 `local.properties` 后的签名配置粘连，禁止 debug 回退，并将固定 SG 证书指纹作为产物门禁。

最终代码 `89f8661e` 的 [run 39941835213](https://github.com/luantu/Bettbox/actions/runs/39941835213) 全链成功，SSID 先行回归 26 项通过。最终云端 APK 已在外置盘单核 API 35 模拟器与 API 37 真机保留数据安装，手机 `base.apk` SHA-256 与 CI 一致。模拟器完成首条规则保存、同名／异名 SSID、SSID 与网段 AND、同网段模拟蜂窝切换、定位关闭保持及手动停止优先；真机完成当前 SSID 独立暂停、两轮后台 Wi-Fi／蜂窝往返、手动停止不自启，恢复后两个节点 2/2，专属探针分别 210 ms、41 ms。

测试结束已删除手机临时地点规则，恢复旧 IP 条件、智能暂停、Wi-Fi 开／蜂窝关及一分钟熄屏；精确位置和后台权限保留。账号、订阅及脚本未编辑。本轮未重做长时间锁屏、真实基站漫游与雅迪前台测试；智能暂停期间既有 WG 的 transport-not-ready 提示仍可出现，不宣称已消除。完整边界和 APK 身份见新增使用与验证文档。

## 2026-10-23 智能暂停与 SG 维护解耦

不增加开关。Android `pauseTun` 只关闭系统 listener，保留 JNI 套接字保护；维护准入独立于 TUN 就绪，保护失败向 Go 返回失败并中止拨号。硬停止仍撤销准入，雅迪保留暂停优先级，迟到启动不得抢回软暂停的资源。

后台使用原生 action 客户端，不再依赖 service isolate 中不可用的 UI `clashCore`。启动就绪立即确保已选 SG 节点，智能暂停期间每 45 秒维护并处理物理网络变化；恢复过程各阶段检查取消资格，不为维护而打开系统 TUN。首页磁贴显示“引流已暂停”和节点就绪数。

`719b7cd5` 的 [run 39949330658](https://github.com/luantu/Bettbox/actions/runs/39949330658) 全链成功，已同签名保留数据安装真机。无 TUN 时两节点实测 198／67 ms；后台 69 秒新增 native-not-ready 为 0；完全断网恢复后仍无 TUN、两节点探针 307／30 ms；解除暂停后恢复 TUN，地址／端点摘要稳定。没有编辑用户已有地点规则、账号、节点或脚本。

手动停止回归发现旧 peer 定时器仍报错，追加 WG Down／Up 生命周期，保留设备与 IP 栈；同步初始化、重建提交复查及 listener 代次绑定防止停止后重新启动。新增定向测试先红后绿，真实 WG 启停 race 回归连续 10 轮通过。手机已被用户取走，这一追加修复尚未真机复测，不将前一包的真机结果冒用为最终包通过。详细记录及待验项目见 `docs/05-智能暂停隧道保活与真机验证-2026-10-23.md`。

追加修复代码 `4516feb3` 的 [run 39952906430](https://github.com/luantu/Bettbox/actions/runs/39952906430) 全链成功，耗时 10 分 7 秒；[APK artifact 12501985861](https://github.com/luantu/Bettbox/actions/runs/39952906430/artifacts/12501985861) 已独立验证固定 v2 签名、原包名及四个 arm64 库，SHA-256 为 `da97cc8ea451e9a36ed44d8334690ae77f6afc59fbd4118009aa2412565b3746`。三项补充 race 压力测试各 100 轮通过。最终包尚未真机安装，当前只推功能分支，保留 `main` 未更新，待最后设备回归。

## 2026-10-26 雅迪快捷方式连续打开

旧包在手机原桌面图标上复现首次成功、十秒内重开失败。`CompatibilityAppManager` 不再用活动会话直接拒绝重开，改由 `CompatibilityLaunchSession` 复用暂停拥有者、合并在途点击并用 generation／revision 撤销旧恢复与清理决策；只保留一个前台监控。停止意图下也允许已接受的雅迪拉起完成，不会因此自动启 VPN。图标、token、桌面 ID、权限与配置均不变。

新增 Java 会话行为测试先红后绿，独立复核的停止清理竞态另补用例修复；最终三组兼容回归及五十轮并发测试通过，测试纳入工作流。代码 `4c274995` 的 [run 40251288321](https://github.com/luantu/Bettbox/actions/runs/40251288321) 全链成功，耗时 10 分 24 秒；[最终 APK](https://github.com/luantu/Bettbox/actions/runs/40251288321/artifacts/12620703156) SHA-256 为 `45bd964fbeb6eb16528fbfd6585f7b662f4087ea442b5f000ac05e8ff63c6fde`。

最终云端包同签名保留数据安装，手机读回同哈希、首装时间不变；原图标六轮快速重开、二十秒前台暂停、离开约10.56秒恢复、恢复后再开，以及VPN手动停止下三轮重开均通过。还补齐上次WG停止修复的设备回归：稳定观察75秒无持续握手失败与自启，主动恢复SG2/2，回原智能暂停后指定双探针245／54ms。原网络、熄屏与智能总开关已恢复，详细用例及未验范围见 `docs/06-雅迪快捷方式连续打开验证-2026-10-26.md`。
