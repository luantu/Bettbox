# Bettbox 飞连版：Android 构建与部署

本分支在 Bettbox 中集成 Mihomo-SG 与 CorpLink 授权。没有机场订阅也能创建基础配置；已有订阅时，应用在最终配置中加入所选飞连 TCP 服务器的独立 WireGuard 节点和同名代理组，保留原有节点、代理组、规则和配置覆写脚本。`SG-Node` 是指向 INTL 组的隐藏兼容别名，`SG-OpenAI` 继续承担原有 ChatGPT 分流。

## 适用范围与安全边界

- 当前工作流生成 Android arm64 APK，最低 Android 版本为 8.0（API 26）。应用包名为 `com.appshub.bettbox.sg`，可与原版 Bettbox 共存。
- SG 测试包的 Android 启动图标保留原版三条形状与背景，但改为青绿渐进配色，便于在手机上区分两个包。商店预览图及其他平台图标不参与此 APK，未随之修改。
- GitHub Actions 使用仓库内固定的**测试签名**，便于同包名覆盖安装、保留 Android Keystore 中的凭据。该签名材料公开，**不可用于正式发布**。正式分发须改用私有生产密钥，并规划密钥轮换和数据迁移。
- 用户名、密码、Cookie、设备身份、OTP 与 WireGuard 私钥只留在设备上。不要把应用数据、配置导出文件或完整运行日志上传到公开仓库。排查问题时先脱敏。
- 上游地址填写飞连登录与节点发现服务的 HTTPS 地址，不是 `/vpn/conn` 返回的 WireGuard 节点地址；实际 TCP VPN 端点由应用登录后发现。Android 会通过当前物理网络解析该上游域名，无需手填 IP。

## 从 GitHub Actions 获取 APK

1. 在本仓库的 **Actions → Android SG APK** 中选择 `codex/corplink-multi-node-impl` 分支，手动运行工作流。功能合并后改选合并后的目标分支；构建前确认所选 ref 和提交 SHA。
2. 等待 Flutter 单测、Go 出站测试、CorpLink Android helper、Mihomo-SG 原生库和 APK 打包全部通过。
3. 下载名为 `Bettbox-android-arm64-sg` 的构建产物，解压得到 `app-release.apk`。记录工作流 run、提交 SHA 和 APK SHA-256，确保安装包与源码对应。

工作流定义见 [android-sg-apk.yml](../.github/workflows/android-sg-apk.yml)。其中 CorpLink helper 按固定提交编译，Mihomo-SG 从本仓库 `core/` 源码编译；构建不依赖本机 Android NDK。SG 测试 APK 通过 `SHOW_APP_ENV_BANNER=false` 隐藏右上角 `PRE` 角标，但仍保留预发布身份和公开测试签名，不因此变成正式发布包。

## 安装和配置

在 arm64 Android 设备上直接安装 APK。已有同签名飞连测试包时，使用 `adb install -r app-release.apk` 覆盖升级，避免卸载后丢失 Android Keystore 保存的密码。原版 Bettbox 的包名不同，不会被覆盖。

打开应用的 **更多 → 飞连 VPN 节点**，启用飞连，只填写用户名、密码和上游 HTTPS 地址。点击**从飞连发现**，勾选需要同时连接的 TCP 服务器；若发现接口暂不可用，可手动输入服务器返回的准确名称。每个节点可选填 HTTPS 健康探针，留空时只检查 TCP/WireGuard 握手。点击**保存并连接**后，应用共用一次账号授权，分别生成节点密钥、取得隧道参数并启动 Android VPN。首次启动若出现系统 VPN 授权提示，需在手机上允许。需要 OpenAI/ChatGPT 走 INTL 时，保持 `SG-OpenAI` 开关启用；新增服务器的分流规则由覆写脚本配置。

飞连页面每三秒更新一次状态，显示已就绪节点数、各节点握手、隧道 IP、上游端点和本次打开页面以来的 IP 变化次数。**刷新状态并恢复**只对异常节点触发首次握手、定向重连或该节点 IP 栈重建；**重新连接隧道**可逐节点主动重连。自定义网站探针失败只是诊断信息，不能单独推翻已就绪的握手，更不会因此重载整个 Profile。保存或重连结束后，页面会立即刷新状态。

Android 首页首次升级会默认加入半宽的 SG-Node 磁贴：标题与状态沿用其他半宽卡片的布局，状态显示“已连接数/启用数”，右上角可手动刷新异常节点；点卡片主体进入飞连页查看每节点详情。磁贴可通过首页右上角“编辑”删除、重新添加或排序；删除后不会在下一次启动时自行出现。

已有机场订阅时，继续按原方式更新订阅。飞连组会在下载配置和覆写脚本处理后合并到最终配置；机场节点和普通分流不应消失。没有订阅时，应用会创建一个可启动的基础 Profile。更换飞连账号或上游地址后重新保存，以免沿用旧授权。

使用脚本增加规则提供者时，要在“配置 → 脚本”选中该脚本，并在脚本页“设置”中启用目标 Profile 的“使用全局脚本覆写”。仅有 `rule-providers` 定义不会产生分流；还要在 `MATCH` 之前有引用它的 `RULE-SET,<提供者名>,<代理组>`。可长按配置卡片查看运行时配置，并在“代理 → 更多 → 提供者”核对规则条目数和更新时间。**全局**模式不按规则分流；验证脚本命中时临时切到**规则**模式，在“更多 → 请求”查看匹配类型和代理链，完成后恢复原模式。若规则源只在 Wi-Fi 下可达，先在 Wi-Fi 下更新并缓存；蜂窝网络下既有缓存可以继续使用，但不能保证当时能更新规则源。

## 可用性验收

构建通过只是安装前提；每个版本仍须在 Android 上核验以下结果：

| 检查项 | 通过标准 |
| --- | --- |
| 授权与节点 | 只填写账号、密码和上游地址；发现并同时选中 INTL 与 `FUZHOU-NODE-1` 后，最终配置含两个 `-WG` 代理、两个同名组及隐藏 `SG-Node` 别名。无需手填 Cookie、OTP、设备身份或密钥。 |
| Android VPN | 保存并完成系统授权后，两节点各自完成 WireGuard-TCP 握手，状态显示 `2/2`；仅有 TCP socket 连通不算通过。单节点故障不得影响另一节点和机场代理。 |
| ChatGPT 分流 | Android 浏览器打开 `chatgpt.com`，请求记录显示浏览器进程经 `SG-OpenAI → SG-Node → INTL-WG`，页面实际加载且有双向流量。若当前 Wi-Fi 本身也能访问 ChatGPT，单看页面打开或公网出口 IP 相同都不能证明走了隧道；还应核对 Android VPN 的 `tun0` 流量，必要时在隔离测试环境临时阻断飞连外层 TCP 端点做反证。未登录首页不等于已验证登录后的对话。 |
| 隧道内 DNS | 配置的 DoH 解析器绑定 SG WireGuard 出站；临时把内核日志级别设为 `info`，访问未缓存的新域名，应出现“DoH resolver TCP connected through WireGuard tunnel”运行时标记，且域名访问成功。测试后恢复原日志级别。仅看配置字段不足以通过。 |
| 网络切换自恢复 | VPN 开启时双向切换 Wi-Fi 和蜂窝；物理网络验证可用后不手动操作，两节点各自恢复，健康节点不因另一节点失败而重连。记录物理接口、各隧道 IP、活跃飞连 TCP 来源和请求结果，不能只看“已连接”字样。普通代理在单节点故障期间仍可用。 |
| 订阅与脚本兼容 | 更新现有订阅后，原机场节点、代理组和规则仍在；覆写脚本的 `rule-providers` 和指向福州组的 `RULE-SET` 在最终配置中有效，且不会被后置节点注入删除。 |

当前版本是否通过上述各项，以对应 Actions run 和 Android 实测记录为准；不要把此清单本身视为完成证明。

## 外置磁盘模拟器（可选）

本机测试环境把 Android SDK 放在 `/Volumes/ExtArchive/Android/sdk`，AVD 放在 `/Volumes/ExtArchive/Android/.android/avd/`。保留数据验证使用 `BettboxSGApi35Test2`，空配置验证使用 `BettboxSGApi35Fresh`；两者顺序启动，限制为单核、禁用音频，完成后关闭，避免持续占用主机 CPU。模拟器中的账号信息仅用于本机测试，不应随镜像或截图分享。

逐项验收与实际结果记录在 [03-Bettbox飞连多节点验证用例与结果.md](03-Bettbox飞连多节点验证用例与结果.md)。未填入设备证据的项目一律视为未验证。

真机验证仍有独立价值：模拟器不能代替不同 Android 厂商的 VPN 权限、后台保活和 Wi-Fi/蜂窝切换行为。
