// The Flipper Zero's RPC, the few messages the screen mirror needs, by hand:
// four messages do not need protoc. See ../../docs/FLIPPER.md.
//
// Over USB and Bluetooth alike the RPC is a stream of PB_Main messages
// (flipperzero-protobuf, flipper.proto), each after its length as a varint.

import 'dart:typed_data';

/// PB_Main's fields (flipper.proto).
const mainCommandId = 1;
const mainCommandStatus = 2;
const mainHasNext = 3;
const mainEmpty = 4;
const mainStopSession = 19;
const mainStartScreenStream = 20;
const mainStopScreenStream = 21;
const mainScreenFrame = 22;
const mainSendInputEvent = 23;

/// PB_Gui.InputKey.
enum FlipperKey { up, down, right, left, ok, back }

/// PB_Gui.InputType. A press goes [press], then [short] or [long], then
/// [release]: the firmware drops an event with no press before it.
enum FlipperInput { press, release, short, long, repeat }

/// PB_Gui.ScreenOrientation.
const orientationHorizontal = 0;
const orientationHorizontalFlip = 1;

/// The screen: 128x64, one bit a pixel.
const screenW = 128;
const screenH = 64;
const frameBytes = screenW * screenH ~/ 8;

/// The glasses' rows: [screenW] pixels in this many bytes.
const rowBytes = screenW ~/ 8;

/// A row as it goes to the glasses: a nibble a byte.
const rowNibbles = rowBytes * 2;

List<int> varint(int n) {
  final out = <int>[];
  while (n >= 0x80) {
    out.add((n & 0x7F) | 0x80);
    n >>= 7;
  }
  out.add(n);
  return out;
}

List<int> _key(int field, int wireType) => varint(field << 3 | wireType);

List<int> _bytesField(int field, List<int> bytes) => [
  ..._key(field, 2),
  ...varint(bytes.length),
  ...bytes,
];

List<int> _varintField(int field, int value) => [
  ..._key(field, 0),
  ...varint(value),
];

/// One PB_Main with [commandId] and its content [field] holding [body],
/// length first: ready to write.
Uint8List mainMessage(int commandId, int field, [List<int> body = const []]) {
  final msg = [
    ..._varintField(mainCommandId, commandId),
    ..._bytesField(field, body),
  ];
  return Uint8List.fromList([...varint(msg.length), ...msg]);
}

Uint8List startScreenStream(int commandId) =>
    mainMessage(commandId, mainStartScreenStream);

Uint8List stopScreenStream(int commandId) =>
    mainMessage(commandId, mainStopScreenStream);

Uint8List inputEvent(int commandId, FlipperKey key, FlipperInput type) =>
    mainMessage(commandId, mainSendInputEvent, [
      ..._varintField(1, key.index),
      ..._varintField(2, type.index),
    ]);

/// A PB_Main as it came: the fields the mirror reads.
class FlipperMessage {
  FlipperMessage(this.commandId, this.status, this.content, this.body);

  final int commandId;

  /// PB.CommandStatus; 0 is OK.
  final int status;

  /// Which of the content's fields it holds, 0 for none.
  final int content;
  final Uint8List body;

  bool get isFrame => content == mainScreenFrame;
}

/// A screen frame: [data] as the Flipper keeps it, and [orientation].
class ScreenFrame {
  ScreenFrame(this.data, this.orientation);
  final Uint8List data;
  final int orientation;
}

/// Reads one field's key and value at [at]; null at the end. Values of wire
/// type 0 are ints, of type 2 byte lists; the others are skipped.
class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int at = 0;

  int varint() {
    var n = 0;
    var shift = 0;
    while (true) {
      if (at >= b.length) throw const FormatException('varint cut short');
      final c = b[at++];
      n |= (c & 0x7F) << shift;
      if (c & 0x80 == 0) return n;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
  }

  /// (field, value) or null at the end.
  (int, Object?)? next() {
    if (at >= b.length) return null;
    final key = varint();
    final field = key >> 3;
    switch (key & 7) {
      case 0:
        return (field, varint());
      case 1:
        at += 8;
        return (field, null);
      case 2:
        final n = varint();
        if (at + n > b.length) throw const FormatException('field cut short');
        final v = Uint8List.sublistView(b, at, at + n);
        at += n;
        return (field, v);
      case 5:
        at += 4;
        return (field, null);
      default:
        throw FormatException('wire type ${key & 7}');
    }
  }
}

FlipperMessage decodeMain(Uint8List b) {
  final r = _Reader(b);
  var id = 0;
  var status = 0;
  var content = 0;
  var body = Uint8List(0);
  for (var f = r.next(); f != null; f = r.next()) {
    final (field, value) = f;
    if (field == mainCommandId && value is int) {
      id = value;
    } else if (field == mainCommandStatus && value is int) {
      status = value;
    } else if (field >= mainEmpty && value is Uint8List) {
      content = field;
      body = value;
    }
  }
  return FlipperMessage(id, status, content, body);
}

ScreenFrame decodeFrame(Uint8List body) {
  final r = _Reader(body);
  var data = Uint8List(0);
  var orientation = 0;
  for (var f = r.next(); f != null; f = r.next()) {
    final (field, value) = f;
    if (field == 1 && value is Uint8List) data = value;
    if (field == 2 && value is int) orientation = value;
  }
  return ScreenFrame(data, orientation);
}

/// Bytes from the Flipper in, whole messages out. A Bluetooth packet is not
/// a message: a frame comes in several, and one may end mid-length.
class MessageSplitter {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<FlipperMessage> add(List<int> bytes) {
    _buf.add(_pending);
    _buf.add(bytes);
    var b = _buf.takeBytes();
    final out = <FlipperMessage>[];
    while (b.isNotEmpty) {
      final r = _Reader(b);
      final int n;
      try {
        n = r.varint();
      } on FormatException {
        break; // the length itself is not all here yet
      }
      if (r.at + n > b.length) break;
      out.add(decodeMain(Uint8List.sublistView(b, r.at, r.at + n)));
      b = Uint8List.sublistView(b, r.at + n);
    }
    _pending = Uint8List.fromList(b);
    return out;
  }

  void clear() => _pending = Uint8List(0);
}

/// The Flipper's frame as the glasses draw sprites: [screenH] rows of
/// [rowBytes], first pixel in the high bit. The Flipper keeps its screen as
/// u8g2 does, in pages: byte (y ~/ 8) * 128 + x holds 8 pixels down, the
/// top one in the low bit. A set bit is a dark pixel on the Flipper, a lit
/// one on the glasses. [orientation] [orientationHorizontalFlip] turns it
/// round; the upright ones are drawn as the screen has them.
Uint8List toRows(List<int> page, [int orientation = orientationHorizontal]) {
  if (page.length < frameBytes) {
    throw FormatException('a frame of ${page.length} bytes');
  }
  final flip = orientation == orientationHorizontalFlip;
  final out = Uint8List(frameBytes);
  for (var y = 0; y < screenH; y++) {
    for (var x = 0; x < screenW; x++) {
      if (page[(y >> 3) * screenW + x] & (1 << (y & 7)) == 0) continue;
      final ox = flip ? screenW - 1 - x : x;
      final oy = flip ? screenH - 1 - y : y;
      out[oy * rowBytes + (ox >> 3)] |= 0x80 >> (ox & 7);
    }
  }
  return out;
}

/// What the glasses get for [rows] when they show [shown]: a mask of the
/// rows that changed, 8 bytes, row 0 in the high bit of the first, and
/// those rows, [rowNibbles] bytes each: a nibble a byte, high one first.
/// The glasses widen a nibble with a table of 16 (modules/flipper.lua); a
/// table for whole bytes took more of their memory than they have to spare.
/// Everything when [shown] is null. Null when nothing changed.
Uint8List? rowsUpdate(Uint8List rows, Uint8List? shown) {
  final mask = Uint8List(screenH ~/ 8);
  final body = BytesBuilder(copy: false);
  for (var y = 0; y < screenH; y++) {
    final row = Uint8List.sublistView(rows, y * rowBytes, (y + 1) * rowBytes);
    if (shown != null) {
      var same = true;
      for (var i = 0; i < rowBytes && same; i++) {
        same = row[i] == shown[y * rowBytes + i];
      }
      if (same) continue;
    }
    mask[y >> 3] |= 0x80 >> (y & 7);
    body.add([for (final b in row) ...[b >> 4, b & 15]]);
  }
  if (body.isEmpty) return null;
  return Uint8List.fromList([...mask, ...body.takeBytes()]);
}
