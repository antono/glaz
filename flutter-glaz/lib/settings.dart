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
  /// off but the triple tap (sleep) and one or two taps on a blank screen.
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

  /// The language recordings are transcribed in, a BCP 47 tag
  /// (services/speech.dart); 'auto' is the phone's own.
  String get speechLanguage => _prefs.getString('speech.language') ?? 'auto';
  set speechLanguage(String tag) => _set('speech.language', tag);

  /// The assistant's agent (services/assistant.dart): an OpenAI-compatible
  /// server -- Hermes Agent's API server -- its key and its model. Phone
  /// only: none of it goes to the glasses.
  String get agentUrl => _prefs.getString('agent.url') ?? '';
  set agentUrl(String url) => _set('agent.url', url.trim());
  String get agentKey => _prefs.getString('agent.key') ?? '';
  set agentKey(String key) => _set('agent.key', key.trim());
  String get agentModel => _prefs.getString('agent.model') ?? 'hermes-agent';
  set agentModel(String model) => _set('agent.model', model.trim());

  /// The language the assistant hears questions in, a BCP 47 tag as
  /// [speechLanguage]; the recordings' until the user picks one.
  String get assistantLanguage =>
      _prefs.getString('agent.language') ?? speechLanguage;
  set assistantLanguage(String tag) => _set('agent.language', tag);

  /// Whether the assistant's answers are read aloud too -- in headphones
  /// only (services/voice.dart); off, they are on the glasses' screen only.
  bool get assistantSpeaks => _prefs.getBool('agent.speak') ?? true;
  set assistantSpeaks(bool on) => _set('agent.speak', on);

  /// Whether the agent may see Glaz's photos and recordings, and take a
  /// photo with the glasses (services/agent_files.dart).
  bool get agentFiles => _prefs.getBool('agent.files') ?? true;
  set agentFiles(bool on) => _set('agent.files', on);

  /// Whether the Lua console takes Lua from a computer too, over HTTP on
  /// the phone's loopback (services/glasses_lua.dart, LuaBridge). Off until
  /// asked for.
  bool get luaBridge => _prefs.getBool('lua.bridge') ?? false;
  set luaBridge(bool on) => _set('lua.bridge', on);

  /// Where the Reader is in its text: the number of the word on the
  /// glasses' screen (services/reader.dart).
  int get readerPlace => _prefs.getInt('reader.place') ?? 0;
  set readerPlace(int word) => _set('reader.place', word);

  /// A module's setting (glasses_menu.dart, ModuleSetting); null = its
  /// default.
  String? config(String module, String key) =>
      _prefs.getString('cfg.$module.$key');
  void setConfig(String module, String key, String value) =>
      _set('cfg.$module.$key', value);

  void _set(String key, Object value) {
    if (value is bool) _prefs.setBool(key, value);
    if (value is String) _prefs.setString(key, value);
    if (value is int) _prefs.setInt(key, value);
    notifyListeners();
  }
}
