import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_ble/frame_ble.dart';

import '../services/glaz_log.dart';
import 'pairing.dart';
import 'protocol.dart';

/// Messages left out of the log: streams of pieces (sound, photos, web
/// requests, file listings) and the minute's battery check.
const _unlogged = {
  audioChunk,
  photoChunk,
  netRequest,
  files,
  fileData,
  statusGet,
  status,
  flipper,
};

/// A message for the log: its code's name and a look at its payload --
/// text if it is text, else the first bytes.
String describeMessage(int code, List<int> payload) {
  final name = codeNames[code] ?? '0x${code.toRadixString(16)}';
  if (payload.isEmpty) return name;
  final text = payload.every((b) => b == 10 || (b >= 32 && b < 127));
  final shown = text
      ? String.fromCharCodes(payload).replaceAll('\n', ' / ')
      : payload.take(12).join(' ') + (payload.length > 12 ? ' ...' : '');
  return '$name ${shown.length > 120 ? '${shown.substring(0, 120)}...' : shown}';
}

/// A message for the glasses in Bluetooth packets, as frame_ble's
/// sendMessage cuts it: each `0x01, code`, the first with the payload's
/// length after (two bytes, big-endian), and as much payload as fits in
/// [maxDataLength] + 1 bytes. No payload, no packets.
List<Uint8List> messagePackets(int code, List<int> payload, int maxDataLength) {
  final room = maxDataLength - 1;
  final out = <Uint8List>[];
  var at = 0;
  while (at < payload.length) {
    final first = at == 0;
    final n = min(payload.length - at, first ? room - 2 : room);
    out.add(
      Uint8List.fromList([
        0x01,
        code & 0xFF,
        if (first) ...[payload.length >> 8 & 0xFF, payload.length & 0xFF],
        ...payload.sublist(at, at + n),
      ]),
    );
    at += n;
  }
  return out;
}

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

  /// Whether the pairing has gone stale, and whose side must forget it;
  /// see pairing.dart. Set by [_watchDrops], cleared by an answer from the
  /// glasses or by [forgetPairing].
  PairingTrouble pairing = PairingTrouble.none;

  /// The glasses last found, kept while the link is down: what
  /// [forgetPairing] forgets.
  BluetoothDevice? _known;
  StreamSubscription<OnConnectionStateChangedEvent>? _drops;
  DateTime? _upAt;
  int _quickDrops = 0;
  bool _pairAfterConnect = false;

  /// The phone can drop its pairing itself on Android only.
  bool get canForgetPairing =>
      _known != null && defaultTargetPlatform == TargetPlatform.android;

  BrilliantDevice? _device;
  StreamSubscription<List<int>>? _data;

  /// data.lua on the glasses answers every packet it has taken with `0x00`
  /// (`0x01` when it failed). The firmware keeps one received packet until
  /// Lua takes it, and the next one overwrites it: a packet sent while Lua
  /// is busy -- drawing, collecting garbage -- was lost, and the message
  /// with it, and data.lua never found its end (docs/PROTOCOL.md, "One
  /// packet at a time"). So the next packet waits for the answer, at most
  /// [ackWait]; glasses that never answer (an older data.lua) are not waited
  /// for again until they do.
  static const ackWait = Duration(milliseconds: 500);
  Completer<void>? _ack;
  bool _acks = true;
  StreamSubscription<String>? _prints;
  StreamSubscription<BrilliantDevice>? _conn;
  final _events = StreamController<List<int>>.broadcast();

  /// Called each time the link comes up, including after a reconnect.
  final List<Future<void> Function()> onConnected = [];

  Stream<List<int>> get events => _events.stream;

  /// The glasses as connected now -- after a reconnect, not the device a
  /// task started with.
  BrilliantDevice? get device => _device;
  bool get connected => state == LinkState.connected;
  bool get busy => task != null;

  void _set(LinkState s) {
    if (s != state) {
      glazLog(LogKind.link, switch (s) {
        LinkState.scanning => 'looking for the glasses',
        LinkState.connecting => 'connecting',
        LinkState.connected => 'connected to ${name ?? 'the glasses'}',
        LinkState.disconnected => 'disconnected',
      });
    }
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
      glazLog(LogKind.link, 'could not connect: $e', problem: true);
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
    _known = scanned.device;
    _watchDrops();
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

  /// Every link up and down with the glasses, frame_ble's own reconnects
  /// included: a link that keeps going down right after coming up is a
  /// pairing that no longer holds (pairing.dart).
  void _watchDrops() {
    _drops ??= FlutterBluePlus.events.onConnectionStateChanged.listen((e) {
      if (e.device.remoteId != _known?.remoteId) return;
      if (e.connectionState == BluetoothConnectionState.connected) {
        _upAt = DateTime.now();
      } else if (e.connectionState == BluetoothConnectionState.disconnected) {
        // a connect that never came up is no drop: frame_ble retrying
        // glasses that are away, every 30 s
        final upAt = _upAt;
        _upAt = null;
        if (upAt != null) {
          final up = DateTime.now().difference(upAt);
          _quickDrops = up < quickDrop ? _quickDrops + 1 : 0;
        }
        _onDrop(e.device, e.device.disconnectReason?.code);
      }
    });
  }

  Future<void> _onDrop(BluetoothDevice device, int? code) async {
    if (busy || defaultTargetPlatform != TargetPlatform.android) return;
    var bonded = false;
    try {
      bonded = await device.bondState.first == BluetoothBondState.bonded;
    } catch (_) {}
    final trouble = pairingTrouble(
      bonded: bonded,
      code: code,
      quickDrops: _quickDrops,
    );
    glazLog(
      LogKind.link,
      'down, reason $code, bonded $bonded, quick drops $_quickDrops'
      '${trouble == PairingTrouble.none ? '' : ': pairing trouble, ${trouble.name}'}',
      problem: trouble != PairingTrouble.none,
    );
    if (trouble == PairingTrouble.none || trouble == pairing) return;
    pairing = trouble;
    // frame_ble would keep reconnecting, and the glasses keep refusing
    await disconnect();
    error = null;
    notifyListeners();
  }

  /// Forgets this phone's pairing with the glasses and connects again;
  /// Android then asks to pair. For [PairingTrouble.phoneStale]: the
  /// glasses forgot the phone, the phone has to forget them too.
  Future<void> forgetPairing() async {
    final device = _known;
    if (device == null) return;
    await disconnect();
    try {
      await device.removeBond();
    } catch (e) {
      error = 'could not forget the pairing: $e';
      notifyListeners();
      return;
    }
    pairing = PairingTrouble.none;
    _quickDrops = 0;
    _pairAfterConnect = true;
    notifyListeners();
    await connect();
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
    if (_pairAfterConnect) {
      // after forgetPairing: ask now, rather than on the first encrypted
      // read; Android shows its pairing dialog
      _pairAfterConnect = false;
      device.device.createBond().catchError((Object e) {
        glazLog(LogKind.link, 'pairing: $e', problem: true);
      });
    }
    _data?.cancel();
    _device = device;
    name = device.device.advName.isEmpty
        ? device.device.platformName
        : device.device.advName;
    _acks = true;
    _data = device.dataResponse.listen((m) {
      if (m.length == 1 && (m[0] == 0x00 || m[0] == 0x01)) {
        // data.lua's answer for a packet, not a message
        if (m[0] == 0x01) {
          glazLog(LogKind.link, 'the glasses failed a packet', problem: true);
        }
        _acks = true;
        _ack?.complete();
        _ack = null;
        return;
      }
      if (m.isNotEmpty && m[0] == status) onStatus(m);
      if (m.isNotEmpty && !_unlogged.contains(m[0])) {
        glazLog(LogKind.message, '<- ${describeMessage(m[0], m.sublist(1))}');
      }
      _events.add(m);
    });
    // what the app on the glasses prints: its errors, 'Frame app is
    // running'; a task's own REPL chatter is the task's business
    _prints?.cancel();
    _prints = device.stringResponse.listen((s) {
      if (busy) return;
      for (final line in s.split('\n')) {
        final l = line.trim();
        if (l.isEmpty || l == '\x02') continue;
        glazLog(
          LogKind.glasses,
          l,
          problem: RegExp(
            r'err|memory|attempt to',
            caseSensitive: false,
          ).hasMatch(l),
        );
      }
    });
    _set(LinkState.connected);
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(statusEvery, (_) {
      if (!busy) requestStatus();
    });
    _handsOffTimer?.cancel();
    _handsOffTimer = Timer.periodic(handsOffEvery, (_) {
      if (_handsOff != handsOffNone) send(handsOff, [_handsOff], log: false);
    });
    // during a task the app is stopped; runTask greets it when done
    if (!busy) _greet();
  }

  void _greet() {
    for (final f in onConnected) {
      f();
    }
    if (_handsOff != handsOffNone) send(handsOff, [_handsOff]);
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
    // the glasses answer: whatever the pairing was, it works
    pairing = PairingTrouble.none;
    _quickDrops = 0;
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
        // to the log, and the system log (adb logcat -s flutter), to see
        // what an upload did without looking at the phone
        if (step != taskStep) glazLog(LogKind.task, '$name: $step');
        taskStep = step;
        taskProgress = progress;
        notifyListeners();
      });
      glazLog(LogKind.task, '$name: done');
    } catch (e) {
      taskError = '$e';
      glazLog(LogKind.task, '$name failed: $e', problem: true);
    } finally {
      task = null;
      notifyListeners();
    }
    if (connected) _greet();
  }

  void _detach(LinkState next) {
    _statusTimer?.cancel();
    _statusTimer = null;
    _handsOffTimer?.cancel();
    _handsOffTimer = null;
    _data?.cancel();
    _data = null;
    _prints?.cancel();
    _prints = null;
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
      // between frame_ble's reconnects there is no BrilliantDevice, but a
      // connect may still be pending
      if (device == null) await _known?.disconnect();
    } catch (_) {}
  }

  // One message at a time, and a gap between two of the same code: the
  // glasses keep only one finished message per code until their main loop
  // collects it (docs/PROTOCOL.md, "One message per code at a time").
  static const sameCodeGap = Duration(milliseconds: 200);
  Future<void> _tail = Future.value();
  final _lastSent = <int, DateTime>{};

  /// [duringTask]: send even while a task has the glasses -- for a task
  /// that has started the app again itself. [log]: false keeps a stream of
  /// them (the Flipper's screen) out of the log.
  Future<void> send(
    int code,
    List<int> payload, {
    bool duringTask = false,
    bool log = true,
  }) {
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
      for (final packet in messagePackets(
        code,
        payload,
        device.maxDataLength!,
      )) {
        final ack = _acks ? (_ack = Completer<void>()) : null;
        await device.sendDataRaw(packet);
        if (ack == null) continue;
        await ack.future.timeout(
          ackWait,
          onTimeout: () {
            _ack = null;
            _acks = false;
            glazLog(LogKind.link, 'no answer for a packet; not waiting');
          },
        );
      }
      _lastSent[code] = DateTime.now();
      if (log && !_unlogged.contains(code)) {
        glazLog(LogKind.message, '-> ${describeMessage(code, payload)}');
      }
    });
    _tail = job.catchError((_) {});
    return job;
  }

  /// Whether the wearer's own gestures are off, and for whom
  /// (docs/PROTOCOL.md, "Remote"): [handsOffRemote] leaves the triple tap
  /// (sleep) and one or two taps on a blank screen, [handsOffKeyboard] the
  /// triple tap alone. Sent again on every connect and every
  /// [handsOffEvery]: the glasses drop it themselves when the link goes or
  /// it is not renewed.
  int get remoteHandsOff => _handsOff;
  int _handsOff = handsOffNone;
  Timer? _handsOffTimer;
  static const handsOffEvery = Duration(seconds: 15);
  set remoteHandsOff(int kind) {
    if (kind == _handsOff) return;
    _handsOff = kind;
    send(handsOff, [kind]);
  }

  /// The remote: [count] taps (1 select, 2 back, 3 the menu), as if on the
  /// arm (docs/PROTOCOL.md, "Remote").
  Future<void> remoteTaps(int count) => send(input, [1, count]);

  /// The remote: a tilt, as if toward a shoulder; [next] is right, the
  /// cursor down.
  Future<void> remoteTilt({required bool next}) =>
      send(input, [2, next ? 1 : 255]);

  /// The remote: take a photo, [size] px square, JPEG [quality] 1 (very
  /// low) to 5 (very high). It comes back as a Camera photo does.
  Future<void> remotePhoto(int size, int quality) =>
      send(photoTake, [size >> 8, size & 0xFF, quality]);

  /// Calls [module]'s remote([arg]) on the glasses (MODULE_CALL). A module
  /// not running is started in the background; the screen stays as it is.
  /// What [arg] means is up to the module.
  Future<void> callModule(String module, String arg) =>
      send(moduleCall, '$module\n$arg'.codeUnits);

  /// Puts [module] on the glasses' screen (APP_OPEN), as if picked in the
  /// menu. A non-empty [arg] goes to its start(), or to its remote() when
  /// it is not started again.
  Future<void> openModule(String module, [String arg = '']) =>
      send(appOpen, utf8.encode(arg.isEmpty ? module : '$module\n$arg'));

  /// The remote: start or stop Recorder on the glasses. The sound comes back
  /// as when recording is started on the glasses.
  Future<void> remoteRecord(bool on) =>
      callModule('recorder', on ? 'on' : 'off');

  /// The wall clock for the top bar: unix time and the UTC offset.
  Future<void> sendClock() {
    final now = DateTime.now();
    final bytes = ByteData(6)
      ..setUint32(0, now.millisecondsSinceEpoch ~/ 1000)
      ..setInt16(4, now.timeZoneOffset.inMinutes);
    return send(clockSet, bytes.buffer.asUint8List());
  }
}
