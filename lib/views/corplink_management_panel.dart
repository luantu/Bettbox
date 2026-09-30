import 'package:bett_box/services/corplink_sg_nodes.dart';
import 'package:bett_box/services/corplink_sg_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef CorplinkProbeSnapshot = ({bool success, DateTime checkedAt});

/// Presentation of applied state. Configuration below is an independent draft.
class CorplinkManagementPanel extends StatelessWidget {
  const CorplinkManagementPanel({
    super.key,
    required this.enabled,
    required this.vpnRunning,
    required this.busy,
    required this.nodes,
    required this.statuses,
    required this.probes,
    required this.ipChanges,
    required this.updatedAt,
    required this.message,
    required this.draftDirty,
    required this.configuration,
    required this.onRestore,
    required this.onReconnectNode,
    required this.onReauthorize,
  });

  final bool enabled, vpnRunning, busy, draftDirty;
  final List<CorplinkNodeSelection> nodes;
  final List<SgCoreStatus> statuses;
  final Map<String, CorplinkProbeSnapshot> probes;
  final Map<String, int> ipChanges;
  final DateTime? updatedAt;
  final String message;
  final Widget configuration;
  final Future<void> Function() onRestore, onReauthorize;
  final Future<void> Function(String) onReconnectNode;

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  Future<void> _confirmed(BuildContext context, {
    required String title,
    required String message,
    required String confirm,
    required Future<void> Function() action,
  }) async {
    final accepted = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(
        title: Text(title), content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirm)),
        ],
      ));
    if (accepted == true && context.mounted) await action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = enabled ? nodes.where((node) => node.enabled).toList()
        : <CorplinkNodeSelection>[];
    final byName = {for (final status in statuses) status.serverName: status};
    final aggregate = summarizeCorplinkNodes(statuses, selected.map((node) => node.serverName));
    final fullyReady = enabled && vpnRunning && aggregate.total > 0 && aggregate.ready == aggregate.total;
    final accent = fullyReady ? Colors.green : theme.colorScheme.primary;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(fullyReady ? Icons.verified_user_outlined : Icons.shield_outlined, color: accent),
            const SizedBox(width: 12),
            Expanded(child: Text('飞连连接', style: theme.textTheme.titleMedium)),
            if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 12),
          Text(!enabled ? '飞连未启用' : aggregate.label,
              style: theme.textTheme.headlineSmall?.copyWith(color: accent)),
          const SizedBox(height: 4),
          Text(vpnRunning ? 'Android VPN 已启动' : 'Android VPN 未启动', style: theme.textTheme.bodySmall),
          if (updatedAt != null)
            Text('更新于 ${_time(updatedAt!)} · 状态每 3 秒刷新', style: theme.textTheme.bodySmall),
          if (enabled && selected.isEmpty)
            const Text('请在下方配置中发现并选择服务器节点。'),
        ],
      ))),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: busy || !enabled || selected.isEmpty ? null : onRestore,
        icon: const Icon(Icons.refresh), label: const Text('检查并恢复'),
      ),
      if (message.isNotEmpty) Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(message, style: theme.textTheme.bodySmall),
      ),
      const SizedBox(height: 12),
      for (final node in selected) ...[
        _CorplinkNodeCard(
          node: node, status: byName[node.serverName], probe: probes[node.serverName],
          ipChanges: ipChanges[node.serverName] ?? 0,
        ),
        const SizedBox(height: 8),
      ],
      Card(child: ExpansionTile(
        key: const ValueKey('corplink-configuration'),
        leading: const Icon(Icons.tune), title: const Text('配置'),
        subtitle: Text(draftDirty ? '未保存的修改' : '账号、节点选择与健康探针'),
        childrenPadding: const EdgeInsets.all(16),
        children: [configuration],
      )),
      Card(child: ExpansionTile(
        key: const ValueKey('corplink-advanced'),
        leading: const Icon(Icons.warning_amber_outlined), title: const Text('高级操作'),
        subtitle: const Text('强制重连、重新授权'),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          if (draftDirty) const Padding(padding: EdgeInsets.only(bottom: 12),
              child: Text('请先保存或取消未提交修改，再执行高级操作。')),
          for (final node in selected) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(width: double.infinity, child: OutlinedButton(
              onPressed: busy || !enabled || draftDirty ? null : () => _confirmed(context,
                title: '重连 ${node.serverName}',
                message: '将中断这个节点的现有连接并重新建立隧道。其他节点不会被主动重连。',
                confirm: '确认重连', action: () => onReconnectNode(node.serverName),
              ),
              child: Text('重连 ${node.serverName}', textAlign: TextAlign.center),
            )),
          ),
          SizedBox(width: double.infinity, child: OutlinedButton(
            onPressed: busy || !enabled || draftDirty ? null : () => _confirmed(context,
              title: '重新授权',
              message: '将使用已保存的账号重新登录并应用配置，飞连连接可能短暂中断。不会提交编辑中的草稿。',
              confirm: '确认重新授权', action: onReauthorize,
            ),
            child: const Text('重新授权'),
          )),
        ],
      )),
    ]);
  }
}

class _CorplinkNodeCard extends StatelessWidget {
  const _CorplinkNodeCard({required this.node, required this.status,
      required this.probe, required this.ipChanges});
  final CorplinkNodeSelection node;
  final SgCoreStatus? status;
  final CorplinkProbeSnapshot? probe;
  final int ipChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = status?.phase;
    final label = switch (phase) {
      SgConnectionPhase.ready => '已连接',
      SgConnectionPhase.needsRebuild => '需要恢复',
      SgConnectionPhase.connecting => '连接中',
      SgConnectionPhase.waitingForTraffic => '等待握手',
      SgConnectionPhase.missing || null => '未创建',
    };
    final ready = phase == SgConnectionPhase.ready;
    final color = ready ? Colors.green : theme.colorScheme.error;
    final hasProbe = effectiveCorplinkNodeProbeUrl(node).isNotEmpty;
    final probeLabel = !hasProbe ? '未设置网站探针' : probe == null ? '网站尚未检测'
        : '上次 HTTPS：${probe!.success ? '有响应' : '失败'} · ${CorplinkManagementPanel._time(probe!.checkedAt)}';
    return Card(child: ExpansionTile(
      title: Row(children: [
        Expanded(child: Text(node.serverName, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall)),
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: color)),
      ]),
      subtitle: Padding(padding: const EdgeInsets.only(top: 6), child: Text(probeLabel,
          style: theme.textTheme.bodySmall)),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [Align(alignment: Alignment.centerLeft, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status?.tunnelIp.isNotEmpty == true) SelectableText('隧道 IP：${status!.tunnelIp}'),
          if (status?.endpoint.isNotEmpty == true) ...[
            const Text('上游端点'), SelectableText(status!.endpoint),
          ],
          Text('本页 IP 变化：$ipChanges 次'),
          if (status?.routesPresent == true) ...[
            Text('下发分流路由：${status!.routeSplit.length} 条'),
            for (final route in status!.routeSplit) SelectableText(route),
            Text('全隧道路由：${status!.routeFull.length} 条，不自动加入分流'),
            TextButton.icon(onPressed: () async {
              await Clipboard.setData(ClipboardData(text: status!.routeSplit.join('\n')));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制下发分流路由')));
            }, icon: const Icon(Icons.copy), label: const Text('复制下发分流路由')),
          ] else const Text('下发路由：尚未取得'),
          if (status != null && status!.routeInvalid > 0)
            Text('${status!.routeInvalid} 条无效路由未纳入列表'),
          if (hasProbe) const Text('响应只确认连通性，不代表业务授权成功；网站失败不会单独触发重连。'),
        ],
      ))],
    ));
  }
}
