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

本节在完成上游合并后记录上游来源、合并提交、冲突处理及验证结果。上面的补丁范围固定按合并前的 `f71482f..8a31b6f` 口径，不把之后引入的上游代码算成本地补丁。
