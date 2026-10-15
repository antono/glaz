import 'dart:async';
import 'dart:convert';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../glasses_menu.dart';
import '../settings.dart';

/// Every module's settings as the glasses take them (SETTINGS_SET, see
/// docs/PROTOCOL.md "Settings"): one 'module.key=value' line each, the
/// module's default where the user set nothing. The whole set every time,
/// so the glasses simply replace what they had.
String settingsText(Settings settings) {
  final lines = <String>[
    for (final section in glassesMenu)
      for (final m in section.modules)
        for (final s in m.settings)
          '${m.id}.${s.key}=${_clean(settings.config(m.id, s.key) ?? s.initial)}',
  ];
  return lines.join('\n');
}

/// One line per setting: no line breaks inside a value.
String _clean(String v) => v.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

/// Keeps the glasses' settings in step with the phone's: sent on every
/// connect, and after each change -- a moment later, so typing a city does
/// not send a message per letter.
class SettingsSync {
  SettingsSync(this.link, this.settings) {
    link.onConnected.add(() => _send(force: true));
    settings.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(debounce, _send);
    });
  }

  final FrameLink link;
  final Settings settings;

  static const debounce = Duration(milliseconds: 600);
  Timer? _debounce;
  String? _sent;

  Future<void> _send({bool force = false}) async {
    if (!link.connected) return;
    final text = settingsText(settings);
    if (!force && text == _sent) return;
    _sent = text;
    // UTF-8: a city may be Минск; the glasses only put it in a URL
    await link.send(settingsSet, utf8.encode(text));
  }
}
