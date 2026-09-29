import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_runtime.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';

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
  List<CorplinkNodeSelection> _nodes = const [
    CorplinkNodeSelection(serverName: 'FZ-INT-Node'),
  ];
  bool _nodeSelectionSaved = false;
  List<String> _discoveredNames = const [];
  final Map<String, String> _lastNodeIPs = {};
  final Map<String, int> _nodeIPChanges = {};
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
    _load();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_enabled && !_busy && !_statusReadInFlight) {
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
      _status = !settings.enabled
          ? '飞连未启用'
          : corplinkAuthMatchesSettings(auth, settings)
              ? '已生成授权文件，尚需检查隧道'
              : '等待授权；SG-OpenAI 组会阻断流量，避免意外直连';
    });
    if (settings.enabled) unawaited(_refreshLiveStatus());
  }

  Future<SgCoreStatus> _readStatus() => readCorplinkSgStatus();

  Future<void> _refreshLiveStatus({bool recover = false}) async {
    if (!_enabled) {
      if (mounted) setState(() => _liveStatus = '飞连未启用');
      return;
    }
    _statusReadInFlight = true;
    try {
      if (_nodeSelectionSaved) {
        final selected = _nodes.where((node) => node.enabled).toList();
        final statuses = recover
            ? await Future.wait([
                for (final node in selected)
                  refreshCorplinkNodeStatus(
                    node.serverName,
                    healthUrl: node.healthUrl,
                  ),
              ])
            : await readCorplinkNodeStatuses();
        if (!mounted) return;
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
        }
        final now = DateTime.now();
        lines.add('更新于 ${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}:'
            '${now.second.toString().padLeft(2, '0')}');
        setState(() {
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
        setState(() => _liveStatus = '状态读取失败：${error.runtimeType}');
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
    final settings = _settings();
    if (settings.validationError != null) {
      setState(() => _status = settings.validationError!);
      return;
    }
    setState(() { _busy = true; _status = '正在从飞连发现 TCP 节点…'; });
    try {
      await settings.save();
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
    setState(() {
      _busy = true;
      _status = settings.enabled ? '正在保存并授权…' : '正在停用飞连…';
    });
    try {
      await settings.save();
      await saveCorplinkNodeSelections(_nodes);
      _nodeSelectionSaved = true;
      await globalState.appController.ensureSgBootstrapProfile();
      final authorized = settings.enabled &&
          await ensureCorplinkAuthorization(settings, force: forceAuthorization);
      await globalState.appController.applyProfile();
      await _refreshLiveStatus(recover: authorized);
      if (!mounted) return;
      setState(() => _status = !settings.enabled
          ? '飞连已停用'
          : authorized
              ? '已授权，连接状态已刷新；请查看下方隧道与 ChatGPT 检查结果'
              : '授权失败（${corplinkSgLastErrorCode.value ?? '请查看应用日志'}）；'
                  'SG-OpenAI 组会阻断流量，普通代理仍可用');
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
      setState(() => _status = '节点探测失败：${error.runtimeType}');
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('飞连 VPN 节点', style: TextStyle(fontSize: 22)),
        const SizedBox(height: 8),
        const Text('连接上游飞连服务器，自动发现 TCP VPN 节点并加入当前配置。'),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('启用飞连'),
          value: _enabled,
          onChanged: _busy ? null : (value) => setState(() => _enabled = value),
        ),
        SwitchListTile(
          title: const Text('OpenAI / ChatGPT 使用 SG-OpenAI'),
          value: _routeOpenAi,
          onChanged: _busy ? null : (value) => setState(() => _routeOpenAi = value),
        ),
        TextField(
          controller: _username,
          decoration: const InputDecoration(labelText: '飞连用户名'),
        ),
        TextField(
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '飞连密码',
            suffixIcon: IconButton(
              tooltip: _showPassword ? '隐藏密码' : '显示密码',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        TextField(
          controller: _server,
          decoration: const InputDecoration(
            labelText: '上游建连服务器',
            hintText: 'https://aq.ruijie.com.cn:10443',
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('TCP 服务器节点',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            TextButton.icon(
              onPressed: _busy || !_enabled ? null : _discoverNodes,
              icon: const Icon(Icons.search),
              label: const Text('从飞连发现'),
            ),
          ],
        ),
        if (_discoveredNames.isNotEmpty)
          Text('已发现：${_discoveredNames.join('、')}',
              style: Theme.of(context).textTheme.bodySmall),
        Text('取消勾选会保留 REJECT 占位组，避免覆写脚本中的规则失去目标。',
            style: Theme.of(context).textTheme.bodySmall),
        for (final node in _nodes) ...[
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(node.serverName),
            subtitle: Text(node.enabled ? '启用独立 WireGuard 隧道与同名代理组' : '停用 · 代理组阻断'),
            value: node.enabled,
            onChanged: _busy ? null : (value) => _replaceNode(
              CorplinkNodeSelection(
                serverName: node.serverName,
                enabled: value ?? false,
                healthUrl: node.healthUrl,
              ),
            ),
          ),
          TextFormField(
            key: ValueKey('health-${node.serverName}'),
            initialValue: node.healthUrl,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: '${node.serverName} 健康探针（可选）',
              hintText: 'https://example.com/ready',
              helperText: '留空只检查 TCP/WireGuard 握手；网站失败不会触发重连',
            ),
            onChanged: (value) => _replaceNode(CorplinkNodeSelection(
              serverName: node.serverName,
              enabled: node.enabled,
              healthUrl: value.trim(),
            )),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(child: TextField(
              controller: _manualServerName,
              decoration: const InputDecoration(labelText: '手动输入服务器节点名'),
            )),
            TextButton(
              onPressed: _busy ? null : _addManualNode,
              child: const Text('添加'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(_status),
        const SizedBox(height: 8),
        SelectableText(_liveStatus),
        const SizedBox(height: 4),
        Text(_livePhase == SgConnectionPhase.ready
            ? _dataPlaneStatus
            : '当前隧道未就绪；上次检查：$_dataPlaneStatus'),
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
          child: const Text('保存并连接'),
        ),
        OutlinedButton(
          onPressed: _busy || !_enabled ? null : () async {
            setState(() {
              _busy = true;
              _status = '正在刷新状态并按需恢复…';
            });
            try {
              await _refreshLiveStatus(recover: true);
              if (mounted) setState(() => _status = '状态已刷新');
            } catch (error) {
              if (mounted) {
                setState(() => _status = '刷新或恢复失败：${error.runtimeType}');
              }
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
          child: const Text('刷新状态并恢复'),
        ),
        OutlinedButton(
          onPressed: _busy || !_enabled ? null : _checkConnection,
          child: const Text('检查连接'),
        ),
        OutlinedButton(
          onPressed: _busy || !_enabled ? null : _reconnect,
          child: const Text('重新连接隧道'),
        ),
        TextButton(
          onPressed: _busy || !_enabled
              ? null
              : () => _save(forceAuthorization: true),
          child: const Text('重新授权'),
        ),
      ],
    );
  }
}
