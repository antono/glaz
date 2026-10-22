import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

import '../settings.dart';

/// A host the terminal connects to over SSH.
@immutable
class TermHost {
  const TermHost({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.user,
    this.keyId,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String user;

  /// The key it signs in with ([TermKey.id]); null: a password.
  final String? keyId;

  /// What known-host fingerprints are kept under: the address, not the name.
  String get address => '$host:$port';

  String get label => name.isEmpty ? '$user@$host' : name;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'key': keyId,
  };

  factory TermHost.fromJson(Map<String, Object?> j) => TermHost(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    host: j['host'] as String,
    port: j['port'] as int? ?? 22,
    user: j['user'] as String,
    keyId: j['key'] as String?,
  );
}

/// A private key, by name; the key itself is in the secure storage.
@immutable
class TermKey {
  const TermKey({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory TermKey.fromJson(Map<String, Object?> j) =>
      TermKey(id: j['id'] as String, name: j['name'] as String);
}

/// Where the secrets go: the private keys, their passphrases, the
/// passwords. Android's keystore through flutter_secure_storage; a map in
/// tests.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class DeviceSecrets implements SecretStore {
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) => value == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);
}

class MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;
}

/// The terminal's hosts and keys, the host it connects to, and the host
/// keys it has seen. Hosts and key names are in [Settings]; the secrets in
/// a [SecretStore].
class TermHosts extends ChangeNotifier {
  TermHosts(this.settings, this.secrets) {
    _load();
  }

  final Settings settings;
  final SecretStore secrets;

  List<TermHost> hosts = [];
  List<TermKey> keys = [];

  /// Host key fingerprints by [TermHost.address], seen on the first
  /// connect and checked on every one after.
  Map<String, String> known = {};

  void _load() {
    final raw = settings.termHosts;
    if (raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      hosts = [
        for (final h in j['hosts'] as List? ?? const [])
          TermHost.fromJson((h as Map).cast()),
      ];
      keys = [
        for (final k in j['keys'] as List? ?? const [])
          TermKey.fromJson((k as Map).cast()),
      ];
      known = ((j['known'] as Map?) ?? const {}).cast<String, String>();
    } on Object {
      // a broken list is an empty one rather than a crash at start
    }
  }

  void _save() {
    settings.termHosts = jsonEncode({
      'hosts': [for (final h in hosts) h.toJson()],
      'keys': [for (final k in keys) k.toJson()],
      'known': known,
    });
    notifyListeners();
  }

  /// The host the terminal connects to: the chosen one, else the first.
  TermHost? get selected {
    for (final h in hosts) {
      if (h.id == settings.termHost) return h;
    }
    return hosts.isEmpty ? null : hosts.first;
  }

  void select(TermHost host) {
    settings.termHost = host.id;
    notifyListeners();
  }

  TermKey? keyOf(TermHost host) {
    for (final k in keys) {
      if (k.id == host.keyId) return k;
    }
    return null;
  }

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Adds [host], or replaces the one with its id; [password] kept with it
  /// when given, '' to forget it.
  Future<void> putHost(TermHost host, {String? password}) async {
    final i = hosts.indexWhere((h) => h.id == host.id);
    final old = i < 0 ? null : hosts[i];
    if (i < 0) {
      hosts = [...hosts, host];
    } else {
      hosts = [...hosts]..[i] = host;
    }
    // a host at another address is another host: its key is not known
    if (old != null && old.address != host.address) known.remove(old.address);
    if (password != null) {
      await secrets.write(
        'term.pass.${host.id}',
        password.isEmpty ? null : password,
      );
    }
    _save();
  }

  Future<void> removeHost(TermHost host) async {
    hosts = hosts.where((h) => h.id != host.id).toList();
    known.remove(host.address);
    await secrets.write('term.pass.${host.id}', null);
    _save();
  }

  /// Adds a key: [pem] an OpenSSH or PEM private key, [passphrase] its own
  /// if it has one.
  Future<TermKey> addKey(String name, String pem, {String? passphrase}) async {
    final key = TermKey(id: newId(), name: name);
    await secrets.write('term.key.${key.id}', pem.trim());
    if (passphrase != null && passphrase.isNotEmpty) {
      await secrets.write('term.keypass.${key.id}', passphrase);
    }
    keys = [...keys, key];
    _save();
    return key;
  }

  /// Makes a new ed25519 key on the phone: the private half never leaves
  /// it, the public one goes into the host's authorized_keys
  /// ([publicKeyLine]).
  Future<TermKey> generateKey(String name) {
    final signing = ed25519.SigningKey.generate();
    final pair = OpenSSHEd25519KeyPair(
      Uint8List.fromList(signing.verifyKey.asTypedList),
      Uint8List.fromList(signing.asTypedList),
      name,
    );
    return addKey(name, pair.toPem());
  }

  /// The line for a host's authorized_keys: type, key, name.
  Future<String?> publicKeyLine(TermKey key) async {
    final pem = await this.pem(key);
    if (pem == null) return null;
    try {
      final pair = SSHKeyPair.fromPem(pem, await passphrase(key)).first;
      return '${pair.type} '
          '${base64.encode(pair.toPublicKey().encode())} ${key.name}';
    } on Object {
      return null;
    }
  }

  Future<void> removeKey(TermKey key) async {
    keys = keys.where((k) => k.id != key.id).toList();
    hosts = [
      for (final h in hosts)
        h.keyId == key.id
            ? TermHost(
                id: h.id,
                name: h.name,
                host: h.host,
                port: h.port,
                user: h.user,
              )
            : h,
    ];
    await secrets.write('term.key.${key.id}', null);
    await secrets.write('term.keypass.${key.id}', null);
    _save();
  }

  Future<String?> pem(TermKey key) => secrets.read('term.key.${key.id}');
  Future<String?> passphrase(TermKey key) =>
      secrets.read('term.keypass.${key.id}');
  Future<String?> password(TermHost host) =>
      secrets.read('term.pass.${host.id}');

  /// Whether [fingerprint] is the key [host] showed before. The first time
  /// it is kept and trusted; after that only the same one is.
  bool trust(TermHost host, String fingerprint) {
    final seen = known[host.address];
    if (seen == null) {
      known[host.address] = fingerprint;
      _save();
      return true;
    }
    return seen == fingerprint;
  }

  /// Forgets the key [host] showed, for a host whose key changed for a
  /// reason the user knows.
  void forgetHostKey(TermHost host) {
    known.remove(host.address);
    _save();
  }
}
