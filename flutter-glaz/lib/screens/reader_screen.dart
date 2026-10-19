import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/reader.dart';
import '../services/services.dart';
import '../theme.dart';

/// The Reader's library, on its page in the Menu tab: the texts the user
/// added, which one the glasses read, how far each got. The texts stay on
/// the phone; the glasses ask for a few dozen words at a time
/// (services/reader.dart).
class ReaderLibrary extends StatelessWidget {
  const ReaderLibrary({super.key});

  @override
  Widget build(BuildContext context) {
    final reader = Services.instance.reader;
    final link = Services.instance.link;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([reader, link]),
      builder: (context, _) {
        final books = reader.books;
        final current = reader.current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Library', style: text.titleMedium)),
                  TextButton.icon(
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste'),
                    onPressed: () => _paste(context),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => _add(context),
                  ),
                ],
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: books.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No texts yet. Paste one, or add one by typing.',
                        style: text.bodyMedium?.copyWith(
                          color: FrameColors.grey,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (final (i, b) in books.indexed) ...[
                          if (i > 0) const Divider(height: 1),
                          _BookTile(b, reading: b.id == current?.id),
                        ],
                      ],
                    ),
            ),
            if (current != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.visibility),
                  label: Text('Read "${_short(current.title)}" on glasses'),
                  onPressed: link.connected ? reader.openOnGlasses : null,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                'The glasses read the marked text, each from its own place. '
                'On the glasses: a tap pauses and goes on, a tilt while '
                'reading changes the speed, a tilt while paused goes back '
                'or on by a sentence.',
                style: text.bodySmall?.copyWith(color: FrameColors.grey),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _paste(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Nothing to paste')));
      }
      return;
    }
    if (context.mounted) await _add(context, text: text);
  }

  Future<void> _add(BuildContext context, {String text = ''}) async {
    final got = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _AddText(text: text),
      ),
    );
    if (got == null || got.$2.trim().isEmpty) return;
    await Services.instance.reader.add(got.$2.trim(), title: got.$1);
  }
}

String _short(String s) => s.length > 24 ? '${s.substring(0, 23)}...' : s;

class _BookTile extends StatelessWidget {
  const _BookTile(this.book, {required this.reading});
  final Book book;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final reader = Services.instance.reader;
    return ListTile(
      leading: IconButton(
        tooltip: reading ? 'The glasses read this' : 'Read this',
        icon: Icon(
          reading ? Icons.radio_button_checked : Icons.radio_button_off,
          color: reading ? FrameColors.red : FrameColors.grey,
        ),
        onPressed: () => reader.select(book),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${book.words} words, ${book.percent}% read'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => BookScreen(book))),
    );
  }
}

/// One text of the library: read it through, make it the one the glasses
/// read, start it over, rename it or delete it.
class BookScreen extends StatefulWidget {
  const BookScreen(this.book, {super.key});
  final Book book;

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  late final Future<String> _text = Services.instance.reader.textOf(
    widget.book,
  );

  @override
  Widget build(BuildContext context) {
    final reader = Services.instance.reader;
    final book = widget.book;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: reader,
      builder: (context, _) {
        final reading = reader.current?.id == book.id;
        return Scaffold(
          appBar: AppBar(
            title: Text(book.title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit),
                onPressed: () => _rename(context),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context),
              ),
            ],
          ),
          body: FutureBuilder<String>(
            future: _text,
            builder: (context, snap) {
              final paragraphs = (snap.data ?? '')
                  .split(RegExp(r'\n\s*\n|\n'))
                  .where((p) => p.trim().isNotEmpty)
                  .toList();
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: paragraphs.length + 1,
                itemBuilder: (context, i) {
                  if (i > 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SelectableText(
                        paragraphs[i - 1],
                        style: text.bodyLarge,
                      ),
                    );
                  }
                  return Card(
                    margin: const EdgeInsets.only(bottom: 20),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${book.words} words, ${book.percent}% read',
                            style: text.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: book.percent / 100),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              reading
                                  ? const Chip(
                                      avatar: Icon(
                                        Icons.radio_button_checked,
                                        color: FrameColors.red,
                                      ),
                                      label: Text('The glasses read this'),
                                    )
                                  : FilledButton.icon(
                                      icon: const Icon(Icons.visibility),
                                      label: const Text('Read this'),
                                      onPressed: () => reader.select(book),
                                    ),
                              if (book.place > 0)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.replay),
                                  label: const Text('Start over'),
                                  onPressed: () => reader.restart(book),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: widget.book.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null) {
      await Services.instance.reader.rename(widget.book, title);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this text?'),
        content: Text(widget.book.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await Services.instance.reader.remove(widget.book);
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// A new text: a title (its first words if left empty) and the text.
class _AddText extends StatefulWidget {
  const _AddText({required this.text});
  final String text;

  @override
  State<_AddText> createState() => _AddTextState();
}

class _AddTextState extends State<_AddText> {
  final _title = TextEditingController();
  late final _text = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NEW TEXT'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop((_title.text, _text.text)),
            child: const Text('Add'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                helperText: 'Empty: its first words',
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _text,
                autofocus: widget.text.isEmpty,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'What to read on the glasses',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
