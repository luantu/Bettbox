# Bettbox 飞连多节点实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 单次飞连账号登录后，让 INTL 与 `FUZHOU-NODE-1` 等 TCP 服务器在同一配置中同时以独立 WireGuard 隧道运行，并经模拟器和真机验证。

**Architecture:** 账号 Cookie 与 OTP 材料共享；节点选择、WireGuard 密钥、`/vpn/conn`、虚拟 IP 栈和恢复状态按服务器原名隔离。配置覆盖层创建服务器同名组与 `<name>-WG` 代理，保留隐藏 `SG-Node` 兼容组和旧 `SG-OpenAI` 规则。核心提供节点列表、状态、定向重连和定向重建接口，Flutter 页面与汇总磁贴调用这些接口。

**Tech Stack:** Dart/Flutter、Go/Mihomo-SG、Android VpnService、GitHub Actions、外置盘 Android arm64 AVD。

**Spec:** `docs/superpowers/specs/2026-09-29-bettbox-corplink-multi-node-design.md`

## Global Constraints

- 只进行一次账号登录；不因第二节点失败悄悄调用第二次密码登录。Cookie/OTP 可共享，WireGuard 密钥和 VPN 会话必须逐节点独立。
- 只选择上游 `protocol_mode=1` 的 TCP 服务器。代理组名必须是用户选中的服务器原名，实际代理名是 `<name>-WG`；旧 `SG-Node` 是隐藏兼容组，不是第二条隧道。
- 保留旧 `SG-OpenAI` 与自动 ChatGPT 规则；新服务器的分流只由覆写脚本注入。未授权或停用的已配置组指向 `REJECT`，不回退 `DIRECT`。
- 节点级故障不得通过全量 `applyProfile()` 暗中重建；节点级 IP 栈重建必须保持另一隧道和机场代理在线。
- 健康探针逐节点配置、使用 HTTPS，不能嵌入账号密码；未设置时只读握手，不用公网网站判定故障。私钥和探针 URL 不进入普通偏好设置或公开日志。
- 当前 Mac 没有 Flutter/Dart；Dart 红绿测试用功能分支上的 `gh workflow run android-sg-apk.yml --ref codex/corplink-multi-node` 观察 `Run Flutter unit tests` 步骤。Go 测试本机用 `nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1`。不得把未运行的测试写成通过。
- 模拟器只用 `/Volumes/ExtArchive/Android/` 下的 arm64 AVD，一次一个、优先 1 vCPU，观察高 CPU 时停止；真机安装保留现有应用数据。`main` 与已发布的 `v1.19.4-sg.1` 在验收前不变。

## Review Focus

- 同名或只差大小写的服务器与机场组冲突时，不覆盖机场配置；Task 3 的冲突测试覆盖。
- `/api/vpn/list` 暂不可用或 INTL 名称换别名时，旧安装继续可用且脚本组名不静默变化；Task 2、3 的迁移测试覆盖。
- 两节点同时请求 `/vpn/conn` 时，`vpn-token`、公钥、端点和隧道 IP 不串用；Task 2 的单次登录测试与 Task 4 的双实例控制面测试覆盖。
- 一个节点需要新 IP 栈，另一个仍有活跃连接时，不能关闭后者或重载全部 Profile；Task 5 的隔离测试覆盖。
- 空探针、单个站点被拦和短时网络抖动不得引发重连风暴；Task 6 的策略测试覆盖。

---

### Task 1: 控制面 TCP 服务器发现

**Files:** Modify `core/Clash.Meta/adapter/outbound/wireguard_corplink.go`, `core/Clash.Meta/adapter/outbound/wireguard_corplink_test.go`, `core/constant.go`, `core/action.go`, `core/hub.go`; Test `core/corplink_status_test.go`。

**Interfaces:** Produce `ListCorplinkVPNNodes(CorplinkOption) ([]CorplinkVPNNodeSummary, error)` with `Name` and `ProtocolMode`; core action `listCorplinkVpnNodes` accepts a JSON string carrying API URL, cookie-file path, device identity and optional physical control IP, and returns only names/modes. Reuse the existing protected control-plane dialer and CookieStore reader; do not introduce another login flow.

- [ ] **Step 1:** Add `TestCorplinkVPNNodeListOnlyTCPAndSanitized` with a fake `/api/vpn/list` returning two TCP and one UDP nodes. Assert two exact names in server order, no endpoint IP/Cookie in the returned JSON, and no `/api/login` request. Add a core action test that rejects malformed input without panicking.
- [ ] **Step 2:** Run `cd core/Clash.Meta && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 -count=1 -run TestCorplinkVPNNodeListOnlyTCPAndSanitized ./adapter/outbound`; expect failure because the list API is missing.
- [ ] **Step 3:** Extract the existing list-request path, implement `ListCorplinkVPNNodes` and its action handler with redacted numeric errors; leave `/vpn/ping` and `/vpn/conn` selection behavior unchanged.
- [ ] **Step 4:** Re-run the named outbound test and `cd core && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 ./...`; expect both exit 0, including malformed and unauthorized fixture cases.
- [ ] **Step 5:** Commit only Task 1 files with a message naming server discovery.

### Task 2: 节点选择、密钥与旧安装迁移

**Files:** Create `lib/services/corplink_sg_nodes.dart`, `test/corplink_sg_nodes_test.dart`; Modify `lib/services/corplink_sg.dart`, `lib/enum/enum.dart`, `lib/models/generated/core.g.dart`, `lib/clash/interface.dart`, `lib/clash/core.dart`。

**Interfaces:** Expose Task 1's core action as `ClashCore.listCorplinkVpnNodes(Map<String, dynamic> request)` and parse its name/mode records. Produce `CorplinkNodeSelection(serverName, enabled, healthUrl)`, `CorplinkNodeKeyPair(publicKey, privateKey)`, `loadCorplinkNodeSelections()`, `saveCorplinkNodeSelections(...)`, and `loadOrCreateCorplinkNodeKeyPair(settings, serverName, legacyAuth:)`. Factor the existing in-flight login lock into `CorplinkAuthCoordinator.ensure(accountSessionKey, login)` so simultaneous node initialization shares one login. SharedPreferences stores names/enabled only; secure storage holds key pairs and HTTPS probe URLs.

- [ ] **Step 1:** Write tests asserting that two server names receive different persistent keys under one account, restart returns the same key for each, another account/upstream cannot reuse them, invalid probe URLs are rejected, and an old INTL key migrates without re-login. Assert concurrent node initialization invokes the shared helper at most once, and a missing server list leaves the old `SG-Node` configuration untouched.
- [ ] **Step 2:** Push the test-only commit to `codex/corplink-multi-node`; dispatch the existing Android SG workflow on that ref and confirm `Run Flutter unit tests` fails for the new missing model/API, not for toolchain setup.
- [ ] **Step 3:** Implement the Dart list-action bridge, selection persistence, secure per-node keys and one-time legacy migration. Keep the Rust helper on the existing single-login path; its old `vpn_server_name` must not force a second login or a second device identity.
- [ ] **Step 4:** Dispatch the workflow again; expect Task 2 Dart tests green and record the run ID. Commit only Task 2 code/tests.

### Task 3: 幂等多节点配置覆盖层

**Files:** Create `lib/services/corplink_sg_overlay.dart`, `test/corplink_sg_overlay_test.dart`; Modify `lib/services/corplink_sg.dart`, `lib/state.dart`, `test/corplink_sg_settings_test.dart`。

**Interfaces:** Produce `mergeCorplinkNodeOverlay(Map<String, dynamic> rawConfig, {required CorplinkSgSettings settings, required List<CorplinkNodeSelection> selections, required Map<String, CorplinkNodeKeyPair> keyPairs, Map<String, dynamic>? auth, String? cookiePath, String? controlIP, Set<String> suppressedNames = const {}})`. `applyCorplinkSgNode` loads these inputs and applies the overlay before and after the existing JavaScript evaluation. Leave `corplinkOpenAiRules` and `SG-OpenAI` available for legacy routing.

- [ ] **Step 1:** Add tests that call the overlay twice and assert exactly one `FUZHOU-NODE-1-WG` proxy, one `FUZHOU-NODE-1` group, one hidden `SG-Node` alias, unchanged airport nodes/rules, and preserved script `RULE-SET`. Add missing-auth/disabled-group `REJECT`, duplicate-name collision, and server rename tests.
- [ ] **Step 2:** Run the new Flutter test in CI on a test-only commit; expect assertion failures against the single-node overlay.
- [ ] **Step 3:** Implement node-level overlay and first-upgrade atomic switch from old `SG-Node` proxy to hidden alias; do not strip script-created rules or rewrite downloaded YAML. Validate collisions before mutating the source map.
- [ ] **Step 4:** Re-run Flutter tests in CI; expect both new and existing `corplink_sg_settings_test.dart` green. Commit Task 3 files.

### Task 4: 多节点状态与定向重连

**Files:** Modify `core/Clash.Meta/adapter/outbound/wireguard.go`, `core/Clash.Meta/adapter/outbound/wireguard_corplink_test.go`, `core/hub.go`, `core/action.go`, `core/constant.go`, `core/corplink_status_test.go`; Modify `lib/enum/enum.dart`, `lib/models/generated/core.g.dart`, `lib/clash/interface.dart`, `lib/clash/core.dart`, `lib/clash/lib.dart`。

**Interfaces:** Produce core action `getCorplinkNodeStatuses` returning a list of objects each carrying `serverName`, and `reconnectCorplinkNode(serverName)` acting on one adapter. Keep `getCorplinkSgStatus`/`reconnectCorplinkTunnel` as temporary INTL-compatible methods. Dart `ClashCore` exposes the two new methods with the same action names.

- [ ] **Step 1:** Add Go tests with two fake CorpLink adapters. Assert both statuses retain distinct names/IPs/endpoints; reconnecting one increments only its counter; unknown name returns false. Add `TestCorplinkTwoNodesUseSeparateTokensAndKeys` with a fake list/ping/conn server: two public keys must receive separate node endpoints, `vpn-token` values and tunnel IPs; one node error must leave the other session usable.
- [ ] **Step 2:** Run `cd core/Clash.Meta && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 -count=1 -run '^TestCorplinkTwoNodesUseSeparateTokensAndKeys$' ./adapter/outbound` and `cd core && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 -count=1 -run 'TestCorplink.*(Status|Reconnect)' ./...`; expect failures at the absent multi-node API and independent-session assertions.
- [ ] **Step 3:** Implement enumeration and named reconnect under the current core lock, then add Flutter action enum/map/interface bridges without changing Android `VpnService` identity.
- [ ] **Step 4:** Run the named outbound two-node test, `cd core && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 ./...`, and dispatch CI for Dart bridge tests; expect exit 0. Commit Task 4 files.

### Task 5: 只重建故障节点的虚拟 IP 栈

**Files:** Modify `core/Clash.Meta/adapter/outbound/wireguard.go`, `core/Clash.Meta/adapter/outbound/wireguard_corplink_lifecycle_test.go`, `core/hub.go`, `core/action.go`, `core/constant.go`; update the corresponding Dart bridge in `lib/clash/interface.dart`, `lib/clash/core.dart`, `lib/enum/enum.dart`, `lib/models/generated/core.g.dart`。

**Interfaces:** Produce `(*WireGuard).RebuildCorplink(ctx context.Context) error` and core action `rebuildCorplinkNode(serverName)`. Rebuild changes only that adapter's device/IP stack; the second adapter stays reachable. The action must serialize with `Close`, reconnect and concurrent dials. No fallback to global `setupConfig` or Dart `applyProfile`.

- [ ] **Step 1:** Add a failing lifecycle test with two adapters: make node A receive a new IP, assert A's old device closes and new stack uses that IP, while B's device, TCP readiness and active request remain unchanged. Add a concurrent rebuild/close test that completes without panic or leaking the old device.
- [ ] **Step 2:** Run the named `wireguard_corplink_lifecycle_test.go` tests with `go test -p 1 -count=1 ./adapter/outbound`; expect failure before implementation.
- [ ] **Step 3:** Extract device-stack creation from `NewWireGuard`, add an adapter-local guarded rebuild using the existing key and new `/vpn/conn` parameters, and expose the named core action. A failed rebuild keeps only node A unhealthy and retryable.
- [ ] **Step 4:** Re-run outbound lifecycle tests and `cd core && nice -n 15 env GOMAXPROCS=2 GOFLAGS=-p=1 go test -p 1 ./...`; expect exit 0. Commit Task 5 files. If the core cannot safely rebuild one adapter, stop here and revise the design instead of shipping full Profile reload as a substitute.

### Task 6: 节点级健康恢复与界面

**Files:** Modify `lib/services/corplink_sg_status.dart`, `lib/services/corplink_sg_runtime.dart`, `lib/services/corplink_sg_recovery.dart`, `lib/views/corplink_sg.dart`, `lib/views/dashboard/widgets/sg_node_status.dart`, `lib/controller.dart`, `lib/main.dart`; Test `test/corplink_sg_settings_test.dart`, `test/sg_dashboard_tile_test.dart` and `test/sg_dashboard_alignment_test.dart`。

**Interfaces:** Produce `readCorplinkNodeStatuses()`, `refreshCorplinkNodeStatus(serverName)`, and per-name `SgRecoveryPolicy` state. The settings page uses Task 1 discovery and Task 2 selections; the existing home tile shows `ready/total` and refreshes unhealthy nodes only.

- [ ] **Step 1:** Write tests for “2/2 已连接”、单节点异常、空探针只看握手、单一被拦站点不重连、两节点各有独立冷却、网络事件后逐节点恢复，以及一个节点错误不触发全量 `applyProfile`。
- [ ] **Step 2:** Push tests and dispatch CI; expect these new Dart assertions to fail while the page/runtime still uses the single `SG-Node` 状态。
- [ ] **Step 3:** 实现列表多选与手填入口、每节点探针和操作、汇总磁贴及后台健康循环。重建分支只调用 Task 5 的命名动作；`lib/main.dart` 的物理切网回调读取所有节点状态，不以任一节点代表全体。
- [ ] **Step 4:** Dispatch CI and inspect Flutter tests, Go outbound tests and APK build steps; expect all green. Commit Task 6 files.

### Task 7: CI APK 与外置盘模拟器验证

**Files:** Create `docs/03-Bettbox飞连多节点验证用例与结果.md`; keep raw/sanitized test material under `work/corplink-multi-node/`; no production-code change unless a failed case proves a defect.

**Interfaces:** Consume the CI artifact built from the feature branch. Produce an APK SHA-256 and a case-by-case emulator record with actual results, not a blank checklist.

- [ ] **Step 1:** Dispatch `.github/workflows/android-sg-apk.yml` on `codex/corplink-multi-node`; verify Flutter tests, Go tests, Rust helper, `libmeta.so` and arm64 APK all succeed. Download the artifact to `outputs/` and check package ID, signature continuity and SHA-256.
- [ ] **Step 2:** Start only `/Volumes/ExtArchive/Android/.android/avd/BettboxSGApi35Test2.avd` using `ANDROID_SDK_ROOT=/Volumes/ExtArchive/Android/sdk`, `ANDROID_AVD_HOME=/Volumes/ExtArchive/Android/.android/avd`, the external SDK's `emulator` binary, `-cores 1 -memory 1536 -gpu off -no-audio`, and a visible window. Monitor CPU and stop the AVD when done. Preserve any pre-existing AVD data before a conflicting signature install.
- [ ] **Step 3:** Install the APK and run cases for list selection, manual node, legacy alias, empty/airport Profile, script RuleSet, REJECT, status and per-node refresh. If real server login is required, present the visible emulator for the user to enter credentials; do not read or log them. A mock service may cover deterministic errors, but must not count as a real handshake.
- [ ] **Step 4:** Write each executed case's steps, expected/actual result, timestamp, build SHA and sanitized evidence to the verification document. Fix failed cases and repeat CI/emulator tests until their final result is explicit. Commit the document after emulator read-back.

### Task 8: 真机闭环、补丁记录与收尾

**Files:** Update `docs/03-Bettbox飞连多节点验证用例与结果.md`, `localpatch.md`, and `work/corplink-multi-node/status.md`; code changes only for diagnosed failures.

**Interfaces:** Consume the exact emulator-checked APK; produce phone evidence for both live tunnels and a complete verification record. Do not update `main` or publish another Release without the user's separate authorization.

- [ ] **Step 1:** When the phone is available, confirm ADB identity and current SG package/signature; `adb install -r` the matching test-signed APK without clearing data. If approval, credential input or a device connection is missing, request it instead of bypassing authentication.
- [ ] **Step 2:** Verify a single login, two simultaneous WG handshakes and separate tunnel IP/status; send controlled traffic through both server-name groups to their configured, authorized probe targets, and confirm the request history chains. If no legitimate target exists for `FUZHOU-NODE-1`, ask the user for one rather than using a guessed internal URL. Keep old `SG-OpenAI`/ChatGPT and an ordinary airport request working.
- [ ] **Step 3:** Interrupt only one node and measure unaffected-node requests while refreshing/rebuilding the failed node. Repeat Wi-Fi→蜂窝→Wi-Fi with both nodes, record recovery time and IP changes, then restore the phone's original connectivity and remove ADB forwards.
- [ ] **Step 4:** Verify a `RULE-SET` targeting `FUZHOU-NODE-1` actually matches in rule mode using a reversible copy of the user's script; preserve the original script and restore the original mode. Fill the verification document's phone results, note any unverified long-term behavior, update `localpatch.md` without removing its existing patch history, and run secret/whitespace scans.
- [ ] **Step 5:** Commit only related code/docs, inspect the branch diff against `9a5736f`, and perform a final independent read-only review if available. Stop only when every required simulator and phone case is evidenced; otherwise keep the active goal and work the failure.
