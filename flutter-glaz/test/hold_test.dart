import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/flipper/companion.dart';
import 'package:glaz/frame/link.dart';
import 'package:glaz/services/flipper_remote.dart';
import 'package:glaz/services/glasses_lua.dart';
import 'package:glaz/services/glaz_log.dart';
import 'package:glaz/services/hold.dart';
import 'package:glaz/settings.dart';

import 'flipper_remote_test.dart' show FakeCompanion, FakeFlipper;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Settings settings;
  late FrameLink link;
  late FakeFlipper flipperZero;
  late FakeCompanion companion;
  late FlipperRemote remote;
  late LinkHold hold;
  late List<Map<Object?, Object?>> states;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    link = FrameLink()
      ..state = LinkState.connected
      ..name = 'Frame 137';
    flipperZero = FakeFlipper()..there = false;
    companion = FakeCompanion()
      ..list.add(const FlipperPaired('13:37:13:37:01:37', 'Glaz'));
    remote = FlipperRemote(
      link,
      settings,
      GlassesLua(link),
      port: flipperZero,
      companion: companion,
      send: (_) {},
    );
    hold = LinkHold(link, settings, remote);
    states = [];
    messenger.setMockMethodCallHandler(LinkHold.channel, (call) async {
      switch (call.method) {
        case 'started':
          return 'flipper';
        case 'state':
          states.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    remote.attach();
    await pumpEventQueue();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(LinkHold.channel, null);
    remote.dispose();
  });

  // ignore: invalid_use_of_protected_member
  void changed(dynamic n) => n.notifyListeners();

  test('why glaz started goes to the log', () async {
    await hold.start();
    expect(GlazLog.instance.entries.last.text, 'start: the Flipper came near');
  });

  test('Android told what is connected, only when it changes', () async {
    await hold.start();
    expect(states, [
      {
        'flipper': true,
        'paired': true,
        'flipperConnected': false,
        'flipperName': null,
        'glasses': true,
        'glassesName': 'Frame 137',
      },
    ]);
    changed(link);
    changed(settings);
    await pumpEventQueue();
    expect(states.length, 1);

    link.state = LinkState.disconnected;
    changed(link);
    await pumpEventQueue();
    expect(states.length, 2);
    expect(states.last['glasses'], false);

    settings.setService('flipper_remote', false);
    await pumpEventQueue();
    expect(states.last['flipper'], false);
  });

  test('the Flipper near: connected at once, and Android told', () async {
    await hold.start();
    flipperZero.there = true;
    await messenger.handlePlatformMessage(
      LinkHold.channel.name,
      LinkHold.channel.codec.encodeMethodCall(
        const MethodCall('present', true),
      ),
      (_) {},
    );
    await pumpEventQueue();
    expect(remote.connected, isTrue);
    expect(states.last['flipperConnected'], true);
    expect(states.last['flipperName'], 'Glaz');
  });

  test('the Flipper gone: nothing to do here', () async {
    await hold.start();
    final opened = flipperZero.opened;
    await messenger.handlePlatformMessage(
      LinkHold.channel.name,
      LinkHold.channel.codec.encodeMethodCall(
        const MethodCall('present', false),
      ),
      (_) {},
    );
    await pumpEventQueue();
    expect(flipperZero.opened, opened);
  });

  test('no channel (not Android): start does nothing', () async {
    messenger.setMockMethodCallHandler(LinkHold.channel, null);
    await hold.start();
    expect(states, isEmpty);
  });
}
