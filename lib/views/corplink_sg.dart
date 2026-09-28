import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/services/corplink_sg.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
      if (!mounted) return;
      setState(() => _status = !settings.enabled
          ? '飞连已停用'
          : authorized
              ? '已授权；请运行连接检查确认 WireGuard 隧道'
              : '授权失败；SG-OpenAI 组会阻断流量，普通代理仍可用');
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
      final delay = await clashCore.getDelay(
        'https://www.apple.com/library/test/success.html',
        'SG-Node',
      );
      if (!mounted) return;
      setState(() => _status = delay.value != null && delay.value! > 0
          ? 'SG-Node 可用，延迟 ${delay.value} ms'
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
      final accepted = await clashLib?.reconnectTunnels() ?? false;
      if (!mounted) return;
      setState(() => _status = accepted
          ? '已请求重连；请运行连接检查'
          : '内核未接受重连请求');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '重连失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
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
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存并连接'),
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
