import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_ble/frame_ble.dart';

import 'protocol.dart';

enum LinkState { disconnected, scanning, connecting, connected }

/// The Bluetooth link to the glasses. Connecting does not interrupt
/// main.lua: no break or reset is sent, the app on the glasses simply gains
/// a host. Messages from the glasses arrive on [events], whole, code first.
class FrameLink extends ChangeNotifier {
  LinkState state = LinkState.disconnected;
  String? name;
  String? error;

  /// From the glasses' STATUS answer; null until the first one.
  int? battery;
  String? firmware;

  /// A job that has the glasses to itself (Upload, Restart): its name, the
  /// step it is on, and how far along, 0..1 (null: unknown). [taskError] is
  /// the last one's failure, cleared when the next starts.
  String? task;
  String taskStep = '';
  double? taskProgress;
  String? taskError;

  static const statusEvery = Duration(minutes: 1);
  Timer? _statusTimer;

  BrilliantDevice? _device;
  StreamSubscription<List<int>>? _data;
  StreamSubscription<BrilliantDevice>? _conn;
  final _events = StreamController<List<int>>.broadcast();

  /// Called each time the link comes up, including after a reconnect.
  final List<Future<void> Function()> onConnected = [];

  Stream<List<int>> get events => _events.stream;
  bool get connected => state == LinkState.connected;
  bool get busy => task != null;

  void _set(LinkState s) {
    state = s;
    notifyListeners();
  }

  Future<void> connect() async {
    if (state != LinkState.disconnected) return;
    error = null;
    try {
      await _connect(const Duration(seconds: 15));
    } catch (e) {
      error = '$e';
      _set(LinkState.disconnected);
    }
  }

  /// Connects again from inside a task, after [release]: the glasses come
  /// back from a reboot (new firmware) and are looked for anew. Throws if
  /// they do not show up within [timeout].
  Future<void> reconnect(Duration timeout) async {
    _set(LinkState.disconnected);
    try {
      await _connect(timeout);
    } catch (_) {
      _set(LinkState.disconnected);
      rethrow;
    }
  }

  /// Gives up the link entirely, auto-reconnect included, so the radio is
  /// free for another connection -- the DFU bootloader. flutter_blue_plus
  /// runs one connect at a time, and frame_ble's reconnect to glasses that
  /// are gone ties it up for 30 s per attempt, over and over (seen: the
  /// bootloader timed out waiting behind it).
  Future<void> release() async {
    await _conn?.cancel();
    _conn = null;
    final device = _device;
    _detach(LinkState.disconnected);
    try {
      await device?.disconnect();
    } catch (_) {}
  }

  /// Scan for the glasses running their app -- service 7a230001 only, so
  /// the DFU bootloader (fe59) is never taken for them -- and connect.
  Future<void> _connect(Duration timeout) async {
    _set(LinkState.scanning);
    await BrilliantBluetooth.requestPermission();
    final scanned = await _scanForApp(timeout);
    if (state != LinkState.scanning) return; // cancelled meanwhile
    _set(LinkState.connecting);
    final device = await BrilliantBluetooth.connect(scanned);
    if (device.state != BrilliantConnectionState.connected) {
      await device.disconnect();
      throw Exception('the glasses are in update mode');
    }
    // frame_ble reconnects by itself on Android and reports it here
    _conn = device.connectionState.listen((d) {
      if (d.state == BrilliantConnectionState.connected) {
        _attach(d);
      } else {
        _detach(LinkState.connecting);
      }
    });
    _attach(device);
  }

  static Future<BrilliantScannedDevice> _scanForApp(Duration timeout) async {
    final found = Completer<BrilliantScannedDevice>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isNotEmpty && !found.isCompleted) {
        final r = results.reduce((a, b) => a.rssi >= b.rssi ? a : b);
        found.complete(BrilliantScannedDevice(device: r.device, rssi: r.rssi));
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')],
        timeout: timeout,
      );
      return await found.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException('no glasses found'),
      );
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  void _attach(BrilliantDevice device) {
    _data?.cancel();
    _device = device;
    name = device.device.advName.isEmpty
        ? device.device.platformName
        : device.device.advName;
    _data = device.dataResponse.listen((m) {
      if (m.isNotEmpty && m[0] == status) onStatus(m);
      _events.add(m);
    });
    _set(LinkState.connected);
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(statusEvery, (_) {
      if (!busy) requestStatus();
    });
    // during a task the app is stopped; runTask greets it when done
    if (!busy) _greet();
  }

  void _greet() {
    for (final f in onConnected) {
      f();
    }
    requestStatus();
  }

  /// Ask for battery and firmware; the answer comes as STATUS. One byte of
  /// payload, because frame_ble sends nothing for an empty one.
  Future<void> requestStatus({bool duringTask = false}) =>
      send(statusGet, [0], duringTask: duringTask);

  /// [0x1B, battery %, firmware version...]; 255 = not sampled yet.
  @visibleForTesting
  void onStatus(List<int> m) {
    if (m.length < 2) return;
    battery = m[1] == 255 ? battery : m[1];
    if (m.length > 2) firmware = ascii.decode(m.sublist(2), allowInvalid: true);
    notifyListeners();
  }

  /// Runs [job] with the glasses to itself. Messages to the running app
  /// are held back meanwhile: the app is stopped while the job runs. When
  /// it ends the app is greeted again as on a fresh connect.
  Future<void> runTask(
    String name,
    Future<void> Function(
      BrilliantDevice device,
      void Function(String step, [double? progress]) report,
    )
    job,
  ) async {
    final device = _device;
    if (device == null || busy) return;
    task = name;
    taskStep = '';
    taskProgress = null;
    taskError = null;
    notifyListeners();
    try {
      await job(device, (step, [progress]) {
        taskStep = step;
        taskProgress = progress;
        notifyListeners();
      });
    } catch (e) {
      taskError = '$e';
    } finally {
      task = null;
      notifyListeners();
    }
    if (connected) _greet();
  }

  void _detach(LinkState next) {
    _statusTimer?.cancel();
    _statusTimer = null;
    _data?.cancel();
    _data = null;
    _device = null;
    _set(next);
  }

  Future<void> disconnect() async {
    // stop listening first, or frame_ble would reconnect
    await _conn?.cancel();
    _conn = null;
    final device = _device;
    _detach(LinkState.disconnected);
    try {
      await BrilliantBluetooth.stopScan();
      await device?.disconnect();
    } catch (_) {}
  }

  // One message at a time, and a gap between two of the same code: the
  // glasses keep only one finished message per code until their main loop
  // collects it (docs/PROTOCOL.md, "One message per code at a time").
  static const sameCodeGap = Duration(milliseconds: 200);
  Future<void> _tail = Future.value();
  final _lastSent = <int, DateTime>{};

  /// [duringTask]: send even while a task has the glasses -- for a task
  /// that has started the app again itself.
  Future<void> send(int code, List<int> payload, {bool duringTask = false}) {
    final job = _tail.then((_) async {
      final device = _device;
      // nothing for the app while a task has stopped it: a data packet's
      // answer would be taken for the REPL's
      if (device == null || (busy && !duringTask)) return;
      final last = _lastSent[code];
      if (last != null) {
        final wait = sameCodeGap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future.delayed(wait);
      }
      await device.sendMessage(code, Uint8List.fromList(payload));
      _lastSent[code] = DateTime.now();
    });
    _tail = job.catchError((_) {});
    return job;
  }

  /// The wall clock for the top bar: unix time and the UTC offset.
  Future<void> sendClock() {
    final now = DateTime.now();
    final bytes = ByteData(6)
      ..setUint32(0, now.millisecondsSinceEpoch ~/ 1000)
      ..setInt16(4, now.timeZoneOffset.inMinutes);
    return send(clockSet, bytes.buffer.asUint8List());
  }
}
