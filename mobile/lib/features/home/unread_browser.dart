import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart' show brandGradient;
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../chat/message_bubble.dart';
import '../settings/wallpaper.dart' show ChatBackground;
import 'chat_tile.dart';
import 'home_screen.dart' show openChat;

/// Chats of the main list that have unread messages, in list order.
final unreadChatIdsProvider = Provider<List<int>>((ref) => [
      for (final chat in ref.watch(chatListProvider('main')))
        if (chat.unreadCount > 0) chat.id,
    ]);

/// Opens the unread browser, or says there is nothing unread.
void openUnreadBrowser(BuildContext context, WidgetRef ref) {
  final chatIds = ref.read(unreadChatIdsProvider);
  if (chatIds.isEmpty) return showToast(context, context.t('unread_none'));
  unawaited(Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => UnreadBrowserScreen(chatIds: chatIds),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)), child: child),
    ),
  )));
}

/// Most unread messages shown on one card; the rest are a tap away in the chat itself.
const _maxPreview = 30;

/// The unread messages of a chat, oldest first, without marking them read (the card is only a preview).
final _unreadMessagesProvider = FutureProvider.autoDispose.family<List<td.Message>, int>((ref, chatId) async {
  final account = ref.watch(accountProvider);
  final chat = account.chats[chatId];
  if (chat == null || chat.unreadCount == 0) return const [];
  final wanted = chat.unreadCount.clamp(1, _maxPreview);
  final found = <td.Message>[];
  var from = 0;
  // TDLib may answer with only what it has cached; ask again from the oldest message got so far.
  for (var attempt = 0; attempt < 3 && found.length < wanted; attempt++) {
    final page = await account.send<td.Messages>(td.GetChatHistory(chatId: chatId, fromMessageId: from, offset: 0, limit: wanted - found.length, onlyLocal: false));
    final messages = page.messages ?? const <td.Message>[];
    if (messages.isEmpty) break;
    found.addAll(messages.where((m) => m.id > chat.lastReadInboxMessageId));
    if (messages.any((m) => m.id <= chat.lastReadInboxMessageId)) break;
    from = messages.map((m) => m.id).reduce((a, b) => a < b ? a : b);
  }
  return found.toList()..sort((a, b) => a.id.compareTo(b.id));
});

/// Telegram's "unread chats" view: the chats with new messages as cards to swipe through, each showing its
/// unread messages, an "all unread" list first, and their avatars in a row below. A tap opens the chat.
class UnreadBrowserScreen extends ConsumerStatefulWidget {
  const UnreadBrowserScreen({super.key, required this.chatIds});

  /// Fixed when the view opens, so reading a chat does not shift the cards under the user's finger.
  final List<int> chatIds;

  @override
  ConsumerState<UnreadBrowserScreen> createState() => _UnreadBrowserScreenState();
}

class _UnreadBrowserScreenState extends ConsumerState<UnreadBrowserScreen> {
  static const _avatarSlot = 58.0;

  final _pages = PageController(viewportFraction: 0.86);
  final _strip = ScrollController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  void _onPage(int page) {
    setState(() => _page = page);
    if (!_strip.hasClients) return;
    // The row is padded by half a screen on each side, so this offset puts the chosen avatar in the middle.
    final target = page * _avatarSlot;
    unawaited(_strip.animateTo(target.clamp(0, _strip.position.maxScrollExtent), duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic));
  }

  void _goTo(int page) => unawaited(_pages.animateToPage(page, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ids = widget.chatIds;
    final label = _page == 0 ? s.t('all_unread') : (ref.watch(chatProvider(ids[_page - 1]))?.title ?? '');
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: brandGradient(Theme.of(context).colorScheme.primary, vertical: true)),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: ids.length + 1,
                  onPageChanged: _onPage,
                  itemBuilder: (context, index) => _Scaled(
                    controller: _pages,
                    index: index,
                    child: index == 0
                        ? _AllUnreadCard(chatIds: ids, onOpen: (id) => _goTo(ids.indexOf(id) + 1))
                        : _UnreadChatCard(chatId: ids[index - 1]),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: _avatarSlot,
                child: ListView.builder(
                  controller: _strip,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: (MediaQuery.sizeOf(context).width - _avatarSlot) / 2),
                  itemExtent: _avatarSlot,
                  itemCount: ids.length + 1,
                  itemBuilder: (context, index) => _StripAvatar(
                    chatId: index == 0 ? null : ids[index - 1],
                    total: ids.length,
                    selected: index == _page,
                    onTap: () => _goTo(index),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Neighbouring cards sit slightly smaller, so the one in front reads as the current chat.
class _Scaled extends StatelessWidget {
  const _Scaled({required this.controller, required this.index, required this.child});

  final PageController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final page = controller.hasClients && controller.position.haveDimensions ? controller.page ?? 0 : controller.initialPage.toDouble();
          final distance = (page - index).abs().clamp(0.0, 1.0);
          return Transform.scale(scale: 1 - distance * 0.08, child: child);
        },
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: child),
      );
}

/// Rounded card with a title pill over its top edge, as in Telegram's unread view.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.subtitle, required this.child, this.onTap});

  final String title;
  final String subtitle;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 260),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8)],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: theme.hintColor)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllUnreadCard extends ConsumerWidget {
  const _AllUnreadCard({required this.chatIds, required this.onOpen});

  final List<int> chatIds;
  final void Function(int chatId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    return _Card(
      title: s.t('all_unread'),
      subtitle: s.count('unread_chats', chatIds.length),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 64, bottom: 8),
          itemExtent: 76,
          itemCount: chatIds.length,
          itemBuilder: (context, index) => ChatTile(chatId: chatIds[index], list: const td.ChatListMain(), onTap: () => onOpen(chatIds[index])),
        ),
      ),
    );
  }
}

/// One chat's unread messages; a tap anywhere opens the chat itself (which marks them read).
class _UnreadChatCard extends ConsumerWidget {
  const _UnreadChatCard({required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final chat = ref.watch(chatProvider(chatId));
    if (chat == null) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    final messages = ref.watch(_unreadMessagesProvider(chatId));
    return _Card(
      title: chat.title,
      subtitle: chatSubtitle(chat, account, s),
      onTap: () => openChat(context, chatId),
      child: ChatBackground(
        chatId: chatId,
        child: messages.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(error is TdException ? error.message : '$error')),
          data: (list) => list.isEmpty
              ? Center(child: Text(s.t('unread_none')))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(4, 64, 4, 12),
                  itemCount: list.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) return _UnreadDivider(label: s.t('unread_messages'));
                    final message = list[index - 1];
                    final previous = index > 1 ? list[index - 2] : null;
                    final next = index < list.length ? list[index] : null;
                    // Read-only preview: taps go to the card, which opens the chat.
                    return IgnorePointer(
                      child: MessageBubble(
                        message: message,
                        chat: chat,
                        showSender: previous == null || account.senderKey(previous.senderId) != account.senderKey(message.senderId),
                        showTail: next == null || account.senderKey(next.senderId) != account.senderKey(message.senderId),
                        selected: false,
                        onTap: () {},
                        onLongPress: () {},
                        onReplyTap: (_) {},
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 3),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
      );
}

/// One avatar of the bottom row; the first slot is the "all unread" list. The current one is larger.
class _StripAvatar extends ConsumerWidget {
  const _StripAvatar({required this.chatId, required this.total, required this.selected, required this.onTap});

  final int? chatId;
  final int total;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = chatId;
    final unread = id == null ? total : (ref.watch(chatProvider(id))?.unreadCount ?? 0);
    final size = selected ? 52.0 : 40.0;
    final face = id == null
        ? Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(Icons.forum_rounded, color: Theme.of(context).colorScheme.primary, size: size * 0.5),
          )
        : ChatAvatar(chatId: id, size: size, showOnline: false);
    return GestureDetector(
      onTap: onTap,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.all(selected ? 2 : 0),
          decoration: BoxDecoration(shape: BoxShape.circle, border: selected ? Border.all(color: Colors.white, width: 2) : null),
          child: Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: face,
          ),
        ),
      ),
    );
  }
}
