import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import '../settings/privacy_screen.dart' show promptText;

final _personalPostsProvider = FutureProvider.autoDispose.family<List<td.Message>, int>((ref, userId) async {
  final result = await ref.watch(accountProvider).send<td.Messages>(td.GetPersonalChatHistory(userId: userId, limit: 3));
  return result.messages ?? const [];
});

/// The channel a user pinned to their profile, with its newest posts.
class PersonalChannelCard extends ConsumerWidget {
  const PersonalChannelCard({super.key, required this.userId, required this.channelChatId});

  final int userId;
  final int channelChatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final chat = account.chats[channelChatId];
    final posts = ref.watch(_personalPostsProvider(userId)).value ?? const [];
    return Column(children: [
      ListTile(
        leading: ChatAvatar(chatId: channelChatId, size: 44, showOnline: false),
        title: Text(chat == null ? s.t('personal_channel') : chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(s.t('personal_channel')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => openChat(context, channelChatId),
      ),
      for (final post in posts)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: Text(messagePreview(post, account, s), maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatChatTime(post.date, s.locale)),
          onTap: () => openChat(context, channelChatId, messageId: post.id),
        ),
    ]);
  }
}

/// Opens the user's existing secret chat (CreateSecretChat) or starts a new one after confirming.
Future<void> openSecretChatWith(BuildContext context, TelegramAccount account, td.User user) async {
  final s = context.s;
  final existing = account.secretChats.values.where((c) => c.userId == user.id && c.state is! td.SecretChatStateClosed).firstOrNull;
  td.Chat? chat;
  if (existing != null) {
    chat = await guard(context, () => account.send<td.Chat>(td.CreateSecretChat(secretChatId: existing.id)));
  } else {
    final ok = await confirm(context, title: s.t('start_secret_chat'), message: s.t('secret_chat_confirm', {'name': user.firstName}));
    if (!ok || !context.mounted) return;
    chat = await guard(context, () => account.createSecretChat(user.id));
  }
  if (chat == null || !context.mounted) return;
  Navigator.of(context).popUntil((route) => route.isFirst);
  openChat(context, chat.id);
}

/// Pixel colors Telegram uses for the 12×12 encryption key picture.
const _keyColors = [Color(0xFFFFFFFF), Color(0xFFD5E6F3), Color(0xFF2D5775), Color(0xFF2F99C9)];

/// 2-bit pixels of the key picture, left to right, top to bottom (144 pixels from 36 bytes).
List<int> secretKeyPixels(List<int> hash) => [
      for (var i = 0; i < 144 && i ~/ 4 < hash.length; i++) (hash[i ~/ 4] >> ((i % 4) * 2)) & 3,
    ];

/// Shows a secret chat's encryption key so both people can compare it in person.
Future<void> showSecretChatKey(BuildContext context, TelegramAccount account, int secretChatId) async {
  final secret = await guard(context, () => account.send<td.SecretChat>(td.GetSecretChat(secretChatId: secretChatId)));
  if (secret == null || !context.mounted) return;
  final s = context.s;
  final hash = base64Decode(secret.keyHash);
  final pixels = secretKeyPixels(hash);
  final hex = [for (final b in hash.take(32)) b.toRadixString(16).padLeft(2, '0')];
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('encryption_key')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (pixels.length == 144)
          SizedBox.square(
            dimension: 192,
            child: GridView.count(
              crossAxisCount: 12,
              physics: const NeverScrollableScrollPhysics(),
              children: [for (final p in pixels) ColoredBox(color: _keyColors[p])],
            ),
          ),
        const SizedBox(height: 12),
        for (var row = 0; row < hex.length; row += 8)
          Text(hex.skip(row).take(8).join(' '), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        const SizedBox(height: 12),
        Text(s.t('encryption_key_hint', {'name': account.userName(secret.userId)}), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
        Text('Layer ${secret.layer}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
    ),
  );
}

/// Report reasons offered for chats, photos and stories, with their label keys.
final reportReasons = <(String, td.ReportReason)>[
  ('report_spam', const td.ReportReasonSpam()),
  ('report_violence', const td.ReportReasonViolence()),
  ('report_pornography', const td.ReportReasonPornography()),
  ('report_child_abuse', const td.ReportReasonChildAbuse()),
  ('report_copyright', const td.ReportReasonCopyright()),
  ('report_fake', const td.ReportReasonFake()),
  ('report_drugs', const td.ReportReasonIllegalDrugs()),
  ('report_personal_details', const td.ReportReasonPersonalDetails()),
  ('report_other', const td.ReportReasonCustom()),
];

/// Reports one profile photo of a chat or user (only full photos from the photo history).
Future<void> reportChatPhoto(BuildContext context, TelegramAccount account, int chatId, int fileId) async {
  final s = context.s;
  final reason = await showModalBottomSheet<td.ReportReason>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final (label, reason) in reportReasons) ListTile(title: Text(s.t(label)), onTap: () => Navigator.pop(context, reason)),
      ]),
    ),
  );
  if (reason == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.ReportChatPhoto(chatId: chatId, fileId: fileId, reason: reason, text: ''));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('report_sent'));
}

/// Whether Telegram offers its "Translate" bar in this chat.
class TranslatableTile extends ConsumerWidget {
  const TranslatableTile({super.key, required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    if (chat == null) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.translate_rounded),
      title: Text(context.t('chat_translatable')),
      subtitle: Text(context.t('chat_translatable_hint')),
      value: chat.isTranslatable,
      onChanged: (on) => guard(context, () => account.send<td.Ok>(td.ToggleChatIsTranslatable(chatId: chatId, isTranslatable: on))),
    );
  }
}

/// Picks the channel shown on the user's own profile, or removes it.
Future<void> pickPersonalChannel(BuildContext context, TelegramAccount account, {required bool hasOne}) async {
  final s = context.s;
  final suitable = await guard(context, () => account.send<td.Chats>(const td.GetSuitablePersonalChats()));
  if (suitable == null || !context.mounted) return;
  final picked = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          if (hasOne)
            ListTile(
              leading: Icon(Icons.link_off_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('personal_channel_remove'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 0),
            ),
          if (suitable.chatIds.isEmpty) ListTile(title: Text(s.t('personal_channel_none'))),
          for (final id in suitable.chatIds)
            ListTile(
              leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
              title: Text(account.chats[id] == null ? '$id' : chatTitle(account.chats[id]!, account, s)),
              onTap: () => Navigator.pop(context, id),
            ),
        ]),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.SetPersonalChat(chatId: picked));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('done'));
}

/// Profile tabs a person can open first, with their label keys.
final profileTabs = <(String, td.ProfileTab)>[
  ('profile_tab_posts', const td.ProfileTabPosts()),
  ('profile_tab_gifts', const td.ProfileTabGifts()),
  ('profile_tab_media', const td.ProfileTabMedia()),
  ('profile_tab_files', const td.ProfileTabFiles()),
  ('profile_tab_links', const td.ProfileTabLinks()),
  ('profile_tab_music', const td.ProfileTabMusic()),
  ('profile_tab_voice', const td.ProfileTabVoice()),
  ('profile_tab_gifs', const td.ProfileTabGifs()),
];

/// Chooses which tab opens first on the user's own profile.
Future<void> pickMainProfileTab(BuildContext context, TelegramAccount account, td.ProfileTab? current) async {
  final s = context.s;
  final picked = await showModalBottomSheet<td.ProfileTab>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final (label, tab) in profileTabs)
          ListTile(
            title: Text(s.t(label)),
            trailing: current.runtimeType == tab.runtimeType ? const Icon(Icons.check_rounded) : null,
            onTap: () => Navigator.pop(context, tab),
          ),
      ]),
    ),
  );
  if (picked == null || !context.mounted) return;
  await guard(context, () => account.send<td.Ok>(td.SetMainProfileTab(mainProfileTab: picked)));
}

/// Label key of a profile tab, for showing the current choice.
String? profileTabLabel(td.ProfileTab? tab) => profileTabs.where((e) => e.$2.runtimeType == tab.runtimeType).firstOrNull?.$1;

/// Copies or shares a link to the user's profile (a temporary one when there is no username).
Future<void> shareMyProfileLink(BuildContext context, TelegramAccount account) async {
  final link = await guard(context, () => account.send<td.UserLink>(const td.GetUserLink()));
  if (link == null || !context.mounted) return;
  final s = context.s;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('profile_link')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(link.url),
        if (link.expiresIn > 0) ...[
          const SizedBox(height: 8),
          Text(s.t('profile_link_expires', {'time': formatDuration(Duration(seconds: link.expiresIn))}), style: TextStyle(color: Theme.of(context).hintColor)),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: link.url));
            Navigator.pop(context);
            showToast(context, s.t('copied'));
          },
          child: Text(s.t('copy')),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            SharePlus.instance.share(ShareParams(text: link.url));
          },
          child: Text(s.t('share')),
        ),
      ],
    ),
  );
}

/// Why [username] can't be used for [chatId] (0 for a chat being created, my id for myself); null when it is free.
Future<String?> usernameProblem(TelegramAccount account, int chatId, String username, Strings s) async {
  try {
    final result = await account.send<td.CheckChatUsernameResult>(td.CheckChatUsername(chatId: chatId, username: username));
    return switch (result) {
      td.CheckChatUsernameResultOk() => null,
      td.CheckChatUsernameResultUsernameInvalid() => s.t('username_invalid'),
      td.CheckChatUsernameResultUsernameOccupied() => s.t('username_taken'),
      td.CheckChatUsernameResultUsernamePurchasable() => s.t('username_purchasable'),
      td.CheckChatUsernameResultPublicChatsTooMany() => s.t('public_chats_limit'),
      td.CheckChatUsernameResultPublicGroupsUnavailable() => s.t('public_groups_unavailable'),
      _ => null,
    };
  } on TdException catch (error) {
    return error.message;
  }
}

/// Before making a new public chat: when the limit is reached, offers to free a link of an older one.
/// Returns true when a new public link may be created now.
Future<bool> ensurePublicChatSlot(BuildContext context, TelegramAccount account) async {
  try {
    await account.send<td.Ok>(const td.CheckCreatedPublicChatsLimit(type: td.PublicChatTypeHasUsername()));
    return true;
  } on TdException {
    // Limit reached; fall through to the list of owned public chats.
  }
  if (!context.mounted) return false;
  final owned = await guard(context, () => account.send<td.Chats>(const td.GetCreatedPublicChats(type: td.PublicChatTypeHasUsername())));
  if (owned == null || !context.mounted) return false;
  final s = context.s;
  final freed = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(s.t('public_chats_too_many_hint'))),
          for (final id in owned.chatIds)
            if (account.chats[id] case final chat?)
              ListTile(
                leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
                title: Text(chatTitle(chat, account, s)),
                subtitle: Text('t.me/${account.usernameOf(chat) ?? ''}'),
                trailing: TextButton(onPressed: () => Navigator.pop(context, id), child: Text(s.t('public_link_revoke'))),
              ),
        ]),
      ),
    ),
  );
  if (freed == null || !context.mounted) return false;
  final group = account.chats[freed] == null ? null : account.supergroupOf(account.chats[freed]!);
  if (group == null) return false;
  final ok = await guard(context, () async {
    await account.send<td.Ok>(td.SetSupergroupUsername(supergroupId: group.id, username: ''));
    return true;
  });
  return ok == true;
}

/// Renames a chat for this device only; Telegram and other people still see the real name.
Future<void> renameChatLocally(BuildContext context, TelegramAccount account, td.Chat chat) async {
  final s = context.s;
  final name = await promptText(context, title: s.t('local_name'), label: s.t('local_name_hint'), initial: localChatName(chat) ?? '');
  if (name == null || !context.mounted) return;
  await guard(context, () => account.setLocalChatName(chat.id, name));
}

/// Joining failed because the user is in too many groups and channels: offers the inactive ones to leave.
/// Returns true when [error] was that limit (and so was handled here).
Future<bool> handleTooManyChannels(BuildContext context, TelegramAccount account, TdException error) async {
  if (error.message != 'CHANNELS_TOO_MUCH') return false;
  final inactive = await guard(context, () => account.send<td.Chats>(const td.GetInactiveSupergroupChats()));
  if (inactive == null || !context.mounted) return true;
  final s = context.s;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: ListView(shrinkWrap: true, children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(s.t('channels_limit'))),
            for (final id in inactive.chatIds)
              if (account.chats[id] case final chat? when account.isMember(chat))
                ListTile(
                  leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
                  title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(chatSubtitle(chat, account, s), maxLines: 1),
                  trailing: TextButton(
                    onPressed: () async {
                      await guard(context, () => account.send<td.Ok>(td.LeaveChat(chatId: id)));
                      setSheetState(() {});
                    },
                    child: Text(s.t('leave')),
                  ),
                ),
          ]),
        ),
      ),
    ),
  );
  return true;
}

/// Asks before leaving a group or channel; the owner also sees who will own it next.
Future<bool> confirmLeaveChat(BuildContext context, TelegramAccount account, td.Chat chat) async {
  final s = context.s;
  var message = s.t('leave_confirm');
  final status = account.supergroupOf(chat)?.status ?? account.basicGroupOf(chat)?.status;
  if (status is td.ChatMemberStatusCreator) {
    try {
      final next = await account.send<td.User>(td.GetChatOwnerAfterLeaving(chatId: chat.id));
      message = '$message\n\n${s.t('owner_after_leaving', {'name': account.userName(next.id)})}';
    } on TdException catch (error) {
      // Nobody can take over (no admins): TDLib answers with an error, the chat simply loses its owner.
      debugPrint('owner after leaving: $error');
    }
  }
  if (!context.mounted) return false;
  return confirm(context, title: s.t('leave'), message: message, destructive: true);
}
