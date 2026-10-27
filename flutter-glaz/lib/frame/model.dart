/// Which Brilliant Labs glasses the link holds (docs/HALO.md).
///
/// Frame and Halo share the Lua service (7a230001-...), so the scan in
/// link.dart finds both; the name they advertise tells them apart: "Frame
/// 4F", "Halo 1A2B". Frame's bootloader advertises "Frame Update" and has
/// no Lua service, so the scan never sees it.
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

  /// Whether the glasses app runs on them. Halo is found and named, but
  /// its display, camera, sleep and firmware update differ from Frame's
  /// (docs/HALO.md), and the bytecode Upload sends is Frame's: Upload,
  /// Restart, Files and Firmware stay off for Halo until glaz has a Halo
  /// build.
  bool get supported => this == frame;
}
