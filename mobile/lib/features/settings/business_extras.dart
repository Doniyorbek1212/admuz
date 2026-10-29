import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/link_router.dart' show openLink;
import 'privacy_screen.dart' show promptText;

// ------------------------------------------------------------------ chatbot for the business account

/// Telegram Business → Chatbots: one bot that answers private chats on the user's behalf.
class BusinessBotScreen extends ConsumerStatefulWidget {
  const BusinessBotScreen({super.key});

  @override
  ConsumerState<BusinessBotScreen> createState() => _BusinessBotScreenState();
}

class _BusinessBotScreenState extends ConsumerState<BusinessBotScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.BusinessConnectedBot? _bot;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    td.BusinessConnectedBot? bot;
    try {
      bot = await _account.send<td.BusinessConnectedBot>(const td.GetBusinessConnectedBot());
    } on TdException catch (error) {
      // 404: no bot connected.
      if (error.code != 404) debugPrint('connected bot unavailable: $error');
    }
    if (mounted) {
      setState(() {
        _bot = bot;
        _loaded = true;
      });
    }
  }

  static const _allRights = td.BusinessBotRights(
    canReply: true,
    canReadMessages: true,
    canDeleteSentMessages: true,
    canDeleteAllMessages: false,
    canEditName: false,
    canEditBio: false,
    canEditProfilePhoto: false,
    canEditUsername: false,
    canViewGiftsAndStars: false,
    canSellGifts: false,
    canChangeGiftSettings: false,
    canTransferAndUpgradeGifts: false,
    canTransferStars: false,
    canManageStories: false,
  );

  Future<void> _save(td.BusinessConnectedBot bot) async {
    final ok = await guard(context, () async {
      await _account.send<td.Ok>(td.SetBusinessConnectedBot(bot: bot));
      return true;
    });
    if (ok == true) await _load();
  }

  Future<void> _connect() async {
    final s = context.s;
    final name = await promptText(context, title: s.t('biz_bot_connect'), label: '@username');
    final username = name?.trim().replaceFirst('@', '') ?? '';
    if (username.isEmpty || !mounted) return;
    final chat = await guard(context, () => _account.send<td.Chat>(td.SearchPublicChat(username: username)));
    if (chat == null || !mounted) return;
    final user = _account.privateUser(chat);
    if (user == null || user.type is! td.UserTypeBot) {
      showToast(context, s.t('biz_bot_not_bot'));
      return;
    }
    await _save(td.BusinessConnectedBot(
      botUserId: user.id,
      recipients: const td.BusinessRecipients(
        chatIds: [],
        excludedChatIds: [],
        selectExistingChats: true,
        selectNewChats: true,
        selectContacts: false,
        selectNonContacts: false,
        excludeSelected: false,
      ),
      rights: _allRights,
    ));
  }

  Widget _recipient(td.BusinessConnectedBot bot, String key, bool value, td.BusinessRecipients Function(bool) change) => SwitchListTile(
        title: Text(context.t(key)),
        value: value,
        onChanged: (on) => _save(td.BusinessConnectedBot(botUserId: bot.botUserId, recipients: change(on), rights: bot.rights)),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final bot = _bot;
    final r = bot?.recipients;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('biz_chatbots'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(padding: const EdgeInsets.all(16), child: Text(s.t('biz_chatbots_hint'), style: TextStyle(color: Theme.of(context).hintColor))),
              if (bot == null)
                ListTile(leading: const Icon(Icons.smart_toy_outlined), title: Text(s.t('biz_bot_connect')), onTap: _connect)
              else ...[
                ListTile(
                  leading: UserAvatar(userId: bot.botUserId, size: 42),
                  title: Text(_account.userName(bot.botUserId)),
                  subtitle: Text(s.t('biz_bot_connected')),
                ),
                SectionHeader(s.t('biz_bot_chats')),
                _recipient(bot, 'biz_bot_existing', r!.selectExistingChats, (on) => _copy(r, selectExistingChats: on)),
                _recipient(bot, 'biz_bot_new', r.selectNewChats, (on) => _copy(r, selectNewChats: on)),
                _recipient(bot, 'biz_bot_contacts', r.selectContacts, (on) => _copy(r, selectContacts: on)),
                _recipient(bot, 'biz_bot_non_contacts', r.selectNonContacts, (on) => _copy(r, selectNonContacts: on)),
                SwitchListTile(
                  title: Text(s.t('biz_bot_can_reply')),
                  value: bot.rights.canReply,
                  onChanged: (on) => _save(td.BusinessConnectedBot(botUserId: bot.botUserId, recipients: r, rights: td.BusinessBotRights.fromJson({...bot.rights.toJson(), 'can_reply': on})!)),
                ),
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(s.t('biz_bot_confirm')),
                  subtitle: Text(s.t('biz_bot_confirm_hint')),
                  onTap: () async {
                    await guard(context, () => _account.send<td.Ok>(td.ConfirmBusinessConnectedBot(botUserId: bot.botUserId)));
                    if (context.mounted) showToast(context, s.t('done'));
                  },
                ),
                ListTile(
                  leading: Icon(Icons.link_off_rounded, color: Theme.of(context).colorScheme.error),
                  title: Text(s.t('biz_bot_disconnect'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () async {
                    await guard(context, () => _account.send<td.Ok>(td.DeleteBusinessConnectedBot(botUserId: bot.botUserId)));
                    await _load();
                  },
                ),
              ],
            ]),
    );
  }
}

td.BusinessRecipients _copy(td.BusinessRecipients r, {bool? selectExistingChats, bool? selectNewChats, bool? selectContacts, bool? selectNonContacts}) =>
    td.BusinessRecipients(
      chatIds: r.chatIds,
      excludedChatIds: r.excludedChatIds,
      selectExistingChats: selectExistingChats ?? r.selectExistingChats,
      selectNewChats: selectNewChats ?? r.selectNewChats,
      selectContacts: selectContacts ?? r.selectContacts,
      selectNonContacts: selectNonContacts ?? r.selectNonContacts,
      excludeSelected: r.excludeSelected,
    );

/// Bar above a private chat the business bot is answering: pause/resume it here, stop it for this chat, or manage it.
class BusinessBotBar extends ConsumerWidget {
  const BusinessBotBar({super.key, required this.chat});

  final td.Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bar = chat.businessBotManageBar;
    if (bar == null) return const SizedBox.shrink();
    final s = context.s;
    final account = ref.watch(accountProvider);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: ListTile(
        dense: true,
        leading: UserAvatar(userId: bar.botUserId, size: 34),
        title: Text(account.userName(bar.botUserId), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(s.t(bar.isBotPaused ? 'biz_bot_paused' : (bar.canBotReply ? 'biz_bot_replying' : 'biz_bot_reading'))),
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            switch (action) {
              case 'pause':
                await guard(context, () => account.send<td.Ok>(td.ToggleBusinessConnectedBotChatIsPaused(chatId: chat.id, isPaused: !bar.isBotPaused)));
              case 'remove':
                await guard(context, () => account.send<td.Ok>(td.RemoveBusinessConnectedBotFromChat(chatId: chat.id)));
              case 'manage':
                if (bar.manageUrl.isNotEmpty) await openLink(context, bar.manageUrl);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'pause', child: Text(s.t(bar.isBotPaused ? 'biz_bot_resume' : 'biz_bot_pause'))),
            PopupMenuItem(value: 'remove', child: Text(s.t('biz_bot_remove_chat'))),
            if (bar.manageUrl.isNotEmpty) PopupMenuItem(value: 'manage', child: Text(s.t('manage'))),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ business features list

final businessFeaturesProvider = FutureProvider.autoDispose<List<td.BusinessFeature>>((ref) async {
  try {
    return (await ref.watch(accountProvider).send<td.BusinessFeatures>(const td.GetBusinessFeatures(source: null))).features;
  } on TdException {
    return const [];
  }
});

/// Label key for a Telegram Business feature.
String businessFeatureKey(td.BusinessFeature feature) => switch (feature) {
      td.BusinessFeatureLocation() => 'biz_location',
      td.BusinessFeatureOpeningHours() => 'biz_hours',
      td.BusinessFeatureQuickReplies() => 'biz_quick_replies',
      td.BusinessFeatureGreetingMessage() => 'biz_greeting',
      td.BusinessFeatureAwayMessage() => 'biz_away',
      td.BusinessFeatureChatFolderTags() => 'folder_tags',
      td.BusinessFeatureBots() => 'biz_chatbots',
      td.BusinessFeatureStartPage() => 'biz_intro',
      td.BusinessFeatureAccountLinks() => 'biz_links',
      _ => 'telegram_business',
    };

// ------------------------------------------------------------------ business chat links (t.me/m/…)

/// Opens the business account behind a t.me/m/… link with its prepared message in the input field.
Future<void> openBusinessChatLink(BuildContext context, TelegramAccount account, String linkName, Future<void> Function(int chatId, String text) setDraft) async {
  final info = await guard(context, () => account.send<td.BusinessChatLinkInfo>(td.GetBusinessChatLinkInfo(linkName: linkName)));
  if (info == null || !context.mounted) return;
  if (info.text.text.isNotEmpty) await setDraft(info.chatId, info.text.text);
}

// ------------------------------------------------------------------ quick reply extras

/// Adds 2–10 photos as one album message to a quick reply shortcut.
Future<void> addQuickReplyAlbum(BuildContext context, TelegramAccount account, String shortcutName) async {
  final files = await ImagePicker().pickMultiImage(imageQuality: 90, maxWidth: 2560, limit: 10);
  if (files.isEmpty || !context.mounted) return;
  if (files.length < 2) {
    showToast(context, context.t('biz_album_min'));
    return;
  }
  await guard(
    context,
    () => account.send<td.QuickReplyMessages>(td.AddQuickReplyShortcutMessageAlbum(
      shortcutName: shortcutName,
      replyToMessageId: 0,
      inputMessageContents: [for (final f in files.take(10)) photoContent(f.path)],
    )),
  );
}

/// Adds an inline bot result (e.g. @gif cats) as a quick reply message.
Future<void> addQuickReplyFromInlineBot(BuildContext context, TelegramAccount account, String shortcutName) async {
  final s = context.s;
  final input = await promptText(context, title: s.t('biz_inline_bot'), label: '@bot ${s.t('search')}');
  final text = input?.trim().replaceFirst('@', '') ?? '';
  final space = text.indexOf(' ');
  if (text.isEmpty || !context.mounted) return;
  final username = space < 0 ? text : text.substring(0, space);
  final query = space < 0 ? '' : text.substring(space + 1);
  final chat = await guard(context, () => account.send<td.Chat>(td.SearchPublicChat(username: username)));
  final bot = chat == null ? null : account.privateUser(chat);
  if (bot == null || !context.mounted) return;
  final results = await guard(context, () => account.inlineResults(bot.id, account.myId, query));
  if (results == null || !context.mounted) return;
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          if (results.results.isEmpty) ListTile(title: Text(s.t('nothing_found'))),
          for (final result in results.results) ListTile(title: Text(_inlineTitle(result)), onTap: () => Navigator.pop(context, _inlineId(result))),
        ]),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.QuickReplyMessage>(td.AddQuickReplyShortcutInlineQueryResultMessage(
      shortcutName: shortcutName,
      replyToMessageId: 0,
      queryId: results.inlineQueryId,
      resultId: picked,
      hideViaBot: false,
    )),
  );
}

String _inlineId(td.InlineQueryResult result) => (result.toJson()['id'] as String?) ?? '';

String _inlineTitle(td.InlineQueryResult result) {
  final json = result.toJson();
  return (json['title'] as String?)?.isNotEmpty == true ? json['title'] as String : (json['@type'] as String? ?? '').replaceFirst('inlineQueryResult', '');
}
