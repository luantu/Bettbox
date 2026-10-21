# Bettbox SG 合并上游 1.19.6 执行计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留完整 Git 历史的前提下，把 `upstream/main@7006a026` 合并进 Bettbox SG 已验证基线 `10832ae1`，产出通过自动测试、GitHub Actions 和外置磁盘模拟器验证的 Android arm64 APK。

**Architecture:** 使用 `git merge --no-ff` 生成双亲 merge commit，先把上游 1.19.6 的通用结构与 SG 不变量合成一个可追溯结果，再以独立修复提交处理编译和行为回归。Android 生命周期、Flutter 配置层和 Mihomo/CorpLink 核心分开验证，最终统一进入 CI 与模拟器。

**Tech Stack:** Flutter/Dart、Kotlin/Android VpnService、Go/Mihomo、Rust CorpLink helper、GitHub Actions、Android arm64 模拟器。

**Spec:** `docs/superpowers/specs/2026-10-21-bettbox-corplink-upstream-1.19.6-merge-design.md`

## Global Constraints

- 必须保留 `10832ae1` 和 `7006a026` 两侧全部祖先；禁止 rebase、squash 和重写已有提交。
- 合并命令必须使用 `git merge --no-ff upstream/main`，最终 merge commit 有两个父提交。
- 已验证分支 `codex/corplink-native-auto-recovery` 不修改；工作分支固定为 `codex/corplink-upstream-1.19.6`。
- Android 包名保持 `com.appshub.bettbox.sg`，签名、橙色图标、隐藏 PRE 标识和 arm64 三套原生库保持不变。
- 上游通用结构优先；CorpLink 多节点、内网 DNS、双开、脚本覆写、网络恢复、智能启停和用户停止意图不得删除或降级。
- 账号、密码、Cookie、OTP、设备身份、私钥和真实内部 DNS 不进入仓库、日志、计划或验证文档。
- 真机未接入前只能交付“APK 构建和模拟器验证完成”，不得声称企业 VPN 真机闭环。

## Review Focus

- 旧配置从 1.19.4 SG 升级到上游 1.19.6 模型时，Profile、脚本、SG 节点选择和用户停止意图不得丢失。
- 上游 Android 服务保活与 SG native recovery 同时触发时，不能重复建 TUN、乱序 START/STOP 或绕过用户手动停止。
- 上游 WireGuard、DNS 或 outbound 接口变化时，两个 CorpLink 节点的会话、密钥、内网 DNS 和恢复状态不能串用。
- 空配置、仅机场配置和 SG+机场混合配置都必须能启动；未勾选 SG 节点时不得生成占位代理组。
- 覆盖安装、应用双开、Wi-Fi／蜂窝切换和局域网排除网段不能因上游默认值变化而回归。

---

### Task 1: 生成可追溯的上游 merge commit

**Files:**
- Modify: 合并产生冲突的全部跟踪文件；以 `git ls-files -u` 为唯一冲突清单。
- Preserve: `docs/superpowers/specs/2026-10-21-bettbox-corplink-upstream-1.19.6-merge-design.md`
- Test: Git 拓扑、冲突索引和冲突标记检查。

**Interfaces:**
- Consumes: SG 基线 `10832ae1d451163d500c184491141c100165e796`；上游 `7006a0263510`；共同基线 `31893466`。
- Produces: 一个双亲 merge commit，第一父提交是当前 SG 历史，第二父提交是 `7006a026`；后续任务只在该 merge commit 之上追加修复。

- [ ] **Step 1: 记录合并前拓扑与工作树状态**

Run: `git status --short && git rev-parse HEAD upstream/main && git merge-base HEAD upstream/main && git rev-list --left-right --count HEAD...upstream/main`

Expected: 工作树为空；HEAD 为设计提交的后继，历史包含 `10832ae1`；上游为 `7006a026`；分叉计数保持本地 236 左右、上游 79。

- [ ] **Step 2: 发起保留历史的合并**

Run: `git merge --no-ff --no-commit upstream/main`

Expected: 命令报告内容冲突并保留 `MERGE_HEAD=7006a026...`；不得使用 `-X ours`、`-X theirs` 或整仓策略覆盖。

- [ ] **Step 3: 解决构建、依赖和生成文件冲突**

以 1.19.6 的 Flutter、Gradle、插件与模型结构为主，保留 SG 测试签名、CorpLink helper、Android arm64 工作流和专项测试。源模型先确定，生成文件与锁文件随后保持一致。

Expected: `pubspec.yaml`、Gradle、workflow、模型源和生成物之间不存在版本或字段不一致。

- [ ] **Step 4: 解决 Android 生命周期与 Flutter 控制层冲突**

合并 `GlobalState.kt`、`ServicePlugin.kt`、`VpnPlugin.kt`、`BettboxVpnService.kt`、`main.dart`、`controller.dart` 和 `state.dart`。保留 upstream service lifecycle，同时保留 SG recovery policy、三态用户意图、双 isolate runtime 通知、智能启停和 LinkProperties 指纹。

Expected: 所有自动入口继续检查用户意图；手动 STOP 的代次可以取消旧 START；故障 STOP 不取消恢复看门狗。

- [ ] **Step 5: 解决 Mihomo、WireGuard、DNS 与 SG 配置冲突**

逐文件合并 `core/`、`core/Clash.Meta/adapter/outbound/wireguard.go`、DNS、配置和 Action 接口。不得整文件选择一侧。每个 SG 扩展接口都要确认上游调用方与关闭顺序。

Expected: 两节点独立状态、TCP Bind、每节点 DNS、Android protect 和节点级恢复接口仍存在，且使用上游 1.19.6 的公共结构。

- [ ] **Step 6: 清理冲突索引与标记**

Run: `git ls-files -u && rg -n '^(<<<<<<<|=======|>>>>>>>)' --glob '!docs/**' . && git diff --check`

Expected: `git ls-files -u` 无输出；`rg` 无冲突标记；`git diff --check` 退出 0。

- [ ] **Step 7: 提交 merge commit 并验证双亲**

Run: `git add -A && git commit -m "merge: sync upstream 1.19.6 into Bettbox SG" && git show -s --format='%H%n%P%n%s' HEAD`

Expected: 新提交有两个父提交；第二父提交为 `7006a026...`；历史中仍可找到 `10832ae1`。

### Task 2: 恢复依赖与 Flutter 配置模型一致性

**Files:**
- Modify: `pubspec.yaml`、`pubspec.lock`、`analysis_options.yaml`、Flutter/Gradle 配置、`lib/models/**`、国际化生成文件。
- Test: `flutter pub get`、Flutter 全套测试、配置迁移专项测试。

**Interfaces:**
- Consumes: Task 1 的 merge commit 与上游 1.19.6 模型结构。
- Produces: 可解析依赖、可生成或自洽的模型/国际化文件、保留 SG 字段的配置层。

- [ ] **Step 1: 运行依赖解析和 Flutter 测试，保存真实失败列表**

Run: 在外置磁盘 Flutter SDK 可用时执行 `flutter pub get && flutter test`；本机无 SDK 时推送当前分支并以 `Android SG APK` workflow 的 Flutter test step 为证据。

Expected: 首轮允许失败；失败必须来自真实编译、模型字段或行为断言，不能用手工猜测替代。

- [ ] **Step 2: 为配置迁移和 SG 字段写回归测试**

补充或调整测试，覆盖旧 1.19.4 配置读取、SG 节点选择、健康探针、TUN 私网排除、首页磁贴和用户运行意图。先运行并确认合并后的缺口能使测试失败。

Expected: 新测试在修复前因缺字段、错误默认值或迁移丢失而失败。

- [ ] **Step 3: 以 1.19.6 模型结构接回 SG 字段**

只修改测试暴露的模型、序列化、Provider 和设置页面接线；不恢复上游已删除的旧框架。

Expected: 旧配置可读，新配置可保存，未配置 SG 的普通用户没有额外对象。

- [ ] **Step 4: 运行 Flutter 全套测试**

Run: `flutter test`

Expected: 全部测试通过，0 failure；如由 Actions 执行，记录 run id 和完整通过计数。

- [ ] **Step 5: 提交 Flutter/配置修复**

Run: `git add pubspec.yaml pubspec.lock analysis_options.yaml lib test arb && git commit -m "fix: reconcile upstream Flutter models with SG config"`

Expected: 提交只包含本任务相关文件。

### Task 3: 合并 Android 1.19.6 生命周期与 SG 恢复状态机

**Files:**
- Modify: `android/app/src/main/kotlin/com/appshub/bettbox/**`
- Modify: `lib/main.dart`、`lib/controller.dart`、`lib/state.dart`、`lib/plugins/service.dart`
- Test: `NativeRecoveryPolicyTest`、`UnderlyingNetworkPathPolicyTest`、`SmartStopSourceRegressionTest`、`VpnRunIntentSourceRegressionTest`、应用双开和 LAN route tests。

**Interfaces:**
- Consumes: Task 2 的配置模型；现有 `NativeRecoveryPolicy`、`VpnRunIntentStore` 和 `UnderlyingNetworkPathPolicy` 接口。
- Produces: 使用上游 service lifecycle、仍满足 SG 自动恢复与用户 STOP 语义的 Android 实现。

- [ ] **Step 1: 运行 Android 纯策略测试并确认失败点**

Run: 使用 OpenJDK 17 编译运行 workflow 中五组 Java 测试，包括 smart-stop 与 user-intent 源码门禁。

Expected: 首轮失败应精确指向上游重构后的接口或接线变化；若全部通过，记录结果并跳到 Kotlin 编译反馈。

- [ ] **Step 2: 增加上游生命周期冲突的回归用例**

测试至少覆盖：service 重绑、START/STOP 顺序、package replace `quick-auto`、手动停止持久化、smart stop 不调用 WireGuard 反射、双开 UID 和 TUN 私网排除。

Expected: 未满足的不变量先红灯；已有用例已覆盖时不重复造同义测试。

- [ ] **Step 3: 修复 Android 与 Dart 接线**

采用上游前台服务、通知和 package 查询改动，重新接入 SG recovery watchdog、控制面旁路、用户意图和状态通知。避免在低层故障路径写用户意图。

Expected: 单一用户动作只有一个 run-intent 代次；自动失败保留恢复资格；手动 STOP 后所有自动入口保持关闭。

- [ ] **Step 4: 运行策略测试和 Android 编译门禁**

Run: 本地 Java 测试全套；随后由 GitHub Actions 执行 Kotlin/Android 编译。

Expected: Java 0 failure；Kotlin 编译没有 unresolved reference、签名变化或 lifecycle API 错误。

- [ ] **Step 5: 提交生命周期修复**

Run: `git add android/app/src/main/kotlin lib/main.dart lib/controller.dart lib/state.dart lib/plugins/service.dart android/app/src/test && git commit -m "fix(android): reconcile upstream lifecycle with SG recovery"`

Expected: 提交不包含 Mihomo core 或无关 UI 重排。

### Task 4: 合并 CorpLink 多节点、脚本与界面

**Files:**
- Modify: `lib/services/corplink_sg*.dart`、`lib/views/corplink_sg.dart`、`lib/controller.dart`、`lib/pages/home.dart`、`lib/views/proxies/**`、脚本覆写相关文件、资源与国际化文件。
- Test: `corplink_*_test.dart`、`sg_dashboard_*_test.dart`、`app_env_banner_test.dart`、脚本与 rule-provider 测试。

**Interfaces:**
- Consumes: Task 2 配置模型、Task 3 Android runtime 状态。
- Produces: 适配上游 UI 结构的 SG 管理页、磁贴、配置覆盖层和脚本注入流程。

- [ ] **Step 1: 运行 SG Flutter 专项测试并记录红灯**

Run: `flutter test test/corplink_* test/sg_dashboard_* test/app_env_banner_test.dart`

Expected: 冲突造成的组件、模型或配置差异必须有可重复失败；无失败则保留通过证据。

- [ ] **Step 2: 处理上游 UI 与脚本结构变化**

把 SG 页面和磁贴接入上游导航、主题、脚本存储与 outbound 视图；保持只有勾选节点才生成对象，`rule-provider` 注入和失效引用失败关闭不变。

Expected: 空配置无 SG 组；机场配置不被覆盖；INTL 与福州组名、探针和脚本目标保持稳定。

- [ ] **Step 3: 核对独立 APK 身份与图标**

检查 `applicationId`、应用名、资源图标、`SHOW_APP_ENV_BANNER=false` 和测试签名配置。

Expected: 安装包与原 Bettbox 不冲突，显示 SG 橙色图标，不显示 PRE。

- [ ] **Step 4: 运行 Flutter 全套测试并提交**

Run: `flutter test`

Expected: 0 failure。

Run: `git add lib assets android/app/src/main/res arb test && git commit -m "fix: restore SG UI and overlay on upstream 1.19.6"`

Expected: 提交只包含界面、覆盖层、资源和相应测试。

### Task 5: 合并 Mihomo、WireGuard、CorpLink 与节点 DNS

**Files:**
- Modify: `core/**`
- Modify: `core/Clash.Meta/adapter/outbound/wireguard.go` 及上游变更涉及的 config/dns/executor 文件。
- Test: `core` 全套 Go tests、`core/Clash.Meta` outbound/config/dns/executor tests。

**Interfaces:**
- Consumes: Task 1 合并后的上游 Mihomo API；现有 CorpLink action、status 和 Android JNI exports。
- Produces: 可构建的 Mihomo-SG 原生库，保留 TCP CorpLink 多节点、每节点 DNS、状态和恢复接口。

- [ ] **Step 1: 运行 Go 测试并保存失败包**

Run: `cd core/Clash.Meta && go test -p 1 ./adapter/outbound/... ./config ./dns ./hub/executor`

Run: `cd core && go test -p 1 ./...`

Expected: 首轮允许因上游 API 变化失败；记录具体包、符号和断言。

- [ ] **Step 2: 为发生接口变化的 SG 行为补红灯测试**

覆盖 TCP transport admission、每节点状态隔离、DNS 出站绑定、网络重连、FD 所有权和两节点并存。已有测试能稳定失败时直接使用，不复制测试。

Expected: 修复前至少一个相关测试失败，错误与冲突行为一致。

- [ ] **Step 3: 按上游公共接口重接 SG 扩展**

调整类型、生命周期锁、outbound 构造、DNS client 和 action 注册。禁止恢复已被上游替换的旧内部结构，禁止用反射访问 WireGuard 私有字段。

Expected: SG 接口调用方与上游 1.19.6 类型一致，节点关闭和重建不串状态。

- [ ] **Step 4: 运行 Go 全套测试**

Run: `cd core/Clash.Meta && go test -p 1 ./adapter/outbound/... ./config ./dns ./hub/executor && cd .. && go test -p 1 ./...`

Expected: 0 failure、0 panic、无数据竞争相关报错。

- [ ] **Step 5: 提交 core 修复**

Run: `git add core && git commit -m "fix(core): port CorpLink SG to upstream 1.19.6"`

Expected: 提交仅含 core 和其测试。

### Task 6: GitHub Actions 构建与 APK 静态验收

**Files:**
- Modify: `.github/workflows/android-sg-apk.yml`，仅在上游工具链确有变化时修改。
- Output: `work/上游合并-1.19.6/验证/` 中的 CI 日志摘要和下载候选。

**Interfaces:**
- Consumes: Tasks 1–5 的提交。
- Produces: 与 HEAD 精确对应的 GitHub Actions success run 和 Android arm64 APK。

- [ ] **Step 1: 推送合并分支并触发 workflow_dispatch**

Run: `git push -u origin codex/corplink-upstream-1.19.6 && gh workflow run android-sg-apk.yml --repo luantu/Bettbox --ref codex/corplink-upstream-1.19.6`

Expected: 远端 SHA 与本地 HEAD 一致；只保留最新有效 run。

- [ ] **Step 2: 监控并修复 CI 失败**

每次只根据真实失败日志修复；新的修复提交推送后取消过期 run。Flutter、Java、Go、Rust helper、Mihomo-SG 和 APK 步骤均需成功。

Expected: 最终 run conclusion 为 `success`。

- [ ] **Step 3: 下载并核对 APK**

检查 SHA-256、`aapt dump badging`、`apksigner verify` 和三个 arm64 库。

Expected: 包名 `com.appshub.bettbox.sg`；versionName 1.19.6；v2签名证书与已验证 SG 包一致；`libcore.so`、`libmeta.so`、`libcorplink-rs-login.so` 均存在。

- [ ] **Step 4: 提交构建流程修订（如有）**

Run: `git add .github/workflows && git commit -m "ci: build merged SG app on upstream 1.19.6"`

Expected: 没有 CI 修订时跳过，不创建空提交。

### Task 7: 外置磁盘模拟器与真机接入前交付

**Files:**
- Modify: `docs/03-Bettbox飞连多节点验证用例与结果.md`
- Modify: `localpatch.md`
- Update outside checkout: `/Volumes/ExtArchive/OpenSource/Bettbox/bettbox/work/corplink-multi-node/status.md`
- Output: `outputs/android-sg-upstream-1.19.6-2026-10-21/`

**Interfaces:**
- Consumes: Task 6 APK。
- Produces: 模拟器验证记录、正式候选 APK、真机接入所需的明确测试清单。

- [ ] **Step 1: 在外置磁盘模拟器安装候选 APK**

一次只启动一个 AVD，限制 CPU；保留数据覆盖安装有账号的 AVD，空配置使用独立 AVD。模拟器不可用时先修复，不用空白假结果替代。

Expected: APK 安装成功、应用全屏正常、包名独立、图标和版本正确。

- [ ] **Step 2: 执行不依赖真实企业网络的用例**

验证空配置、机场 Profile、脚本覆写、SG 页面、磁贴、手动停止不自启、覆盖安装三态、TUN 启停和双开包范围。

Expected: 每项有通过／失败／未验证状态；真实授权与内网 DNS明确标“待真机”。

- [ ] **Step 3: 更新验证文档和补丁记录**

记录合并 commit、CI run、APK hash、模拟器环境、实际结果、已知限制和真机测试清单。文档不含凭据和内部敏感值。

Expected: `localpatch.md` 能说明上游 1.19.6 合并和保留的 SG 功能；验证文档不把模拟器编译结果写成真机闭环。

- [ ] **Step 4: 提升正式 APK 并清理过程文件**

把唯一有效候选复制到 `outputs/android-sg-upstream-1.19.6-2026-10-21/`；失败 APK、重复下载和临时截图留在过程区或删除，不能混入 outputs。

Expected: 正式目录只有可追溯候选与必要说明；过程文件处置已记录。

- [ ] **Step 5: 进行整分支独立代码复核**

复核范围从 merge 前基线到最终 HEAD，重点检查 Review Focus 五类风险。Critical/Important 必须修复并有测试；Minor 单独列出，不夹带无关重构。

Expected: 复核结论 Ready，或明确列出尚未关闭的阻断。

- [ ] **Step 6: 通知用户接入真机**

提供构建页、artifact 链接、本地 APK 路径、模拟器结果和待执行真机用例。此处暂停，不自动进入主分支或发布 Release。

Expected: 用户接入真机后再执行双节点、内网 DNS、ChatGPT、Wi-Fi／蜂窝、授权旁路和稳态验收。

## 本地引用关系

- [[../specs/2026-10-21-bettbox-corplink-upstream-1.19.6-merge-design]]
- [[../specs/2026-09-29-bettbox-corplink-multi-node-design]]
- [[../../../localpatch|Bettbox SG 本地补丁记录]]
