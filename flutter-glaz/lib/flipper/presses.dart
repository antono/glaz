import 'proto.dart';

export 'proto.dart' show FlipperKey;

/// The Flipper's keys, the RPC's own (proto.dart), in the order the Glaz
/// app numbers them, from 1 (flipper-glaz/src/link.rs). Not the RPC's
/// order: Left and Right are the other way round there.
const glazKeys = [
  FlipperKey.up,
  FlipperKey.down,
  FlipperKey.left,
  FlipperKey.right,
  FlipperKey.ok,
  FlipperKey.back,
];

/// How a key was pressed, from 1: let go quickly, held, or still held
/// and repeating.
enum FlipperPress { short, long, repeat }

/// One press, as the keys characteristic notifies it.
class FlipperKeyPress {
  const FlipperKeyPress(this.key, this.press);
  final FlipperKey key;
  final FlipperPress press;

  @override
  bool operator ==(Object other) =>
      other is FlipperKeyPress && other.key == key && other.press == press;

  @override
  int get hashCode => Object.hash(key, press);

  @override
  String toString() => '${key.name} ${press.name}';
}

/// A press as the Flipper sends it: 3 bytes, the version 1, the key and
/// the press. Null for anything else.
FlipperKeyPress? decodePress(List<int> bytes) {
  if (bytes.length != 3 || bytes[0] != 1) return null;
  final key = bytes[1] - 1;
  final press = bytes[2] - 1;
  if (key < 0 || key >= glazKeys.length) return null;
  if (press < 0 || press >= FlipperPress.values.length) return null;
  return FlipperKeyPress(glazKeys[key], FlipperPress.values[press]);
}

/// The glasses' input for a press (docs/PROTOCOL.md, "Remote"), as
/// KeyRemote (keys.dart) sends a keyboard's: left the previous item, right
/// the next; up and down their own pair, which a module may take (Scales)
/// and the glasses otherwise treat as previous and next; repeats step the
/// same way; OK selects, held the menu; Back goes back. Null: nothing for
/// the glasses. A long Back closes the Flipper's app.
List<int>? gestureFor(FlipperKeyPress p) => switch ((p.key, p.press)) {
  (FlipperKey.left, _) => const [2, 255],
  (FlipperKey.right, _) => const [2, 1],
  (FlipperKey.up, _) => const [3, 255],
  (FlipperKey.down, _) => const [3, 1],
  (FlipperKey.ok, FlipperPress.short) => const [1, 1],
  (FlipperKey.ok, FlipperPress.long) => const [1, 3],
  (FlipperKey.back, FlipperPress.short) => const [1, 2],
  _ => null,
};
