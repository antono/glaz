/// Something the phone does on behalf of the Lua apps on the glasses.
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
    'Saves photos from Camera and Time series, by date',
    true,
  ),
  GlazService(
    'location',
    'Location',
    "Tells the apps you allow where the phone is",
    true,
  ),
  GlazService(
    'keys',
    'Keyboard remote',
    'Arrows, Space and Backspace on a Bluetooth keyboard or a Flipper '
        'Zero drive the glasses',
    true,
  ),
];
