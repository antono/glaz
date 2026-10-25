import 'package:flutter/material.dart';

import '../services/assistant.dart';
import '../services/services.dart';
import '../theme.dart';

/// One chat with the assistant: the questions, what the agent asked the
/// phone for on the way, and its answers; a question written at the bottom
/// goes on with it. [chat] null: a new one, made by the first question.
class AssistantChatScreen extends StatefulWidget {
  const AssistantChatScreen(this.chat, {super.key});
  final AssistantChat? chat;

  @override
  State<AssistantChatScreen> createState() => _AssistantChatScreenState();
}

class _AssistantChatScreenState extends State<AssistantChatScreen> {
  final _assistant = Services.instance.assistant;
  final _question = TextEditingController();
  late AssistantChat? _chat = widget.chat;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  void _ask() {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    _question.clear();
    if (_chat == null) _assistant.newChat();
    _assistant.ask(q, chat: _chat);
  }

  Future<void> _delete(AssistantChat chat) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text(chat.title),
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
    _assistant.remove(chat);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _assistant,
      builder: (context, _) {
        // a new chat is the one its first question made
        final chat = _chat ??= _assistant.current;
        final busy =
            _assistant.state != AssistantState.idle &&
            (chat == null || _assistant.current == chat);
        final items = <Widget>[
          if (chat != null)
            for (final t in chat.turns) ..._turn(context, t),
          if (busy) _Busy(_assistant),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(
              chat?.title ?? 'New chat',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (chat != null)
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(chat),
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Text(
                          'Ask here, or tap the glasses in Assistant',
                          style: TextStyle(color: FrameColors.grey),
                        ),
                      )
                    // reversed: the newest stays in sight at the bottom
                    : ListView(
                        reverse: true,
                        padding: const EdgeInsets.all(12),
                        children: items.reversed.toList(),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: TextField(
                    controller: _question,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _ask(),
                    decoration: InputDecoration(
                      hintText: 'Ask in writing',
                      helperText:
                          'As if said aloud; the answer goes to the glasses',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _ask,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A question, the tool calls on the way, and the answer, each of its own.
  List<Widget> _turn(BuildContext context, AssistantTurn t) {
    final scheme = Theme.of(context).colorScheme;
    return [
      _Bubble(
        right: true,
        color: FrameColors.nightBlue,
        child: SelectableText(
          t.question,
          style: const TextStyle(color: FrameColors.white),
        ),
      ),
      for (final q in t.queries) _ToolCallCard(q),
      if (t.error != null)
        // selectable: an error is what one copies to ask about it
        _Bubble(
          color: scheme.errorContainer,
          child: SelectableText(
            t.error!,
            style: TextStyle(color: scheme.onErrorContainer),
          ),
        )
      else if (t.answer != null)
        _Bubble(
          color: scheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (t.answer!.isNotEmpty) SelectableText(t.answer!),
              for (final c in t.commands)
                Text(
                  '$c',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
    ];
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child, required this.color, this.right = false});
  final Widget child;
  final Color color;
  final bool right;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// What the agent asked the phone for, apart from the answers and in a
/// colour of its own: a photo taken, the photos or notes looked through.
class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard(this.call);
  final ToolCall call;

  static const _color = FrameColors.orange;

  IconData get _icon => switch (call.command.name) {
    'photo' => Icons.photo_camera_outlined,
    'photos' => Icons.photo_library_outlined,
    'getphoto' => Icons.image_outlined,
    'recordings' => Icons.mic_none,
    'transcript' => Icons.notes,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final icon = _icon;
    final label = call.label;
    final result = call.result;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.12),
          border: Border.all(color: _color.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: _color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label, style: const TextStyle(color: _color)),
                ),
                if (result == null) ...[
                  const SizedBox(width: 8),
                  const SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _color,
                    ),
                  ),
                ],
              ],
            ),
            if (result != null && result.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  result,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: FrameColors.grey,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy(this.assistant);
  final AssistantService assistant;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              assistant.state == AssistantState.listening
                  ? 'Listening: ${assistant.heard}'
                  : 'Thinking...',
            ),
          ),
        ],
      ),
    );
  }
}
