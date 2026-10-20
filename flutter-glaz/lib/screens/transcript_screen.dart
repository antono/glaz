import 'package:flutter/material.dart';

import '../services/recordings.dart';
import '../services/services.dart';
import '../services/speech.dart' show speechLanguages;
import '../theme.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// [tag]'s name in [speechLanguages]; 'another language' when not known.
String languageName(String? tag) {
  for (final (t, name) in speechLanguages) {
    if (t == tag) return name;
  }
  return 'another language';
}

/// One recording's transcript, from the transcript button in Recordings:
/// the language to hear it in -- for this recording alone, when not the
/// one picked for all -- transcribing it again, and sending the text to
/// the Reader on the glasses.
class TranscriptScreen extends StatefulWidget {
  const TranscriptScreen(this.recording, {super.key});
  final Recording recording;

  @override
  State<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<TranscriptScreen> {
  late Recording _r = widget.recording;

  /// The language to transcribe in next: the transcript's own, else the
  /// one picked for all.
  late String _language =
      _r.language != null && speechLanguages.any((l) => l.$1 == _r.language)
      ? _r.language!
      : Services.instance.settings.speechLanguage;

  @override
  void initState() {
    super.initState();
    Services.instance.recorder.store.addListener(_reload);
  }

  @override
  void dispose() {
    Services.instance.recorder.store.removeListener(_reload);
    super.dispose();
  }

  /// The recording read again: a transcript saved is a new [Recording].
  Future<void> _reload() async {
    final all = await Services.instance.recorder.store.list();
    for (final r in all) {
      if (r.file.path == _r.file.path && mounted) setState(() => _r = r);
    }
  }

  Future<void> _transcribe() async {
    final transcripts = Services.instance.transcripts;
    final all = Services.instance.settings.speechLanguage;
    try {
      // the one for all is not picked: it follows when that changes
      await transcripts.transcribe(
        _r,
        language: _language == all ? null : _language,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Transcribing failed: $e')));
    }
  }

  Future<void> _toReader() async {
    final reader = Services.instance.reader;
    final link = Services.instance.link;
    final t = _r.at;
    final book = await reader.addOrSelect(
      _r.transcript!,
      title:
          'Recording ${_two(t.day)}.${_two(t.month)} '
          '${_two(t.hour)}:${_two(t.minute)}',
    );
    if (link.connected) await reader.openOnGlasses();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          link.connected
              ? 'Reading "${book.title}" on the glasses'
              : '"${book.title}" is in the Reader; the glasses are not '
                    'connected',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final transcripts = Services.instance.transcripts;
    final t = _r.at;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_two(t.day)}.${_two(t.month)}.${t.year} '
          '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}',
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([transcripts, Services.instance.link]),
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final transcripts = Services.instance.transcripts;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final live = transcripts.live[_r.file.path];
    final busy = live != null;
    final transcript = _r.transcript;
    final downloading = transcripts.downloading;
    final canHear = transcripts.transcriber != null;
    // heard in another language than the one to hear it in now
    final other = transcript != null && _r.language != _language;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (canHear)
          Row(
            children: [
              const Expanded(child: Text('Language')),
              DropdownButton<String>(
                value: _language,
                onChanged: busy
                    ? null
                    : (v) {
                        if (v != null) setState(() => _language = v);
                      },
                items: [
                  for (final (tag, name) in speechLanguages)
                    DropdownMenuItem(value: tag, child: Text(name)),
                ],
              ),
            ],
          ),
        if (canHear)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: Text(
                transcript == null ? 'Transcribe' : 'Transcribe again',
              ),
              onPressed: busy ? null : _transcribe,
            ),
          ),
        const SizedBox(height: 8),
        if (busy) ...[
          LinearProgressIndicator(value: downloading),
          const SizedBox(height: 8),
          Text(
            downloading != null
                ? 'Downloading the language: ${(downloading * 100).round()}%'
                : live.isEmpty
                ? 'Listening...'
                : live,
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ] else if (transcript == null)
          Text(
            'Not transcribed yet.',
            style: text.bodyLarge?.copyWith(color: FrameColors.grey),
          )
        else ...[
          if (other)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Transcribed in ${languageName(_r.language)}',
                style: text.bodySmall?.copyWith(color: FrameColors.grey),
              ),
            ),
          SelectableText(
            transcript.isEmpty ? 'Nothing heard.' : transcript,
            style: text.bodyLarge,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.visibility),
          label: const Text('Read on glasses'),
          onPressed: busy || transcript == null || transcript.trim().isEmpty
              ? null
              : _toReader,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Goes into the Reader library and opens on the glasses, one '
            'word at a time.',
            style: text.bodySmall?.copyWith(color: FrameColors.grey),
          ),
        ),
      ],
    );
  }
}
