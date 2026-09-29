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
        if (_enabled != settings.enabled ||
            _status?.phase != status?.phase ||
            _status?.tunnelIp != status?.tunnelIp) {
          _lastProbeOk = null;
        }
        _enabled = settings.enabled;
        _status = status;
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
    if (!mounted) return;
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
    if (_error != null) return '状态异常 · 点击刷新';
    if (!_enabled) return '未启用 · 点击配置';
    if (!globalState.isStart) return 'VPN 未启动 · 点击刷新';
    final phase = _status?.phase;
    final text = switch (phase) {
      SgConnectionPhase.ready => _lastProbeOk == null
          ? '隧道已连接'
          : _lastProbeOk!
              ? '已连接 · 上次检查可达'
              : '已连接 · 上次检查失败',
      SgConnectionPhase.waitingForTraffic => '等待首次握手',
      SgConnectionPhase.connecting => '正在连接',
      SgConnectionPhase.needsRebuild => '连接异常 · 点击刷新',
      SgConnectionPhase.missing || null => '节点未创建 · 点击配置',
    };
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        onPressed: _openSettings,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(14.ap, 12.ap, 14.ap, 0),
              child: Row(
                children: [
                  Icon(Icons.vpn_key_outlined,
                      size: 18, color: context.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('SG-Node',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.titleSmall?.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        )),
                  ),
                  IconButton(
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    padding: EdgeInsets.zero,
                    tooltip: '刷新状态并恢复 SG-Node',
                    onPressed: _busy ? null : _refresh,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(14.ap, 0, 14.ap, 12.ap),
              child: Text(
                _summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
