/// Which Brilliant Labs glasses the link holds (docs/HALO.md).
///
/// Frame and Halo share the Lua service (7a230001-...), so the scan in
/// link.dart finds both. Two things tell them apart. Before connecting, the
/// name they advertise: "Frame 4F", "Halo 3C" ([fromName]); a hint, since
/// it may be missing or changed. Once connected, what their Lua service
/// holds: only Halo has the speaker's characteristic ([fromGatt], issue
/// #6). Frame's bootloader advertises "Frame Update" and has no Lua
/// service, so the scan never sees it.
enum GlassesModel {
  frame('Frame'),
  halo('Halo');

  const GlassesModel(this.label);

  /// The product's name, as the glasses advertise it.
  final String label;

  /// The model advertising [name], or null for a name that says nothing:
  /// none yet, or one the user gave the glasses in the phone's Bluetooth
  /// settings.
  static GlassesModel? fromName(String? name) {
    final n = name?.trim() ?? '';
    if (n.startsWith('Halo')) return halo;
    if (n.startsWith('Frame')) return frame;
    return null;
  }

  /// The model whose Lua service holds the characteristics [uuids] (as
  /// their 128-bit strings), or null when there is no Lua service among
  /// them: not discovered yet. Halo's has ...0005, the speaker's audio
  /// from the host, besides Frame's ...0002 and ...0003
  /// (ble_lua.h in halo-firmware).
  static GlassesModel? fromGatt(Iterable<String> uuids) {
    final all = {for (final u in uuids) u.toLowerCase()};
    if (all.contains(haloAudio)) return halo;
    if (all.contains(luaWrite)) return frame;
    return null;
  }

  /// The Lua service's REPL and data, written by the host: Frame's and
  /// Halo's.
  static const luaWrite = '7a230002-5475-a6a4-654c-8431f6ad49c4';

  /// Audio for Halo's speaker, written by the host (HALO_AUDIO_TX_UUID):
  /// Halo's only.
  static const haloAudio = '7a230005-5475-a6a4-654c-8431f6ad49c4';

  /// Whether its require() loads bytecode. Halo's loads text only
  /// (lua_file.c in halo-firmware), so Upload sends it source.
  bool get loadsBytecode => this == frame;
}
