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

/// One setting of a module, edited on the phone and read on the glasses
/// with _M.host.setting(key, default) (docs/PROTOCOL.md, "Settings").
/// Values travel as text; [initial] is the module's own default.
class ModuleSetting {
  /// One of [options], shown with [optionLabels] when given.
  const ModuleSetting.choice(
    this.key,
    this.label,
    this.initial,
    this.options, {
    this.optionLabels,
    this.help,
  }) : text = false;

  /// Free text, e.g. a city.
  const ModuleSetting.text(this.key, this.label, {this.initial = '', this.help})
    : text = true,
      options = const [],
      optionLabels = null;

  final String key;
  final String label;
  final String initial;
  final bool text;
  final List<String> options;
  final List<String>? optionLabels;
  final String? help;

  String labelOf(String option) {
    final i = options.indexOf(option);
    return i < 0 || optionLabels == null ? option : optionLabels![i];
  }
}

const _photoSettings = [
  ModuleSetting.choice(
    'resolution',
    'Resolution',
    '512',
    ['256', '512', '720'],
    optionLabels: ['256 px', '512 px', '720 px'],
    help: 'Square. Bigger takes longer to send.',
  ),
  ModuleSetting.choice(
    'quality',
    'Quality',
    'MEDIUM',
    ['VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH'],
    optionLabels: ['Very low', 'Low', 'Medium', 'High', 'Very high'],
    help: 'JPEG quality. Higher is sharper and slower to send.',
  ),
];

class GlassesModule {
  const GlassesModule(
    this.id,
    this.label,
    this.kind,
    this.icon,
    this.summary, {
    this.network = false,
    this.location = false,
    this.settings = const [],
  });

  /// Asks where the phone is (docs/PROTOCOL.md, "Location"), so it needs
  /// the user's permission, on its settings page.
  final bool location;

  /// What can be set for it on the phone.
  final List<ModuleSetting> settings;

  /// Opens a settings page in the Menu tab.
  bool get configurable => settings.isNotEmpty || network || location;

  /// File name in ../modules/, without .lua.
  final String id;

  /// The label the glasses draw (_M.label).
  final String label;
  final ModuleKind kind;
  final IconData icon;
  final String summary;

  /// Uses the Internet through the phone (docs/PROTOCOL.md, "Internet"), so
  /// it asks for the user's permission in the Menu tab.
  final bool network;
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
    GlassesModule(
      'assistant',
      'Assistant',
      ModuleKind.app,
      Icons.assistant,
      'Tap, ask aloud, tap again: the agent answers. Tilt to page.',
      settings: [
        ModuleSetting.choice(
          'bits',
          'Quality',
          '16',
          ['8', '16'],
          optionLabels: ['8 bit', '16 bit, heard better'],
          help: '16 bit sends twice as much; on a busy link some is lost.',
        ),
      ],
    ),
    GlassesModule(
      'photo',
      'Camera',
      ModuleKind.app,
      Icons.photo_camera,
      'Tap to take a photo; it is sent to the phone.',
      settings: _photoSettings,
    ),
    GlassesModule(
      'timeseries',
      'Time series',
      ModuleKind.background,
      Icons.burst_mode,
      'A photo every 1 to 60 seconds, sent to the phone.',
      settings: [
        ModuleSetting.choice(
          'interval',
          'Interval',
          '4',
          ['1', '2', '4', '8', '10', '20', '30', '40', '60'],
          optionLabels: [
            '1 s',
            '2 s',
            '4 s',
            '8 s',
            '10 s',
            '20 s',
            '30 s',
            '40 s',
            '60 s',
          ],
          help: 'Where a new series starts; tilt changes it while shooting.',
        ),
        ..._photoSettings,
      ],
    ),
    GlassesModule(
      'recorder',
      'Recorder',
      ModuleKind.background,
      Icons.mic,
      'Tap to record; the sound goes to the Recordings tab.',
      settings: [
        ModuleSetting.choice(
          'bits',
          'Quality',
          '8',
          ['8', '16'],
          optionLabels: ['Speech, 8 bit', 'Better, 16 bit'],
          help: '16 bit sends twice as much; on a busy link some is lost.',
        ),
      ],
    ),
    GlassesModule(
      'stopwatch',
      'Stopwatch',
      ModuleKind.background,
      Icons.timer,
      'Tap to start or pause, tilt to reset.',
    ),
    GlassesModule(
      'files',
      'Files',
      ModuleKind.app,
      Icons.folder,
      'Browse and preview the files stored on the glasses.',
    ),
    GlassesModule(
      'weather',
      'Weather',
      ModuleKind.app,
      Icons.cloud,
      'The weather where the phone is, fetched by the phone.',
      network: true,
      location: true,
      settings: [
        ModuleSetting.text(
          'city',
          'City',
          help:
              "Empty: wherever the phone is -- its GPS with Location "
              'access, else a guess from its Internet address.',
        ),
        ModuleSetting.text(
          'country',
          'Country',
          help: 'Optional, to tell same-named cities apart.',
        ),
      ],
    ),
  ]),
  MenuSection('Sensors', Icons.sensors, [
    GlassesModule(
      'battery',
      'Battery',
      ModuleKind.info,
      Icons.battery_full,
      'Charge level, in percent.',
    ),
    GlassesModule(
      'tilt',
      'Tilt',
      ModuleKind.app,
      Icons.screen_rotation,
      'Live head orientation: pitch and roll.',
    ),
    GlassesModule(
      'taptune',
      'Tap tune',
      ModuleKind.app,
      Icons.touch_app,
      'Tune how hard a tap has to be. Needs custom firmware.',
    ),
  ]),
  MenuSection('Settings', Icons.tune, [
    GlassesModule(
      'brightness',
      'Brightness',
      ModuleKind.app,
      Icons.brightness_6,
      'Tilt to preview a level, tap to keep it.',
    ),
    GlassesModule(
      'sleep',
      'Sleep',
      ModuleKind.app,
      Icons.bedtime,
      'Deep sleep now, until the next tap.',
    ),
  ]),
  MenuSection('Info', Icons.info_outline, [
    GlassesModule(
      'notifications',
      'Notifications',
      ModuleKind.app,
      Icons.notifications,
      'The last phone notifications; tilt to page.',
    ),
    GlassesModule(
      'bluetooth',
      'Bluetooth',
      ModuleKind.app,
      Icons.bluetooth,
      'Link status, MAC address and packet size.',
    ),
    GlassesModule(
      'uptime',
      'Uptime',
      ModuleKind.info,
      Icons.schedule,
      'Time since the glasses were switched on.',
    ),
    GlassesModule(
      'firmware',
      'Firmware',
      ModuleKind.info,
      Icons.memory,
      'The firmware version.',
    ),
    GlassesModule(
      'about',
      'About',
      ModuleKind.info,
      Icons.badge,
      'Name, version and author of the glasses app.',
    ),
  ]),
];
