import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/forward_picker.dart';
import '../contacts/contacts_screen.dart';
import '../home/home_screen.dart';
import '../profile/profile_more.dart' show handleTooManyChannels;
import 'web_app_screen.dart';

/// Opens a Mini App page for [botUserId] at [url].
Future<void> _pushWebApp(BuildContext context, String url, int botUserId) => Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => WebAppScreen(url: url, botUserId: botUserId),
    ));

// ------------------------------------------------------------------ joining chats

/// Joins by chat id ([JoinChat]) or link ([JoinChatByInviteLink]) and handles every outcome:
/// joined (returns the chat id), request sent, declined, a guard bot check, or the channel limit.
Future<int?> joinChatChecked(BuildContext context, TelegramAccount account, td.TdFunction request) async {
  final s = context.s;
  try {
    final result = await account.send<td.ChatJoinResult>(request);
    if (!context.mounted) return null;
    switch (result) {
      case td.ChatJoinResultSuccess(:final chatId):
        return chatId;
      case td.ChatJoinResultRequestSent():
        showToast(context, s.t('join_request_sent'));
      case td.ChatJoinResultDeclined():
        showToast(context, s.t('join_declined'));
      case td.ChatJoinResultGuardBotApprovalRequired(:final botUserId, :final queryId):
        // The group's guard bot checks the user in a Mini App first; Telegram adds them afterwards.
        final url = await guard(context, () => account.send<td.HttpUrl>(td.GetGuardBotWebAppUrl(queryId: queryId, parameters: webAppParameters(themeParametersOf(context)))));
        if (url != null && context.mounted) await _pushWebApp(context, url.url, botUserId);
    }
  } on TdException catch (error) {
    if (!context.mounted) return null;
    if (error.message == 'INVITE_REQUEST_SENT') {
      showToast(context, s.t('join_request_sent'));
    } else if (!await handleTooManyChannels(context, account, error) && context.mounted) {
      showError(context, error);
    }
  }
  return null;
}

// ------------------------------------------------------------------ bot profile extras

final _similarBotsProvider = FutureProvider.autoDispose.family<(List<int>, int), int>((ref, botUserId) async {
  final account = ref.watch(accountProvider);
  try {
    final bots = await account.send<td.Users>(td.GetBotSimilarBots(botUserId: botUserId));
    final count = await account.send<td.Count>(td.GetBotSimilarBotCount(botUserId: botUserId, returnLocal: false));
    return (bots.userIds, count.count);
  } on TdException {
    return (const <int>[], 0);
  }
});

final _attachmentBotProvider = FutureProvider.autoDispose.family<td.AttachmentMenuBot?, int>((ref, botUserId) async {
  try {
    return await ref.watch(accountProvider).send<td.AttachmentMenuBot>(td.GetAttachmentMenuBot(botUserId: botUserId));
  } on TdException {
    return null;
  }
});

/// Extra rows on a bot's profile: open its main app, attachment menu, emoji status access, similar bots.
class BotProfileExtras extends ConsumerWidget {
  const BotProfileExtras({super.key, required this.bot, required this.chatId, required this.info});

  final td.User bot;
  final int chatId;
  final td.UserFullInfo? info;

  Future<void> _openMainApp(BuildContext context, TelegramAccount account) async {
    final app = await guard(
      context,
      () => account.send<td.MainWebApp>(td.GetMainWebApp(chatId: chatId, botUserId: bot.id, startParameter: '', parameters: webAppParameters(themeParametersOf(context)))),
    );
    if (app != null && context.mounted) await _pushWebApp(context, app.url.url, bot.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final type = bot.type;
    final attach = type is td.UserTypeBot && type.canBeAddedToAttachmentMenu ? ref.watch(_attachmentBotProvider(bot.id)).value : null;
    final similar = ref.watch(_similarBotsProvider(bot.id)).value;
    final botInfo = info?.botInfo;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (type is td.UserTypeBot && type.hasMainWebApp)
        ListTile(leading: const Icon(Icons.apps_rounded), title: Text(s.t('bot_open_app')), onTap: () => _openMainApp(context, account)),
      if (attach != null)
        SwitchListTile(
          secondary: const Icon(Icons.attach_file_rounded),
          title: Text(s.t('bot_attach_menu')),
          value: attach.isAdded,
          onChanged: (on) async {
            if (on && attach.requestWriteAccess && !await confirm(context, title: attach.name, message: s.t('bot_write_access_ask', {'bot': attach.name}))) return;
            if (!context.mounted) return;
            await guard(context, () => account.send<td.Ok>(td.ToggleBotIsAddedToAttachmentMenu(botUserId: bot.id, isAdded: on, allowWriteAccess: on)));
            ref.invalidate(_attachmentBotProvider(bot.id));
          },
        ),
      if (botInfo != null)
        SwitchListTile(
          secondary: const Icon(Icons.emoji_emotions_outlined),
          title: Text(s.t('bot_emoji_status_access')),
          value: botInfo.canManageEmojiStatus,
          onChanged: (on) => guard(context, () => account.send<td.Ok>(td.ToggleBotCanManageEmojiStatus(botUserId: bot.id, canManageEmojiStatus: on))),
        ),
      if (similar != null && similar.$1.isNotEmpty) ...[
        SectionHeader(similar.$2 > similar.$1.length ? '${s.t('similar_bots')} · ${similar.$2}' : s.t('similar_bots')),
        SizedBox(
          height: 100,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final id in similar.$1)
              InkWell(
                onTap: () async {
                  await account.send<td.Ok>(td.OpenBotSimilarBot(botUserId: bot.id, openedBotUserId: id)).catchError((Object _) => const td.Ok());
                  final chat = await account.openPrivateChat(id);
                  if (context.mounted) openChat(context, chat.id);
                },
                child: SizedBox(
                  width: 76,
                  child: Column(children: [
                    const SizedBox(height: 6),
                    UserAvatar(userId: id, size: 52),
                    const SizedBox(height: 4),
                    Text(account.userName(id), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
          ]),
        ),
      ],
    ]);
  }
}

// ------------------------------------------------------------------ Mini App links and store

/// t.me/bot/app links: find the app, ask when Telegram wants confirmation, then open it.
Future<void> openWebAppLink(BuildContext context, TelegramAccount account, td.InternalLinkTypeWebApp link) async {
  final chat = await guard(context, () => account.send<td.Chat>(td.SearchPublicChat(username: link.botUsername)));
  final bot = chat == null ? null : account.privateUser(chat);
  if (bot == null || !context.mounted) return;
  final found = await guard(context, () => account.send<td.FoundWebApp>(td.SearchWebApp(botUserId: bot.id, webAppShortName: link.webAppShortName)));
  if (found == null || !context.mounted) return;
  final s = context.s;
  var allowWrite = false;
  if (!found.skipConfirmation || found.requestWriteAccess) {
    final ok = await confirm(
      context,
      title: found.webApp.title,
      message: found.requestWriteAccess ? s.t('bot_write_access_ask', {'bot': account.userName(bot.id)}) : s.t('webapp_open_ask', {'bot': account.userName(bot.id)}),
      confirmLabel: s.t('open'),
    );
    if (!ok || !context.mounted) return;
    allowWrite = found.requestWriteAccess;
  }
  final url = await guard(
    context,
    () => account.send<td.HttpUrl>(td.GetWebAppLinkUrl(
      chatId: account.myId,
      botUserId: bot.id,
      webAppShortName: link.webAppShortName,
      startParameter: link.startParameter,
      allowWriteAccess: allowWrite,
      parameters: webAppParameters(themeParametersOf(context)),
    )),
  );
  if (url != null && context.mounted) await _pushWebApp(context, url.url, bot.id);
}

final popularWebAppBotsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.FoundUsers>(const td.GetGrossingWebAppBots(offset: '', limit: 12))).userIds;
  } on TdException {
    return const [];
  }
});

final recentInlineBotsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.Users>(const td.GetRecentInlineBots())).userIds;
  } on TdException {
    return const [];
  }
});

/// Mini App asked to share a message the bot prepared (web_app_send_prepared_message): pick a chat and send it.
Future<bool> sendPreparedInlineMessage(BuildContext context, TelegramAccount account, int botUserId, String preparedId, Future<int?> Function() pickChat) async {
  final prepared = await guard(context, () => account.send<td.PreparedInlineMessage>(td.GetPreparedInlineMessage(botUserId: botUserId, preparedMessageId: preparedId)));
  if (prepared == null || !context.mounted) return false;
  final chatId = await pickChat();
  if (chatId == null || !context.mounted) return false;
  final resultId = (prepared.result.toJson()['id'] as String?) ?? '';
  final sent = await guard(context, () => account.sendInlineResult(chatId, prepared.inlineQueryId, resultId));
  return sent != null;
}

/// Mini App asked to download a file (web_app_request_file_download): Telegram checks it, the user confirms.
Future<bool> downloadWebAppFile(BuildContext context, TelegramAccount account, int botUserId, String fileName, String url, Future<void> Function(Uri) open) async {
  final ok = await guard(context, () async {
    await account.send<td.Ok>(td.CheckWebAppFileDownload(botUserId: botUserId, fileName: fileName, url: url));
    return true;
  });
  if (ok != true || !context.mounted) return false;
  final s = context.s;
  final confirmed = await confirm(context, title: s.t('webapp_download'), message: s.t('webapp_download_ask', {'bot': account.userName(botUserId), 'file': fileName}));
  if (!confirmed) return false;
  await open(Uri.parse(url));
  return true;
}

/// Outline Telegram draws while a bot's Mini App loads.
final webAppPlaceholderProvider = FutureProvider.autoDispose.family<td.Outline?, int>((ref, botUserId) async {
  try {
    return await ref.watch(accountProvider).send<td.Outline>(td.GetWebAppPlaceholder(botUserId: botUserId));
  } on TdException {
    return null;
  }
});

/// Mini App asked the user to pick someone for the bot (a keyboard button the bot prepared in advance).
Future<bool> sharePreparedButton(BuildContext context, TelegramAccount account, int botUserId, String preparedId) async {
  final button = await guard(context, () => account.send<td.KeyboardButton>(td.GetPreparedKeyboardButton(botUserId: botUserId, preparedButtonId: preparedId)));
  if (button == null || !context.mounted) return false;
  final source = td.KeyboardButtonSourceWebApp(botUserId: botUserId, preparedButtonId: preparedId);
  switch (button.type) {
    case td.KeyboardButtonTypeRequestUsers(:final id):
      final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
      if (user == null || !context.mounted) return false;
      final ok = await guard(context, () async {
        await account.send<td.Ok>(td.ShareUsersWithBot(source: source, buttonId: id, sharedUserIds: [user.id], onlyCheck: false));
        return true;
      });
      return ok == true;
    case td.KeyboardButtonTypeRequestChat(:final id):
      final picked = await Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => const ForwardPickerScreen()));
      if (picked is! int || !context.mounted) return false;
      final ok = await guard(context, () async {
        await account.send<td.Ok>(td.ShareChatWithBot(source: source, buttonId: id, sharedChatId: picked, onlyCheck: false));
        return true;
      });
      return ok == true;
    default:
      return false;
  }
}
