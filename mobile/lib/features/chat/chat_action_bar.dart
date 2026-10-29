import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'message_extras.dart' show reportChat;

/// Telegram's bar above a new chat: add contact, block, report spam, share my number.
class ChatActionBarView extends ConsumerWidget {
  const ChatActionBarView({super.key, required this.chat});

  final td.Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bar = chat.actionBar;
    if (bar == null) return const SizedBox.shrink();
    final s = context.s;
    final account = ref.watch(accountProvider);
    final user = account.privateUser(chat);
    final error = Theme.of(context).colorScheme.error;

    Future<void> dismiss() => account.send<td.Ok>(td.RemoveChatActionBar(chatId: chat.id));
    Future<void> reportSpam() async {
      await reportChat(context, account, chat.id);
      if (context.mounted) await guard(context, dismiss);
    }

    Future<void> block() async {
      if (user == null) return;
      final ok = await confirm(context, title: s.t('block'), message: chatTitle(chat, account, s), destructive: true);
      if (!ok || !context.mounted) return;
      await guard(context, () async {
        await account.send<td.Ok>(td.SetMessageSenderBlockList(senderId: td.MessageSenderUser(userId: user.id), blockList: const td.BlockListMain()));
        await dismiss();
        return true;
      });
    }

    Future<void> addContact() async {
      if (user == null) return;
      await guard(context, () async {
        await account.send<td.Ok>(td.AddContact(
          userId: user.id,
          contact: td.ImportedContact(phoneNumber: user.phoneNumber, firstName: user.firstName, lastName: user.lastName, note: null),
          sharePhoneNumber: false,
        ));
        return true;
      });
    }

    final List<(String, Color?, Future<void> Function())> buttons = switch (bar) {
      td.ChatActionBarReportSpam() => [(s.t('report_spam'), error, reportSpam)],
      td.ChatActionBarReportAddBlock() => [(s.t('add_contact'), null, addContact), (s.t('block'), error, block)],
      td.ChatActionBarAddContact() => [(s.t('add_contact'), null, addContact)],
      td.ChatActionBarSharePhoneNumber() when user != null => [
          (s.t('share_my_phone'), null, () => guard(context, () => account.send<td.Ok>(td.SharePhoneNumber(userId: user.id)))),
        ],
      _ => [],
    };
    final info = switch (bar) {
      td.ChatActionBarReportAddBlock(:final accountInfo?) when accountInfo.registrationYear > 0 =>
        s.t('account_registered', {'date': '${accountInfo.registrationMonth.toString().padLeft(2, '0')}.${accountInfo.registrationYear}', 'country': accountInfo.phoneNumberCountryCode}),
      td.ChatActionBarJoinRequest(:final title, :final isChannel, :final requestDate) =>
        s.t(isChannel ? 'join_request_channel_info' : 'join_request_group_info', {'title': title, 'date': formatChatTime(requestDate, s.locale)}),
      _ => null,
    };
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: [
          Expanded(
            child: info != null && buttons.isEmpty
                ? Padding(padding: const EdgeInsets.all(8), child: Text(info, style: const TextStyle(fontSize: 13)))
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    if (info != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(info, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
                    Row(children: [
                      for (final (label, color, action) in buttons)
                        Expanded(child: TextButton(onPressed: action, child: Text(label, style: TextStyle(color: color), overflow: TextOverflow.ellipsis))),
                    ]),
                  ]),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, size: 20), tooltip: s.t('hide'), onPressed: () => guard(context, dismiss)),
        ]),
      ),
    );
  }
}
