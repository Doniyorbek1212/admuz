import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart';

/// Story "⋮" menu. Returns true when the story was deleted and the viewer should move on.
Future<bool> showStoryMenu(BuildContext context, TelegramAccount account, td.Story story) async {
  final s = context.s;
  final mine = story.posterChatId == account.myId;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, key, value) in <(IconData, String, String)>[
              if (story.canGetInteractions) (Icons.visibility_rounded, 'story_viewers', 'viewers'),
              if (story.canBeEdited) (Icons.edit_rounded, 'story_edit_caption', 'caption'),
              if (story.canSetPrivacySettings) (Icons.lock_outline_rounded, 'story_privacy', 'privacy'),
              if (story.canToggleIsPostedToChatPage)
                (story.isPostedToChatPage ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
                    story.isPostedToChatPage ? 'story_unpin_profile' : 'story_pin_profile', 'profile'),
              if (!mine) (Icons.visibility_off_rounded, 'story_stealth', 'stealth'),
              if (!mine) (Icons.archive_outlined, 'story_hide_chat', 'hide'),
              if (!mine) (Icons.flag_outlined, 'report', 'report'),
              if (story.canBeDeleted) (Icons.delete_rounded, 'delete', 'delete'),
            ])
              ListTile(
                leading: Icon(icon, color: value == 'delete' ? Theme.of(context).colorScheme.error : null),
                title: Text(s.t(key), style: value == 'delete' ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  switch (action) {
    case 'viewers':
      await _showViewers(context, account, story);
    case 'caption':
      final text = await promptText(context, title: s.t('story_edit_caption'), label: s.t('caption'), initial: story.caption.text);
      if (text != null && context.mounted) {
        await guard(context, () => account.send<td.Ok>(td.EditStory(
              storyPosterChatId: story.posterChatId,
              storyId: story.id,
              content: null,
              areas: null,
              caption: td.FormattedText(text: text, entities: const []),
            )));
      }
    case 'privacy':
      final options = <String, String>{'everyone': s.t('everybody'), 'contacts': s.t('my_contacts'), 'close': s.t('close_friends')};
      final chosen = await pickOption(context, s.t('story_privacy'), options, null);
      if (chosen == null || !context.mounted) return false;
      final td.StoryPrivacySettings privacy = switch (chosen) {
        'contacts' => const td.StoryPrivacySettingsContacts(exceptUserIds: []),
        'close' => const td.StoryPrivacySettingsCloseFriends(),
        _ => const td.StoryPrivacySettingsEveryone(exceptUserIds: []),
      };
      await guard(context, () => account.send<td.Ok>(td.SetStoryPrivacySettings(storyId: story.id, privacySettings: privacy)));
    case 'profile':
      await guard(
        context,
        () => account.send<td.Ok>(td.ToggleStoryIsPostedToChatPage(storyPosterChatId: story.posterChatId, storyId: story.id, isPostedToChatPage: !story.isPostedToChatPage)),
      );
    case 'stealth':
      final ok = await guard(context, () async {
        await account.send<td.Ok>(const td.ActivateStoryStealthMode());
        return true;
      });
      if (ok == true && context.mounted) showToast(context, s.t('story_stealth_on'));
    case 'hide':
      await guard(context, () => account.send<td.Ok>(td.SetChatActiveStoriesList(chatId: story.posterChatId, storyList: const td.StoryListArchive())));
      if (context.mounted) showToast(context, s.t('story_hidden_chat'));
    case 'report':
      await _report(context, account, story);
    case 'delete':
      final ok = await confirm(context, title: s.t('story_delete_confirm'), destructive: true);
      if (!ok || !context.mounted) return false;
      final done = await guard(context, () async {
        await account.send<td.Ok>(td.DeleteStory(storyPosterChatId: story.posterChatId, storyId: story.id));
        return true;
      });
      return done == true;
  }
  return false;
}

Future<void> _showViewers(BuildContext context, TelegramAccount account, td.Story story) async {
  final s = context.s;
  final result = await guard(
    context,
    () => account.send<td.StoryInteractions>(td.GetStoryInteractions(
      storyId: story.id,
      query: '',
      onlyContacts: false,
      preferForwards: false,
      preferWithReaction: true,
      offset: '',
      limit: 100,
    )),
  );
  if (result == null || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(s.count('views', result.totalCount), style: Theme.of(context).textTheme.titleMedium),
          ),
          if (result.interactions.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s.t('seen_nobody'))),
          for (final item in result.interactions)
            ListTile(
              leading: switch (item.actorId) {
                td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 40, showOnline: false),
                td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 40, showOnline: false),
                _ => const SizedBox.square(dimension: 40),
              },
              title: Text(account.senderName(item.actorId)),
              subtitle: Text(formatChatTime(item.interactionDate, s.locale)),
              trailing: switch (item.type) {
                td.StoryInteractionTypeView(chosenReactionType: td.ReactionTypeEmoji(:final emoji)) => Text(emoji, style: const TextStyle(fontSize: 20)),
                td.StoryInteractionTypeForward() || td.StoryInteractionTypeRepost() => const Icon(Icons.repeat_rounded),
                _ => null,
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> _report(BuildContext context, TelegramAccount account, td.Story story) async {
  final s = context.s;
  var optionId = '';
  var text = '';
  for (var step = 0; step < 6; step++) {
    final td.ReportStoryResult result;
    try {
      result = await account.send<td.ReportStoryResult>(td.ReportStory(storyPosterChatId: story.posterChatId, storyId: story.id, optionId: optionId, text: text));
    } on TdException catch (error) {
      if (context.mounted) showError(context, error);
      return;
    }
    if (!context.mounted) return;
    switch (result) {
      case td.ReportStoryResultOptionRequired(:final title, :final options):
        final chosen = await pickOption(context, title, {for (final o in options) o.id: o.text}, null);
        if (chosen == null) return;
        optionId = chosen;
      case td.ReportStoryResultTextRequired(optionId: final id):
        final details = await promptText(context, title: s.t('report_details'), label: s.t('report_details_hint'));
        if (details == null) return;
        optionId = id;
        text = details;
      default:
        showToast(context, s.t('report_sent'));
        return;
    }
  }
}
