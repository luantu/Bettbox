# Bettbox 飞连版：Android 构建与部署

本分支在 Bettbox 中集成 Mihomo-SG 与 CorpLink 授权。飞连节点是独立功能：没有机场订阅也能创建基础配置；已有订阅时，应用会在最终配置中合并 `SG-Node` 与 `SG-OpenAI`，保留原有节点、代理组、规则和配置覆写脚本。

## 适用范围与安全边界

- 当前工作流生成 Android arm64 APK，最低 Android 版本为 8.0（API 26）。应用包名为 `com.appshub.bettbox.sg`，可与原版 Bettbox 共存。
- GitHub Actions 使用仓库内固定的**测试签名**，便于同包名覆盖安装、保留 Android Keystore 中的凭据。该签名材料公开，**不可用于正式发布**。正式分发须改用私有生产密钥，并规划密钥轮换和数据迁移。
- 用户名、密码、Cookie、设备身份、OTP 与 WireGuard 私钥只留在设备上。不要把应用数据、配置导出文件或完整运行日志上传到公开仓库。排查问题时先脱敏。
- 上游地址填写飞连登录与节点发现服务的 HTTPS 地址，不是 `/vpn/conn` 返回的 WireGuard 节点地址；实际 TCP VPN 端点由应用登录后发现。

## 从 GitHub Actions 获取 APK

1. 在本仓库的 **Actions → Android SG APK** 中选择 `codex/feilian-android` 分支，运行工作流；推送该分支也会自动触发构建。
2. 等待 Flutter 单测、Go 出站测试、CorpLink Android helper、Mihomo-SG 原生库和 APK 打包全部通过。
3. 下载名为 `Bettbox-android-arm64-sg` 的构建产物，解压得到 `app-release.apk`。记录工作流 run、提交 SHA 和 APK SHA-256，确保安装包与源码对应。

工作流定义见 [android-sg-apk.yml](../.github/workflows/android-sg-apk.yml)。其中 CorpLink helper 按固定提交编译，Mihomo-SG 从本仓库 `core/` 源码编译；构建不依赖本机 Android NDK。

## 安装和配置

在 arm64 Android 设备上直接安装 APK。已有同签名飞连测试包时，使用 `adb install -r app-release.apk` 覆盖升级，避免卸载后丢失 Android Keystore 保存的密码。原版 Bettbox 的包名不同，不会被覆盖。

打开应用的 **更多 → 飞连 SG-Node**，启用飞连，仅填写用户名、密码和上游 HTTPS 地址，点击**保存并连接**。应用负责登录、保存授权、生成设备 ID/设备名及 WireGuard 材料，并创建 `SG-Node`；点击**检查连接**，应显示节点可用及延迟。需要 OpenAI/ChatGPT 走飞连时，保持页面中的 `SG-OpenAI` 开关启用，再启动首页的 VPN 服务。

已有机场订阅时，继续按原方式更新订阅。飞连组会在下载配置和覆写脚本处理后合并到最终配置；机场节点和普通分流不应消失。没有订阅时，应用会创建一个可启动的基础 Profile。更换飞连账号或上游地址后重新保存，以免沿用旧授权。

## 可用性验收

构建通过只是安装前提；每个版本仍须在 Android 上核验以下结果：

| 检查项 | 通过标准 |
| --- | --- |
| 授权与节点 | 只填写三项信息后，`SG-Node` 出现在最终配置，节点检查返回有效延迟；无需手填 Cookie、OTP、设备身份或密钥。 |
| Android VPN | 启动服务后系统 VPN 保持连接，WireGuard-TCP 完成握手；仅有 TCP socket 连通不算通过。 |
| ChatGPT 分流 | Android 浏览器打开 `chatgpt.com`，请求记录显示 `SG-OpenAI → SG-Node`，页面实际加载且有双向流量。未登录首页不等于已验证登录后的对话。 |
| 隧道内 DNS | 配置的 DoH 解析器绑定 SG WireGuard 出站；新域名解析时应出现“DoH resolver TCP connected through WireGuard tunnel”运行时标记，且域名访问成功。仅看配置字段不足以通过。 |
| 网络切换自恢复 | VPN 开启时切换 Wi-Fi；恢复联网后不手动操作，SG 应重新握手，并在四分钟内再次连通 ChatGPT。普通代理在 SG 故障期间仍可用。 |
| 订阅兼容 | 更新现有订阅后，原机场节点、代理组和规则仍在，`SG-Node` 与 `SG-OpenAI` 只出现一次。 |

当前版本是否通过上述各项，以对应 Actions run 和 Android 实测记录为准；不要把此清单本身视为完成证明。

## 外置磁盘模拟器（可选）

本机测试环境把 Android SDK 放在 `/Volumes/ExtArchive/Android/sdk`，AVD 放在 `/Volumes/ExtArchive/Android/.android/avd/BettboxSGApi35.avd`。启动时限制为单核、禁用音频；完成测试后关闭模拟器，避免持续占用主机 CPU。模拟器中的账号信息仅用于本机测试，不应随镜像或截图分享。

真机验证仍有独立价值：模拟器不能代替不同 Android 厂商的 VPN 权限、后台保活和 Wi-Fi/蜂窝切换行为。
