import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/services/corplink_sg.dart';
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
    if (!mounted) return;
    setState(() {
      _username.text = settings.username;
      _password.text = settings.password;
      _server.text = settings.server;
      _enabled = settings.enabled;
      _routeOpenAi = settings.routeOpenAi;
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

  Future<void> _save({bool forceAuthorization = false}) async {
    if (_busy) return;
    final settings = _settings();
    final validationError = settings.validationError;
    if (validationError != null) {
      setState(() => _status = validationError);
      return;
    }
    setState(() {
      _busy = true;
      _status = settings.enabled ? '正在保存并授权…' : '正在停用飞连…';
    });
    try {
      await settings.save();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('飞连 SG-Node', style: TextStyle(fontSize: 22)),
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
