import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/glaz_log.dart';

/// What the Flipper's Glaz app (flipper-glaz/) shows of the glasses.
/// Null: not known; no [name], no glasses connected.
class GlassesStatus {
  const GlassesStatus({this.name, this.diskFree, this.memFree, this.app});
  final String? name;
  final int? diskFree;
  final int? memFree;
  final String? app;
}

/// The status as the Flipper reads it (`Status::parse` in
/// flipper-glaz/src/main.rs): a version byte, 1, then fields as tag,
/// length, value -- 1 the name, 2 free disk and 3 free memory in bytes
/// as u32 little-endian, 4 the app. A field not known is left out.
List<int> encodeStatus(GlassesStatus s) {
  final out = <int>[1];
  void text(int tag, String? v) {
    if (v == null) return;
    // The Flipper's fonts are ASCII, and it keeps 23 bytes.
    final b = [for (final c in v.codeUnits.take(maxText)) c < 0x80 ? c : 0x3F];
    out.addAll([tag, b.length, ...b]);
  }

  void number(int tag, int? v) {
    if (v == null) return;
    final n = v.clamp(0, 0xFFFFFFFF);
    out.addAll([tag, 4, n & 0xFF, n >> 8 & 0xFF, n >> 16 & 0xFF, n >> 24]);
  }

  text(1, s.name);
  number(2, s.diskFree);
  number(3, s.memFree);
  text(4, s.app);
  return out;
}

const maxText = 23;

/// A way to the Flipper's Glaz app: the status goes one way. The service
/// is written against this, so tests give it a Flipper of their own.
abstract class FlipperStatusPort {
  /// Connects to a Flipper with the Glaz app open; false when there is
  /// none.
  Future<bool> open();
  Future<void> close();
  Future<void> write(List<int> bytes);

  /// Fires when an open link goes down by itself.
  Stream<void> get lost;
}

/// The glaz GATT service the Flipper's Glaz app adds beside its keyboard
/// (flipper-glaz/src/link.rs). The Flipper is paired with the phone as a
/// keyboard, named 'Control' and its name; the phone talks to it over the
/// same link, as a second client beside Android's own.
class FlipperStatusBle implements FlipperStatusPort {
  static final service = Guid('a96fe95e-083f-402e-8be1-a9d5235813ca');
  static final status = Guid('99a2eadd-2f24-4073-b412-56fc14ba5ecb');

  /// Names a Flipper's keyboard has: 'Control' and the Flipper's name.
  static const namePrefix = 'Control ';

  /// The status is written whole: the MTU must hold it (link.rs drops a
  /// write in pieces).
  static const mtu = 185;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _status;
  StreamSubscription<BluetoothConnectionState>? _state;
  final _lost = StreamController<void>.broadcast();

  @override
  Stream<void> get lost => _lost.stream;

  @override
  Future<bool> open() async {
    final List<BluetoothDevice> bonded;
    try {
      bonded = await FlutterBluePlus.bondedDevices;
    } catch (_) {
      return false; // not on this platform (iOS)
    }
    for (final d in bonded) {
      if (!d.platformName.startsWith(namePrefix)) continue;
      if (await _try(d)) return true;
    }
    return false;
  }

  Future<bool> _try(BluetoothDevice d) async {
    try {
      await d.connect(timeout: const Duration(seconds: 10));
    } catch (_) {
      return false; // not in range, or not in the Glaz app
    }
    try {
      if (Platform.isAndroid) await d.requestMtu(mtu);
      var char = _find(await d.discoverServices());
      if (char == null && Platform.isAndroid) {
        // Android keeps a paired device's services, as they were the
        // first time: from Remote, or an older Glaz app. Ask afresh.
        await d.clearGattCache();
        char = _find(await d.discoverServices());
      }
      if (char == null) {
        glazLog(LogKind.link, 'Flipper remote: ${d.platformName} has no Glaz');
        await d.disconnect();
        return false;
      }
      _device = d;
      _status = char;
      _state = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _device == d) {
          _device = null;
          _status = null;
          _lost.add(null);
        }
      });
      glazLog(
        LogKind.link,
        'Flipper remote: ${d.platformName}, mtu ${d.mtuNow}',
      );
      return true;
    } catch (e) {
      glazLog(LogKind.link, 'Flipper remote: $e', problem: true);
      try {
        await d.disconnect();
      } catch (_) {}
      return false;
    }
  }

  static BluetoothCharacteristic? _find(List<BluetoothService> services) =>
      services
          .where((s) => s.uuid == service)
          .firstOrNull
          ?.characteristics
          .where((c) => c.uuid == status)
          .firstOrNull;

  @override
  Future<void> write(List<int> bytes) async {
    await _status?.write(bytes);
  }

  @override
  Future<void> close() async {
    await _state?.cancel();
    _state = null;
    final d = _device;
    _device = null;
    _status = null;
    try {
      await d?.disconnect();
    } catch (_) {}
  }
}
