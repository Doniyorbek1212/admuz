import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

class _SearchResults {
  const _SearchResults({this.chats = const [], this.global = const [], this.messages = const []});

  final List<int> chats;
  final List<int> global;
  final List<td.Message> messages;
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
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _query = value.trim();
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
        final found = await account.send<td.FoundMessages>(td.SearchMessages(
          chatList: const td.ChatListMain(),
          query: query,
          offset: '',
          limit: 50,
          filter: null,
          chatTypeFilter: null,
          minDate: 0,
          maxDate: 0,
        ));
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

    final results = await Future.wait([local, server, public, byPhone()]);
    final foundMessages = await messages();
    if (!mounted || generation != _generation) return;
    final mine = {...results[0], ...results[1]}.toList();
    setState(() {
      _loading = false;
      _results = _SearchResults(
        chats: mine,
        global: {...results[3], ...results[2]}.where((id) => !mine.contains(id)).toList(),
        messages: foundMessages,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    ref.watch(chatListProvider('main'));
    return Scaffold(
      appBar: AppBar(
        title: TextFormField(
          initialValue: widget.initialQuery,
          autofocus: widget.initialQuery.isEmpty,
          style: TextStyle(color: context.onAppBar),
          cursorColor: context.onAppBar,
          decoration: InputDecoration(hintText: s.t('search_hint'), hintStyle: TextStyle(color: context.onAppBarMuted), border: InputBorder.none),
          onChanged: _onChanged,
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
      ),
      body: _query.isEmpty
          ? _RecentChats(onTap: (id) => openChat(context, id))
          : ListView(
              children: [
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
  const _RecentChats({required this.onTap});

  final ValueChanged<int> onTap;

  @override
  ConsumerState<_RecentChats> createState() => _RecentChatsState();
}

class _RecentChatsState extends ConsumerState<_RecentChats> {
  List<int> _top = const [];
  List<int> _recent = const [];
  List<int> _recommended = const [];

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
    ]);
    if (!mounted) return;
    setState(() {
      _top = results[0];
      _recent = results[1];
      _recommended = results[2];
    });
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
    final top = _top.isNotEmpty ? _top : ref.watch(chatListProvider('main')).take(20).map((c) => c.id).toList();
    return ListView(
      children: [
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
        if (_recommended.isNotEmpty) SectionHeader(s.t('recommended_channels')),
        for (final id in _recommended)
          if (account.chats[id] case final chat?) _row(chat, chatSubtitle(chat, account, s)),
      ],
    );
  }
}

