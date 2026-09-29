# Bettbox SG 分支本地补丁记录

本文件记录 `codex/feilian-android` 相对 fork 的 `main` 所做的改动，供后续同步 Bettbox 上游时辨认哪些行为必须保留。比较基线是 `f71482f`，合并上游前的分支提交是 `8a31b6f`；该区间有 136 个提交，涉及 143 个跟踪文件。以下按功能归纳，不逐条重复提交历史。

## 产品行为

- Android 测试包使用独立的 `com.appshub.bettbox.sg` applicationId，与原版 `com.appshub.bettbox` 并存。它使用固定的公开测试签名，支持同包名保留数据覆盖升级；这个签名不能用于生产发布。启动图标的三条前景形状改为青绿渐进色，右上角 `PRE` 视觉角标只在 SG 构建中隐藏，应用仍按预发布包处理。相关文件：`android/app/build.gradle.kts`、`android/app/sg-test.keystore`、`android/app/src/main/res/drawable/ic_launcher_foreground_*.xml`、`lib/manager/app_manager.dart`。
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
- 新增回归用例覆盖双节点密钥/令牌/IP 隔离、单节点 401 时完整配置仍加载、同名组与同名代理保护、脚本改写托管名称时的失败关闭、IP 变化只替换一个设备、并发重建/关闭及网络切换补偿。Go 低并发测试和重建路径的竞态检测已通过。提交 `e7295e8` 的 [Android SG APK 工作流](https://github.com/luantu/Bettbox/actions/runs/36555032514) 全部成功；该包 SHA-256 为 `4ec0db639ce8a2dace869082d1ec59cc5b4282262b5e886993e98efb1ba4a95f`，现作为预览包保存。外置盘空白模拟器验证了授权失败时的 `REJECT` 占位组和 VPN 启动；保留旧授权的 AVD 发现节点时暴露 `_TypeError`，已在 `b0e75fc` 修复并通过云端构建，但设备复测仍未完成。独立复核发现覆写脚本改写托管组后会被静默覆盖，`ba7bd6f` 已改为提示并阻断相关组，新一轮 Actions run `36560582858` 正在执行。真机双节点和真实路由均未验收。逐项结果见 `docs/03-Bettbox飞连多节点验证用例与结果.md`，不能沿用上文单节点真机结果判定多节点完成。
