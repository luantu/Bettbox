import 'dart:async';

import 'package:bett_box/common/smart_network_policy.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:material_ui/material_ui.dart';

import 'smart_network_rule_editor.dart';

class SmartNetworkSettings extends StatefulWidget {
  const SmartNetworkSettings({super.key, required this.rulesJson,
    required this.legacyNetworks, required this.onChanged});
  final String rulesJson;
  final String legacyNetworks;
  final ValueChanged<String> onChanged;
  @override
  State<SmartNetworkSettings> createState() => _SmartNetworkSettingsState();
}

class _SmartNetworkSettingsState extends State<SmartNetworkSettings>
    with WidgetsBindingObserver {
  List<SmartNetworkSnapshot> _networks = const [];
  bool _backgroundGranted = false;
  bool _loading = false;
  bool _smartStopped = false;
  bool _running = false;
  String? _error;
  Timer? _timer;
  late final NativeEventCallback _events;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = (method, arguments) async {
      if (method == 'networkChanged' || method == 'runStateChanged') await _refresh();
    };
    service?.addNativeEventCallback(_events);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    service?.removeNativeEventCallback(_events);
    _timer?.cancel(); super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { _refresh(); service?.checkSmartAutoStop(); }
  }

  Future<void> _refresh() async {
    if (!mounted || _loading) return;
    setState(() => _loading = true);
    try {
      final result = await service?.getSmartNetworkSnapshot();
      final stopped = await service?.isSmartStopped() ?? false;
      final running = await service?.getStatus() ?? false;
      if (!mounted) return;
      setState(() {
        _networks = SmartNetworkSnapshot.decode(result);
        _backgroundGranted = result?['backgroundLocationGranted'] == true;
        _smartStopped = stopped; _running = running; _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '读取当前网络失败，未改变 VPN 状态');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(List<SmartNetworkRule> rules, {SmartNetworkRule? initial,
    String ssid = ''}) async {
    final saved = await showDialog<SmartNetworkRule>(context: context, builder: (context) =>
      AlertDialog(title: Text(initial == null ? '添加地点规则' : '编辑地点规则'),
        content: SizedBox(width: 440, child: SmartNetworkRuleEditor(
          initial: initial ?? SmartNetworkRule(id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: ssid, ssid: ssid),
          onSaved: (rule) => Navigator.of(context).pop(rule))),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消'))]));
    if (saved == null || !mounted) return;
    // Refuse to overwrite an externally updated list with a stale dialog copy.
    final current = SmartNetworkRule.decode(widget.rulesJson).toList();
    final index = current.indexWhere((rule) => rule.id == saved.id);
    if (index >= 0) { current[index] = saved; } else { current.add(saved); }
    widget.onChanged(SmartNetworkRule.encode(current));
  }

  Future<void> _delete(SmartNetworkRule rule) async {
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('删除地点规则？'), content: Text('删除“${rule.name}”后将重新检查智能启停。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))]));
    if (confirm != true || !mounted) return;
    final current = SmartNetworkRule.decode(widget.rulesJson);
    widget.onChanged(SmartNetworkRule.encode(current.where((item) => item.id != rule.id).toList()));
  }

  @override
  Widget build(BuildContext context) {
    List<SmartNetworkRule> rules = const [];
    var invalid = false;
    try { rules = SmartNetworkRule.decode(widget.rulesJson); } catch (_) { invalid = true; }
    final wifi = _networks.where((network) => network.selected && network.transport == 'wifi').firstOrNull;
    final hasSelected = _networks.any((network) => network.selected);
    final ssidStatusText = switch (wifi?.ssidStatus) {
      'permissionRequired' => '需要位置权限',
      'locationDisabled' => '系统定位未开启',
      _ => '暂未取得 Wi-Fi 名称',
    };
    final decision = SmartNetworkPolicy.evaluate(networks: _networks,
      rulesJson: widget.rulesJson, legacyNetworks: widget.legacyNetworks);
    final scheme = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(color: scheme.surfaceContainerLow, child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Expanded(child: Text('当前网络与启停状态', style: TextStyle(fontWeight: FontWeight.w600))),
            IconButton(onPressed: _loading ? null : () async {
              await service?.checkSmartAutoStop(); await _refresh();
            }, tooltip: '刷新网络状态', icon: const Icon(Icons.refresh))]),
          Text(!hasSelected ? '当前底层出口尚未确定，暂不自动切换' : wifi == null ? '当前使用蜂窝／有线网络' : wifi.ssidAvailable
            ? 'Wi-Fi：${wifi.ssid}' : 'Wi-Fi：SSID 暂不可读（$ssidStatusText）'),
          if (wifi != null && wifi.ips.isNotEmpty) Text('本机 IP：${wifi.ips.join('，')}'),
          const SizedBox(height: 8),
          Text(_smartStopped ? '已智能暂停 VPN' : _running ? 'VPN 正在运行' : 'VPN 已停止'),
          Text(decision.reason),
          const SizedBox(height: 4),
          const Text('状态每 15 秒更新；切网与配置变动会主动检查。手动停止不会被自动启动。', style: TextStyle(fontSize: 12)),
          if (_error != null) Text(_error!, style: TextStyle(color: scheme.error)),
        ]))),
      if (wifi != null && !wifi.ssidAvailable) ...[
        const SizedBox(height: 8),
        const Text('读取 SSID 需要精确位置权限及系统定位开关；读取失败不会退回仅 IP 匹配。'),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: () async { await app?.requestSmartWifiPermission(); await _refresh(); },
            child: const Text('允许读取 Wi-Fi 名称')),
          TextButton(onPressed: () => app?.openSmartWifiLocationSettings(), child: const Text('打开系统定位设置')),
        ]),
      ],
      if (!_backgroundGranted) ...[
        const SizedBox(height: 8),
        const Text('锁屏后识别 SSID 可能需要将位置权限设为“始终允许”。未授权时会显示不可读并保持状态，不会猜测网络身份。',
          style: TextStyle(fontSize: 12)),
        Align(alignment: Alignment.centerLeft, child: TextButton(
          onPressed: () => app?.openAppSettings(), child: const Text('打开应用权限设置'))),
      ],
      const SizedBox(height: 12),
      const Text('地点规则', style: TextStyle(fontWeight: FontWeight.w600)),
      const Text('同一条中的 SSID 与地址必须同时满足；不同规则任一命中就暂停。'),
      if (invalid) Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('地点规则格式错误，原配置已保留；请修正配置后再编辑。', style: TextStyle(color: scheme.error))),
      for (final rule in rules) Card(child: Column(children: [
        ListTile(title: Text(rule.name), subtitle: Text([
          if (rule.ssid.isNotEmpty) 'SSID：${rule.ssid}',
          if (rule.networks.isNotEmpty) '地址：${rule.networks}',
        ].join('\n')), trailing: Switch(value: rule.enabled, onChanged: (value) {
          widget.onChanged(SmartNetworkRule.encode(rules.map((item) =>
            item.id == rule.id ? item.withEnabled(value) : item).toList()));
        })),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => _edit(rules, initial: rule), child: const Text('编辑')),
          TextButton(onPressed: () => _delete(rule), child: const Text('删除')),
        ]),
      ])),
      Wrap(spacing: 8, children: [
        FilledButton.tonalIcon(onPressed: invalid ? null : () => _edit(rules),
          icon: const Icon(Icons.add), label: const Text('添加地点规则')),
        OutlinedButton.icon(onPressed: invalid || wifi?.ssidAvailable != true ? null : () => _edit(rules, ssid: wifi!.ssid!),
          icon: const Icon(Icons.wifi), label: const Text('使用当前 Wi-Fi')),
      ]),
      if (widget.legacyNetworks.trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('注意：下方旧版 IP 规则仍然有效，会独立触发暂停。要避免相同网段误判，请将其改成地点规则后，再清空旧规则。',
          style: TextStyle(color: scheme.error)),
      ],
    ]));
  }
}
