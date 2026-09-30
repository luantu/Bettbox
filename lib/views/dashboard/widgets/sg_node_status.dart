import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/services/corplink_sg.dart';
import 'package:bett_box/services/corplink_sg_nodes.dart';
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
  SgNodeAggregate? _aggregate;
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
      final selections = await loadCorplinkNodeSelections();
      final statuses = settings.enabled && selections != null
          ? await readCorplinkNodeStatuses()
          : const <SgCoreStatus>[];
      final aggregate = settings.enabled && selections != null
          ? summarizeCorplinkNodes(
              statuses,
              selections.where((node) => node.enabled).map((node) => node.serverName),
            )
          : null;
      final status = settings.enabled && selections == null
          ? await readCorplinkSgStatus()
          : null;
      if (!mounted) return;
      setState(() {
        if (_enabled != settings.enabled ||
            _status?.phase != status?.phase ||
            _status?.tunnelIp != status?.tunnelIp) {
          _lastProbeOk = null;
        }
        _enabled = settings.enabled;
        _status = status;
        _aggregate = aggregate;
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
      final selections = await loadCorplinkNodeSelections();
      if (selections != null) {
        final enabledNodes = selections.where((node) => node.enabled).toList();
        final statuses = await Future.wait([
          for (final node in enabledNodes)
            refreshCorplinkNodeStatus(
              node.serverName,
              healthUrl: effectiveCorplinkNodeProbeUrl(node),
            ),
        ]);
        if (!mounted) return;
        setState(() => _aggregate = summarizeCorplinkNodes(
          statuses,
          enabledNodes.map((node) => node.serverName),
        ));
        return;
      }
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
    if (_aggregate != null) return _aggregate!.label;
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
      child: Stack(
        children: [
          Positioned.fill(
            child: CommonCard(
              onPressed: _openSettings,
              info: const Info(iconData: Icons.vpn_key_outlined, label: 'SG-Node'),
              child: Container(
                width: double.infinity,
                padding: baseInfoEdgeInsets.copyWith(top: 0),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    _summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodyMedium?.toLight.adjustSize(0),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4.ap,
            right: 8.ap,
            child: IconButton(
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
          ),
        ],
      ),
    );
  }
}
