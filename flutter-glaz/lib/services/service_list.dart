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
    'recordings',
    'Recordings',
    'Saves what Recorder hears, as WAV files',
    true,
  ),
  GlazService(
    'agent',
    'AI agent',
    'Your agent, which Assistant and Factchecker ask: any server with the '
        'OpenAI chat API',
    true,
  ),
  GlazService(
    'assistant',
    'Assistant',
    "Answers what you ask the glasses' Assistant, with the AI agent",
    true,
  ),
  GlazService(
    'factcheck',
    'Factchecker',
    "Checks the facts said around you, with the AI agent, for the "
        "glasses' Factchecker",
    true,
  ),
  GlazService(
    'translate',
    'Translate',
    "Translates what the other speaker says, on the phone, for the "
        "glasses' Translate",
    true,
  ),
  GlazService(
    'tuner',
    'Tuner',
    "Hears an instrument, with the phone's microphone or the glasses', "
        "and tells the glasses' Tuner the note",
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
  GlazService(
    'flipper',
    'Flipper screen',
    "A Flipper Zero's screen on the glasses, in Apps > Flipper",
    true,
  ),
  GlazService(
    'flipper_remote',
    'Flipper remote',
    "A Flipper Zero's Glaz app drives the glasses and shows their name, "
        'free space and app',
    true,
  ),
  GlazService(
    'term',
    'Terminal',
    'An SSH shell on the glasses, in Apps > Terminal; a keyboard on the '
        'phone types into it',
    true,
  ),
];
