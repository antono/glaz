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

// Reader's speeds: words a minute, in the steps a tilt makes
// (modules/reader.lua, WPM_MIN to WPM_MAX by WPM_STEP).
const _wpm = [
  '100',
  '125',
  '150',
  '175',
  '200',
  '225',
  '250',
  '275',
  '300',
  '325',
  '350',
  '375',
  '400',
  '425',
  '450',
  '475',
  '500',
  '525',
  '550',
  '575',
  '600',
  '625',
  '650',
  '675',
  '700',
  '725',
  '750',
  '775',
  '800',
];
const _wpmLabels = [
  '100 wpm',
  '125 wpm',
  '150 wpm',
  '175 wpm',
  '200 wpm',
  '225 wpm',
  '250 wpm',
  '275 wpm',
  '300 wpm',
  '325 wpm',
  '350 wpm',
  '375 wpm',
  '400 wpm',
  '425 wpm',
  '450 wpm',
  '475 wpm',
  '500 wpm',
  '525 wpm',
  '550 wpm',
  '575 wpm',
  '600 wpm',
  '625 wpm',
  '650 wpm',
  '675 wpm',
  '700 wpm',
  '725 wpm',
  '750 wpm',
  '775 wpm',
  '800 wpm',
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
      'reader',
      'Reader',
      ModuleKind.app,
      Icons.speed,
      'Speed reading, a word at a time. Tap to pause, tilt for speed.',
      settings: [
        ModuleSetting.choice(
          'wpm',
          'Speed',
          '300',
          _wpm,
          optionLabels: _wpmLabels,
          help: 'Words a minute. A tilt while reading changes it too.',
        ),
      ],
    ),
    GlassesModule(
      'photo',
      'Camera',
      ModuleKind.app,
      Icons.photo_camera,
      'Tap to take a photo; it is sent to the phone.',
      settings: [
        ..._photoSettings,
        ModuleSetting.text(
          'aim_x',
          'Aim, across',
          initial: '261',
          help:
              'Where the cross for the photo\'s centre is, in display '
              'pixels from the left, 0 to 640. The camera sees about twice '
              'as wide as the display.',
        ),
        ModuleSetting.text(
          'aim_y',
          'Aim, down',
          initial: '327',
          help: 'From the top, 0 to 400.',
        ),
      ],
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
    GlassesModule(
      'flipper',
      'Flipper',
      ModuleKind.app,
      Icons.cast,
      "A Flipper Zero's screen, through the phone; its own buttons "
          'drive it.',
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
