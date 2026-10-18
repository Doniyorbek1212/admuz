import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/chat_screen.dart';
import '../chat/topics_screen.dart';
import '../contacts/contacts_screen.dart';
import '../search/search_screen.dart';
import '../stories/stories.dart';
import 'chat_tile.dart';
import 'ghost_mode_button.dart';
import 'home_drawer.dart';
import 'home_shell.dart';

/// Right-hand pane of the tablet split view; null on phones.
final chatPaneNavigatorKey = GlobalKey<NavigatorState>();

/// Width from which the chat list and the open chat are shown side by side.
const splitViewMinWidth = 840.0;

void openChat(BuildContext context, int chatId, {int? messageId}) {
  final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
  final chat = account.chats[chatId];
  final Widget screen = messageId == null && chat != null && account.isForum(chat)
      ? TopicsScreen(chatId: chatId)
      : ChatScreen(key: ValueKey('chat_${chatId}_$messageId'), chatId: chatId, initialMessageId: messageId);
  final pane = chatPaneNavigatorKey.currentState;
  if (pane != null && MediaQuery.sizeOf(context).width >= splitViewMinWidth) {
    // The chat becomes the pane's root page: no back arrow, Esc/closeChat empties the pane.
    pane.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => screen), (_) => false);
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
}

/// Leaves the chat on screen: back to the list on phones, the empty pane in split view.
void closeChat(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else if (navigator == chatPaneNavigatorKey.currentState) {
    navigator.pushReplacement(MaterialPageRoute<void>(builder: (_) => const _EmptyChatPane()));
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, this.inShell = false});

  /// Inside [HomeShell]: the drawer belongs to the shell's scaffold.
  final bool inShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final s = context.s;
    final tabs = <(String, String)>[
      ('main', s.t('all_chats')),
      if (ref.watch(settingsProvider.select((st) => st.chatTypeTabs)))
        for (final type in chatTypeTabs) (type, s.t('tab_${type.substring(5)}')),
      for (final folder in folders) ('folder:${folder.id}', folder.name.text.text),
    ];
    final wide = MediaQuery.sizeOf(context).width >= splitViewMinWidth;
    final pages = TabBarView(
      children: [for (final tab in tabs) ChatListView(listKey: tab.$1, showArchive: tab.$1 == 'main')],
    );
    final newMessage = FloatingActionButton(
      tooltip: s.t('new_message'),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ContactsScreen(pickToChat: true))),
      child: const Icon(Icons.edit_rounded),
    );
    final list = DefaultTabController(
      key: ValueKey(tabs.map((t) => t.$1).join(',')),
      length: tabs.length,
      child: wide
          // Telegram Desktop layout: folder rail on the left, search field above the list.
          ? Scaffold(
              drawer: const HomeDrawer(),
              body: Row(
                children: [
                  if (tabs.length > 1) _FolderRail(tabs: tabs, folders: folders),
                  Expanded(
                    child: Column(
                      children: [
                        _DesktopListHeader(showMenu: tabs.length <= 1),
                        Expanded(child: pages),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : Scaffold(
              drawer: inShell ? null : const HomeDrawer(),
              appBar: AppBar(
                leading: inShell
                    ? IconButton(
                        icon: const Icon(Icons.menu_rounded),
                        tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                        onPressed: () => homeShellScaffoldKey.currentState?.openDrawer(),
                      )
                    : null,
                title: const _ConnectionTitle(),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search_rounded),
                    tooltip: s.t('search'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
                  ),
                  const GhostModeButton(),
                ],
                bottom: tabs.length > 1
                    ? TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        indicatorColor: context.onAppBar,
                        labelColor: context.onAppBar,
                        unselectedLabelColor: context.onAppBarMuted,
                        dividerColor: Colors.transparent,
                        tabs: [for (final tab in tabs) Tab(child: _FolderTabLabel(listKey: tab.$1, title: tab.$2))],
                      )
                    : null,
              ),
              body: pages,
              // Lifts the button above the shell's floating bottom bar (reported as bottom padding).
              floatingActionButton: Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                child: newMessage,
              ),
            ),
    );
    if (!wide) return list;
    return Row(
      children: [
        SizedBox(width: tabs.length > 1 ? _FolderRail.width + 340 : 360, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: Navigator(
            key: chatPaneNavigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const _EmptyChatPane()),
          ),
        ),
      ],
    );
  }
}

class _EmptyChatPane extends StatelessWidget {
  const _EmptyChatPane();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/logo.png', width: 96, height: 96),
              const SizedBox(height: 16),
              Text(context.t('select_chat'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 16)),
            ],
          ),
        ),
      );
}

class _FolderTabLabel extends ConsumerWidget {
  const _FolderTabLabel({required this.listKey, required this.title});

  final String listKey;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider(listKey));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        if (unread > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            // Translucent white on accent bars, the accent on light (desktop) bars.
            decoration: BoxDecoration(
              color: context.onAppBar == Colors.white ? Colors.white24 : Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(formatCount(unread), style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
        ],
      ],
    );
  }
}

/// "Connecting…"-style status while TDLib isn't fully online, otherwise null.
String? _connectionText(BuildContext context, WidgetRef ref) {
  final s = context.s;
  return switch (ref.watch(connectionStateProvider)) {
    td.ConnectionStateWaitingForNetwork() => s.t('waiting_network'),
    td.ConnectionStateConnecting() || td.ConnectionStateConnectingToProxy() => s.t('connecting'),
    td.ConnectionStateUpdating() => s.t('updating'),
    _ => null,
  };
}

class _ConnectionTitle extends ConsumerWidget {
  const _ConnectionTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = _connectionText(context, ref);
    if (text == null) return const Text('Sado');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: context.onAppBar)),
        const SizedBox(width: 10),
        Text(text),
      ],
    );
  }
}

/// Wide layout: search field above the chat list (opens search), doubling as the connection status line.
class _DesktopListHeader extends ConsumerWidget {
  const _DesktopListHeader({required this.showMenu});

  /// Without a folder rail the drawer button lives here.
  final bool showMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = _connectionText(context, ref);
    final fill = theme.brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF1F3F5);
    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showMenu)
            IconButton(
              icon: Icon(Icons.menu_rounded, color: theme.hintColor),
              tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(showMenu ? 0 : 12, 9, 0, 9),
              child: Material(
                color: fill,
                borderRadius: BorderRadius.circular(19),
                child: InkWell(
                  borderRadius: BorderRadius.circular(19),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      if (status != null)
                        const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(Icons.search_rounded, size: 20, color: theme.hintColor),
                      const SizedBox(width: 10),
                      Text(status ?? context.t('search'), style: TextStyle(color: theme.hintColor, fontSize: 14.5)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          GhostModeButton(color: theme.hintColor),
          // Takes the floating "new message" button's place, as in Telegram Desktop.
          IconButton(
            icon: Icon(Icons.edit_outlined, color: theme.hintColor),
            tooltip: context.t('new_message'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ContactsScreen(pickToChat: true))),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// Wide layout: vertical folder bar like Telegram Desktop, with the drawer button on top.
class _FolderRail extends StatelessWidget {
  const _FolderRail({required this.tabs, required this.folders});

  static const width = 72.0;

  final List<(String, String)> tabs;
  final List<td.ChatFolderInfo> folders;

  /// Tab key or Telegram folder icon name (ChatFolderIcon.name) to a Material icon.
  static IconData _icon(String key) => switch (key) {
        'main' || 'All' => Icons.forum_rounded,
        'type:private' || 'Private' => Icons.person_rounded,
        'type:group' || 'Groups' => Icons.groups_rounded,
        'type:channel' || 'Channels' => Icons.campaign_rounded,
        'type:bot' || 'Bots' => Icons.smart_toy_rounded,
        'type:unread' || 'Unread' => Icons.mark_chat_unread_rounded,
        'Unmuted' => Icons.notifications_active_rounded,
        'Favorite' || 'Crown' => Icons.star_rounded,
        'Work' || 'Trade' || 'Money' => Icons.work_rounded,
        'Home' => Icons.home_rounded,
        'Love' || 'Like' => Icons.favorite_rounded,
        'Study' || 'Book' || 'Note' => Icons.menu_book_rounded,
        'Game' || 'Party' || 'Mask' => Icons.sports_esports_rounded,
        'Sport' => Icons.sports_soccer_rounded,
        'Travel' || 'Airplane' => Icons.flight_rounded,
        'Setup' => Icons.settings_rounded,
        'Light' => Icons.lightbulb_rounded,
        'Palette' || 'Flower' || 'Cat' => Icons.palette_rounded,
        _ => Icons.folder_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folderIcons = {for (final folder in folders) 'folder:${folder.id}': folder.icon.name};
    final controller = DefaultTabController.of(context);
    final background = theme.brightness == Brightness.dark
        ? const Color(0xFF10151B)
        : Color.lerp(theme.colorScheme.primary, const Color(0xFF17212B), 0.85)!;
    return Container(
      width: width,
      color: background,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.menu_rounded, color: Colors.white70),
                tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _FolderRailItem(
                      listKey: tabs[i].$1,
                      title: tabs[i].$2,
                      icon: _icon(folderIcons[tabs[i].$1] ?? tabs[i].$1),
                      selected: controller.index == i,
                      onTap: () => controller.animateTo(i),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderRailItem extends ConsumerWidget {
  const _FolderRailItem({required this.listKey, required this.title, required this.icon, required this.selected, required this.onTap});

  final String listKey;
  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider(listKey));
    final color = selected ? Colors.white : Colors.white60;
    return Material(
      color: selected ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Column(
            children: [
              Badge(
                isLabelVisible: unread > 0,
                label: Text(formatCount(unread)),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(height: 5),
              Text(
                title,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11.5, height: 1.15, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scrollable chat list for one TDLib chat list; loads more chats on demand.
class ChatListView extends ConsumerStatefulWidget {
  const ChatListView({super.key, required this.listKey, this.showArchive = false});

  final String listKey;
  final bool showArchive;

  @override
  ConsumerState<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends ConsumerState<ChatListView> with AutomaticKeepAliveClientMixin {
  bool _loading = false;

  @override
  bool get wantKeepAlive => true;

  td.ChatList get _list => chatListFromKey(widget.listKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || !mounted) return;
    final account = ref.read(accountProvider);
    if (account.isListFullyLoaded(_list)) return;
    _loading = true;
    try {
      await account.loadChats(_list);
    } on TdException catch (error) {
      debugPrint('loadChats failed: $error');
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final chats = ref.watch(chatListProvider(widget.listKey));
    final archived = widget.showArchive ? ref.watch(chatListProvider('archive')) : const <td.Chat>[];
    final account = ref.watch(accountProvider);
    final openChatId = ref.watch(openChatProvider);
    final s = context.s;
    if (chats.isEmpty && archived.isEmpty) {
      if (!account.isListFullyLoaded(_list)) return const Center(child: CircularProgressIndicator());
      return EmptyState(icon: Icons.forum_rounded, title: s.t('no_chats'), subtitle: s.t('no_chats_hint'));
    }
    final archiveRow = archived.isNotEmpty ? 1 : 0;
    final list = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 800) _loadMore();
        return false;
      },
      child: ListView.builder(
        itemCount: chats.length + archiveRow,
        itemExtent: isDesktop ? 66 : 76,
        itemBuilder: (context, index) {
          if (archiveRow == 1 && index == 0) return _ArchiveTile(chats: archived);
          final chat = chats[index - archiveRow];
          return ChatTile(
            key: ValueKey(chat.id),
            chatId: chat.id,
            list: _list,
            selected: chat.id == openChatId,
            onTap: () => openChat(context, chat.id),
          );
        },
      ),
    );
    if (widget.listKey != 'main') return list;
    return Column(children: [const StoriesBar(), Expanded(child: list)]);
  }
}

class _ArchiveTile extends ConsumerWidget {
  const _ArchiveTile({required this.chats});

  final List<td.Chat> chats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final unread = chats.where((c) => c.unreadCount > 0).length;
    final names = chats.take(4).map((c) => chatTitle(c, account, s)).join(', ');
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ArchiveScreen())),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Theme.of(context).hintColor.withValues(alpha: 0.35),
              child: const Icon(Icons.archive_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(s.t('archive'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5)),
                  const SizedBox(height: 3),
                  Text(names, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).hintColor)),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: Theme.of(context).hintColor, borderRadius: BorderRadius.circular(11)),
                child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12.5)),
              ),
          ],
        ),
      ),
    );
  }
}

class ArchiveScreen extends StatelessWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('archive'))),
        body: const ChatListView(listKey: 'archive'),
      );
}

class HiddenChatsScreen extends ConsumerWidget {
  const HiddenChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: Text(context.t('hidden_chats'))),
        body: const ChatListView(listKey: 'hidden'),
      );
}
