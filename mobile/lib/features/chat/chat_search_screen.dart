import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Search inside one chat; pops with the id of the tapped message so the chat can jump to it.
class ChatSearchScreen extends ConsumerStatefulWidget {
  const ChatSearchScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends ConsumerState<ChatSearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<td.Message> _results = const [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(text.trim()));
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _loading = true);
    try {
      final found = await ref.read(accountProvider).send<td.FoundChatMessages>(td.SearchChatMessages(
            chatId: widget.chatId,
            query: query,
            fromMessageId: 0,
            offset: 0,
            limit: 100,
          ));
      // A newer query may have finished first.
      if (mounted && _query.text.trim() == query) setState(() => _results = found.messages);
    } on TdException catch (error) {
      debugPrint('chat search failed: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (text) => _search(text.trim()),
          style: TextStyle(color: context.onAppBar, fontSize: 17),
          cursorColor: context.onAppBar,
          decoration: InputDecoration(
            hintText: s.t('search'),
            hintStyle: TextStyle(color: context.onAppBarMuted),
            border: InputBorder.none,
          ),
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
      ),
      body: _results.isEmpty
          ? Center(
              child: Text(
                _query.text.trim().isEmpty || _loading ? '' : s.t('nothing_found'),
                style: TextStyle(color: hint),
              ),
            )
          : ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(indent: 72),
              itemBuilder: (context, index) {
                final message = _results[index];
                final sender = account.senderName(message.senderId);
                return ListTile(
                  leading: switch (message.senderId) {
                    td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 44),
                    td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 44),
                    _ => ChatAvatar(chatId: widget.chatId, size: 44),
                  },
                  title: Row(
                    children: [
                      Expanded(child: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(formatChatTime(message.date, s.locale), style: TextStyle(fontSize: 12.5, color: hint)),
                    ],
                  ),
                  subtitle: Text(messagePreview(message, account, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, message.id),
                );
              },
            ),
    );
  }
}
