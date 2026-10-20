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
  /// see pairing.dart. Set by [_onDrop], cleared by an answer from the
  /// glasses or by [forgetPairing].
  PairingTrouble pairing = PairingTrouble.none;

  /// The glasses last found, kept while the link is down: what
  /// [forgetPairing] forgets.
  BluetoothDevice? _known;
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

  // -- Keeping the link up ------------------------------------------------
  //
  // The app keeps the link itself (docs/PROTOCOL.md, "Keeping the link").
  // frame_ble's reconnect is not used: its connectionState took every
  // Bluetooth device's events for the glasses' -- the Flipper connecting
  // made the link look gone while it was up (seen: four minutes "connecting"
  // to glasses that were connected), and frame_ble then reconnected the
  // Flipper, with a year's timeout.

  /// The user wants the glasses connected: from [connect] until
  /// [disconnect], across restarts ([onRemember]). Every drop is followed
  /// by another go.
  bool get wanted => _wanted;
  bool _wanted = false;

  /// A task let go of the link ([release]) and takes it back ([reconnect]).
  bool _released = false;

  /// The glasses' Bluetooth id, kept across restarts ([onRemember]): a
  /// connect goes straight to them, no scan.
  String? knownId;

  /// The glasses' name as last seen: a connect straight to [knownId] gets
  /// none from Android, which only knows it from a scan or the pairing.
  String? knownName;

  /// Called with what to keep across restarts: the glasses' id, and
  /// whether the link is wanted.
  void Function(String? id, String? name, bool wanted)? onRemember;

  StreamSubscription<OnConnectionStateChangedEvent>? _states;
  StreamSubscription<BluetoothAdapterState>? _adapter;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  Timer? _retry;
  Future<void>? _trying;
  Future<void>? _bringing;

  /// The gaps between direct attempts, each at most [attemptTimeout]. Past
  /// the last the phone waits for the glasses instead (Android's
  /// autoConnect): it connects once they show up -- in range again, woken
  /// by a tap -- and costs nothing meanwhile.
  static const retryGaps = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
  ];
  static const attemptTimeout = Duration(seconds: 10);

  /// Waiting for the glasses, the wait is set up again this often: one
  /// Android dropped is not waited on forever.
  static const waitAgain = Duration(minutes: 10);

  /// With the link up and nothing from the glasses this long -- they
  /// answer STATUS every minute -- the log says so; past [silentReconnect]
  /// the link is dropped and made again: Android sometimes keeps one that
  /// carries nothing.
  static const silentAfter = Duration(seconds: 150);
  static const silentReconnect = Duration(minutes: 5);
  bool _silentLogged = false;

  // For the connection details (home_screen.dart) and the log.

  /// The attempt going on or last made since the link was last up.
  int attempt = 0;

  /// When the next attempt goes; null when none is set.
  DateTime? nextAttempt;

  /// Android connects as soon as the glasses show up (autoConnect).
  bool waitingForGlasses = false;

  DateTime? upSince;
  DateTime? downSince;

  /// Since the app started: links made, and lost without being asked.
  int connects = 0;
  int drops = 0;

  /// Why the link went down last: Android's code and its name.
  String? lastDrop;

  /// Anything from the glasses: a message, a print, a packet's answer.
  DateTime? lastHeard;

  int? rssi;
  int? mtu;

  /// Packets data.lua never answered ([ackWait]).
  int ackTimeouts = 0;

  /// At app start: the glasses kept from before, and whether the link was
  /// wanted then; wanted, it connects at once.
  void start({String? id, String? name, bool wanted = true}) {
    knownId = id;
    knownName = name;
    _adapter ??= FlutterBluePlus.adapterState.listen(_onAdapter);
    if (wanted) connect();
  }

  void _remember(String id) {
    if (id == knownId) return;
    knownId = id;
    onRemember?.call(id, knownName, _wanted);
  }

  void _onAdapter(BluetoothAdapterState s) {
    if (s == _adapterState) return;
    _adapterState = s;
    glazLog(LogKind.link, 'Bluetooth ${s.name}');
    if (s == BluetoothAdapterState.on) {
      if (_wanted && error == 'Bluetooth is off') error = null;
      if (_wanted) _kick();
    } else if (s == BluetoothAdapterState.off) {
      _retry?.cancel();
      nextAttempt = null;
      waitingForGlasses = false;
      if (_wanted) error = 'Bluetooth is off';
      _detach(LinkState.disconnected);
    }
  }

  Future<void> connect() async {
    _wanted = true;
    _released = false;
    error = null;
    attempt = 0;
    onRemember?.call(knownId, knownName, true);
    if (waitingForGlasses) {
      // Android's wait taken back, or a direct connect would meet it
      waitingForGlasses = false;
      try {
        await _known?.disconnect();
      } catch (_) {}
    }
    _kick();
    await _trying;
  }

  /// The next attempt, [after] from now; one at a time.
  void _kick([Duration after = Duration.zero]) {
    _retry?.cancel();
    if (!_wanted || _released || connected) return;
    nextAttempt = DateTime.now().add(after);
    notifyListeners();
    _retry = Timer(after, () {
      nextAttempt = null;
      _trying ??= _try().whenComplete(() => _trying = null);
    });
  }

  bool get _off => !_wanted || _released;

  Future<void> _try() async {
    if (_off || connected || _bringing != null) return;
    if (_adapterState == BluetoothAdapterState.off) {
      error = 'Bluetooth is off';
      _set(LinkState.disconnected);
      return;
    }
    attempt++;
    try {
      await BrilliantBluetooth.requestPermission();
      BluetoothDevice dev;
      final id = knownId;
      if (id == null) {
        _set(LinkState.scanning);
        glazLog(LogKind.link, 'attempt $attempt: looking for the glasses');
        dev = (await _scanForApp(const Duration(seconds: 15))).device;
        _remember(dev.remoteId.str);
      } else {
        dev = BluetoothDevice.fromId(id);
      }
      if (_off) return;
      _watch(dev);
      _set(LinkState.connecting);
      if (attempt > retryGaps.length) {
        if (waitingForGlasses) {
          // the wait set up again: the old one cancelled first
          try {
            await dev.disconnect();
          } catch (_) {}
          if (_off) return;
        }
        // glasses that answer to another id -- others, or reset -- are
        // found by looking, and connected to at once
        if (id != null) {
          _set(LinkState.scanning);
          final found = await _scanForApp(const Duration(seconds: 10))
              .then<BluetoothDevice?>((s) => s.device, onError: (_) => null);
          if (_off) return;
          _set(LinkState.connecting);
          if (found != null) {
            if (found.remoteId != dev.remoteId) {
              glazLog(LogKind.link, 'the glasses are at ${found.remoteId} now');
            }
            dev = found;
            _remember(dev.remoteId.str);
            _watch(dev);
            waitingForGlasses = false;
            glazLog(LogKind.link, 'attempt $attempt: found, connecting');
            await dev.connect(timeout: attemptTimeout, mtu: null);
            if (_off) return;
            await _bringUp(dev);
            return;
          }
        }
        glazLog(
          LogKind.link,
          'attempt $attempt: waiting for the glasses to show up',
        );
        waitingForGlasses = true;
        notifyListeners();
        await dev.connect(autoConnect: true, mtu: null);
        if (dev.isConnected) await _bringUp(dev);
        if (!connected) _kick(waitAgain);
        return;
      }
      glazLog(LogKind.link, 'attempt $attempt: connecting to ${dev.remoteId}');
      await dev.connect(timeout: attemptTimeout, mtu: null);
      if (_off) return;
      await _bringUp(dev);
    } catch (e) {
      if (_off || connected) return;
      error = '$e';
      glazLog(LogKind.link, 'attempt $attempt failed: $e', problem: true);
      _kick(retryGaps[min(attempt, retryGaps.length) - 1]);
    }
  }

  /// The link is up at Android's level: the glasses' services, then the
  /// app's. One at a time: the connect and the event both get here.
  Future<void> _bringUp(BluetoothDevice dev) =>
      _bringing ??= _bring(dev).whenComplete(() => _bringing = null);

  Future<void> _bring(BluetoothDevice dev) async {
    if (_device != null) return;
    final d = await BrilliantBluetooth.enableServices(dev);
    if (d.state != BrilliantConnectionState.connected) {
      await dev.disconnect();
      throw Exception('the glasses are in update mode');
    }
    _remember(dev.remoteId.str);
    _attach(d);
  }

  /// Connects again from inside a task, after [release]: the glasses come
  /// back from a reboot (new firmware) and are looked for anew -- the app's
  /// service only, never the bootloader. Throws if they do not show up
  /// within [timeout]; the link is then tried again as after a drop.
  Future<void> reconnect(Duration timeout) async {
    _released = false;
    _retry?.cancel();
    _set(LinkState.scanning);
    try {
      final scanned = await _scanForApp(timeout);
      _watch(scanned.device);
      _set(LinkState.connecting);
      await scanned.device.connect(timeout: attemptTimeout, mtu: null);
      await _bringUp(scanned.device);
    } catch (_) {
      _set(LinkState.disconnected);
      if (_wanted) _kick(retryGaps.first);
      rethrow;
    }
  }

  /// Gives up the link for a while, reconnecting included, so the radio
  /// is free for another connection -- the DFU bootloader: flutter_blue_plus
  /// runs one connect at a time (seen: the bootloader timed out waiting
  /// behind a reconnect). [reconnect] takes it back.
  Future<void> release() async {
    _released = true;
    _retry?.cancel();
    nextAttempt = null;
    waitingForGlasses = false;
    final device = _device;
    _detach(LinkState.disconnected);
    try {
      await (device?.device ?? _known)?.disconnect();
    } catch (_) {}
  }

  /// The glasses' own link events, and no other device's.
  void _watch(BluetoothDevice dev) {
    if (_states != null && _known?.remoteId == dev.remoteId) return;
    _states?.cancel();
    _known = dev;
    _states = FlutterBluePlus.events.onConnectionStateChanged
        .where((e) => e.device.remoteId == dev.remoteId)
        .listen(_onState);
  }

  void _onState(OnConnectionStateChangedEvent e) {
    if (e.connectionState == BluetoothConnectionState.connected) {
      _upAt = DateTime.now();
      // Android's autoConnect, or a connect of its own: taken up here
      if (_device == null && !_released) {
        _bringUp(e.device).catchError((Object err) {
          glazLog(
            LogKind.link,
            'could not take up the link: $err',
            problem: true,
          );
          e.device.disconnect().catchError((_) {});
          _kick(retryGaps.first);
        });
      }
    } else if (e.connectionState == BluetoothConnectionState.disconnected) {
      final r = e.device.disconnectReason;
      final upAt = _upAt;
      _upAt = null;
      final wasUp = _device != null;
      if (wasUp) _detach(LinkState.connecting);
      // a connect that never came up is no drop: an attempt that failed
      if (upAt == null) return;
      final up = DateTime.now().difference(upAt);
      _quickDrops = up < quickDrop ? _quickDrops + 1 : 0;
      if (_off) return; // asked for
      drops++;
      lastDrop = r == null
          ? 'unknown'
          : '${r.code}${r.description == null ? '' : ' ${r.description}'}';
      glazLog(
        LogKind.link,
        'down after ${_span(up)} up, reason $lastDrop, drop $drops, '
        'quick drops $_quickDrops',
      );
      _onDrop(e.device, r?.code);
      _kick(const Duration(milliseconds: 500));
    }
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
    if (trouble == PairingTrouble.none || trouble == pairing) return;
    glazLog(
      LogKind.link,
      'pairing trouble, ${trouble.name}: bonded $bonded, reason $code',
      problem: true,
    );
    pairing = trouble;
    // reconnecting would go on, and the glasses keep refusing
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
    _nameOf(device.device);
    _acks = true;
    final now = DateTime.now();
    final down = downSince;
    glazLog(
      LogKind.link,
      'up: mtu ${device.device.mtuNow}, attempt $attempt'
      '${down == null ? '' : ', down ${_span(now.difference(down))}'}'
      ', link $connects, drops $drops',
    );
    connects++;
    upSince = now;
    downSince = null;
    lastHeard = now;
    _silentLogged = false;
    attempt = 0;
    nextAttempt = null;
    waitingForGlasses = false;
    error = null;
    mtu = device.device.mtuNow;
    _retry?.cancel();
    _data = device.dataResponse.listen((m) {
      _heard();
      if (m.length == 1 && (m[0] == 0x00 || m[0] == 0x01)) {
        // data.lua's answer for a packet, not a message
        if (m[0] == 0x01) {
          glazLog(LogKind.link, 'the glasses failed a packet', problem: true);
        }
        _heard();
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
      _heard();
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
      if (busy) return;
      requestStatus();
      _health();
    });
    _handsOffTimer?.cancel();
    _handsOffTimer = Timer.periodic(handsOffEvery, (_) {
      if (_handsOff != handsOffNone) send(handsOff, [_handsOff], log: false);
    });
    // during a task the app is stopped; runTask greets it when done
    if (!busy) _greet();
  }

  /// The glasses' name: from the scan, else Android's for the device,
  /// else the pairing's, else the one kept; a new one is kept.
  void _nameOf(BluetoothDevice dev) {
    void take(String n) {
      name = n;
      if (n == knownName) return;
      knownName = n;
      onRemember?.call(knownId, n, _wanted);
    }

    final seen = dev.advName.isNotEmpty ? dev.advName : dev.platformName;
    if (seen.isNotEmpty) return take(seen);
    name = knownName ?? 'Frame';
    if (defaultTargetPlatform != TargetPlatform.android) return;
    FlutterBluePlus.bondedDevices
        .then((bonded) {
          for (final b in bonded) {
            if (b.remoteId == dev.remoteId && b.platformName.isNotEmpty) {
              take(b.platformName);
              notifyListeners();
            }
          }
        })
        .catchError((_) {});
  }

  void _heard() {
    lastHeard = DateTime.now();
    if (_silentLogged) {
      _silentLogged = false;
      glazLog(LogKind.link, 'the glasses speak again');
    }
  }

  /// Every [statusEvery]: the signal, and whether the glasses still speak.
  void _health() {
    final d = _device;
    final heard = lastHeard;
    if (d == null || heard == null) return;
    d.device
        .readRssi()
        .then((v) {
          rssi = v;
          notifyListeners();
        })
        .catchError((_) {});
    final quiet = DateTime.now().difference(heard);
    if (quiet > silentReconnect) {
      glazLog(
        LogKind.link,
        'nothing from the glasses for ${_span(quiet)}: connecting again',
        problem: true,
      );
      // the drop is taken up as any other ([_onState])
      d.device.disconnect().catchError((_) {});
    } else if (quiet > silentAfter && !_silentLogged) {
      _silentLogged = true;
      glazLog(
        LogKind.link,
        'nothing from the glasses for ${_span(quiet)}, the link up',
        problem: true,
      );
    }
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
    if (_device != null) downSince = DateTime.now();
    upSince = null;
    rssi = null;
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

  /// Drops the link and stops trying, until [connect]; across restarts.
  Future<void> disconnect() async {
    _wanted = false;
    onRemember?.call(knownId, knownName, false);
    _retry?.cancel();
    nextAttempt = null;
    waitingForGlasses = false;
    attempt = 0;
    final device = _device;
    _detach(LinkState.disconnected);
    try {
      await BrilliantBluetooth.stopScan();
      // also a connect still pending, or Android waiting for the glasses
      await (device?.device ?? _known)?.disconnect();
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
            ackTimeouts++;
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
      send(moduleCall, utf8.encode('$module\n$arg'));

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

/// A length of time as the log and the details show it: 45 s, 3 min 12 s,
/// 2 h 5 min.
String _span(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min ${s % 60} s';
  return '${s ~/ 3600} h ${s % 3600 ~/ 60} min';
}

/// [_span] for the details screen.
String linkSpan(Duration d) => _span(d);
