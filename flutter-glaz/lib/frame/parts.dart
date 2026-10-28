import 'package:flutter/services.dart';

import 'model.dart';

/// The glasses' parts (docs/DEVICES.md). name.lua is the same on every
/// pair of glasses; name.frame.lua and name.halo.lua are its parts, each
/// uploaded to its own glasses alone. A module goes only to glasses it has
/// a part for, and the Menu tab lists only those.

/// The glasses [file] (a file name, as reader.frame.lua) is a part for, or
/// null for a file that is the same on all of them (reader.lua,
/// data.min.lua).
GlassesModel? partFor(String file) {
  final parts = file.split('.');
  if (parts.length < 3 || parts.last != 'lua') return null;
  final suffix = parts[parts.length - 2];
  for (final m in GlassesModel.values) {
    if (m.name == suffix) return m;
  }
  return null;
}

/// [file] without its part's suffix and .lua: reader.frame.lua -> reader.
String stemOf(String file) {
  final name = file.replaceAll(RegExp(r'\.lua$'), '');
  final model = partFor(file);
  return model == null
      ? name
      : name.substring(0, name.length - model.name.length - 1);
}

/// The modules (file names, no .lua) with a part for [model], from the
/// app's assets (assets/lua/apps/).
Set<String> modulesFor(Iterable<String> assets, GlassesModel model) => {
  for (final a in assets)
    if (a.startsWith('assets/lua/apps/'))
      if (partFor(a.split('/').last) == model) stemOf(a.split('/').last),
};

/// Which modules each pair of glasses has, read once from the assets: for
/// the Menu tab and whatever else lists the glasses' apps.
class GlassesParts {
  GlassesParts(this._modules);

  final Map<GlassesModel, Set<String>> _modules;

  static Future<GlassesParts> load(AssetBundle bundle) async {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    final assets = manifest.listAssets().toList();
    return GlassesParts({
      for (final m in GlassesModel.values) m: modulesFor(assets, m),
    });
  }

  /// Whether [module] runs on [model]: it has a part for it.
  bool has(String module, GlassesModel model) =>
      _modules[model]?.contains(module) ?? false;

  /// The modules Upload sends to [model]: those [installed] that run there
  /// (luaFiles).
  Set<String> sentTo(GlassesModel model, bool Function(String) installed) => {
    for (final m in _modules[model] ?? const <String>{})
      if (installed(m)) m,
  };
}
