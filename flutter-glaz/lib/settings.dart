import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything the user picks, kept across restarts.
class Settings extends ChangeNotifier {
  Settings(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  ThemeMode get themeMode =>
      ThemeMode.values.asNameMap()[_prefs.getString('theme')] ??
      ThemeMode.system;
  set themeMode(ThemeMode mode) => _set('theme', mode.name);

  /// A phone service. Notifications start off: they need a permission first.
  bool serviceOn(String id) =>
      _prefs.getBool('service.$id') ?? id != 'notifications';
  void setService(String id, bool on) => _set('service.$id', on);

  /// Whether a module (by its file name) is wanted on the glasses.
  bool installed(String module) => _prefs.getBool('app.$module') ?? true;
  void setInstalled(String module, bool on) => _set('app.$module', on);

  /// Whether a module may use the Internet through the phone. Off until the
  /// user says otherwise.
  bool netAllowed(String module) => _prefs.getBool('net.$module') ?? false;
  void setNetAllowed(String module, bool on) => _set('net.$module', on);

  void _set(String key, Object value) {
    if (value is bool) _prefs.setBool(key, value);
    if (value is String) _prefs.setString(key, value);
    notifyListeners();
  }
}
