import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// What the user chose in the forward picker (aka-style advanced forward).
class ForwardRequest {
  const ForwardRequest({required this.chatIds, this.hideSender = false, this.removeCaption = false, this.editedText});

  final List<int> chatIds;

  /// Send as a copy, without "Forwarded from".
  final bool hideSender;
  final bool removeCaption;

  /// New text for a single text message forwarded as a copy; null when unchanged.
  final String? editedText;
}

/// Picks a chat to forward to. Pops with the chat id, or with a [ForwardRequest] when [multiple] is set.
class ForwardPickerScreen extends ConsumerStatefulWidget {
  const ForwardPickerScreen({super.key, this.multiple = false, this.hasCaption = false, this.editableText});

  /// Several chats at once plus copy options.
  final bool multiple;
  final bool hasCaption;

  /// Text of a single text message, editable when it is sent as a copy.
  final String? editableText;

  @override
  ConsumerState<ForwardPickerScreen> createState() => _ForwardPickerScreenState();
}

class _ForwardPickerScreenState extends ConsumerState<ForwardPickerScreen> {
  String _query = '';
  final List<int> _chosen = [];
  bool _hideSender = false;
  bool _removeCaption = false;
  late final _text = TextEditingController(text: widget.editableText);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text.trim();
    final edited = _hideSender && widget.editableText != null && text.isNotEmpty && text != widget.editableText!.trim();
    Navigator.pop(
      context,
      ForwardRequest(chatIds: List.of(_chosen), hideSender: _hideSender, removeCaption: _removeCaption, editedText: edited ? text : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final chats = ref
        .watch(chatListProvider('main'))
        .where((c) => account.canSendMessages(c))
        .where((c) => _query.isEmpty || chatTitle(c, account, s).toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          style: TextStyle(color: context.onAppBar),
          cursorColor: context.onAppBar,
          decoration: InputDecoration(
            hintText: s.t('forward_to'),
            hintStyle: TextStyle(color: context.onAppBarMuted),
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value.trim()),
        ),
      ),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          final chosen = _chosen.contains(chat.id);
          return ListTile(
            leading: ChatAvatar(chatId: chat.id, size: 44),
            title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(chatSubtitle(chat, account, s), maxLines: 1),
            trailing: widget.multiple ? Checkbox(value: chosen, onChanged: (_) => _toggle(chat.id)) : null,
            onTap: () => widget.multiple ? _toggle(chat.id) : Navigator.pop(context, chat.id),
          );
        },
      ),
      bottomNavigationBar: widget.multiple && _chosen.isNotEmpty ? _options(s) : null,
    );
  }

  void _toggle(int chatId) => setState(() {
        if (!_chosen.remove(chatId)) _chosen.add(chatId);
      });

  Widget _options(Strings s) => Material(
        elevation: 8,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  dense: true,
                  title: Text(s.t('forward_hide_sender')),
                  value: _hideSender,
                  onChanged: (v) => setState(() => _hideSender = v),
                ),
                if (widget.hasCaption)
                  SwitchListTile(
                    dense: true,
                    title: Text(s.t('forward_hide_caption')),
                    value: _removeCaption,
                    onChanged: (v) => setState(() => _removeCaption = v),
                  ),
                if (_hideSender && widget.editableText != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(labelText: s.t('forward_edit_text'), border: const OutlineInputBorder()),
                    ),
                  ),
                const SizedBox(height: 6),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(s.t('forward_send', {'n': '${_chosen.length}'})),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ),
      );
}
