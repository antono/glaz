import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/glasses_lua.dart';
import '../services/services.dart';
import '../theme.dart';

/// A Lua console on the glasses, inside their running app: type, Run, read
/// what it printed and returned. The names of the glasses' tables -- frame,
/// frame.display... -- come up as you type, asked of the glasses. A switch
/// opens the same console to a computer (LuaBridge).
class LuaScreen extends StatefulWidget {
  const LuaScreen({super.key});

  @override
  State<LuaScreen> createState() => _LuaScreenState();
}

class _Entry {
  _Entry(this.code);
  final String code;
  LuaAnswer? answer;
  String? failure;
}

class _LuaScreenState extends State<LuaScreen> {
  final _lua = Services.instance.lua;
  final _settings = Services.instance.settings;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _entries = <_Entry>[];
  final _history = <String>[];
  int? _back; // how far up the history Up has gone
  List<String> _suggestions = const [];
  int _asked = 0;

  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 13);

  @override
  void initState() {
    super.initState();
    _lua.forget();
    _input.addListener(_suggest);
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _before {
    final sel = _input.selection;
    final end = sel.isValid ? sel.baseOffset : _input.text.length;
    return _input.text.substring(0, end);
  }

  Future<void> _suggest() async {
    final ask = ++_asked;
    final found = await _lua.completions(_before);
    if (!mounted || ask != _asked) return;
    setState(() => _suggestions = found.take(30).toList());
  }

  void _complete(String name) {
    final before = _before;
    final after = _input.text.substring(before.length);
    final typed = RegExp(r'[A-Za-z0-9_.]*$').firstMatch(before)![0]!;
    final head = before.substring(0, before.length - typed.length) + name;
    _input.value = TextEditingValue(
      text: head + after,
      selection: TextSelection.collapsed(offset: head.length),
    );
  }

  Future<void> _run() async {
    final code = _input.text.trim();
    if (code.isEmpty) return;
    final entry = _Entry(code);
    setState(() {
      _entries.insert(0, entry);
      _history.remove(code);
      _history.insert(0, code);
      _back = null;
      _input.clear();
    });
    try {
      entry.answer = await _lua.run(code);
    } catch (e) {
      entry.failure = '$e'.replaceFirst('Exception: ', '');
    }
    // what ran may have made or changed globals
    _lua.forget();
    if (mounted) setState(() {});
  }

  void _up() {
    if (_history.isEmpty) return;
    final i = ((_back ?? -1) + 1).clamp(0, _history.length - 1);
    _back = i;
    _input.text = _history[i];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Widget _entry(_Entry e) {
    final a = e.answer;
    final Color color;
    final String text;
    if (e.failure != null) {
      color = FrameColors.orange;
      text = e.failure!;
    } else if (a == null) {
      color = FrameColors.grey;
      text = '...';
    } else {
      color = a.ok ? FrameColors.white : FrameColors.pink;
      text = a.text.isEmpty ? (a.ok ? 'ok' : 'error') : a.text;
    }
    return InkWell(
      onTap: () => _input.text = e.code,
      onLongPress: () => Clipboard.setData(ClipboardData(text: text)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '> ${e.code}',
              style: _mono.copyWith(color: FrameColors.skyBlue),
            ),
            SelectableText(text, style: _mono.copyWith(color: color)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: _settings,
          builder: (context, _) => SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.computer, color: FrameColors.skyBlue),
            title: const Text('Open to a computer'),
            subtitle: const Text(
              'Lua over adb: 127.0.0.1:${LuaBridge.port} on the phone '
              '(scripts/phone_lua.py)',
            ),
            value: _settings.luaBridge,
            onChanged: (on) => _settings.luaBridge = on,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Runs inside the app on the glasses. Try '
                      'frame.battery_level() or frame.file.space(). Tap an '
                      'entry to edit it again, hold to copy.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [for (final e in _entries) _entry(e)],
                ),
        ),
        if (_suggestions.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in _suggestions)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: ActionChip(
                      label: Text(s.split('.').last, style: _mono),
                      onPressed: () => _complete(s),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  style: _mono,
                  minLines: 1,
                  maxLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: const InputDecoration(
                    hintText: 'Lua',
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Previous',
                icon: const Icon(Icons.history),
                onPressed: _up,
              ),
              IconButton(
                tooltip: 'Run',
                icon: const Icon(
                  Icons.play_arrow,
                  color: FrameColors.lightGreen,
                ),
                onPressed: _run,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
