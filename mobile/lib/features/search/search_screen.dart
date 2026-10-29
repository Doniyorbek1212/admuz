import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../chat/sponsored_bubble.dart' show reportSponsored;
import '../home/home_screen.dart';
import '../stories/story_extras.dart' show openStoriesByTag;
import '../webapp/bot_extras.dart' show popularWebAppBotsProvider, recentInlineBotsProvider;

class _SearchResults {
  const _SearchResults({
    this.chats = const [],
    this.global = const [],
    this.messages = const [],
    this.sponsored = const [],
    this.hashtags = const [],
    this.postLimits,
  });

  final List<int> chats;
  final List<int> global;
  final List<td.Message> messages;
  final List<td.SponsoredChat> sponsored;
  final List<String> hashtags;
  final td.PublicPostSearchLimits? postLimits;

  _SearchResults withPostLimits(td.PublicPostSearchLimits limits) =>
      _SearchResults(chats: chats, global: global, messages: messages, sponsored: sponsored, hashtags: hashtags, postLimits: limits);
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  /// Text searched right away, e.g. a tapped #hashtag.
  final String initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  _SearchResults _results = const _SearchResults();
  int _generation = 0;
  late final _controller = TextEditingController(text: widget.initialQuery);
  // Public posts cost a free daily query or stars, so they load only on request.
  List<td.Message>? _posts;
  String _postsOffset = '';
  final Set<int> _viewedAds = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) {
      _query = widget.initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _searchFor(String query) {
    _controller.text = query;
    _onChanged(query);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _query = value.trim();
    _posts = null;
    _postsOffset = '';
    if (_query.isEmpty) {
      setState(() => _results = const _SearchResults());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final query = _query;
    final generation = ++_generation;
    final account = ref.read(accountProvider);
    setState(() => _loading = true);
    Future<List<int>> safeChats(Future<td.Chats> request) async {
      try {
        return (await request).chatIds;
      } on TdException {
        return const [];
      }
    }

    final local = safeChats(account.send<td.Chats>(td.SearchChats(query: query, typeFilter: null, limit: 30)));
    final server = safeChats(account.send<td.Chats>(td.SearchChatsOnServer(query: query, typeFilter: null, limit: 30)));
    final public = query.length >= 4
        ? safeChats(account.send<td.Chats>(td.SearchPublicChats(query: query, typeFilter: null)))
        : Future.value(const <int>[]);
    Future<List<td.Message>> messages() async {
      if (query.length < 2) return const [];
      try {
        var found = await account.send<td.FoundMessages>(td.SearchMessages(
          chatList: const td.ChatListMain(),
          query: query,
          offset: '',
          limit: 50,
          filter: null,
          chatTypeFilter: null,
          minDate: 0,
          maxDate: 0,
        ));
        // Secret chats live only on this device, so the server search above never sees them.
        try {
          final secret = await account.send<td.FoundMessages>(td.SearchSecretMessages(chatId: 0, query: query, offset: '', limit: 30, filter: null));
          if (secret.messages.isNotEmpty) found = found.copyWith(messages: [...secret.messages, ...found.messages]);
        } on TdException catch (error) {
          debugPrint('secret chat search failed: $error');
        }
        // #hashtag / $cashtag: public channel posts too, as Telegram's search does.
        if (RegExp(r'^[#$]\w+$').hasMatch(query)) {
          final public = await account.send<td.FoundMessages>(td.SearchPublicMessagesByTag(tag: query, offset: '', limit: 50));
          final seen = {for (final m in found.messages) (m.chatId, m.id)};
          return [...found.messages, ...public.messages.where((m) => !seen.contains((m.chatId, m.id)))];
        }
        return found.messages;
      } on TdException {
        return const [];
      }
    }

    // Contact finder: a phone number finds that Telegram user even when they are not a contact.
    Future<List<int>> byPhone() async {
      final digits = query.replaceAll(RegExp(r'[\s()+-]'), '');
      if (!RegExp(r'^\d{7,15}$').hasMatch(digits)) return const [];
      try {
        final user = await account.send<td.User>(td.SearchUserByPhoneNumber(phoneNumber: digits, onlyLocal: false));
        final chat = await account.send<td.Chat>(td.CreatePrivateChat(userId: user.id, force: false));
        return [chat.id];
      } on TdException {
        return const [];
      }
    }

    Future<T?> optional<T extends td.TdObject>(td.TdFunction request) async {
      try {
        return await account.send<T>(request);
      } on TdException {
        return null;
      }
    }

    final tagPrefix = RegExp(r'^#(\w*)$').firstMatch(query)?.group(1);
    final extras = Future.wait<td.TdObject?>([
      optional<td.SponsoredChats>(td.GetSearchSponsoredChats(query: query)),
      tagPrefix == null ? Future.value() : optional<td.Hashtags>(td.SearchHashtags(prefix: tagPrefix, limit: 10)),
      query.length >= 2 ? optional<td.PublicPostSearchLimits>(td.GetPublicPostSearchLimits(query: query)) : Future.value(),
    ]);
    final results = await Future.wait([local, server, public, byPhone()]);
    final foundMessages = await messages();
    final extra = await extras;
    if (!mounted || generation != _generation) return;
    final mine = {...results[0], ...results[1]}.toList();
    setState(() {
      _loading = false;
      _results = _SearchResults(
        chats: mine,
        global: {...results[3], ...results[2]}.where((id) => !mine.contains(id)).toList(),
        messages: foundMessages,
        sponsored: (extra[0] as td.SponsoredChats?)?.chats ?? const [],
        hashtags: [for (final tag in (extra[1] as td.Hashtags?)?.hashtags ?? const <String>[]) if ('#$tag' != query) tag],
        postLimits: extra[2] as td.PublicPostSearchLimits?,
      );
    });
  }

  Future<void> _searchPosts() async {
    final limits = _results.postLimits;
    if (limits == null) return;
    final s = context.s;
    final free = limits.isCurrentQueryFree || limits.remainingFreeQueryCount > 0;
    if (!free) {
      final ok = await confirm(context, title: s.t('public_posts'), message: s.t('public_posts_paid', {'n': '${limits.starCount}'}), confirmLabel: s.t('search'));
      if (!ok || !mounted) return;
    }
    final query = _query;
    final found = await guard(
      context,
      () => ref.read(accountProvider).send<td.FoundPublicPosts>(
            td.SearchPublicPosts(query: query, offset: _postsOffset, limit: 30, starCount: free ? 0 : limits.starCount),
          ),
    );
    if (found == null || !mounted || query != _query) return;
    setState(() {
      _posts = [...?_posts, ...found.messages];
      _postsOffset = found.nextOffset;
      if (found.searchLimits case final next?) _results = _results.withPostLimits(next);
    });
  }

  Future<void> _openSponsored(td.SponsoredChat ad) async {
    final account = ref.read(accountProvider);
    await guard(context, () => account.send<td.Ok>(td.OpenSponsoredChat(sponsoredChatUniqueId: ad.uniqueId)));
    if (mounted) openChat(context, ad.chatId);
  }

  Widget _sponsoredTile(BuildContext context, td.SponsoredChat ad) {
    final account = ref.read(accountProvider);
    final chat = account.chats[ad.chatId];
    if (chat == null) return const SizedBox.shrink();
    final s = context.s;
    if (_viewedAds.add(ad.uniqueId)) account.send<td.Ok>(td.ViewSponsoredChat(sponsoredChatUniqueId: ad.uniqueId)).ignore();
    return ListTile(
      leading: ChatAvatar(chatId: ad.chatId, size: 46),
      title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([s.t('sponsored'), if (ad.sponsorInfo case final info? when info.isNotEmpty) info].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (_) => reportSponsored(
          context,
          (optionId) => account.send<td.ReportSponsoredResult>(td.ReportSponsoredChat(sponsoredChatUniqueId: ad.uniqueId, optionId: optionId)),
        ),
        itemBuilder: (context) => [PopupMenuItem(value: 'report', child: Text(s.t('ad_report')))],
      ),
      onTap: () => _openSponsored(ad),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    ref.watch(chatListProvider('main'));
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.initialQuery.isEmpty,
          style: TextStyle(color: context.onAppBar),
          cursorColor: context.onAppBar,
          decoration: InputDecoration(hintText: s.t('search_hint'), hintStyle: TextStyle(color: context.onAppBarMuted), border: InputBorder.none),
          onChanged: _onChanged,
        ),
        // Always present: adding/removing `bottom` rebuilds the AppBar subtree, recreating the field and making the IME wipe the text.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(height: 2),
        ),
      ),
      body: _query.isEmpty
          ? _RecentChats(onTap: (id) => openChat(context, id), onQuery: _searchFor)
          : ListView(
              children: [
                if (_results.hashtags.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      children: [
                        for (final tag in _results.hashtags)
                          Padding(padding: const EdgeInsets.only(right: 6), child: ActionChip(label: Text('#$tag'), onPressed: () => _searchFor('#$tag'))),
                      ],
                    ),
                  ),
                // A #hashtag also finds public stories that carry it.
                if (RegExp(r'^[#$]\w+$').hasMatch(_query))
                  ListTile(
                    leading: const Icon(Icons.motion_photos_on_outlined),
                    title: Text(s.t('stories_with_tag', {'tag': _query})),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => openStoriesByTag(context, _query),
                  ),
                if (_results.sponsored.isNotEmpty) SectionHeader(s.t('sponsored')),
                for (final ad in _results.sponsored) _sponsoredTile(context, ad),
                if (_results.chats.isNotEmpty) SectionHeader(s.t('chats_and_contacts')),
                for (final id in _results.chats) _chatTile(context, id),
                if (_results.global.isNotEmpty) SectionHeader(s.t('global_search')),
                for (final id in _results.global) _chatTile(context, id, showUsername: true),
                if (_results.messages.isNotEmpty) SectionHeader(s.t('messages')),
                for (final message in _results.messages)
                  ListTile(
                    leading: ChatAvatar(chatId: message.chatId, size: 46),
                    title: Text(
                      account.chats[message.chatId] == null ? '' : chatTitle(account.chats[message.chatId]!, account, s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(messagePreview(message, account, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text(formatChatTime(message.date, s.locale), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                    onTap: () => openChat(context, message.chatId, messageId: message.id),
                  ),
                if (_results.postLimits case final limits?) ...[
                  SectionHeader(s.t('public_posts')),
                  for (final message in _posts ?? const <td.Message>[])
                    ListTile(
                      leading: ChatAvatar(chatId: message.chatId, size: 46),
                      title: Text(account.chats[message.chatId]?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(messagePreview(message, account, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Text(formatChatTime(message.date, s.locale), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                      onTap: () => openChat(context, message.chatId, messageId: message.id),
                    ),
                  if (_posts == null || _postsOffset.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.travel_explore_rounded),
                      title: Text(s.t(_posts == null ? 'public_posts_search' : 'load_more')),
                      subtitle: Text(limits.isCurrentQueryFree || limits.remainingFreeQueryCount > 0
                          ? s.t('public_posts_free_left', {'n': '${limits.remainingFreeQueryCount}', 'total': '${limits.dailyFreeQueryCount}'})
                          : s.t('public_posts_paid', {'n': '${limits.starCount}'})),
                      onTap: _searchPosts,
                    ),
                ],
                if (!_loading && _results.chats.isEmpty && _results.global.isEmpty && _results.messages.isEmpty)
                  Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(s.t('nothing_found')))),
              ],
            ),
    );
  }

  Widget _chatTile(BuildContext context, int chatId, {bool showUsername = false}) {
    final account = ref.read(accountProvider);
    final chat = account.chats[chatId];
    if (chat == null) return const SizedBox.shrink();
    final s = context.s;
    final username = account.usernameOf(chat);
    return ListTile(
      leading: ChatAvatar(chatId: chatId, size: 46),
      title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        showUsername && username != null ? '@$username, ${chatSubtitle(chat, account, s)}' : chatSubtitle(chat, account, s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        // Remembered so it shows under "Recently found" next time, like Telegram.
        account.send<td.Ok>(td.AddRecentlyFoundChat(chatId: chatId)).ignore();
        openChat(context, chatId);
      },
    );
  }
}

/// Before typing: frequent contacts, recently found chats and recommended channels, as in Telegram.
class _RecentChats extends ConsumerStatefulWidget {
  const _RecentChats({required this.onTap, required this.onQuery});

  final ValueChanged<int> onTap;
  final ValueChanged<String> onQuery;

  @override
  ConsumerState<_RecentChats> createState() => _RecentChatsState();
}

class _RecentChatsState extends ConsumerState<_RecentChats> {
  List<int> _top = const [];
  List<int> _recent = const [];
  List<int> _recommended = const [];
  List<int> _opened = const [];
  List<String> _tags = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    Future<List<int>> ids(td.TdFunction request) async {
      try {
        return (await account.send<td.Chats>(request)).chatIds;
      } on TdException {
        return const []; // Top chats are off when the user disabled them in Telegram.
      }
    }

    final results = await Future.wait([
      ids(const td.GetTopChats(category: td.TopChatCategoryUsers(), limit: 20)),
      ids(const td.SearchRecentlyFoundChats(query: '', typeFilter: null, limit: 50)),
      ids(const td.GetRecommendedChats()),
      ids(const td.GetRecentlyOpenedChats(limit: 20)),
    ]);
    var tags = const <String>[];
    try {
      tags = (await account.send<td.Hashtags>(const td.GetSearchedForTags(tagPrefix: '#', limit: 12))).hashtags;
    } on TdException catch (error) {
      debugPrint('searched tags failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _tags = tags;
      _top = results[0];
      _recent = results[1];
      _recommended = results[2];
      _opened = results[3];
    });
  }

  /// Bots from the lists below have no chat yet until one is created.
  Future<void> _openUser(int userId) async {
    final chat = await guard(context, () => ref.read(accountProvider).openPrivateChat(userId));
    if (chat != null && mounted) widget.onTap(chat.id);
  }

  Widget _row(td.Chat chat, String subtitle, {Widget? trailing}) => ListTile(
        leading: ChatAvatar(chatId: chat.id, size: 44),
        title: Text(chatTitle(chat, ref.read(accountProvider), context.s), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        onTap: () => widget.onTap(chat.id),
      );

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    // Top chats are off when the user disabled them; then show what was opened lately.
    final top = _top.isNotEmpty
        ? _top
        : _opened.isNotEmpty
            ? _opened
            : ref.watch(chatListProvider('main')).take(20).map((c) => c.id).toList();
    return ListView(
      children: [
        if (_tags.isNotEmpty) ...[
          Row(children: [
            Expanded(child: SectionHeader(s.t('recent_hashtags'))),
            TextButton(
              onPressed: () async {
                await guard(context, () => account.send<td.Ok>(const td.ClearSearchedForTags(clearCashtags: false)));
                await _load();
              },
              child: Text(s.t('clear')),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final tag in _tags)
                InputChip(
                  label: Text(tag),
                  onPressed: () => widget.onQuery(tag),
                  onDeleted: () async {
                    await guard(context, () => account.send<td.Ok>(td.RemoveSearchedForTag(tag: tag)));
                    await _load();
                  },
                ),
            ]),
          ),
        ],
        SectionHeader(s.t('recent')),
        SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final id in top)
                if (account.chats[id] case final chat?)
                  InkWell(
                    onTap: () => widget.onTap(id),
                    onLongPress: _top.isEmpty
                        ? null
                        : () async {
                            final ok = await confirm(context, title: s.t('top_chat_remove'), message: chatTitle(chat, account, s));
                            if (!ok || !context.mounted) return;
                            await guard(context, () => account.send<td.Ok>(td.RemoveTopChat(category: const td.TopChatCategoryUsers(), chatId: id)));
                            await _load();
                          },
                    child: SizedBox(
                      width: 76,
                      child: Column(
                        children: [
                          const SizedBox(height: 6),
                          ChatAvatar(chatId: id, size: 54),
                          const SizedBox(height: 4),
                          Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
        if (_recent.isNotEmpty)
          Row(
            children: [
              Expanded(child: SectionHeader(s.t('recently_found'))),
              TextButton(
                onPressed: () async {
                  await guard(context, () => account.send<td.Ok>(const td.ClearRecentlyFoundChats()));
                  await _load();
                },
                child: Text(s.t('clear')),
              ),
            ],
          ),
        for (final id in _recent)
          if (account.chats[id] case final chat?)
            _row(
              chat,
              chatSubtitle(chat, account, s),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () async {
                  await guard(context, () => account.send<td.Ok>(td.RemoveRecentlyFoundChat(chatId: id)));
                  await _load();
                },
              ),
            ),
        if (ref.watch(recentInlineBotsProvider).value case final bots? when bots.isNotEmpty) ...[
          SectionHeader(s.t('recent_inline_bots')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final id in bots)
                ActionChip(
                  avatar: UserAvatar(userId: id, size: 24),
                  label: Text('@${account.users[id]?.usernames?.activeUsernames.firstOrNull ?? account.userName(id)}'),
                  onPressed: () => _openUser(id),
                ),
            ]),
          ),
        ],
        if (ref.watch(popularWebAppBotsProvider).value case final apps? when apps.isNotEmpty) ...[
          SectionHeader(s.t('popular_mini_apps')),
          for (final id in apps)
            ListTile(
              leading: UserAvatar(userId: id, size: 44),
              title: Text(account.userName(id), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.t('mini_app')),
              onTap: () => _openUser(id),
            ),
        ],
        if (_recommended.isNotEmpty) SectionHeader(s.t('recommended_channels')),
        for (final id in _recommended)
          if (account.chats[id] case final chat?) _row(chat, chatSubtitle(chat, account, s)),
      ],
    );
  }
}

