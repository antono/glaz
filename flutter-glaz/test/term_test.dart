import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/core.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/term.dart';
import 'package:glaz/settings.dart';
import 'package:glaz/term/hosts.dart';
import 'package:glaz/term/screen.dart';

class FakeSession implements TermSession {
  final _out = StreamController<Uint8List>(sync: true);
  final _done = Completer<void>();
  final written = <String>[];
  final sizes = <(int, int)>[];
  bool closed = false;

  void say(String s) => _out.add(Uint8List.fromList(utf8.encode(s)));
  void end() => _done.complete();

  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  void write(Uint8List data) => written.add(utf8.decode(data));
  @override
  void resize(int cols, int rows) => sizes.add((cols, rows));
  @override
  Future<void> get done => _done.future;
  @override
  void close() => closed = true;
}

Terminal screenOf(String s) => Terminal()
  ..resize(termCols, termRows)
  ..write(s);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the screen as the glasses take it', () {
    test('text, colors, and blank rows', () {
      final rows = glassesRows(
        screenOf('\x1b[32mok\x1b[0m done\r\n\x1b[1;31merror\x1b[0m'),
      );
      expect(rows, hasLength(termRows));
      expect(rows[0].text.trimRight(), 'ok done');
      expect(rows[0].attrs[0], FramePalette.green);
      expect(rows[0].attrs[3], FramePalette.white);
      expect(rows[1].attrs[0], FramePalette.red);
      expect(rows[5].blank, isTrue);
    });

    test('the cursor is an inverted cell', () {
      final rows = glassesRows(screenOf(r'$ '));
      // white text by default: the cursor is white behind dark text
      expect(
        rows[0].attrs[2],
        FramePalette.white << 4 | FramePalette.nightBlue,
      );
      final hidden = glassesRows(screenOf('\x1b[?25l\$ '));
      expect(hidden[0].attrs[2], FramePalette.white);
    });

    test('a background, and inverse video', () {
      final rows = glassesRows(
        screenOf('\x1b[44mbar\x1b[0m \x1b[7mrev\x1b[0m'),
      );
      expect(rows[0].attrs[0] >> 4, FramePalette.nightBlue);
      expect(
        rows[0].attrs[4],
        FramePalette.white << 4 | FramePalette.nightBlue,
      );
    });

    test('box drawing, blocks and the rest come down to ASCII', () {
      expect(glassesChar(0x2500), '-');
      expect(glassesChar(0x2502), '|');
      expect(glassesChar(0x250C), '+');
      expect(glassesChar(0x2588), isNull);
      expect(glassesChar(0x0416), '?'); // Ж: the font has no Cyrillic
      final rows = glassesRows(screenOf('\x1b[33m█\x1b[0m'));
      expect(rows[0].text[0], ' ');
      expect(rows[0].attrs[0], FramePalette.yellow << 4 | FramePalette.yellow);
    });

    test('256 colors and RGB go to the nearest of Frame\'s', () {
      expect(nearestFrame(0xFF0000), FramePalette.red);
      expect(nearestFrame(0x00FF00), FramePalette.green);
      expect(nearestFrame(0xA0FF80), FramePalette.lightGreen);
      final rows = glassesRows(screenOf('\x1b[38;5;214mx\x1b[38;2;0;0;255my'));
      expect(rows[0].attrs[0], FramePalette.orange);
      expect(rows[0].attrs[1] & 0x0F, isNot(FramePalette.white));
    });

    test('a frame carries the rows that changed, trailing blanks left off', () {
      final a = glassesRows(screenOf('one\r\ntwo'));
      final first = termFrame(a, null, 1)!;
      expect(first.sublist(0, 5), [0x66, 1, 0, 0xFF, 0xF0]);
      // row 1: 'one' and three attribute bytes
      expect(first.sublist(5, 12), [3, ...'one'.codeUnits, 1, 1, 1]);

      final b = glassesRows(screenOf('one\r\ntwo!'));
      final next = termFrame(b, a, 2)!;
      expect(next.sublist(3, 5), [0x40, 0x00], reason: 'row 2 only');
      expect(termFrame(b, b, 3), isNull);
      expect(termFrame(b, b, 3, typed: true)!.sublist(2, 5), [1, 0, 0]);
    });
  });

  group('hosts', () {
    late Settings settings;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
    });

    test('kept across restarts, secrets apart', () async {
      final secrets = MemorySecrets();
      final hosts = TermHosts(settings, secrets);
      final key = await hosts.addKey('laptop', 'PEM', passphrase: 'pp');
      await hosts.putHost(
        TermHost(id: 'h', name: '', host: 'desk', user: 'me', keyId: key.id),
        password: 'pw',
      );
      expect(settings.termHosts, isNot(contains('PEM')));
      expect(settings.termHosts, isNot(contains('pw')));
      final again = TermHosts(settings, secrets);
      expect(again.selected!.label, 'me@desk');
      expect(again.keyOf(again.selected!)!.name, 'laptop');
      expect(await again.pem(key), 'PEM');
      expect(await again.password(again.selected!), 'pw');
    });

    test(
      'a key made on the phone reads back, and gives its public line',
      () async {
        final hosts = TermHosts(settings, MemorySecrets());
        final key = await hosts.generateKey('glaz-test');
        final pem = (await hosts.pem(key))!;
        expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
        expect(SSHKeyPair.fromPem(pem).single.type, 'ssh-ed25519');
        final line = (await hosts.publicKeyLine(key))!;
        expect(
          line,
          matches(
            RegExp(
              r'^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=* glaz-test$',
            ),
          ),
        );
      },
    );

    test('the first host key is kept, and only it trusted after', () async {
      final hosts = TermHosts(settings, MemorySecrets());
      const h = TermHost(id: 'h', name: '', host: 'desk', user: 'me');
      await hosts.putHost(h);
      expect(hosts.trust(h, 'SHA256:a'), isTrue);
      expect(hosts.trust(h, 'SHA256:a'), isTrue);
      expect(hosts.trust(h, 'SHA256:b'), isFalse);
      hosts.forgetHostKey(h);
      expect(hosts.trust(h, 'SHA256:b'), isTrue);
    });
  });

  group('the service', () {
    late Settings settings;
    late TermHosts hosts;
    late FakeSession session;
    late List<List<int>> sent;
    late List<List<int>> gestures;
    late TermService service;
    var opened = 0;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      hosts = TermHosts(settings, MemorySecrets());
      session = FakeSession();
      sent = [];
      gestures = [];
      opened = 0;
      service = TermService(
        FrameLink()..state = LinkState.connected,
        settings,
        hosts,
        open: (host, hosts, cols, rows) async {
          opened++;
          return session;
        },
        send: sent.add,
        gesture: gestures.add,
      )..attach();
    });

    List<List<int>> toModule() => [
      for (final s in sent)
        if (String.fromCharCodes(s.take(5)) == 'term\n') s.sublist(5),
    ];
    List<List<int>> frames() => toModule().where((m) => m[0] == 0x66).toList();
    List<String> words() => [
      for (final m in toModule())
        if (m[0] == 0x73) String.fromCharCodes(m.sublist(1)),
    ];

    test('no host: the glasses say where to add one', () {
      fakeAsync((async) {
        service.onEvent([term, 1, termCols, termRows]);
        async.flushMicrotasks();
        expect(words().single, startsWith('Add a host'));
        expect(opened, 0);
      });
    });

    test('on screen: connects, and sends one frame at a time', () {
      fakeAsync((async) {
        hosts.putHost(
          const TermHost(id: 'h', name: 'desk', host: 'desk', user: 'me'),
        );
        async.flushMicrotasks();
        service.onEvent([term, 1, termCols, termRows]);
        async.flushMicrotasks();
        expect(opened, 1);
        expect(words().single, 'connecting to\ndesk');
        expect(service.takesKeys, isTrue);
        expect(frames(), hasLength(1), reason: 'the blank screen, cursor on');

        session.say('hello');
        async.elapse(TermService.gather);
        expect(frames(), hasLength(1), reason: 'waits for the answer');

        service.onEvent([term, 2, frames().last[1]]);
        expect(frames(), hasLength(2));
        final f = frames().last;
        expect(f.sublist(3, 5), [0x80, 0x00], reason: 'row 1 only');
        expect(String.fromCharCodes(f.sublist(6, 11)), 'hello');
      });
    });

    test('keys go to the shell as a terminal sends them', () {
      fakeAsync((async) {
        hosts.putHost(const TermHost(id: 'h', name: '', host: 'd', user: 'u'));
        async.flushMicrotasks();
        service.onEvent([term, 1, termCols, termRows]);
        async.flushMicrotasks();

        service.key(LogicalKeyboardKey.keyL, character: 'l');
        service.key(LogicalKeyboardKey.keyS, character: 'S', shift: true);
        service.key(LogicalKeyboardKey.enter);
        service.key(LogicalKeyboardKey.keyC, ctrl: true);
        service.key(LogicalKeyboardKey.arrowUp);
        service.key(LogicalKeyboardKey.keyX, character: 'x', alt: true);
        service.key(LogicalKeyboardKey.shiftLeft);
        expect(session.written, ['l', 'S', '\r', '\x03', '\x1b[A', '\x1bX']);

        // Ctrl+Alt+Esc: back on the glasses, nothing to the shell
        service.key(LogicalKeyboardKey.escape, ctrl: true, alt: true);
        expect(gestures, [
          [1, 2],
        ]);
        expect(session.written, hasLength(6));

        // a typed frame says so, for the glasses' idle timeout
        service.onEvent([term, 2, frames().last[1]]);
        async.elapse(TermService.gather);
        expect(frames().last[2], 1);
      });
    });

    test('closed on the glasses, the shell is kept a while, then ended', () {
      fakeAsync((async) {
        hosts.putHost(const TermHost(id: 'h', name: '', host: 'd', user: 'u'));
        async.flushMicrotasks();
        service.onEvent([term, 1, termCols, termRows]);
        async.flushMicrotasks();
        service.onEvent([term, 0]);
        expect(service.takesKeys, isFalse);
        expect(service.key(LogicalKeyboardKey.keyA, character: 'a'), isFalse);

        // back: the same shell, all rows again
        final before = frames().length;
        service.onEvent([term, 1, termCols, termRows]);
        async.flushMicrotasks();
        expect(opened, 1);
        expect(frames().length, before + 1);
        expect(frames().last.sublist(3, 5), [0xFF, 0xF0]);

        service.onEvent([term, 0]);
        async.elapse(TermService.keepFor);
        expect(session.closed, isTrue);
      });
    });

    test('the shell ends: the glasses say so', () async {
      await hosts.putHost(
        const TermHost(id: 'h', name: '', host: 'd', user: 'u'),
      );
      service.onEvent([term, 1, termCols, termRows]);
      await pumpEventQueue();
      session.end();
      await pumpEventQueue();
      expect(words().last, startsWith('the shell ended'));
      expect(service.takesKeys, isFalse);
    });
  });
}
