import 'package:flutter/material.dart';

import '../services/gemini.dart';
import '../services/services.dart';
import '../theme.dart';

/// The Gemini browser's bookmarks, on its page in the Menu tab: they are
/// its home page on the glasses (services/gemini.dart).
class GeminiBookmarks extends StatelessWidget {
  const GeminiBookmarks({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final gemini = Services.instance.gemini;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, gemini]),
      builder: (context, _) {
        final list = bookmarksOf(settings);
        final open = gemini.url;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Bookmarks', style: text.titleMedium)),
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => _edit(context, list, null),
                  ),
                ],
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No bookmarks: the home page on the glasses is empty.',
                        style: text.bodyMedium?.copyWith(
                          color: FrameColors.grey,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (final (i, b) in list.indexed)
                          ListTile(
                            leading: const Icon(
                              Icons.bookmark,
                              color: FrameColors.skyBlue,
                            ),
                            title: Text(b.title.isEmpty ? b.url : b.title),
                            subtitle: Text(b.url),
                            onTap: () => _edit(context, list, i),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (i > 0)
                                  IconButton(
                                    tooltip: 'Up',
                                    icon: const Icon(Icons.arrow_upward),
                                    onPressed: () => setBookmarks(settings, [
                                      ...list.sublist(0, i - 1),
                                      b,
                                      list[i - 1],
                                      ...list.sublist(i + 1),
                                    ]),
                                  ),
                                IconButton(
                                  tooltip: 'Delete',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => setBookmarks(settings, [
                                    for (final (j, x) in list.indexed)
                                      if (j != i) x,
                                  ]),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                open == null
                    ? 'The home page of Gemini on the glasses. The phone '
                          'fetches the pages: allow it the Internet above.'
                    : 'The home page of Gemini on the glasses. Open there '
                          'now: ${open == homeUrl ? 'home' : open}',
                style: text.bodySmall?.copyWith(color: FrameColors.grey),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Adds a bookmark (at null) or changes bookmark [at].
  Future<void> _edit(BuildContext context, List<Bookmark> list, int? at) async {
    final settings = Services.instance.settings;
    final old = at == null ? null : list[at];
    final url = TextEditingController(text: old?.url ?? 'gemini://');
    final title = TextEditingController(text: old?.title ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(at == null ? 'Add bookmark' : 'Bookmark'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: 'Address'),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final u = url.text.trim();
    final t = title.text.trim();
    url.dispose();
    title.dispose();
    if (ok != true || u.isEmpty || u == 'gemini://') return;
    final b = Bookmark(u.contains('://') ? u : 'gemini://$u', t);
    setBookmarks(settings, [
      for (final (j, x) in list.indexed) j == at ? b : x,
      if (at == null) b,
    ]);
  }
}
