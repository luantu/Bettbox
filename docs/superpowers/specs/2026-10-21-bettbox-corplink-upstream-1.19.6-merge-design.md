# Bettbox SG 合并上游 1.19.6 设计

## 目标

把 `upstream/main@7006a026` 合并到已经完成真机验收的 `10832ae1`，保留双方完整提交历史，并让 Bettbox SG 继续具备机场代理、CorpLink 多节点、内网 DNS、网络恢复和手动停止语义。合并完成后先取得自动测试与 Android arm64 APK 构建结果，再进行模拟器验证；真机验证等用户重新接入手机后执行。

## 当前基线

本次合并从 `10832ae1d451163d500c184491141c100165e796` 创建分支 `codex/corplink-upstream-1.19.6`。该提交对应已经安装并通过真机验证的 SG 版本，可作为独立回退点。

上游目标是 `7006a0263510`，版本为 1.19.6。双方共同基线为 `31893466`。从共同基线计算，当前分支有 235 个本地提交，上游有 79 个提交；上游改动 741 个文件，与本地改动重叠 67 个文件。预演合并已经在 Android VPN 生命周期、Flutter 控制器、配置模型、生成文件、工作流和 Mihomo 核心等位置发现冲突。

## 历史与分支策略

合并必须保留现有提交拓扑。执行时使用 `git merge --no-ff upstream/main`，生成一个明确的合并提交。禁止使用 rebase、squash、filter-branch 或把现有 SG 历史重新压成若干 cherry-pick。

当前已验证分支 `codex/corplink-native-auto-recovery` 保持不动。所有冲突处理、测试修订和构建调整都发生在 `codex/corplink-upstream-1.19.6`。合并分支出现不可接受的回归时，直接回到 `10832ae1`，不修改已验证分支和已发布标签。

## 合并原则

上游负责通用应用框架，SG 分支负责企业 VPN 能力。冲突不能机械选择 `ours` 或 `theirs`，必须按职责逐项重建。

通用 Flutter 页面、依赖升级、桌面平台修订、脚本引擎和配置模型优先采用上游 1.19.6 的结构。现有 SG 功能按新结构重新接入，避免把上游已经删除或替换的旧实现整块带回。

以下 SG 行为是不可丢失的合并不变量：

- Android 包名保持 `com.appshub.bettbox.sg`，测试签名和橙色 SG 图标保持不变，界面不显示 PRE 标识；
- 机场订阅、普通代理、Profile、配置拉取、脚本覆写和原有分流仍可使用；
- CorpLink 只使用一个账号登录，支持多个独立 TCP 节点，每个节点有自己的 WireGuard 密钥、会话、状态、DNS 和恢复动作；
- 只为已勾选且授权成功的服务器创建同名代理组与 `<serverName>-WG` 节点，不生成旧 `SG-Node`、`SG-OpenAI` 或占位组；
- ChatGPT 规则直接指向已启用的 INTL 组；福州域名、内网网段及 `rule-provider` 仍由覆写脚本负责；
- INTL 公网 DNS 走隧道内 DoH，福州受保护域名使用服务端下发的内网 DNS，并绑定福州 WireGuard 出站；
- Android 应用双开流量、TUN 私网排除网段和小米局域网直连规则保持现有行为；
- 网络切换、同一蜂窝 Network 对象内的 LinkProperties 变化、CorpLink native transport not ready、授权期 TUN 自捕获都保留现有恢复机制；
- 智能启停只撤销和重建 Android TUN，不调用不安全的 WireGuard 私有字段反射；
- 用户手动停止后，应用启动、开机、覆盖安装、网络变化和恢复看门狗都不得自行拉起；用户再次手动启动后才恢复自动重连；
- 日志、状态页和测试产物不得输出密码、Cookie、OTP、设备身份、私钥或真实内部 DNS 配置。

## 冲突处理顺序

先处理构建系统与依赖，再处理应用生命周期，最后处理 Mihomo 核心。这样能尽早发现上游工具链、生成代码和 API 变化，避免在错误基线上修业务冲突。

第一组是 `pubspec.yaml`、锁文件、Flutter／Gradle／NDK 设置、CI 工作流和生成文件。以 1.19.6 的依赖关系为主，保留 SG 测试签名、arm64 构建、CorpLink Rust helper 和现有测试门禁。生成文件要与合并后的源模型一致，不能手工拼出无法再生成的状态。

第二组是 `GlobalState`、`ServicePlugin`、`VpnPlugin`、`BettboxVpnService`、`main.dart`、`controller.dart`、`state.dart` 和设置模型。采用上游服务生命周期结构，同时保留 SG 的 native recovery policy、用户运行意图、双 isolate 状态同步、智能启停和网络路径指纹。任何自动启动入口都必须继续遵守三态用户意图。

第三组是 `core/` 与 `core/Clash.Meta/`。以 SG 的 CorpLink TCP Bind、按节点 WireGuard、内网 DNS 和状态接口为业务基线，再吸收上游 WireGuard、配置解析、DNS、运行时和依赖更新。这里不接受整文件覆盖。每个冲突都要确认接口调用方、状态所有权和关闭顺序。

第四组是界面、国际化、图标、脚本覆写与验证文档。采用上游页面结构和新文案生成方式，重新放入 SG 管理页、首页磁贴、配置项和既有脚本能力。资源文件不复制旧生成物覆盖上游新版。

## 验证设计

冲突解决后先跑现有快速门禁：Flutter 全套测试、Android Java 策略测试、Go outbound/config/dns/executor 和 `core` 全套测试。新增或改写的冲突必须有针对性的回归测试；不能只以编译通过判断行为未退化。

本地门禁通过后推送合并分支，由 GitHub Actions 构建 Android arm64 APK。构建必须确认：包名仍是 SG 独立包、版本采用上游 1.19.6、签名证书未变、`libcore.so`、`libmeta.so` 和 `libcorplink-rs-login.so` 均存在。

APK 构建成功后先在外置磁盘模拟器验证安装、空配置、机场 Profile、脚本覆写、SG 管理页、手动停止不自启和基本 TUN 生命周期。真实企业账号、双节点、ChatGPT、福州内网 DNS、Wi-Fi／蜂窝切换及长期稳态只在用户接入真机后验收。模拟器不能替代真实 CorpLink 授权结果。

## 验收标准

合并阶段完成必须同时满足以下条件：

- Git 历史中可见 `10832ae1` 的全部祖先、上游 `7006a026` 的全部祖先及一个明确的 merge commit；
- 工作树干净，冲突标记、未跟踪生成物和临时构建文件均已处理；
- Flutter、Java、Go 和 SG 专项测试全部通过；
- GitHub Actions 对合并分支构建成功，APK 静态身份与原生库核对通过；
- 模拟器安装和基础生命周期验证通过；
- 真机尚未接入时，状态只能写“待真机验证”，不能写成最终闭环。

真机接入后的最终标准沿用现有 SG 验收：一次账号授权后两个节点同时可用，ChatGPT 走 INTL，福州规则与内网 DNS 走福州节点；重新授权、Wi-Fi／蜂窝切换、蜂窝地址变化、native transport not ready 和手动停止语义均通过；机场订阅和普通代理不回归。

## 风险与回退

最大风险是上游 Android 服务生命周期与 SG 恢复状态机互相覆盖，以及上游 Mihomo／WireGuard 更新改变 SG 使用的内部结构。依赖与生成模型升级也可能造成“能编译但旧配置迁移失败”。这些风险通过分组解决冲突、专项回归测试和 merge commit 前后的差异复核控制。

任何阶段发现无法同时满足上游 1.19.6 与 SG 不变量时，保留冲突现场和失败测试，停止合并提交，不用删除功能或降低验收标准换取绿灯。回退目标固定为 `10832ae1`，不会回滚或改写它。

## 本地引用关系

- [[2026-09-29-bettbox-corplink-multi-node-design]]
- [[2026-09-29-bettbox-corplink-node-dns-design]]
- [[../../../localpatch|Bettbox SG 本地补丁记录]]
- [[../../../../../../bettbox/work/corplink-multi-node/status|CorpLink 多节点执行状态]]
