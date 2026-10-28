import '../frame/link.dart';
import '../frame/protocol.dart';

/// A scale for the glasses' Scales (apps/scales/scales.lua): [notes] in
/// semitones above the root, [flavour] the note that makes it what it is,
/// drawn green; [major] shows it against the major pentatonic, else the
/// minor one.
class GuitarScale {
  const GuitarScale(
    this.name,
    this.short,
    this.notes, {
    this.flavour,
    this.major = false,
  });

  final String name;

  /// Its label beside a board, six letters at most.
  final String short;
  final List<int> notes;
  final int? flavour;
  final bool major;
}

const minorPentatonic = GuitarScale('minor pent', 'm pent', [0, 3, 5, 7, 10]);
const _majorPentatonicNotes = [0, 2, 4, 7, 9];
const majorPentatonic = GuitarScale(
  'major pent',
  'M pent',
  _majorPentatonicNotes,
  major: true,
);

/// The scales, in the order the remote's Up and Down go through them.
/// They live here, not on the glasses: their memory holds one at a time.
const guitarScales = <GuitarScale>[
  minorPentatonic,
  GuitarScale('blues', 'blues', [0, 3, 5, 6, 7, 10], flavour: 6),
  GuitarScale('dorian', 'dorian', [0, 2, 3, 5, 7, 9, 10], flavour: 9),
  GuitarScale('phrygian', 'phryg', [0, 1, 3, 5, 7, 8, 10], flavour: 1),
  // Aeolian
  GuitarScale('minor', 'minor', [0, 2, 3, 5, 7, 8, 10], flavour: 8),
  GuitarScale('harm minor', 'harm', [0, 2, 3, 5, 7, 8, 11], flavour: 11),
  GuitarScale('mel minor', 'melod', [0, 2, 3, 5, 7, 9, 11], flavour: 11),
  GuitarScale('locrian', 'locr', [0, 1, 3, 5, 6, 8, 10], flavour: 6),
  majorPentatonic,
  GuitarScale(
    'major blues',
    'Mblues',
    [0, 2, 3, 4, 7, 9],
    flavour: 3,
    major: true,
  ),
  // Ionian
  GuitarScale(
    'major',
    'major',
    [0, 2, 4, 5, 7, 9, 11],
    flavour: 11,
    major: true,
  ),
  GuitarScale(
    'mixolydian',
    'mixo',
    [0, 2, 4, 5, 7, 9, 10],
    flavour: 10,
    major: true,
  ),
  GuitarScale(
    'lydian',
    'lydian',
    [0, 2, 4, 6, 7, 9, 11],
    flavour: 6,
    major: true,
  ),
  GuitarScale(
    'phryg dom',
    'ph dom',
    [0, 1, 4, 5, 7, 8, 10],
    flavour: 4,
    major: true,
  ),
];

String _hex(List<int> notes) => notes.map((n) => n.toRadixString(16)).join();

/// Scale [n] as the glasses take it (apps/scales/scales.lua, remote()):
/// `g<n> <count> <name>|<short>|<notes>|<flavour>|<base short>|<base notes>`,
/// a hex digit a note; the base empty for a pentatonic, shown alone. [n]
/// past the end wraps round.
String scaleAnswer(int n, [List<GuitarScale> scales = guitarScales]) {
  final i = n % scales.length;
  final s = scales[i];
  final base = s.major ? majorPentatonic : minorPentatonic;
  final alone = identical(s, base) || s.notes.length == 5;
  return 'g$i ${scales.length} ${s.name}|${s.short}|${_hex(s.notes)}|'
      '${s.flavour?.toRadixString(16) ?? ''}|'
      '${alone ? '' : base.short}|${alone ? '' : _hex(base.notes)}';
}

/// Answers the glasses' Scales: SCALE_GET [0x02, n] asks for scale n, and
/// it comes back as MODULE_CALL 'scales' (docs/PROTOCOL.md, "Scales").
class ScalesService {
  ScalesService(this.link, {void Function(String)? send})
    : _send = send ?? ((arg) => link.callModule('scales', arg));

  final FrameLink link;
  final void Function(String) _send;

  void attach() => link.events.listen(onMessage);

  void onMessage(List<int> m) {
    if (m.length < 2 || m[0] != scaleGet) return;
    _send(scaleAnswer(m[1]));
  }
}
