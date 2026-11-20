import 'dart:async';

import 'package:bett_box/clash/core.dart';
import 'package:material_ui/material_ui.dart';

class NotebookView extends StatefulWidget {
  const NotebookView({super.key, this.readState, this.updateState});

  final Future<Map> Function()? readState;
  final Future<Map> Function(Map<String, Object?>)? updateState;

  static String title(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh'
      ? 'Notebook 检测'
      : 'Notebook check';

  @override
  State<NotebookView> createState() => _NotebookViewState();
}

class _NotebookViewState extends State<NotebookView> {
  Map _state = const {};
  Timer? _poll;
  bool _reading = false;
  bool _writing = false;
  bool _error = false;
  int _revision = 0;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String zh, String en) => _zh ? zh : en;
  List<Map> get _groups =>
      (_state['groups'] as List? ?? []).whereType<Map>().toList();

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_reading || _writing) return;
    _reading = true;
    final revision = _revision;
    try {
      final state = await (widget.readState ?? clashCore.getNotebook)();
      if (!mounted || revision != _revision) return;
      setState(() {
        _state = state;
        _error = state.isEmpty;
      });
    } catch (_) {
      if (mounted && revision == _revision && !_error) {
        setState(() => _error = true);
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _send(Map<String, Object?> change) async {
    if (_writing || _error) return;
    if (change['force'] == true) {
      if ((_state['profile'] as String? ?? '').isEmpty) return;
    } else if (_state['ready'] != true) {
      return;
    }
    _revision++;
    setState(() => _writing = true);
    try {
      final state = await (widget.updateState ?? clashCore.setNotebook)({
        'profile': _state['profile'],
        ...change,
      });
      if (mounted && state.isNotEmpty) setState(() => _state = state);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _text('配置提交失败，请刷新后重试', 'Could not save. Refresh and try again.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _writing = false);
        unawaited(_refresh());
      }
    }
  }

  Future<void> _editInterval() async {
    var input = '${_state['interval'] ?? 60}';
    String? error;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_text('检测周期（分钟）', 'Check interval (minutes)')),
          content: TextFormField(
            initialValue: input,
            onChanged: (value) => input = value,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: '1–1440', errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_text('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final value = int.tryParse(input.trim());
                if (value == null || value < 1 || value > 1440) {
                  update(() => error = _text('请输入 1–1440', 'Enter 1–1440'));
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: Text(_text('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (value != null && mounted) await _send({'interval': value});
  }

  Widget _groupTile(Map group) {
    final name = group['name'] as String;
    final watched = group['watched'] == true;
    final selector = group['type'] == 'Selector';
    final disabled = _writing || _error;
    final selected = group['selected'] as String? ?? '';
    final members = (group['members'] as List? ?? const []).whereType<Map>();
    return ExpansionTile(
      key: ValueKey(name),
      leading: Checkbox(
        semanticLabel: _text('关注 $name', 'Watch $name'),
        value: watched,
        onChanged: disabled
            ? null
            : (value) => _send({'group': name, 'watch': value}),
      ),
      title: Text(name),
      subtitle: Text(
        selected.isEmpty ? '${group['type']}' : '${group['type']} · $selected',
      ),
      initiallyExpanded: watched,
      children: [
        if (watched)
          SwitchListTile(
            title: Text(_text('失败时自动切换', 'Switch automatically on failure')),
            subtitle: selector
                ? null
                : Text(_text('此组由内核自动选路', 'This group is managed by the core')),
            value: selector && group['autoSwitch'] == true,
            onChanged: selector && !disabled
                ? (value) => _send({'group': name, 'autoSwitch': value})
                : null,
          ),
        if (watched && members.isEmpty)
          ListTile(title: Text(_text('等待候选节点', 'Waiting for candidates'))),
        if (watched)
          for (final member in members) _memberTile(member, selected),
      ],
    );
  }

  Widget _memberTile(Map member, String selected) {
    final name = member['name'] as String;
    final unsupported = member['unsupported'] == true;
    final available = member['verdict'] == 'available' && !unsupported;
    final status = available
        ? _text('检测通过', 'Check passed')
        : unsupported
        ? _text('Notebook 跳转到不支持页面', 'Notebook redirected to unsupported')
        : _text('暂无可用结果', 'No usable result');
    return ListTile(
      dense: true,
      selected: name == selected,
      contentPadding: const EdgeInsetsDirectional.only(start: 26, end: 18),
      leading: Tooltip(
        message: status,
        child: Icon(
          Icons.circle,
          size: 10,
          color: available
              ? Colors.green
              : Theme.of(context).colorScheme.outline,
        ),
      ),
      title: Text(name),
      trailing: available ? Text("${member['delay']} ms") : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final ready = _state['ready'] == true && !_error;
    final busy = _state['busy'] == true;
    final pending = _state['pending'] == true;
    final checked = DateTime.tryParse('${_state['checked'] ?? ''}')?.toLocal();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed:
                    !_error &&
                        !_writing &&
                        (_state['watchedCount'] as int? ?? 0) > 0
                    ? () => _send({'force': true})
                    : null,
                icon: const Icon(Icons.refresh),
                label: Text(_text('立即检测', 'Check now')),
              ),
              OutlinedButton(
                onPressed: ready && !_writing ? _editInterval : null,
                child: Text(
                  _text(
                    "周期 ${_state['interval'] ?? 60} 分钟",
                    "Every ${_state['interval'] ?? 60} min",
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error)
          TextButton(
            onPressed: _refresh,
            child: Text(_text('无法读取内核 · 重试', 'Core unavailable · Retry')),
          )
        else if (!ready)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _text('启动代理后可选择关注组', 'Start the proxy to choose groups to watch'),
            ),
          )
        else if (busy || pending || checked != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              pending
                  ? _text('已排队', 'Check queued')
                  : busy
                  ? _text('正在检测候选节点', 'Checking candidates')
                  : _text(
                      '上次检测 ${TimeOfDay.fromDateTime(checked!).format(context)}',
                      'Last check ${TimeOfDay.fromDateTime(checked).format(context)}',
                    ),
            ),
          ),
        if (ready)
          SwitchListTile(
            title: Text(_text('切换后通知', 'Notify after switching')),
            value: _state['notify'] == true,
            onChanged: _writing ? null : (value) => _send({'notify': value}),
          ),
        if (ready)
          Expanded(
            child: ListView.builder(
              itemCount: groups.length,
              itemBuilder: (_, index) => _groupTile(groups[index]),
            ),
          ),
      ],
    );
  }
}
