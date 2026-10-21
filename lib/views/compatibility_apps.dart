import 'dart:typed_data';

import 'package:bett_box/services/compatibility_apps.dart';
import 'package:material_ui/material_ui.dart';

class CompatibilityAppsView extends StatefulWidget {
  const CompatibilityAppsView({
    super.key,
    this.platform = const AndroidCompatibilityAppsPlatform(),
  });

  final CompatibilityAppsPlatform platform;

  @override
  State<CompatibilityAppsView> createState() => _CompatibilityAppsViewState();
}

class _CompatibilityAppsViewState extends State<CompatibilityAppsView>
    with WidgetsBindingObserver {
  CompatibilityAppStatus? _status;
  Uint8List? _icon;
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final results = await Future.wait<Object?>([
      widget.platform.readStatus(yadeaSmartMotoPackage),
      widget.platform.readIcon(yadeaSmartMotoPackage),
    ]);
    if (!mounted) return;
    setState(() {
      _status = results[0] as CompatibilityAppStatus;
      _icon = results[1] as Uint8List?;
    });
  }

  Future<void> _run(
    Future<bool> Function() action,
    String success,
    String failure,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    final ok = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok ? success : failure;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: _icon == null
                          ? const Icon(Icons.electric_moped_outlined, size: 36)
                          : Image.memory(_icon!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('雅迪智行', style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      )),
                      Text('无 Root 兼容启动'),
                    ],
                  )),
                ]),
                const SizedBox(height: 16),
                const Text(
                  '兼容入口会先暂停 Bettbox VPN/TUN，确认系统不再显示 VPN 后再打开雅迪。'
                  '离开雅迪后，仅在 VPN 原本正在运行且你没有手动停止时自动恢复。',
                ),
                const SizedBox(height: 12),
                Text(status == null
                    ? '正在检查…'
                    : !status.installed
                        ? '未安装雅迪智行'
                        : status.usageAccessGranted
                            ? '自动恢复权限已开启'
                            : '自动恢复权限未开启'),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_message, style: TextStyle(color: scheme.primary)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (status?.usageAccessGranted != true)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(
              widget.platform.openUsageAccessSettings,
              '请在系统页面允许 Bettbox 查看使用情况',
              '无法打开使用情况设置',
            ),
            icon: const Icon(Icons.security_outlined),
            label: const Text('授予自动恢复权限'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy || status?.installed != true ||
                  status?.shortcutSupported != true
              ? null
              : () => _run(
                    () => widget.platform.createShortcut(yadeaSmartMotoPackage),
                    '已请求在桌面创建雅迪兼容快捷方式',
                    '桌面不支持或拒绝创建快捷方式',
                  ),
          icon: const Icon(Icons.add_to_home_screen_outlined),
          label: const Text('创建雅迪智行兼容快捷方式'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy || status?.installed != true
              ? null
              : () => _run(
                    () => widget.platform.launchCompatible(yadeaSmartMotoPackage),
                    '已进入雅迪兼容模式',
                    '无法打开雅迪智行',
                  ),
          icon: const Icon(Icons.open_in_new),
          label: const Text('兼容打开'),
        ),
        if (status?.usageAccessGranted != true) ...[
          const SizedBox(height: 12),
          const Text(
            '未授予使用情况权限时仍可暂停 VPN 并打开雅迪，'
            '用完后请通过通知栏“立即恢复 Bettbox”手动恢复。',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ],
    );
  }
}
