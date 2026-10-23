import 'package:bett_box/common/smart_network_policy.dart';
import 'package:material_ui/material_ui.dart';

class SmartNetworkRuleEditor extends StatefulWidget {
  const SmartNetworkRuleEditor({super.key, required this.initial, required this.onSaved});
  final SmartNetworkRule initial;
  final ValueChanged<SmartNetworkRule> onSaved;
  @override
  State<SmartNetworkRuleEditor> createState() => _SmartNetworkRuleEditorState();
}

class _SmartNetworkRuleEditorState extends State<SmartNetworkRuleEditor> {
  late final TextEditingController _name;
  late final TextEditingController _ssid;
  late final TextEditingController _networks;
  late bool _enabled;
  String? _error;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _ssid = TextEditingController(text: widget.initial.ssid);
    _networks = TextEditingController(text: widget.initial.networks);
    _enabled = widget.initial.enabled;
  }
  @override
  void dispose() { _name.dispose(); _ssid.dispose(); _networks.dispose(); super.dispose(); }

  void _save() {
    final rule = SmartNetworkRule(id: widget.initial.id, name: _name.text.trim(),
      enabled: _enabled, ssid: _ssid.text, networks: _networks.text.trim());
    setState(() => _error = rule.validationError);
    if (_error == null) widget.onSaved(rule);
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    Flexible(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _name, key: const ValueKey('rule-name'),
        decoration: const InputDecoration(labelText: '地点名称'), maxLength: 40),
      const SizedBox(height: 8),
      TextField(controller: _ssid, key: const ValueKey('rule-ssid'),
        autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'Wi-Fi 名称（SSID，可选）',
          helperText: '完整名称，区分大小写；空格也是名称的一部分')),
      const SizedBox(height: 16),
      TextField(controller: _networks, key: const ValueKey('rule-networks'),
        autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'IP／网关条件（可选）',
          hintText: '192.168.110.0/24,gateway:192.168.110.1',
          helperText: '填写两项时必须同时满足；示例网段为 /24，/32 仅匹配一个 IP', helperMaxLines: 3)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('启用此规则'),
        value: _enabled, onChanged: (value) => setState(() => _enabled = value)),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8),
        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ]))),
    const SizedBox(height: 12),
    Align(alignment: Alignment.centerRight, child: FilledButton.icon(
      onPressed: _save, icon: const Icon(Icons.save_outlined), label: const Text('保存规则'))),
  ]);
}
