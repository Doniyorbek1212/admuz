import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/message_content.dart';
import '../profile/statistics_screen.dart';
import '../settings/privacy_screen.dart';
import 'stories.dart';

/// A chat's stories outside the 24-hour feed: posted to its page, the archive (owner/admins) and albums.
class ChatStoriesScreen extends ConsumerStatefulWidget {
  const ChatStoriesScreen({super.key, required this.chatId, required this.canManage});

  final int chatId;

  /// Own profile or a channel the user administers: archive, pinning and albums can be edited.
  final bool canManage;

  @override
  ConsumerState<ChatStoriesScreen> createState() => _ChatStoriesScreenState();
}

class _ChatStoriesScreenState extends ConsumerState<ChatStoriesScreen> {
  td.Stories? _posted;
  td.Stories? _archived;
  List<td.StoryAlbum> _albums = const [];

  TelegramAccount get _account => ref.read(accountProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.chatId;
    final posted = await guard(context, () => _account.send<td.Stories>(td.GetChatPostedToChatPageStories(chatId: id, fromStoryId: 0, limit: 100)));
    td.Stories? archived;
    if (widget.canManage && mounted) {
      archived = await guard(context, () => _account.send<td.Stories>(td.GetChatArchivedStories(chatId: id, fromStoryId: 0, limit: 100)));
    }
    var albums = const <td.StoryAlbum>[];
    try {
      albums = (await _account.send<td.StoryAlbums>(td.GetChatStoryAlbums(chatId: id))).albums;
    } on Exception {
      // Albums are optional; older chats simply have none.
    }
    if (mounted) {
      setState(() {
        _posted = posted;
        _archived = archived;
        _albums = albums;
      });
    }
  }

  Future<void> _storyMenu(td.Story story, td.Stories from) async {
    if (!widget.canManage) return;
    final s = context.s;
    final pinned = from.pinnedStoryIds.contains(story.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (story.isPostedToChatPage)
            ListTile(
              leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
              title: Text(s.t(pinned ? 'unpin' : 'pin')),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
          if (story.canToggleIsPostedToChatPage)
            ListTile(
              leading: Icon(story.isPostedToChatPage ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined),
              title: Text(s.t(story.isPostedToChatPage ? 'story_unpin_profile' : 'story_pin_profile')),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
          if (story.canBeAddedToAlbum)
            ListTile(leading: const Icon(Icons.photo_album_outlined), title: Text(s.t('story_add_album')), onTap: () => Navigator.pop(context, 'album')),
          if (story.canGetStatistics)
            ListTile(leading: const Icon(Icons.insights_rounded), title: Text(s.t('statistics')), onTap: () => Navigator.pop(context, 'stats')),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'pin':
        final ids = pinned ? [for (final i in from.pinnedStoryIds) if (i != story.id) i] : [story.id, ...from.pinnedStoryIds];
        await guard(context, () => _account.send<td.Ok>(td.SetChatPinnedStories(chatId: widget.chatId, storyIds: ids)));
      case 'profile':
        await guard(
          context,
          () => _account.send<td.Ok>(td.ToggleStoryIsPostedToChatPage(storyPosterChatId: story.posterChatId, storyId: story.id, isPostedToChatPage: !story.isPostedToChatPage)),
        );
      case 'album':
        await _addToAlbum(story);
      case 'stats':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoryStatisticsScreen(story: story)));
        return;
      default:
        return;
    }
    await _load();
  }

  Future<void> _addToAlbum(td.Story story) async {
    final s = context.s;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.add_rounded), title: Text(s.t('story_album_new')), onTap: () => Navigator.pop(context, 0)),
          for (final album in _albums) ListTile(leading: const Icon(Icons.photo_album_outlined), title: Text(album.name), onTap: () => Navigator.pop(context, album.id)),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 0) {
      final name = await promptText(context, title: s.t('story_album_new'), label: s.t('story_album_name'));
      if (name == null || name.trim().isEmpty || !mounted) return;
      await guard(context, () => _account.send<td.StoryAlbum>(td.CreateStoryAlbum(storyPosterChatId: widget.chatId, name: name.trim(), storyIds: [story.id])));
    } else {
      await guard(context, () => _account.send<td.StoryAlbum>(td.AddStoryAlbumStories(chatId: widget.chatId, storyAlbumId: picked, storyIds: [story.id])));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final tabs = [
      (s.t('stories_posted'), _posted),
      if (widget.canManage) (s.t('stories_archive'), _archived),
    ];
    return DefaultTabController(
      length: tabs.length + 1,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.t('stories')),
          bottom: TabBar(tabs: [for (final (label, _) in tabs) Tab(text: label), Tab(text: s.t('story_albums'))]),
        ),
        body: TabBarView(children: [
          for (final (_, stories) in tabs)
            stories == null
                ? const Center(child: CircularProgressIndicator())
                : StoryGrid(chatId: widget.chatId, stories: stories.stories, pinned: stories.pinnedStoryIds, onLongPress: (story) => _storyMenu(story, stories)),
          _albums.isEmpty
              ? Center(child: Text(s.t('nothing_here')))
              : ListView(children: [
                  for (final album in _albums)
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.photo_album_outlined)),
                      title: Text(album.name),
                      trailing: widget.canManage
                          ? PopupMenuButton<String>(
                              onSelected: (action) async {
                                if (action == 'rename') {
                                  final name = await promptText(context, title: s.t('rename'), label: s.t('story_album_name'), initial: album.name);
                                  if (name == null || name.trim().isEmpty || !context.mounted) return;
                                  await guard(context, () => _account.send<td.StoryAlbum>(td.SetStoryAlbumName(chatId: widget.chatId, storyAlbumId: album.id, name: name.trim())));
                                } else {
                                  final ok = await confirm(context, title: s.t('delete'), message: album.name, destructive: true);
                                  if (!ok || !context.mounted) return;
                                  await guard(context, () => _account.send<td.Ok>(td.DeleteStoryAlbum(chatId: widget.chatId, storyAlbumId: album.id)));
                                }
                                await _load();
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'rename', child: Text(s.t('rename'))),
                                PopupMenuItem(value: 'delete', child: Text(s.t('delete'))),
                              ],
                            )
                          : null,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => _AlbumScreen(chatId: widget.chatId, album: album, canManage: widget.canManage),
                      )),
                    ),
                ]),
        ]),
      ),
    );
  }
}

class _AlbumScreen extends ConsumerStatefulWidget {
  const _AlbumScreen({required this.chatId, required this.album, required this.canManage});

  final int chatId;
  final td.StoryAlbum album;
  final bool canManage;

  @override
  ConsumerState<_AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<_AlbumScreen> {
  List<td.Story>? _stories;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(
      context,
      () => ref.read(accountProvider).send<td.Stories>(td.GetStoryAlbumStories(chatId: widget.chatId, storyAlbumId: widget.album.id, offset: 0, limit: 100)),
    );
    if (mounted) setState(() => _stories = result?.stories ?? const []);
  }

  Future<void> _remove(td.Story story) async {
    if (!widget.canManage) return;
    final ok = await confirm(context, title: context.t('story_album_remove'), destructive: true);
    if (!ok || !mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).send<td.StoryAlbum>(td.RemoveStoryAlbumStories(chatId: widget.chatId, storyAlbumId: widget.album.id, storyIds: [story.id])),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final stories = _stories;
    return Scaffold(
      appBar: AppBar(title: Text(widget.album.name)),
      body: stories == null
          ? const Center(child: CircularProgressIndicator())
          : StoryGrid(chatId: widget.chatId, stories: stories, onLongPress: _remove),
    );
  }
}

/// Three-column grid of story covers; tapping plays from that story on.
class StoryGrid extends StatelessWidget {
  const StoryGrid({super.key, required this.chatId, required this.stories, this.pinned = const [], this.onLongPress});

  final int chatId;
  final List<td.Story> stories;
  final List<int> pinned;
  final void Function(td.Story story)? onLongPress;

  void _play(BuildContext context, int index) {
    final rest = stories.sublist(index);
    final entry = td.ChatActiveStories(
      chatId: chatId,
      list: null,
      order: 0,
      canBeArchived: false,
      // Everything counts as read so the player starts at the tapped story.
      maxReadStoryId: rest.map((s) => s.id).fold(0, (a, b) => a > b ? a : b),
      stories: [for (final s in rest) td.StoryInfo(storyId: s.id, date: s.date, isForCloseFriends: false, isLive: false)],
    );
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoryViewer(feed: [entry], initialIndex: 0)));
  }

  @override
  Widget build(BuildContext context) {
    if (stories.isEmpty) return Center(child: Text(context.t('nothing_here')));
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2, childAspectRatio: 9 / 16),
      itemCount: stories.length,
      itemBuilder: (context, index) {
        final story = stories[index];
        final file = switch (story.content) {
          td.StoryContentPhoto(:final photo) => bestPhotoSize(photo, target: 320)?.photo,
          td.StoryContentVideo(:final video) => video.thumbnail?.file,
          _ => null,
        };
        return GestureDetector(
          onTap: () => _play(context, index),
          onLongPress: onLongPress == null ? null : () => onLongPress!(story),
          child: Stack(fit: StackFit.expand, children: [
            file == null ? const ColoredBox(color: Colors.black26) : TdImage(file: file, fit: BoxFit.cover),
            if (pinned.contains(story.id)) const Positioned(right: 4, top: 4, child: Icon(Icons.push_pin_rounded, color: Colors.white, size: 18)),
            if (story.content is td.StoryContentVideo)
              const Positioned(left: 4, bottom: 4, child: Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 20)),
          ]),
        );
      },
    );
  }
}

/// Views/forwards and reactions graphs of one channel story, plus its public reposts count.
class StoryStatisticsScreen extends ConsumerWidget {
  const StoryStatisticsScreen({super.key, required this.story});

  final td.Story story;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('statistics'))),
      body: FutureBuilder(
        future: Future.wait([
          account.send<td.StoryStatistics>(td.GetStoryStatistics(chatId: story.posterChatId, storyId: story.id, isDark: isDark)),
          account.send<td.PublicForwards>(td.GetStoryPublicForwards(storyPosterChatId: story.posterChatId, storyId: story.id, offset: '', limit: 1)),
        ]),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text(s.t('nothing_here')));
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final stats = data[0] as td.StoryStatistics;
          final forwards = data[1] as td.PublicForwards;
          return ListView(children: [
            ListTile(leading: const Icon(Icons.public_rounded), title: Text(s.t('stat_public_shares')), trailing: Text('${forwards.totalCount}')),
            StatGraphCard(chatId: story.posterChatId, title: s.t('stat_interactions'), graph: stats.storyInteractionGraph),
            StatGraphCard(chatId: story.posterChatId, title: s.t('stat_reactions'), graph: stats.storyReactionGraph),
          ]);
        },
      ),
    );
  }
}
