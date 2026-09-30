import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_runtime.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'corplink_management_panel.dart';

class CorplinkSgView extends StatefulWidget {
  const CorplinkSgView({super.key});

  @override
  State<CorplinkSgView> createState() => _CorplinkSgViewState();
}

class _CorplinkSgViewState extends State<CorplinkSgView> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _server = TextEditingController();
  final _manualServerName = TextEditingController();
  List<CorplinkNodeSelection> _nodes = const [];
  List<CorplinkNodeSelection> _appliedNodes = const [];
  List<SgCoreStatus> _nodeStatuses = const [];
  CorplinkSgSettings? _appliedSettings;
  DateTime? _lastStateReadAt;
  bool _loading = true;
  bool _nodeSelectionSaved = false;
  List<String> _discoveredNames = const [];
  final Map<String, String> _lastNodeIPs = {};
  final Map<String, int> _nodeIPChanges = {};
  final Map<String, CorplinkNodeProbeObservation> _nodeProbeResults = {};
  bool _enabled = false;
  bool _routeOpenAi = true;
  bool _showPassword = false;
  bool _busy = false;
  String _status = '正在读取飞连设置…';
  String _liveStatus = '正在读取隧道状态…';
  String _dataPlaneStatus = '尚未检测 ChatGPT 访问';
  SgConnectionPhase _livePhase = SgConnectionPhase.missing;
  String? _lastTunnelIp;
  int _tunnelIpChanges = 0;
  Timer? _statusTimer;
  bool _statusReadInFlight = false;

  @override
  void initState() {
    super.initState();
    _username.addListener(_draftChanged);
    _password.addListener(_draftChanged);
    _server.addListener(_draftChanged);
    _load();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_appliedSettings?.enabled == true && !_busy && !_statusReadInFlight) {
        unawaited(_refreshLiveStatus());
      }
    });
  }

  Future<void> _load() async {
    final settings = await CorplinkSgSettings.load();
    final auth = await loadCorplinkConfig();
    final selectedNodes = await loadCorplinkNodeSelections();
    if (!mounted) return;
    setState(() {
      _username.text = settings.username;
      _password.text = settings.password;
      _server.text = settings.server;
      _enabled = settings.enabled;
      _routeOpenAi = settings.routeOpenAi;
      _nodeSelectionSaved = selectedNodes != null;
      if (selectedNodes != null) _nodes = selectedNodes;
      _appliedSettings = settings;
      _appliedNodes = List.unmodifiable(_nodes);
      _loading = false;
      _status = !settings.enabled
          ? ''
          : corplinkAuthMatchesSettings(auth, settings)
              ? ''
              : '等待授权；当前不生成飞连组或自动 ChatGPT 规则';
    });
    if (settings.enabled) unawaited(_refreshLiveStatus());
  }

  Future<SgCoreStatus> _readStatus() => readCorplinkSgStatus();

  Future<void> _refreshLiveStatus({bool recover = false}) async {
    if (_appliedSettings?.enabled != true) {
      if (mounted) setState(() => _liveStatus = '飞连未启用');
      return;
    }
    _statusReadInFlight = true;
    try {
      if (_nodeSelectionSaved) {
        final selected = _appliedNodes.where((node) => node.enabled).toList();
        final observed = <String, bool>{};
        final statuses = recover
            ? await Future.wait([
                for (final node in selected)
                  refreshCorplinkNodeStatus(
                    node.serverName,
                    healthUrl: effectiveCorplinkNodeProbeUrl(node),
                    onProbe: (success) => observed[node.serverName] = success,
                  ),
              ])
            : await readCorplinkNodeStatuses();
        if (!mounted) return;
        if (recover) {
          for (final node in selected) {
            final success = observed[node.serverName];
            if (success == null) {
              _nodeProbeResults.remove(node.serverName);
            } else {
              _nodeProbeResults[node.serverName] = CorplinkNodeProbeObservation(
                success: success,
                checkedAt: DateTime.now(),
              );
            }
          }
        }
        final byName = {for (final status in statuses) status.serverName: status};
        final summary = summarizeCorplinkNodes(
          statuses,
          selected.map((node) => node.serverName),
        );
        final lines = <String>[
          globalState.isStart ? 'Android VPN 已启动' : 'Android VPN 未启动',
          summary.label,
        ];
        for (final node in selected) {
          final status = byName[node.serverName];
          final phase = switch (status?.phase) {
            SgConnectionPhase.ready => '已连接',
            SgConnectionPhase.waitingForTraffic => '等待握手',
            SgConnectionPhase.connecting => '连接中',
            SgConnectionPhase.needsRebuild => '需重建',
            SgConnectionPhase.missing || null => '未创建',
          };
          if (status != null && status.tunnelIp.isNotEmpty) {
            final previous = _lastNodeIPs[node.serverName];
            if (previous != null && previous != status.tunnelIp) {
              _nodeIPChanges[node.serverName] =
                  (_nodeIPChanges[node.serverName] ?? 0) + 1;
            }
            _lastNodeIPs[node.serverName] = status.tunnelIp;
          }
          lines.add('${node.serverName}：$phase'
              '${status?.tunnelIp.isNotEmpty == true ? ' · ${status!.tunnelIp}' : ''}'
              ' · IP 变化 ${_nodeIPChanges[node.serverName] ?? 0} 次');
          if (status != null && status.endpoint.isNotEmpty) {
            lines.add('  上游端点：${status.endpoint}');
          }
          if (status != null && status.routesPresent) {
            lines.add('  下发分流路由：${status.routeSplit.isEmpty ? '空列表' : status.routeSplit.join('、')}');
            lines.add('  全隧道路由：${status.routeFull.length} 条（不自动用于分流）');
            if (status.routeInvalid > 0) {
              lines.add('  路由字段中 ${status.routeInvalid} 条无效，未纳入列表');
            }
          } else {
            lines.add('  下发路由：尚未取得');
          }
          if (effectiveCorplinkNodeProbeUrl(node).isNotEmpty) {
            final observation = _nodeProbeResults[node.serverName];
            final label = isIntlCorplinkServerName(node.serverName)
                ? 'ChatGPT HTTPS'
                : '内网 HTTPS';
            final checkedAt = observation?.checkedAt;
            final time = checkedAt == null
                ? ''
                : ' · ${checkedAt.hour.toString().padLeft(2, '0')}:'
                  '${checkedAt.minute.toString().padLeft(2, '0')}:'
                  '${checkedAt.second.toString().padLeft(2, '0')}';
            lines.add('  上次$label 探针：'
                '${observation == null ? '未检测' : observation.success ? '有响应' : '失败'}$time');
          }
        }
        final now = DateTime.now();
        lines.add('更新于 ${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}:'
            '${now.second.toString().padLeft(2, '0')}');
        setState(() {
          _nodeStatuses = List.unmodifiable(statuses);
          _lastStateReadAt = now;
          _livePhase = summary.total > 0 && summary.ready == summary.total
              ? SgConnectionPhase.ready
              : SgConnectionPhase.connecting;
          _liveStatus = lines.join('\n');
          _dataPlaneStatus = '各节点探针仅作诊断；隧道健康以 TCP/WireGuard 握手为准';
        });
        return;
      }
      final status = recover
          ? await refreshCorplinkSgStatus(probe: _probeChatGpt)
          : await _readStatus();
      if (!mounted) return;
      final phase = switch (status.phase) {
        SgConnectionPhase.missing => '节点未创建',
        SgConnectionPhase.waitingForTraffic => '等待首次握手',
        SgConnectionPhase.connecting => 'TCP/WireGuard 尚未就绪',
        SgConnectionPhase.ready => 'WireGuard 握手已就绪',
        SgConnectionPhase.needsRebuild => '隧道地址需要重建',
      };
      if (status.tunnelIp.isNotEmpty) {
        if (_lastTunnelIp != null && _lastTunnelIp != status.tunnelIp) {
          _tunnelIpChanges++;
        }
        _lastTunnelIp = status.tunnelIp;
      }
      final now = DateTime.now();
      final checkedAt = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}';
      setState(() {
        _livePhase = status.phase;
        _liveStatus = [
            globalState.isStart ? 'Android VPN 已启动' : 'Android VPN 未启动',
            phase,
            if (status.tunnelIp.isNotEmpty) '隧道 IP：${status.tunnelIp}',
            '本页观察到的 IP 变化：$_tunnelIpChanges 次',
            if (status.endpoint.isNotEmpty) '上游端点：${status.endpoint}',
            '更新于 $checkedAt',
          ].join('\n');
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _liveStatus = '状态读取失败：${error.runtimeType}';
          _status = _liveStatus;
        });
      }
      if (recover) rethrow;
    } finally {
      _statusReadInFlight = false;
    }
  }

  Future<bool> _probeChatGpt() async {
    try {
      final delay = await clashCore.getDelay(
        'https://chatgpt.com/robots.txt', 'SG-Node');
      final ok = delay.value != null && delay.value! > 0;
      if (mounted) {
        final now = DateTime.now();
        final checkedAt = '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}:'
            '${now.second.toString().padLeft(2, '0')}';
        setState(() => _dataPlaneStatus = ok
            ? '$checkedAt ChatGPT 域名有 HTTPS 响应，${delay.value} ms（不代表登录成功）'
            : '$checkedAt ChatGPT 访问失败；隧道握手状态请看上方');
      }
      return ok;
    } catch (error) {
      if (mounted) {
        setState(() => _dataPlaneStatus = 'ChatGPT 访问失败：${error.runtimeType}');
      }
      return false;
    }
  }

  CorplinkSgSettings _settings() => CorplinkSgSettings(
        enabled: _enabled,
        routeOpenAi: _routeOpenAi,
        username: _username.text.trim(),
        password: _password.text,
        server: _server.text.trim(),
      );

  void _draftChanged() {
    if (mounted && !_loading) setState(() {});
  }

  bool get _hasAccountChanges {
    final applied = _appliedSettings;
    final draft = _settings();
    return applied == null || applied.username.trim() != draft.username ||
        applied.password != draft.password || applied.server.trim() != draft.server;
  }

  bool get _hasUnsavedChanges {
    final applied = _appliedSettings;
    if (applied == null) return false;
    if (corplinkSgSettingsChanged(applied, _settings()) || _nodes.length != _appliedNodes.length) return true;
    for (var i = 0; i < _nodes.length; i++) {
      final a = _nodes[i], b = _appliedNodes[i];
      if (a.serverName != b.serverName || a.enabled != b.enabled || a.healthUrl != b.healthUrl) return true;
    }
    return false;
  }

  Future<bool> _confirmConfigurationApply() async =>
      await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('保存并应用配置'),
        content: const Text('将重新载入配置，飞连连接可能短暂中断。停用节点后，引用它的分流规则会被阻断。继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存并应用')),
        ],
      )) ?? false;

  void _cancelDraft() {
    final applied = _appliedSettings;
    if (applied == null) return;
    _loading = true;
    _username.text = applied.username;
    _password.text = applied.password;
    _server.text = applied.server;
    setState(() {
      _enabled = applied.enabled;
      _routeOpenAi = applied.routeOpenAi;
      _nodes = List.of(_appliedNodes);
      _showPassword = false;
      _loading = false;
      _status = '未提交的修改已取消';
    });
  }

  Future<void> _editProbe(CorplinkNodeSelection node) async {
    var value = node.healthUrl;
    final form = GlobalKey<FormState>();
    final saved = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text('${node.serverName} 健康探针'),
      content: Form(key: form, child: TextFormField(
        initialValue: value, keyboardType: TextInputType.url,
        autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'HTTPS 探测地址',
            hintText: 'https://example.com/ready',
            helperText: 'INTL 留空使用默认 ChatGPT 探针；其他留空只检查握手', helperMaxLines: 3),
        onChanged: (next) => value = next,
        validator: (_) => CorplinkNodeSelection(serverName: node.serverName,
            enabled: node.enabled, healthUrl: value.trim()).validationError,
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () {
          if (form.currentState?.validate() == true) Navigator.pop(context, value.trim());
        }, child: const Text('保存到草稿')),
      ],
    ));
    if (saved != null && mounted) _replaceNode(CorplinkNodeSelection(
        serverName: node.serverName, enabled: node.enabled, healthUrl: saved));
  }

  void _replaceNode(CorplinkNodeSelection next) {
    setState(() {
      _nodes = [
        for (final node in _nodes)
          if (node.serverName == next.serverName) next else node,
      ];
    });
  }

  Future<void> _discoverNodes() async {
    if (_busy) return;
    if (_hasAccountChanges || _appliedSettings?.isConfigured != true) {
      setState(() => _status = '请先保存账号；首次保存会自动发现节点。');
      return;
    }
    final applied = _appliedSettings!;
    final settings = CorplinkSgSettings(enabled: true, routeOpenAi: applied.routeOpenAi,
        username: applied.username, password: applied.password, server: applied.server);
    if (settings.validationError != null) {
      setState(() => _status = settings.validationError!);
      return;
    }
    setState(() { _busy = true; _status = '正在从飞连发现 TCP 节点…'; });
    try {
      final names = await discoverCorplinkVpnNodeNames(settings);
      if (!mounted) return;
      final selectedNames = _nodes.map((node) => node.serverName).toSet();
      setState(() {
        _discoveredNames = names;
        _nodes = [
          ..._nodes,
          for (final name in names)
            if (!selectedNames.contains(name))
              CorplinkNodeSelection(serverName: name, enabled: false),
        ];
        _status = '发现 ${names.length} 个 TCP 节点；旧 INTL 名称不会自动改动，'
            '请自行勾选要同时连接的节点后保存';
      });
    } catch (error) {
      final code = error is StateError ? error.message.toString() : '';
      final safeCode = RegExp(
        r'^(?:CORPLINK_[A-Z_]+|corplink vpn list (?:HTTP|code) [0-9]+)$',
      );
      if (mounted) {
        setState(() => _status = '发现节点失败：'
            '${safeCode.hasMatch(code) ? code : error.runtimeType}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addManualNode() {
    final name = _manualServerName.text.trim();
    final selection = CorplinkNodeSelection(serverName: name);
    if (selection.validationError != null) {
      setState(() => _status = selection.validationError!);
      return;
    }
    if (_nodes.any((node) => node.serverName == name)) {
      setState(() => _status = '此节点已在列表中');
      return;
    }
    setState(() {
      _nodes = [..._nodes, selection];
      _manualServerName.clear();
      _status = '已添加 $name；保存后生效';
    });
  }

  Future<void> _save({bool forceAuthorization = false}) async {
    if (_busy) return;
    if (forceAuthorization && _hasUnsavedChanges) {
      setState(() => _status = '请先保存或取消修改，再重新授权。');
      return;
    }
    final settings = _settings();
    final validationError = settings.validationError;
    if (validationError != null) {
      setState(() => _status = validationError);
      return;
    }
    for (final node in _nodes) {
      if (node.validationError != null) {
        setState(() => _status = '${node.serverName}：${node.validationError}');
        return;
      }
    }
    if (!forceAuthorization && _hasUnsavedChanges &&
        _appliedSettings?.enabled == true && globalState.isStart) {
      if (!await _confirmConfigurationApply() || !mounted) return;
    }
    setState(() {
      _busy = true;
      _status = settings.enabled ? '正在保存并授权…' : '正在停用飞连…';
    });
    try {
      await settings.save();
      await saveCorplinkNodeSelections(_nodes);
      _appliedSettings = settings;
      _appliedNodes = List.unmodifiable(_nodes);
      _nodeProbeResults.clear();
      _nodeSelectionSaved = true;
      await globalState.appController.ensureSgBootstrapProfile();
      final authorized = settings.enabled &&
          await ensureCorplinkAuthorization(settings, force: forceAuthorization);
      if (authorized && _nodes.isEmpty) {
        final names = await discoverCorplinkVpnNodeNames(settings);
        if (!mounted) return;
        _discoveredNames = names;
        _nodes = [for (final name in names)
          CorplinkNodeSelection(serverName: name, enabled: false)];
      }
      await globalState.appController.applyProfile();
      await _refreshLiveStatus(recover: authorized);
      if (!mounted) return;
      setState(() => _status = !settings.enabled
          ? '飞连已停用'
          : authorized
              ? _appliedNodes.where((node) => node.enabled).isEmpty
                  ? '账号已登录；请选择要同时连接的节点，再保存并应用。'
                  : '配置已应用，连接状态已更新'
              : '授权失败（${corplinkSgLastErrorCode.value ?? '请查看应用日志'}）；'
                  '未创建飞连节点，普通代理按原配置运行');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '保存或应用失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkConnection() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在检查 SG-Node…';
    });
    try {
      if (_nodeSelectionSaved) {
        await _refreshLiveStatus(recover: true);
        if (mounted) setState(() => _status = '各节点状态已检查；详见下方实时信息');
        return;
      }
      final ok = await _probeChatGpt();
      await _refreshLiveStatus();
      if (!mounted) return;
      setState(() => _status = ok
          ? 'ChatGPT 域名连通，登录页面仍需实际验证'
          : '节点探测失败；可尝试重新连接或重新授权');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = error is StateError &&
          error.message == 'ANDROID_VPN_START_TIMEOUT'
          ? 'Android VPN 尚未就绪；请确认系统授权后重试检查。未启动隧道探针。'
          : '节点探测失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconnectNode(String serverName) async {
    if (_busy || _hasUnsavedChanges || _appliedSettings?.enabled != true) return;
    final matches = _appliedNodes.where((node) => node.enabled && node.serverName == serverName);
    if (matches.isEmpty) return;
    final node = matches.first;
    setState(() { _busy = true; _status = '正在重连 $serverName…'; });
    try {
      await ensureCorplinkVpnReady();
      final before = await readCorplinkNodeStatus(serverName);
      if (before.rebuildRequired) {
        await clashCore.rebuildCorplinkNode(serverName);
      } else {
        await clashCore.reconnectCorplinkNode(serverName);
      }
      await clashCore.ensureCorplinkNode(serverName);
      await refreshCorplinkNodeStatus(serverName,
        healthUrl: effectiveCorplinkNodeProbeUrl(node),
        onProbe: (success) => _nodeProbeResults[serverName] =
            CorplinkNodeProbeObservation(success: success, checkedAt: DateTime.now()));
      await _refreshLiveStatus();
      if (mounted) setState(() => _status = '$serverName 的状态已刷新');
    } catch (error) {
      if (mounted) setState(() => _status = '节点重连失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconnect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在重建 TCP 隧道…';
    });
    try {
      if (_nodeSelectionSaved) {
        if (!globalState.isStart) {
          await globalState.appController.updateStatus(true);
        }
        for (final node in _nodes.where((node) => node.enabled)) {
          final status = await readCorplinkNodeStatus(node.serverName);
          if (status.rebuildRequired) {
            await clashCore.rebuildCorplinkNode(node.serverName);
          } else {
            await clashCore.reconnectCorplinkNode(node.serverName);
          }
          await clashCore.ensureCorplinkNode(node.serverName);
        }
        await _refreshLiveStatus();
        if (mounted) setState(() => _status = '已逐节点请求重连，状态已刷新');
        return;
      }
      final before = await _readStatus();
      if (!globalState.isStart) {
        await globalState.appController.updateStatus(true);
      }
      final accepted = before.rebuildRequired
          ? false
          : (before.present && await clashCore.reconnectCorplinkTunnel());
      if (!accepted) {
        await globalState.appController.applyProfile(silence: true);
      }
      await _probeChatGpt();
      await _refreshLiveStatus();
      if (!mounted) return;
      setState(() => _status = accepted
          ? '隧道已请求重连，状态已刷新'
          : '隧道已重建，状态已刷新');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '重连失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _username.dispose();
    _password.dispose();
    _server.dispose();
    _manualServerName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CorplinkManagementPanel(
      enabled: _appliedSettings?.enabled == true,
      vpnRunning: globalState.isStart,
      busy: _busy,
      nodes: _appliedNodes,
      statuses: _nodeStatuses,
      probes: {for (final entry in _nodeProbeResults.entries)
        entry.key: (success: entry.value.success, checkedAt: entry.value.checkedAt)},
      ipChanges: _nodeIPChanges,
      updatedAt: _lastStateReadAt,
      message: _status,
      draftDirty: _hasUnsavedChanges,
      configuration: _buildConfiguration(context),
      onRestore: _checkConnection,
      onReconnectNode: _reconnectNode,
      onReauthorize: () => _save(forceAuthorization: true),
    );
  }

  Widget _buildConfiguration(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('编辑中的修改仅在保存并应用后生效。'),
        SwitchListTile(
          title: const Text('启用飞连'),
          subtitle: const Text('保存后生效'),
          value: _enabled,
          onChanged: _busy ? null : (value) => setState(() => _enabled = value),
        ),
        SwitchListTile(
          title: const Text('ChatGPT / OpenAI'),
          subtitle: const Text('自动使用已选择的 INTL 节点'),
          value: _routeOpenAi,
          onChanged: _busy ? null : (value) => setState(() => _routeOpenAi = value),
        ),
        TextField(
          enabled: !_busy,
          controller: _username,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '飞连用户名'),
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: !_busy,
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '飞连密码',
            suffixIcon: IconButton(
              tooltip: _showPassword ? '隐藏密码' : '显示密码',
              onPressed: _busy ? null : () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          controller: _server,
          decoration: const InputDecoration(
            labelText: '上游建连服务器',
            hintText: 'https://vpn.example.com:10443',
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('TCP 服务器节点',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            TextButton.icon(
              onPressed: _busy || !_enabled || _hasAccountChanges ||
                  _appliedSettings?.isConfigured != true ? null : _discoverNodes,
              icon: const Icon(Icons.search),
              label: const Text('从飞连发现'),
            ),
          ],
        ),
        if (_discoveredNames.isNotEmpty)
          Text('已发现：${_discoveredNames.join('、')}',
              style: Theme.of(context).textTheme.bodySmall),
        Text('取消勾选后不生成该节点和组；脚本中失效的目标会由内置 REJECT 阻断。',
            style: Theme.of(context).textTheme.bodySmall),
        if (_nodes.isEmpty)
          const Text('首次保存账号会自动发现服务器；选择节点后再保存并应用。'),
        for (final node in _nodes) ...[
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(node.serverName),
            subtitle: Text(node.enabled ? '已选择 · 保存后启用' : '未选择'),
            secondary: IconButton(
              tooltip: '设置 ${node.serverName} 的健康探针',
              icon: const Icon(Icons.monitor_heart_outlined),
              onPressed: _busy ? null : () => _editProbe(node),
            ),
            value: node.enabled,
            onChanged: _busy ? null : (value) => _replaceNode(
              CorplinkNodeSelection(
                serverName: node.serverName,
                enabled: value ?? false,
                healthUrl: node.healthUrl,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        ExpansionTile(
          title: const Text('手动补充节点（一般无需使用）'),
          children: [Row(
          children: [
            Expanded(child: TextField(
              enabled: !_busy,
              controller: _manualServerName,
              decoration: const InputDecoration(labelText: '服务器原名（不要填写网址）'),
            )),
            TextButton(
              onPressed: _busy ? null : _addManualNode,
              child: const Text('添加'),
            ),
          ],
        )]),
        const SizedBox(height: 16),
        ValueListenableBuilder<String?>(
          valueListenable: corplinkSgLastErrorCode,
          builder: (_, code, _) => code == null
              ? const SizedBox.shrink()
              : Text('最近授权错误码：$code'),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: corplinkSgLastCoreErrorCode,
          builder: (_, code, _) => code == null
              ? const SizedBox.shrink()
              : Text('最近控制面错误：$code'),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: corplinkSgLastScriptErrorCode,
          builder: (_, code, _) => code == null
              ? const SizedBox.shrink()
              : Text('最近覆写脚本冲突：$code'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_enabled && _appliedSettings?.isConfigured != true
              ? '登录并发现节点' : '保存并应用'),
        ),
        TextButton(
          onPressed: _busy || !_hasUnsavedChanges ? null : _cancelDraft,
          child: const Text('取消修改'),
        ),
      ],
    );
  }
}
