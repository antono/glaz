import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/glaz_log.dart';
import '../theme.dart';

/// What the app and the glasses did: the link going up and down, what the
/// glasses printed (their errors with file and line), Upload's steps, the
/// assistant, and the messages between them. Newest first.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

/// What the list shows: everything but the messages, only problems, or
/// one kind.
enum _Filter {
  all,
  problems,
  link,
  glasses,
  task,
  assistant,
  translate,
  factcheck,
  message,
}

class _LogScreenState extends State<LogScreen> {
  final _log = GlazLog.instance;
  var _filter = _Filter.all;

  static String _label(_Filter f) => switch (f) {
    _Filter.all => 'All',
    _Filter.problems => 'Problems',
    _ => LogKind.values.byName(f.name).label,
  };

  bool _shows(LogEntry e) => switch (_filter) {
    // the messages are many; they have a filter of their own
    _Filter.all => e.kind != LogKind.message,
    _Filter.problems => e.problem,
    _ => e.kind.name == _filter.name,
  };

  static String _time(DateTime t) =>
      [t.hour, t.minute, t.second].map((n) => '$n'.padLeft(2, '0')).join(':');

  static String _day(DateTime t) =>
      '${t.year}-${'${t.month}'.padLeft(2, '0')}-${'${t.day}'.padLeft(2, '0')}';

  Future<void> _copy(List<LogEntry> shown) async {
    final text = shown.reversed
        .map(
          (e) =>
              '${_day(e.at)} ${_time(e.at)} ${e.kind.label}'
              '${e.problem ? ' !' : ''}: ${e.text}',
        )
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied ${shown.length} entries')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _log,
      builder: (context, _) {
        final shown = _log.entries.where(_shows).toList().reversed.toList();
        return Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final f in _Filter.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(_label(f)),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${shown.length} entries',
                      style: text.bodySmall?.copyWith(color: FrameColors.grey),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: shown.isEmpty ? null : () => _copy(shown),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                  TextButton.icon(
                    onPressed: _log.entries.isEmpty ? null : _log.clear,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing yet',
                        style: text.bodyMedium?.copyWith(
                          color: FrameColors.grey,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final e = shown[i];
                        final newDay =
                            i == shown.length - 1 ||
                            _day(shown[i + 1].at) != _day(e.at);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: newDay
                                        ? '${_day(e.at)} ${_time(e.at)}  '
                                        : '${_time(e.at)}  ',
                                  ),
                                  TextSpan(
                                    text: e.kind.label,
                                    style: TextStyle(
                                      color: e.problem
                                          ? scheme.error
                                          : FrameColors.skyBlue,
                                    ),
                                  ),
                                ],
                              ),
                              style: text.labelSmall?.copyWith(
                                color: FrameColors.grey,
                              ),
                            ),
                            SelectableText(
                              e.text,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: e.problem ? scheme.error : null,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
