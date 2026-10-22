import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/services.dart';
import '../term/hosts.dart';
import '../theme.dart';

/// The terminal's hosts and keys (term/hosts.dart), and the shell it holds
/// (services/term.dart). The terminal itself is on the glasses: Apps >
/// Terminal, with a keyboard on the phone.
class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final term = Services.instance.term;
    final hosts = term.hosts;
    return ListenableBuilder(
      listenable: Listenable.merge([term, hosts]),
      builder: (context, _) {
        final selected = hosts.selected;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.terminal, color: FrameColors.skyBlue),
                title: Text(term.state),
                subtitle: const Text(
                  'Open Apps > Terminal on the glasses; a keyboard on the '
                  'phone types into it. Ctrl+Alt+Esc closes it.',
                ),
                trailing: term.state.startsWith('connected')
                    ? TextButton(
                        onPressed: term.disconnect,
                        child: const Text('Disconnect'),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            _Heading('HOSTS', onAdd: () => _editHost(context, hosts, null)),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (hosts.hosts.isEmpty)
                    const ListTile(title: Text('No hosts yet')),
                  for (final h in hosts.hosts)
                    ListTile(
                      leading: Icon(
                        h.id == selected?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: FrameColors.skyBlue,
                      ),
                      title: Text(h.label),
                      subtitle: Text(
                        '${h.user}@${h.address} · '
                        '${hosts.keyOf(h)?.name ?? 'password'}',
                      ),
                      onTap: () => hosts.select(h),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _editHost(context, hosts, h),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Heading(
              'KEYS',
              onAdd: () => _addKey(context, hosts),
              onNew: () => _newKey(context, hosts),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (hosts.keys.isEmpty)
                    const ListTile(
                      title: Text('No keys yet'),
                      subtitle: Text('Paste a private key: OpenSSH or PEM'),
                    ),
                  for (final k in hosts.keys)
                    ListTile(
                      leading: const Icon(
                        Icons.key,
                        color: FrameColors.skyBlue,
                      ),
                      title: Text(k.name),
                      onTap: () => _copyPublic(context, hosts, k),
                      subtitle: const Text('Tap to copy its public key'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeKey(context, hosts, k),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.onAdd, this.onNew});
  final String text;
  final VoidCallback onAdd;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      ),
      if (onNew != null)
        TextButton.icon(
          icon: const Icon(Icons.auto_awesome),
          label: const Text('New key'),
          onPressed: onNew,
        ),
      IconButton(icon: const Icon(Icons.add), onPressed: onAdd),
    ],
  );
}

/// Makes a key on the phone and copies its public half.
Future<void> _newKey(BuildContext context, TermHosts hosts) async {
  final key = await hosts.generateKey('glaz-${TermHosts.newId()}');
  if (context.mounted) await _copyPublic(context, hosts, key);
}

/// The key pair in [pem], or why it is not one.
(SSHKeyPair?, String?) _parse(String pem, String passphrase) {
  try {
    final pairs = SSHKeyPair.fromPem(
      pem.trim(),
      passphrase.isEmpty ? null : passphrase,
    );
    if (pairs.isEmpty) return (null, 'no key in it');
    return (pairs.first, null);
  } catch (e) {
    return (null, '$e');
  }
}

Future<void> _copyPublic(
  BuildContext context,
  TermHosts hosts,
  TermKey key,
) async {
  final line = await hosts.publicKeyLine(key);
  if (line == null) return;
  await Clipboard.setData(ClipboardData(text: line));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Public key of ${key.name} copied: add it to the host\'s '
          '~/.ssh/authorized_keys',
        ),
      ),
    );
  }
}

Future<void> _removeKey(
  BuildContext context,
  TermHosts hosts,
  TermKey key,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete ${key.name}?'),
      content: const Text(
        'The private key is gone from the phone; hosts that used it ask '
        'for a password instead.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok == true) await hosts.removeKey(key);
}

Future<void> _addKey(BuildContext context, TermHosts hosts) async {
  final name = TextEditingController();
  final pem = TextEditingController();
  final pass = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Add a key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: pem,
                minLines: 4,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Private key',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                ),
              ),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase, if it has one',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: const TextStyle(color: FrameColors.red),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final (pair, why) = _parse(pem.text, pass.text);
              if (pair == null) {
                setState(() => error = 'Not a key: $why');
                return;
              }
              await hosts.addKey(
                name.text.trim().isEmpty ? pair.type : name.text.trim(),
                pem.text,
                passphrase: pass.text,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _editHost(
  BuildContext context,
  TermHosts hosts,
  TermHost? old,
) async {
  final name = TextEditingController(text: old?.name ?? '');
  final host = TextEditingController(text: old?.host ?? '');
  final port = TextEditingController(text: '${old?.port ?? 22}');
  final user = TextEditingController(text: old?.user ?? '');
  final password = TextEditingController();
  var keyId = old?.keyId ?? (hosts.keys.isEmpty ? null : hosts.keys.first.id);
  final seen = old == null ? null : hosts.known[old.address];
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(old == null ? 'Add a host' : 'Edit ${old.label}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
              TextField(
                controller: user,
                decoration: const InputDecoration(labelText: 'User'),
              ),
              DropdownButtonFormField<String?>(
                initialValue: keyId,
                decoration: const InputDecoration(labelText: 'Sign in with'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Password')),
                  for (final k in hosts.keys)
                    DropdownMenuItem(value: k.id, child: Text(k.name)),
                ],
                onChanged: (v) => setState(() => keyId = v),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: keyId == null
                      ? 'Password'
                      : 'Password, if the key is not enough',
                  hintText: old == null ? null : 'unchanged',
                ),
              ),
              if (seen != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Host key $seen',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          hosts.forgetHostKey(old!);
                          Navigator.pop(context);
                        },
                        child: const Text('Forget'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (old != null)
            TextButton(
              onPressed: () async {
                await hosts.removeHost(old);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (host.text.trim().isEmpty || user.text.trim().isEmpty) return;
              await hosts.putHost(
                TermHost(
                  id: old?.id ?? TermHosts.newId(),
                  name: name.text.trim(),
                  host: host.text.trim(),
                  port: int.tryParse(port.text.trim()) ?? 22,
                  user: user.text.trim(),
                  keyId: keyId,
                ),
                password: password.text.isEmpty ? null : password.text,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
