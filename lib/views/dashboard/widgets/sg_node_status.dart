import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_runtime.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/corplink_sg.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';

class SgNodeStatusTile extends StatefulWidget {
  const SgNodeStatusTile({super.key});

  @override
  State<SgNodeStatusTile> createState() => _SgNodeStatusTileState();
}

class _SgNodeStatusTileState extends State<SgNodeStatusTile> {
  late final VoidCallback _tickListener;
  bool _enabled = false;
  bool _reading = false;
  bool _busy = false;
  bool? _lastProbeOk;
  SgCoreStatus? _status;
  DateTime? _updatedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tickListener = () => unawaited(_poll());
    dashboardRefreshManager.tick5s.addListener(_tickListener);
    unawaited(_poll());
  }

  @override
  void dispose() {
    dashboardRefreshManager.tick5s.removeListener(_tickListener);
    super.dispose();
  }

  Future<void> _poll() async {
    if (!mounted || _reading || _busy) return;
    _reading = true;
    try {
      final settings = await CorplinkSgSettings.load();
      final status = settings.enabled ? await readCorplinkSgStatus() : null;
      if (!mounted) return;
      setState(() {
        _enabled = settings.enabled;
        _status = status;
        _updatedAt = DateTime.now();
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.runtimeType.toString());
    } finally {
      _reading = false;
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final settings = await CorplinkSgSettings.load();
    if (!settings.enabled || !settings.isConfigured) {
      _openSettings();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await refreshCorplinkSgStatus(
        probe: () async {
          final ok = await probeCorplinkSgChatGpt();
          _lastProbeOk = ok;
          return ok;
        },
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        _updatedAt = DateTime.now();
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.runtimeType.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openSettings() {
    showExtend(
      context,
      builder: (_, type) => AdaptiveSheetScaffold(
        type: type,
        title: '飞连 SG-Node',
        body: const CorplinkSgView(),
      ),
    );
  }

  String get _summary {
    if (_error != null) return '状态读取或恢复失败：$_error';
    if (!_enabled) return '飞连未启用，点按配置';
    if (!globalState.isStart) return 'Android VPN 未启动';
    final phase = _status?.phase;
    final text = switch (phase) {
      SgConnectionPhase.ready => 'WireGuard 握手就绪',
      SgConnectionPhase.waitingForTraffic => '等待首次握手',
      SgConnectionPhase.connecting => '隧道尚未就绪',
      SgConnectionPhase.needsRebuild => '需要重建隧道',
      SgConnectionPhase.missing || null => 'SG 节点未创建',
    };
    if (phase == SgConnectionPhase.ready && _lastProbeOk != null) {
      return '$text · ChatGPT ${_lastProbeOk! ? '有响应' : '未连通'}';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final updatedAt = _updatedAt;
    final timeText = updatedAt == null
        ? ''
        : '${updatedAt.hour.toString().padLeft(2, '0')}:'
          '${updatedAt.minute.toString().padLeft(2, '0')}:'
          '${updatedAt.second.toString().padLeft(2, '0')}';
    final tunnelIp = _status?.tunnelIp ?? '';
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        onPressed: _openSettings,
        child: Padding(
          padding: baseInfoEdgeInsets,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.vpn_key_outlined,
                      color: context.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('SG-Node',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.titleSmall),
                  ),
                  IconButton(
                    tooltip: '刷新状态并恢复 SG-Node',
                    onPressed: _busy ? null : _refresh,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Spacer(),
              Text(_summary, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (tunnelIp.isNotEmpty || timeText.isNotEmpty)
                Text(
                  [
                    if (tunnelIp.isNotEmpty) '隧道 IP：$tunnelIp',
                    if (timeText.isNotEmpty) '更新于 $timeText',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
