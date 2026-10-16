import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything the user picks, kept across restarts.
class Settings extends ChangeNotifier {
  Settings(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

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

  /// Whether a module may know where the phone is. Off until allowed.
  bool locAllowed(String module) => _prefs.getBool('loc.$module') ?? false;
  void setLocAllowed(String module, bool on) => _set('loc.$module', on);

  /// Whether the Remote tab, while in front, turns the wearer's own gestures
  /// off but the triple tap and a waking tap.
  bool get remoteHandsOff => _prefs.getBool('remote.handsOff') ?? true;
  set remoteHandsOff(bool on) => _set('remote.handsOff', on);

  /// The bottom bar's tabs, in the user's order (by id); null until they
  /// rearrange it.
  List<String>? get tabOrder => _prefs.getStringList('tabs');
  set tabOrder(List<String>? ids) {
    if (ids == null) {
      _prefs.remove('tabs');
    } else {
      _prefs.setStringList('tabs', ids);
    }
    notifyListeners();
  }

  /// A module's setting (glasses_menu.dart, ModuleSetting); null = its
  /// default.
  String? config(String module, String key) =>
      _prefs.getString('cfg.$module.$key');
  void setConfig(String module, String key, String value) =>
      _set('cfg.$module.$key', value);

  void _set(String key, Object value) {
    if (value is bool) _prefs.setBool(key, value);
    if (value is String) _prefs.setString(key, value);
    notifyListeners();
  }
}
