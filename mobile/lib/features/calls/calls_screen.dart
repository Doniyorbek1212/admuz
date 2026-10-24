import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../chat/call_options.dart';

/// Recent calls (all / missed), Telegram's "Calls" list: tap to call back, clear the history.
class CallsScreen extends ConsumerStatefulWidget {
  const CallsScreen({super.key});

  @override
  ConsumerState<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends ConsumerState<CallsScreen> {
  bool _onlyMissed = false;
  List<td.Message>? _calls;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final found = await guard(
      context,
      () => ref.read(accountProvider).send<td.FoundMessages>(td.SearchCallMessages(offset: '', limit: 100, onlyMissed: _onlyMissed)),
    );
    if (mounted) setState(() => _calls = found?.messages ?? const []);
  }

  Future<void> _clear() async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('calls_clear'), message: s.t('calls_clear_hint'), destructive: true);
    if (!ok || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.DeleteAllCallMessages(revoke: false)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final calls = _calls;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('calls')),
        actions: [IconButton(tooltip: s.t('calls_clear'), icon: const Icon(Icons.delete_sweep_rounded), onPressed: _clear)],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<bool>(
              segments: [ButtonSegment(value: false, label: Text(s.t('calls_all'))), ButtonSegment(value: true, label: Text(s.t('calls_missed')))],
              selected: {_onlyMissed},
              onSelectionChanged: (value) {
                setState(() {
                  _onlyMissed = value.first;
                  _calls = null;
                });
                _load();
              },
            ),
          ),
          Expanded(
            child: calls == null
                ? const Center(child: CircularProgressIndicator())
                : calls.isEmpty
                    ? Center(child: Text(s.t('nothing_here')))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: calls.length,
                          itemBuilder: (context, index) {
                            final message = calls[index];
                            final content = message.content;
                            if (content is! td.MessageCall) return const SizedBox.shrink();
                            final userId = switch (account.chats[message.chatId]?.type) {
                              td.ChatTypePrivate(:final userId) => userId,
                              _ => 0,
                            };
                            final missed = !message.isOutgoing &&
                                (content.discardReason is td.CallDiscardReasonMissed || content.discardReason is td.CallDiscardReasonDeclined);
                            final color = missed ? Theme.of(context).colorScheme.error : null;
                            return ListTile(
                              leading: ChatAvatar(chatId: message.chatId, size: 44, showOnline: false),
                              title: Text(account.chats[message.chatId]?.title ?? '', style: TextStyle(color: color)),
                              subtitle: Row(
                                children: [
                                  Icon(message.isOutgoing ? Icons.call_made_rounded : Icons.call_received_rounded, size: 15, color: color ?? Colors.green),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      [
                                        formatChatTime(message.date, s.locale),
                                        if (content.duration > 0) formatDuration(Duration(seconds: content.duration)),
                                      ].join(' · '),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: userId == 0
                                  ? null
                                  : IconButton(
                                      icon: Icon(content.isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: Theme.of(context).colorScheme.primary),
                                      onPressed: () => startTelegramCall(context, userId, video: content.isVideo),
                                    ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
