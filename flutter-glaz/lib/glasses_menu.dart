import 'package:flutter/material.dart';

/// What happens when an item is picked on the glasses (docs/PROTOCOL.md).
enum ModuleKind {
  /// Shows one value, then clears itself after a few seconds.
  info('one value'),

  /// Keeps running until a double tap, or a minute with no tap.
  app('app'),

  /// An app that keeps working after it leaves the screen.
  background('background');

  const ModuleKind(this.label);
  final String label;
}

class GlassesModule {
  const GlassesModule(this.id, this.label, this.kind, this.icon, this.summary);

  /// File name in ../modules/, without .lua.
  final String id;

  /// The label the glasses draw (_M.label).
  final String label;
  final ModuleKind kind;
  final IconData icon;
  final String summary;
}

class MenuSection {
  const MenuSection(this.label, this.icon, this.modules);
  final String label;
  final IconData icon;
  final List<GlassesModule> modules;
}

/// The menu as the glasses show it: the MENU tree in ../frame_app.lua.
///
/// The glasses own the menu; this copy only describes it. A test
/// (test/glasses_menu_test.dart) fails when the two drift apart.
const glassesMenu = <MenuSection>[
  MenuSection('Apps', Icons.apps, [
    GlassesModule('photo', 'Camera', ModuleKind.app, Icons.photo_camera,
        'Tap to take a photo; it is sent to the phone.'),
    GlassesModule('timeseries', 'Time series', ModuleKind.background,
        Icons.burst_mode, 'A photo every 1 to 60 seconds, sent to the phone.'),
    GlassesModule('stopwatch', 'Stopwatch', ModuleKind.background,
        Icons.timer, 'Tap to start or pause, tilt to reset.'),
    GlassesModule('files', 'Files', ModuleKind.app, Icons.folder,
        'Browse and preview the files stored on the glasses.'),
  ]),
  MenuSection('Sensors', Icons.sensors, [
    GlassesModule('battery', 'Battery', ModuleKind.info,
        Icons.battery_full, 'Charge level, in percent.'),
    GlassesModule('tilt', 'Tilt', ModuleKind.app, Icons.screen_rotation,
        'Live head orientation: pitch and roll.'),
    GlassesModule('taptune', 'Tap tune', ModuleKind.app, Icons.touch_app,
        'Tune how hard a tap has to be. Needs custom firmware.'),
  ]),
  MenuSection('Settings', Icons.tune, [
    GlassesModule('bluetooth', 'Bluetooth', ModuleKind.app,
        Icons.bluetooth, 'Link status, MAC address and packet size.'),
    GlassesModule('brightness', 'Brightness', ModuleKind.app,
        Icons.brightness_6, 'Tilt to preview a level, tap to keep it.'),
    GlassesModule('sleep', 'Sleep', ModuleKind.app, Icons.bedtime,
        'Deep sleep now, until the next tap.'),
  ]),
  MenuSection('Info', Icons.info_outline, [
    GlassesModule('uptime', 'Uptime', ModuleKind.info, Icons.schedule,
        'Time since the glasses were switched on.'),
    GlassesModule('firmware', 'Firmware', ModuleKind.info, Icons.memory,
        'The firmware version.'),
    GlassesModule('about', 'About', ModuleKind.info, Icons.badge,
        'Name, version and author of the glasses app.'),
  ]),
];
