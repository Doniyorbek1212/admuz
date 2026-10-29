import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/calls/call_service.dart';
import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../calls/video_chat_screen.dart';
import '../settings/privacy_screen.dart' show promptText;
import 'stories.dart';
import 'story_archive.dart' show StoryGrid;

// ------------------------------------------------------------------ public story search

/// Public stories found by hashtag, place or venue, shown as a grid that opens the player.
class FoundStoriesScreen extends ConsumerStatefulWidget {
  const FoundStoriesScreen({super.key, required this.title, required this.search});

  final String title;
  final td.TdFunction Function(String offset) search;

  @override
  ConsumerState<FoundStoriesScreen> createState() => _FoundStoriesScreenState();
}

class _FoundStoriesScreenState extends ConsumerState<FoundStoriesScreen> {
  final List<td.Story> _stories = [];
  String _next = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final found = await guard(context, () => ref.read(accountProvider).send<td.FoundStories>(widget.search(_next)));
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (found != null) {
        _stories.addAll(found.stories);
        _next = found.nextOffset;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    // The player needs one poster per feed entry; group the results by who posted them.
    final byChat = <int, List<td.Story>>{};
    for (final story in _stories) {
      (byChat[story.posterChatId] ??= []).add(story);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stories.isEmpty
              ? Center(child: Text(s.t('nothing_found')))
              : ListView(children: [
                  for (final MapEntry(key: chatId, value: stories) in byChat.entries) ...[
                    ListTile(
                      leading: ChatAvatar(chatId: chatId, size: 34, showOnline: false),
                      title: Text(ref.watch(accountProvider).chats[chatId]?.title ?? ''),
                    ),
                    StoryGrid(chatId: chatId, stories: stories),
                  ],
                  if (_next.isNotEmpty) TextButton(onPressed: _load, child: Text(s.t('load_more'))),
                ]),
    );
  }
}

void openStoriesByTag(BuildContext context, String tag) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FoundStoriesScreen(title: tag, search: (offset) => td.SearchPublicStoriesByTag(storyPosterChatId: 0, tag: tag, offset: offset, limit: 30)),
    ));

/// Stories tagged with the place shown on [area] (a location sticker or a venue).
void openStoriesForArea(BuildContext context, td.StoryAreaType area) {
  final screen = switch (area) {
    td.StoryAreaTypeVenue(:final venue) => FoundStoriesScreen(
        title: venue.title,
        search: (offset) => td.SearchPublicStoriesByVenue(venueProvider: venue.provider, venueId: venue.id, offset: offset, limit: 30),
      ),
    td.StoryAreaTypeLocation(:final address?) => FoundStoriesScreen(
        title: [address.city, address.street].where((p) => p.isNotEmpty).join(', '),
        search: (offset) => td.SearchPublicStoriesByLocation(address: address, offset: offset, limit: 30),
      ),
    _ => null,
  };
  if (screen != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
}

// ------------------------------------------------------------------ viewer helpers

/// The full reaction list for a story (long press on the heart).
Future<String?> pickStoryReaction(BuildContext context, TelegramAccount account) async {
  final available = await guard(context, () => account.send<td.AvailableReactions>(const td.GetStoryAvailableReactions(rowSize: 8)));
  if (available == null || !context.mounted) return null;
  final emojis = <String>{
    for (final r in [...available.topReactions, ...available.recentReactions, ...available.popularReactions])
      if (!r.needsPremium || account.me?.isPremium == true)
        if (r.type case td.ReactionTypeEmoji(:final emoji)) emoji,
  };
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Wrap(spacing: 4, runSpacing: 4, children: [
          for (final emoji in emojis)
            InkWell(onTap: () => Navigator.pop(context, emoji), child: Padding(padding: const EdgeInsets.all(6), child: Text(emoji, style: const TextStyle(fontSize: 28)))),
        ]),
      ),
    ),
  );
}

/// A chat's current stories (fetched when the chat isn't in the loaded story lists), opened in the player.
Future<void> openChatActiveStories(BuildContext context, TelegramAccount account, int chatId) async {
  final active = await guard(context, () => account.send<td.ChatActiveStories>(td.GetChatActiveStories(chatId: chatId)));
  if (active == null || !context.mounted) return;
  if (active.stories.isEmpty) {
    showToast(context, context.t('stories_none_active'));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoryViewer(feed: [active], initialIndex: 0)));
}

/// New frame for a video story's cover, picked as a second of the video.
Future<void> editStoryCover(BuildContext context, TelegramAccount account, td.Story story) async {
  final s = context.s;
  final duration = switch (story.content) {
    td.StoryContentVideo(:final video) => video.duration,
    _ => 0.0,
  };
  final text = await promptText(context, title: s.t('story_cover'), label: s.t('story_cover_second', {'n': duration.toStringAsFixed(1)}), keyboard: TextInputType.number);
  final second = double.tryParse(text?.replaceAll(',', '.') ?? '');
  if (second == null || second < 0 || !context.mounted) return;
  await guard(context, () => account.send<td.Ok>(td.EditStoryCover(storyPosterChatId: story.posterChatId, storyId: story.id, coverFrameTimestamp: second.clamp(0, duration))));
}

/// Who posts the story: the user, or one of the channels/groups where they may post stories.
Future<int?> pickStoryPoster(BuildContext context, TelegramAccount account) async {
  td.Chats? chats;
  try {
    chats = await account.send<td.Chats>(const td.GetChatsToPostStories());
  } on TdException catch (error) {
    debugPrint('chats to post stories: $error');
  }
  if (!context.mounted) return null;
  if (chats == null || chats.chatIds.isEmpty) return account.myId;
  final s = context.s;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text(s.t('story_post_as'), style: const TextStyle(fontWeight: FontWeight.w700))),
        ListTile(leading: UserAvatar(userId: account.myId, size: 38), title: Text(s.t('story_post_me')), onTap: () => Navigator.pop(context, account.myId)),
        for (final id in chats!.chatIds)
          if (account.chats[id] case final chat?)
            ListTile(leading: ChatAvatar(chatId: id, size: 38, showOnline: false), title: Text(chatTitle(chat, account, s)), onTap: () => Navigator.pop(context, id)),
      ]),
    ),
  );
}

/// Chats whose stories notify differently from the default (Settings → Notifications → Stories).
class StoryNotificationExceptionsScreen extends ConsumerWidget {
  const StoryNotificationExceptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('story_notification_exceptions'))),
      body: FutureBuilder<td.Chats>(
        future: account.send<td.Chats>(const td.GetStoryNotificationSettingsExceptions()),
        builder: (context, snapshot) {
          final ids = snapshot.data?.chatIds;
          if (ids == null) return snapshot.hasError ? Center(child: Text(errorText(context, snapshot.error!))) : const Center(child: CircularProgressIndicator());
          if (ids.isEmpty) return Center(child: Text(s.t('nothing_here')));
          return ListView(children: [
            for (final id in ids)
              if (account.chats[id] case final chat?)
                ListTile(
                  leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
                  title: Text(chatTitle(chat, account, s)),
                  subtitle: Text(s.t(chat.notificationSettings.muteStories ? 'state_off' : 'state_on')),
                ),
          ]);
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ live stories

/// Starts a live story for the user or a channel: an in-app stream (joined right away) or an RTMP one
/// (OBS etc.; the server URL and key are shown).
Future<void> startLiveStory(BuildContext context, TelegramAccount account, int chatId) async {
  final s = context.s;
  final rtmp = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.mic_rounded), title: Text(s.t('live_from_phone')), onTap: () => Navigator.pop(context, false)),
        ListTile(leading: const Icon(Icons.cast_rounded), title: Text(s.t('live_rtmp')), subtitle: Text(s.t('live_rtmp_hint')), onTap: () => Navigator.pop(context, true)),
      ]),
    ),
  );
  if (rtmp == null || !context.mounted) return;
  final result = await guard(
    context,
    () => account.send<td.StartLiveStoryResult>(td.StartLiveStory(
      chatId: chatId,
      privacySettings: const td.StoryPrivacySettingsEveryone(exceptUserIds: []),
      protectContent: false,
      isRtmpStream: rtmp,
      enableMessages: true,
      paidMessageStarCount: 0,
    )),
  );
  if (result == null || !context.mounted) return;
  if (result is! td.StartLiveStoryResultOk) {
    showToast(context, s.t('live_start_failed'));
    return;
  }
  final story = result.story;
  if (rtmp) {
    await showRtmpCredentials(context, account, chatId);
  } else if (story.content case td.StoryContentLive(:final groupCallId)) {
    await joinLiveStory(context, account, chatId, groupCallId);
  }
}

/// RTMP server URL and stream key for a live story; the key can be replaced if it leaked.
Future<void> showRtmpCredentials(BuildContext context, TelegramAccount account, int chatId) async {
  var rtmp = await guard(context, () => account.send<td.RtmpUrl>(td.GetLiveStoryRtmpUrl(chatId: chatId)));
  if (rtmp == null || !context.mounted) return;
  final s = context.s;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(s.t('live_rtmp')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.t('live_rtmp_url')),
          SelectableText(rtmp!.url),
          const SizedBox(height: 10),
          Text(s.t('live_rtmp_key')),
          SelectableText(rtmp!.streamKey),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              final fresh = await guard(context, () => account.send<td.RtmpUrl>(td.ReplaceLiveStoryRtmpUrl(chatId: chatId)));
              if (fresh != null) setDialog(() => rtmp = fresh);
            },
            child: Text(s.t('live_rtmp_replace')),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: rtmp!.streamKey)),
            child: Text(s.t('copy')),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok'))),
        ],
      ),
    ),
  );
}

/// Joins the group call behind a live story and opens its screen.
Future<void> joinLiveStory(BuildContext context, TelegramAccount account, int posterChatId, int groupCallId) async {
  final session = await guard(context, () => CallService.instance.joinLiveStory(posterChatId, groupCallId));
  if (session == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LiveStoryScreen(groupCallId: groupCallId, posterChatId: posterChatId)));
}

/// Live story room: who streams, top Star donors, who the user writes as, paid reactions, and the call itself.
class LiveStoryScreen extends ConsumerStatefulWidget {
  const LiveStoryScreen({super.key, required this.groupCallId, required this.posterChatId});

  final int groupCallId;
  final int posterChatId;

  @override
  ConsumerState<LiveStoryScreen> createState() => _LiveStoryScreenState();
}

class _LiveStoryScreenState extends ConsumerState<LiveStoryScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.GroupCallParticipant? _streamer;
  td.LiveStoryDonors? _donors;
  int _pendingStars = 0;
  Timer? _commit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Leaving with reactions still pending sends them, as the undo window is over anyway.
    if (_pendingStars > 0) unawaited(_account.send<td.Ok>(td.CommitPendingLiveStoryReactions(groupCallId: widget.groupCallId)).catchError((Object _) => const td.Ok()));
    _commit?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final streamer = await _account.send<td.GroupCallParticipant>(td.GetLiveStoryStreamer(groupCallId: widget.groupCallId));
      if (mounted) setState(() => _streamer = streamer);
    } on TdException catch (error) {
      debugPrint('live streamer unknown: $error');
    }
    try {
      final donors = await _account.send<td.LiveStoryDonors>(td.GetLiveStoryTopDonors(groupCallId: widget.groupCallId));
      if (mounted) setState(() => _donors = donors);
    } on TdException catch (error) {
      debugPrint('live donors unknown: $error');
    }
  }

  Future<void> _react(int stars) async {
    final ok = await guard(context, () async {
      await _account.send<td.Ok>(td.AddPendingLiveStoryReaction(groupCallId: widget.groupCallId, starCount: stars));
      return true;
    });
    if (ok != true || !mounted) return;
    setState(() => _pendingStars += stars);
    // Telegram's undo window: send the pending stars a few seconds after the last tap.
    _commit?.cancel();
    _commit = Timer(const Duration(seconds: 5), () async {
      await _account.send<td.Ok>(td.CommitPendingLiveStoryReactions(groupCallId: widget.groupCallId)).catchError((Object _) => const td.Ok());
      if (mounted) setState(() => _pendingStars = 0);
      unawaited(_load());
    });
  }

  Future<void> _undo() async {
    _commit?.cancel();
    await guard(context, () => _account.send<td.Ok>(td.RemovePendingLiveStoryReactions(groupCallId: widget.groupCallId)));
    if (mounted) setState(() => _pendingStars = 0);
  }

  Future<void> _pickSender() async {
    final senders = await guard(context, () => _account.send<td.ChatMessageSenders>(td.GetLiveStoryAvailableMessageSenders(groupCallId: widget.groupCallId)));
    if (senders == null || !mounted) return;
    final picked = await showModalBottomSheet<td.MessageSender>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final sender in senders.senders)
            ListTile(
              title: Text(_account.senderName(sender.sender)),
              trailing: sender.needsPremium ? const Icon(Icons.star_rounded) : null,
              onTap: () => Navigator.pop(context, sender.sender),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.SetLiveStoryMessageSender(groupCallId: widget.groupCallId, messageSenderId: picked)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final session = CallService.instance.currentGroup.value;
    final streamer = _streamer;
    return Scaffold(
      appBar: AppBar(title: Text(_account.chats[widget.posterChatId]?.title ?? s.t('live_story'))),
      body: ListView(children: [
        if (streamer != null)
          ListTile(
            leading: const Icon(Icons.sensors_rounded, color: Colors.redAccent),
            title: Text(_account.senderName(streamer.participantId)),
            subtitle: Text(s.t('live_streaming')),
          ),
        if (_donors case final donors? when donors.topDonors.isNotEmpty) ...[
          SectionHeader('${s.t('live_top_donors')} · ⭐ ${donors.totalStarCount}'),
          for (final donor in donors.topDonors)
            ListTile(
              dense: true,
              title: Text(donor.senderId == null ? s.t('anonymous') : _account.senderName(donor.senderId!)),
              trailing: Text('⭐ ${donor.starCount}'),
            ),
        ],
        SectionHeader(s.t('live_support')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 8, children: [
            for (final stars in const [1, 10, 50, 100]) ActionChip(label: Text('⭐ $stars'), onPressed: () => _react(stars)),
            if (_pendingStars > 0) ActionChip(avatar: const Icon(Icons.undo_rounded, size: 18), label: Text('${s.t('undo')} ($_pendingStars)'), onPressed: _undo),
          ]),
        ),
        ListTile(leading: const Icon(Icons.person_outline_rounded), title: Text(s.t('live_send_as')), onTap: _pickSender),
        if (session != null && !session.ended)
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Text(s.t('live_open_call')),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoChatScreen(session: session))),
          ),
      ]),
    );
  }
}
