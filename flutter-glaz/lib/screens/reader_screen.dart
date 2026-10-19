import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/services.dart';
import '../theme.dart';

/// The text the glasses' Reader reads, and how far it got: on Reader's
/// page in the Menu tab. The text stays on the phone; the glasses ask for
/// a few dozen words at a time (services/reader.dart).
class ReaderText extends StatelessWidget {
  const ReaderText({super.key});

  @override
  Widget build(BuildContext context) {
    final reader = Services.instance.reader;
    final link = Services.instance.link;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([reader, link]),
      builder: (context, _) {
        final words = reader.words;
        final place = reader.place;
        final percent = words.isEmpty ? 0 : (place + 1) * 100 ~/ words.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
              child: Text('Text', style: text.titleMedium),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (words.isEmpty)
                      Text(
                        'No text yet. Paste one, or type it.',
                        style: text.bodyMedium?.copyWith(
                          color: FrameColors.grey,
                        ),
                      )
                    else ...[
                      Text(
                        '${words.length} words, $percent% read',
                        style: text.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      // where the glasses are: the word on their screen
                      // and what follows it
                      Text(
                        words.skip(place).take(24).join(' '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: FrameColors.grey,
                        ),
                      ),
                      if (place > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: percent / 100),
                      ],
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.content_paste),
                          label: const Text('Paste'),
                          onPressed: () => _paste(context),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.edit),
                          label: const Text('Edit'),
                          onPressed: () => _edit(context),
                        ),
                        if (place > 0)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.replay),
                            label: const Text('Start over'),
                            onPressed: reader.restart,
                          ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.visibility),
                          label: const Text('Read on glasses'),
                          onPressed: words.isNotEmpty && link.connected
                              ? reader.openOnGlasses
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                'On the glasses: a tap pauses and goes on, a tilt while '
                'reading changes the speed, a tilt while paused goes back '
                'or on by a sentence. The place is kept here.',
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
    await Services.instance.reader.setText(text);
  }

  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(
      text: Services.instance.reader.text,
    );
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('TEXT'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: 'What to read on the glasses',
              ),
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (text != null && text.trim() != Services.instance.reader.text) {
      await Services.instance.reader.setText(text.trim());
    }
  }
}
