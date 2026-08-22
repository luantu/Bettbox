# CorpLink SG-Node 集成方案

## 目标

Bettbox 保留现有机场订阅、节点测速、配置覆写和分流能力，并增加一个内置的
`SG-Node-Linux`/`SG-Node` CorpLink 节点。用户只填写：

- 飞连用户名；
- 飞连密码；
- 上游建连服务器地址。

device ID、device name、WireGuard 密钥、Cookie、隧道地址、MTU、DoH 和节点名称均由
应用按固定规则生成或维护，不要求用户手工填写。

## 推荐架构

不要在 Bettbox 外部再启动一套 Mihomo。Bettbox 的 `patchRawConfig()` 是统一入口，
应在这里把 CorpLink WireGuard 出站追加到当前最终配置：

```text
机场订阅/本地配置
        ↓
Bettbox 原有配置解析和 JS 覆写
        ↓
CorpLink 授权状态刷新
        ↓
追加 SG-Node-Linux WireGuard-TCP 出站
        ↓
保留原有 proxy-groups/rules，并将 SG-Node-Linux 暴露给覆写脚本
        ↓
同一个 Mihomo 内核运行机场节点和 CorpLink 节点
```

这样机场节点和 SG 节点共享同一个控制器、连接记录、DNS 和分流体系；覆写脚本可以
使用固定节点名 `SG-Node-Linux` 加入 OpenAI 专用组。

## 输入与安全存储

新增 `CorpLinkSettings` 配置模型，但密码不能进入普通 `shared_preferences.json`。
用户名和服务器地址可以进入 Bettbox 配置；密码、Cookie 和密钥应使用平台安全存储。
首次保存后，应用只在内存中组装 Mihomo 配置，不把明文密码写进 profile、日志或导出包。

## 固定默认值

```text
节点名：SG-Node-Linux
协议：WireGuard over TCP
国际服务器端口：由 CorpLink /vpn/list 返回，当前 FZ-INT 为 34080
MTU：使用服务端下发值，当前为 1400
DNS：remote-dns-resolve=true
DoH：8.8.8.8、1.1.1.1，必须通过隧道访问
```

每个 Bettbox 安装实例首次启用时生成唯一 `device_name` 和 `device_id`，并生成新的
WireGuard 私钥。不能复制 Windows 正式实例或另一台 Bettbox 的 Cookie/密钥。

## 授权生命周期

1. 用户点击启用 SG 节点。
2. Bettbox 调用随应用发布的 `corplink-rs` 子进程完成登录和 2FA。
3. 保存 Cookie、device identity 和 private key 到安全存储。
4. Mihomo 启动或重启前调用 `/vpn/conn`，取得最新隧道 IP、peer public key、endpoint、MTU。
5. 组装 `wireguard` 出站并追加到最终配置。
6. Cookie 接近过期时后台刷新；刷新失败不得删除当前仍健康的隧道。
7. 日志记录授权阶段、handshake 阶段、DoH 阶段和真实代理请求阶段，但不得记录密码、Cookie 或私钥。

## 配置注入约束

注入逻辑必须满足：

- 不覆盖机场原有 `proxies`；
- 不覆盖机场原有 `proxy-groups`，只追加节点和目标组成员；
- 节点已存在时按名称更新，不产生重复节点；
- 原有覆写脚本在注入前后都能运行；
- `remote-dns-resolve` 强制为 `true`；
- OpenAI 专用组优先包含 `SG-Node-Linux`，但保留机场节点作为备用；
- Windows 正式节点 `SG-Node` 仍由现有 Windows 配置管理，不被 Linux 集成重命名。

## 验收标准

必须分别验证：

1. 只使用机场配置时，原有机场节点仍能连接；
2. 只输入用户名、密码、服务器地址时，能生成并保存独立 CorpLink 身份；
3. Mihomo 日志出现 `corplink refreshed` 和 `WireGuard handshake completed`；
4. `SG-Node-Linux` 出现在 `/proxies` 和目标 proxy-group；
5. DoH 请求经隧道访问；
6. 通过 SG-Node-Linux 访问 `https://chatgpt.com/robots.txt` 返回 HTTP 200；
7. Windows 正式 `SG-Node` 同时在线且仍返回 HTTP 200；
8. 停止/重启 Bettbox 后 Cookie、密钥和 device identity 仍可恢复；
9. 授权失败、handshake 超时和 DNS 失败能在日志中区分。

## 实现顺序

1. 添加安全凭据存储和 `CorpLinkSettings`；
2. 添加设置页面，只显示三个用户输入项和启用状态；
3. 封装 `CorpLinkAuthService`；
4. 在 `patchRawConfig()` 中注入 SG 出站、DoH 和 proxy-group；
5. 将 Mihomo-SG 分支构建产物替换 Bettbox core；
6. 增加单元测试、配置快照测试和桌面端真实 ChatGPT 验收；
7. 更新构建脚本和发布说明。

## 构建与发布

GitHub Actions 的 Windows amd64 构建会自动从 `luantu/corplink-rs` 编译并放置
`corplink-rs.exe`。本地构建时，需要先在 `tools/corplink-rs/windows/x64/`（或
`arm64/`）放置对应架构的 helper，再执行：

```powershell
flutter pub get
dart run setup.dart --target windows --arch amd64
flutter build windows --release
dart run windows/packaging/exe/package_windows.dart --arch amd64
```

打包脚本会把 `corplink-rs.exe` 复制到 Bettbox 安装目录，与 `Bettbox.exe` 同级。
如果未找到该文件，机场功能仍可构建，但 SG 节点登录不会在空白系统上自动工作。
