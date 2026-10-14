// What the phone knows about the glasses' apps and the services it offers
// them. For now this mirrors the MENU tree in ../frame_app.lua by hand; once
// the app can upload main.lua and modules itself, this becomes the source of
// that tree.

/// A module in ../modules/, one menu item on the glasses.
class GlazModule {
  const GlazModule(
    this.id,
    this.label,
    this.description, {
    this.network = false,
  });

  /// File name in modules/, without .lua.
  final String id;
  final String label;
  final String description;

  /// Uses the Internet through the phone, so it needs the user's permission.
  final bool network;
}

/// A submenu on the glasses.
class GlazSection {
  const GlazSection(this.label, this.apps);
  final String label;
  final List<GlazModule> apps;
}

const sections = [
  GlazSection('Apps', [
    GlazModule('photo', 'Camera', 'Take a photo and send it to the phone'),
    GlazModule(
      'timeseries',
      'Time series',
      'A photo every few seconds, sent to the phone',
    ),
    GlazModule('stopwatch', 'Stopwatch', 'Keeps counting in the background'),
    GlazModule('files', 'Files', 'Browse the files on the glasses'),
    GlazModule(
      'weather',
      'Weather',
      'The weather where the phone is',
      network: true,
    ),
  ]),
  GlazSection('Sensors', [
    GlazModule('battery', 'Battery', 'Charge level'),
    GlazModule('tilt', 'Tilt', 'Live head orientation'),
    GlazModule('taptune', 'Tap tune', 'Tune tap detection (custom firmware)'),
  ]),
  GlazSection('Settings', [
    GlazModule('bluetooth', 'Bluetooth', 'The Bluetooth link at a glance'),
    GlazModule('brightness', 'Brightness', 'Pick the display brightness'),
    GlazModule('sleep', 'Sleep', 'Put the glasses to sleep'),
  ]),
  GlazSection('Info', [
    GlazModule(
      'notifications',
      'Notifications',
      'The last phone notifications',
    ),
    GlazModule('uptime', 'Uptime', 'Time since boot'),
    GlazModule('firmware', 'Firmware', 'Firmware version'),
    GlazModule('about', 'About', 'Name, version, author'),
  ]),
];

/// Something the phone does on behalf of Lua apps on the glasses.
class GlazService {
  const GlazService(this.id, this.label, this.description, this.ready);
  final String id;
  final String label;
  final String description;

  /// True once this app implements it; the rest are shown as planned.
  final bool ready;
}

const services = [
  GlazService('clock', 'Clock', 'Sets the time in the top bar', true),
  GlazService(
    'notifications',
    'Notifications',
    'Shows phone notifications on the glasses',
    true,
  ),
  GlazService(
    'network',
    'Internet',
    'Lets the apps you allow fetch data from the internet',
    true,
  ),
  GlazService(
    'photos',
    'Photos',
    'Receives photos from Camera and Time series',
    false,
  ),
  GlazService(
    'location',
    'Location',
    'Gives apps the phone\'s position',
    false,
  ),
];
