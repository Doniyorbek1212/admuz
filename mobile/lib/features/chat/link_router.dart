import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/link_safety.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/link_policy.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import '../webapp/bot_extras.dart' show joinChatChecked, openWebAppLink;
import '../settings/premium_extras.dart';
import '../settings/business_extras.dart' show openBusinessChatLink;
import '../settings/misc_extras.dart' show openExternalLoginLink;
import '../settings/affiliate_programs.dart' show openAffiliateLink;
import '../settings/stars_extras.dart' show openBoostLink;
import '../settings/telegram_extras.dart' show installLanguagePack;
import 'forward_picker.dart';
import 'oauth_login.dart';
import 'sticker_sets.dart';

/// Explains why a link is risky. Blocked links cannot be opened at all; dangerous ones need a deliberate
/// second tap on a red button. Returns true when the user chose to open the link.
Future<bool> confirmRiskyLink(BuildContext context, String url, LinkRisk risk) async {
  if (!risk.warns) return true;
  final s = context.s;
  final theme = Theme.of(context);
  final blocked = risk.level == LinkRiskLevel.blocked;
  // A website (not a Telegram link) can be put on the user's blocklist straight from the warning.
  final uri = Uri.tryParse(url);
  final site = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') ? normalizeDomain(url) : '';
  final canBlockSite = site.isNotEmpty && site != 't.me' && risk.reasonKey != 'link_risk_user_blocked';
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(risk.isDangerous ? Icons.gpp_bad_rounded : Icons.shield_outlined, color: risk.isDangerous ? theme.colorScheme.error : Colors.orange, size: 40),
      title: Text(s.t(blocked ? 'link_blocked_title' : (risk.isDangerous ? 'link_danger_title' : 'link_caution_title'))),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.t(risk.reasonKey)),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: theme.colorScheme.errorContainer.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(10)),
          child: Text(url, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ),
        if (!blocked) ...[const SizedBox(height: 12), Text(s.t('link_risk_advice'), style: TextStyle(color: theme.hintColor, fontSize: 13))],
      ]),
      actions: [
        if (canBlockSite)
          TextButton(
            onPressed: () {
              ProviderScope.containerOf(context, listen: false).read(linkPolicyProvider.notifier).addDomain(site, blocked: true);
              Navigator.pop(context, false);
              showToast(context, s.t('link_site_blocked', {'site': site}));
            },
            child: Text(s.t('link_block_site')),
          ),
        if (!blocked)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('link_open_anyway')),
          ),
        FilledButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t(blocked ? 'close' : 'link_dont_open'))),
      ],
    ),
  );
  return result ?? false;
}

/// Opens a link inside the app when TDLib recognises it (t.me/…, tg://…), otherwise in the browser.
/// Every link is checked first; [shownText] is the visible text of a text link.
Future<void> openLink(BuildContext context, String url, {String? shownText}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final risk = assessLink(url, shownText: shownText, policy: container.read(linkPolicyProvider));
  if (!await confirmRiskyLink(context, url, risk) || !context.mounted) return;
  final account = container.read(accountProvider);
  td.InternalLinkType? type;
  try {
    type = await account.send<td.InternalLinkType>(td.GetInternalLinkType(link: url));
  } on TdException {
    type = null; // not a Telegram link
  }
  if (!context.mounted) return;
  final handled = type != null && await _openInternal(context, account, type);
  if (handled || !context.mounted) return;
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  if (uri == null) return;
  // Bot login links ask before signing the user in on the site.
  if ((uri.scheme == 'http' || uri.scheme == 'https') && await openExternalLoginLink(context, account, uri.toString())) return;
  if (!context.mounted) return;
  // Telegram's browser setting (Settings → Data → Browser) decides in-app vs external, per site.
  var mode = LaunchMode.externalApplication;
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    try {
      final type = await account.send<td.WebBrowserType>(td.GetLinkWebBrowserType(link: uri.toString()));
      if (type is td.WebBrowserTypeInApp) mode = LaunchMode.inAppBrowserView;
    } on TdException catch (error) {
      debugPrint('browser type unknown: $error');
    }
  }
  await launchUrl(uri, mode: mode);
}

/// Opens a public chat or user by @username.
Future<void> openUsernameChat(BuildContext context, TelegramAccount account, String username, {String draft = ''}) async {
  final chat = await guard(context, () => account.send<td.Chat>(td.SearchPublicChat(username: username)));
  if (chat == null || !context.mounted) return;
  if (draft.isNotEmpty) await _setDraft(account, chat.id, draft);
  if (context.mounted) openChat(context, chat.id);
}

/// Returns false for link kinds the app has no screen for; the caller then opens the browser.
Future<bool> _openInternal(BuildContext context, TelegramAccount account, td.InternalLinkType type) async {
  switch (type) {
    case td.InternalLinkTypePublicChat(:final chatUsername, :final draftText):
      await openUsernameChat(context, account, chatUsername, draft: draftText);
    case td.InternalLinkTypeChatInvite(:final inviteLink):
      await _joinByInvite(context, account, inviteLink);
    case td.InternalLinkTypeMessage(:final url):
      final info = await guard(context, () => account.send<td.MessageLinkInfo>(td.GetMessageLinkInfo(url: url)));
      if (info == null || !context.mounted) return true;
      if (info.chatId == 0) {
        showToast(context, context.t('link_not_found'));
      } else {
        openChat(context, info.chatId, messageId: info.message?.id);
      }
    case td.InternalLinkTypeStickerSet(:final stickerSetName):
      final set = await guard(context, () => account.stickerSetByName(stickerSetName));
      if (set != null && context.mounted) await showStickerSetSheet(context, set.id);
    case td.InternalLinkTypeChatFolderInvite(:final inviteLink):
      await _addFolder(context, account, inviteLink);
    case td.InternalLinkTypeProxy(:final proxy?):
      final s = context.s;
      final ok = await confirm(context, title: s.t('proxy_add'), message: '${proxy.server}:${proxy.port}');
      if (ok && context.mounted) await guard(context, () => account.addProxy(proxy));
    case td.InternalLinkTypeUserPhoneNumber(:final phoneNumber, :final draftText):
      final user = await guard(context, () => account.send<td.User>(td.SearchUserByPhoneNumber(phoneNumber: phoneNumber, onlyLocal: false)));
      if (user != null && context.mounted) await _openUser(context, account, user.id, draft: draftText);
    case td.InternalLinkTypeUserToken(:final token):
      final user = await guard(context, () => account.send<td.User>(td.SearchUserByToken(token: token)));
      if (user != null && context.mounted) await _openUser(context, account, user.id);
    case td.InternalLinkTypeBotStart(:final botUsername, :final startParameter):
      final chat = await guard(context, () => account.send<td.Chat>(td.SearchPublicChat(username: botUsername)));
      if (chat == null || !context.mounted) return true;
      if (chat.type case td.ChatTypePrivate(:final userId)) {
        await guard(context, () => account.send<td.Message>(td.SendBotStartMessage(botUserId: userId, chatId: chat.id, parameter: startParameter)));
      }
      if (context.mounted) openChat(context, chat.id);
    case td.InternalLinkTypePremiumGiftCode(:final code):
      await applyGiftCode(context, account, code);
    // Logging in another device from a message is how accounts get stolen: only the QR scanner may do it.
    case td.InternalLinkTypeQrCodeAuthentication() || td.InternalLinkTypeAuthenticationCode():
      await confirmRiskyLink(context, 'tg://login', const LinkRisk(LinkRiskLevel.blocked, 'link_risk_login'));
    // A prefilled message to forward: the user picks the chat and sends it themselves; nothing goes out automatically.
    case td.InternalLinkTypeMessageDraft(:final text):
      final picked = await Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => const ForwardPickerScreen()));
      if (picked is! int || !context.mounted) return true;
      await _setDraft(account, picked, text.text);
      if (context.mounted) openChat(context, picked);
    case td.InternalLinkTypeBackground(:final backgroundName):
      final background = await guard(context, () => account.send<td.Background>(td.SearchBackground(name: backgroundName)));
      if (background == null || !context.mounted) return true;
      final apply = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.t('chat_background')),
          content: switch (background.document?.thumbnail) {
            final thumb? => ClipRRect(borderRadius: BorderRadius.circular(12), child: AspectRatio(aspectRatio: 0.6, child: TdImage(file: thumb.file))),
            null => Text(background.name),
          },
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.t('background_apply'))),
          ],
        ),
      );
      if (apply != true || !context.mounted) return true;
      await guard(
        context,
        () => account.send<td.Background>(td.SetDefaultBackground(
          background: td.InputBackgroundRemote(backgroundId: background.id),
          type: background.type,
          forDarkTheme: Theme.of(context).brightness == Brightness.dark,
        )),
      );
    case td.InternalLinkTypeChatAffiliateProgram(:final username, :final referrer):
      await openAffiliateLink(context, account, username, referrer);
    case td.InternalLinkTypeChatBoost(:final url):
      await openBoostLink(context, account, url, (chatId) => showBoostSheet(context, account, chatId));
    case td.InternalLinkTypeWebApp() && final link:
      await openWebAppLink(context, account, link);
    case td.InternalLinkTypeBusinessChat(:final linkName):
      await openBusinessChatLink(context, account, linkName, (chatId, text) async {
        await _setDraft(account, chatId, text);
        if (context.mounted) openChat(context, chatId);
      });
    case td.InternalLinkTypeOauth(:final url):
      await handleOauthLink(context, account, url);
    case td.InternalLinkTypeLanguagePack(:final languagePackId):
      await installLanguagePack(context, account, languagePackId);
    case td.InternalLinkTypeSavedMessages():
      final chat = await guard(context, () => account.openPrivateChat(account.myId));
      if (chat != null && context.mounted) openChat(context, chat.id);
    case td.InternalLinkTypeUnknownDeepLink(:final link):
      final info = await guard(context, () => account.send<td.DeepLinkInfo>(td.GetDeepLinkInfo(link: link)));
      if (info == null || !context.mounted) return true;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(info.text.text),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('ok')))],
        ),
      );
    default:
      return false;
  }
  return true;
}

Future<void> _openUser(BuildContext context, TelegramAccount account, int userId, {String draft = ''}) async {
  final chat = await guard(context, () => account.openPrivateChat(userId));
  if (chat == null || !context.mounted) return;
  if (draft.isNotEmpty) await _setDraft(account, chat.id, draft);
  if (context.mounted) openChat(context, chat.id);
}

Future<void> _setDraft(TelegramAccount account, int chatId, String text) async {
  try {
    await account.saveDraft(chatId, text);
  } on TdException {
    // The draft is only a convenience; opening the chat matters more.
  }
}

/// Shows the chat behind an invite link and joins it (or sends a join request) on confirmation.
Future<void> _joinByInvite(BuildContext context, TelegramAccount account, String inviteLink) async {
  final info = await guard(context, () => account.send<td.ChatInviteLinkInfo>(td.CheckChatInviteLink(inviteLink: inviteLink)));
  if (info == null || !context.mounted) return;
  // Already a member, or a preview is available: just open it.
  if (info.chatId != 0 && account.chats[info.chatId]?.positions.isNotEmpty == true) {
    openChat(context, info.chatId);
    return;
  }
  final s = context.s;
  final isChannel = info.type is td.InviteLinkChatTypeChannel;
  final join = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(info.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(s.count(isChannel ? 'subscribers' : 'members', info.memberCount), textAlign: TextAlign.center),
            if (info.description.isNotEmpty) ...[const SizedBox(height: 12), Text(info.description, textAlign: TextAlign.center)],
            if (info.createsJoinRequest) ...[const SizedBox(height: 12), Text(s.t('join_request_hint'), textAlign: TextAlign.center)],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.t(info.createsJoinRequest ? 'join_request_send' : (isChannel ? 'subscribe' : 'join_group'))),
            ),
          ],
        ),
      ),
    ),
  );
  if (join != true || !context.mounted) return;
  final chatId = await joinChatChecked(context, account, td.JoinChatByInviteLink(inviteLink: inviteLink));
  if (chatId != null && context.mounted) openChat(context, chatId);
}

/// Adds a shared folder (t.me/addlist/…) with all of its chats the user is not in yet.
Future<void> _addFolder(BuildContext context, TelegramAccount account, String inviteLink) async {
  final info = await guard(context, () => account.send<td.ChatFolderInviteLinkInfo>(td.CheckChatFolderInviteLink(inviteLink: inviteLink)));
  if (info == null || !context.mounted) return;
  final s = context.s;
  final title = info.chatFolderInfo.name.text.text;
  if (info.missingChatIds.isEmpty) {
    showToast(context, s.t('folder_already_added', {'name': title}));
    return;
  }
  final ok = await confirm(context, title: title, message: s.t('folder_add_hint', {'n': '${info.missingChatIds.length}'}), confirmLabel: s.t('add'));
  if (!ok || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.AddChatFolderByInviteLink(inviteLink: inviteLink, chatIds: info.missingChatIds));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('folder_added', {'name': title}));
}
