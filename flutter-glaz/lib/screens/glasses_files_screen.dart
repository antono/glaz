import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/glasses_files.dart';
import '../services/services.dart';
import '../theme.dart';

String _size(int? n) {
  if (n == null) return '';
  if (n < 1024) return '$n B';
  return '${(n / 1024).toStringAsFixed(n < 10240 ? 1 : 0)} KB';
}

/// One folder on the glasses. The app on them keeps running meanwhile.
class GlassesFilesScreen extends StatefulWidget {
  const GlassesFilesScreen({super.key, this.path = ''});

  /// '' is the root; 'dir' or 'dir/sub' below it.
  final String path;

  @override
  State<GlassesFilesScreen> createState() => _GlassesFilesScreenState();
}

class _GlassesFilesScreenState extends State<GlassesFilesScreen> {
  late Future<GlassesFolder> _listing = _load();

  Future<GlassesFolder> _load() => Services.instance.files.list(widget.path);

  String _child(String name) =>
      widget.path.isEmpty ? name : '${widget.path}/$name';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path.isEmpty ? 'FILES' : '/${widget.path}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _listing = _load()),
          ),
        ],
      ),
      body: FutureBuilder<GlassesFolder>(
        future: _listing,
        builder: (context, snap) {
          if (snap.hasError) {
            return _Message(
              '${snap.error}'.replaceFirst('Exception: ', ''),
              error: true,
            );
          }
          final folder = snap.data;
          if (folder == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = folder.entries;
          if (entries.isEmpty) return const _Message('Empty');
          final total = entries.fold<int>(0, (n, e) => n + (e.size ?? 0));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (folder.free != null && folder.total != null)
                _Space(folder.free!, folder.total!),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${entries.length} items, ${_size(total)}',
                  style: text.bodySmall?.copyWith(color: FrameColors.grey),
                ),
              ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final e in entries)
                      ListTile(
                        leading: Icon(
                          e.folder ? Icons.folder : _icon(e.name),
                          color: e.folder
                              ? FrameColors.yellow
                              : FrameColors.skyBlue,
                        ),
                        title: Text(
                          e.name,
                          style: const TextStyle(fontFamily: monoFamily),
                        ),
                        trailing: e.folder
                            ? const Icon(Icons.chevron_right)
                            : Text(_size(e.size)),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => e.folder
                                ? GlassesFilesScreen(path: _child(e.name))
                                : _FileScreen(_child(e.name), e.size),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _icon(String name) {
    if (name.endsWith('.lua')) return Icons.code;
    if (name.endsWith('.txt')) return Icons.description_outlined;
    if (name.endsWith('.jpg') || name.endsWith('.png')) return Icons.image;
    return Icons.insert_drive_file_outlined;
  }
}

/// How full the glasses' file system is: a bar and the free bytes. Only
/// with firmware that can tell (GlassesFolder.free).
class _Space extends StatelessWidget {
  const _Space(this.free, this.total);
  final int free;
  final int total;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final used = total <= 0 ? 0.0 : ((total - free) / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_size(free)} free of ${_size(total)}',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: used,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            color: used > 0.9 ? FrameColors.orange : FrameColors.seaBlue,
            backgroundColor: FrameColors.outline,
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: error ? FrameColors.red : FrameColors.grey),
      ),
    ),
  );
}

/// A file's text, as the glasses read it: by lines, cut at 64 KB.
class _FileScreen extends StatefulWidget {
  const _FileScreen(this.path, this.size);
  final String path;
  final int? size;

  @override
  State<_FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends State<_FileScreen> {
  late final _content = Services.instance.files.read(widget.path);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.path.split('/').last)),
      body: FutureBuilder(
        future: _content,
        builder: (context, snap) {
          if (snap.hasError) {
            return _Message(
              '${snap.error}'.replaceFirst('Exception: ', ''),
              error: true,
            );
          }
          final bytes = snap.data;
          if (bytes == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Reading ${_size(widget.size)} over Bluetooth...',
                    style: const TextStyle(color: FrameColors.grey),
                  ),
                ],
              ),
            );
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                utf8.decode(bytes, allowMalformed: true),
                style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
              ),
            ),
          );
        },
      ),
    );
  }
}
