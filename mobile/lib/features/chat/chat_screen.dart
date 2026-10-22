import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/chat_history.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import '../profile/chat_info_screen.dart';
import '../settings/wallpaper.dart';
import 'bot_keyboard.dart';
import 'chat_search_screen.dart';
import 'composer.dart';
import 'forward_picker.dart';
import 'marked_messages_screen.dart';
import 'media_viewers.dart';
import 'message_bubble.dart';
import 'message_content.dart';
import 'scheduled_screen.dart';
import 'sponsored_bubble.dart';

/// Message menu entry: icon, label, action value (suffix ':destructive' paints it red).
typedef _MenuEntry = (IconData, String, String);

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.initialMessageId, this.topicId, this.topicName, this.debugHistory});

  final int chatId;
  final int? initialMessageId;

  /// Forum topic to show instead of the whole chat.
  final int? topicId;
  final String? topicName;

  /// Pre-filled history for screenshot tests; skips loading from TDLib.
  @visibleForTesting
  final ChatHistory? debugHistory;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  late final ChatHistory _history;
  final _scroll = ScrollController();
  final _itemKeys = <int, GlobalKey>{};
  final Set<int> _selected = {};
  td.Message? _replyTo;
  td.Message? _editing;
  td.Message? _pinned;
  int? _highlighted;
  bool _showScrollDown = false;
  bool _replyKeyboardHidden = false;
  int? _seenMarkupId;
  final _composerKey = GlobalKey<ComposerState>();
  late final OpenChatNotifier _openChat = ref.read(openChatProvider.notifier);

  /// Where the last click/tap landed: desktop context menus open there.
  Offset _lastPointer = Offset.zero;

  @override
  void initState() {
    super.initState();
    openChatFromContent = (context, chatId) => openChat(context, chatId);
    final topicId = widget.topicId;
    if (topicId != null) _account.activeTopics[widget.chatId] = topicId;
    _history = widget.debugHistory ??
        ChatHistory(_account, widget.chatId, ghostMode: ref.read(settingsProvider).ghostMode, topicId: topicId);
    _history.addListener(_onHistory);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openChat.set(widget.chatId));
    if (widget.debugHistory == null) unawaited(_load());
  }

  Future<void> _load() async {
    await _history.loadInitial();
    if (widget.initialMessageId != null) await _jumpTo(widget.initialMessageId!);
    await _refreshPinned();
    await _loadReplyMarkup();
  }

  Future<void> _loadReplyMarkup() async {
    final chat = _account.chats[widget.chatId];
    if (chat == null || chat.replyMarkupMessageId == 0 || _account.replyMarkupMessages.containsKey(chat.id)) return;
    try {
      final message = await _account.send<td.Message>(td.GetMessage(chatId: chat.id, messageId: chat.replyMarkupMessageId));
      _account.replyMarkupMessages[chat.id] = message;
      if (mounted) setState(() {});
    } on TdException catch (error) {
      debugPrint('reply markup unavailable: $error');
    }
  }

  void _insertText(String text) => _composerKey.currentState?.setText(text);

  Future<void> _sendKeyboardText(td.Chat chat, td.Message markupMessage, String text) async {
    // In groups the answer replies to the keyboard message so the bot knows which keyboard was used.
    final replyId = _account.isGroup(chat) ? markupMessage.id : null;
    await guard(context, () => _account.sendText(chat.id, text, replyToId: replyId));
    unawaited(_scrollToBottom());
  }

  Future<void> _refreshPinned() async {
    final pinned = await _account.pinnedMessage(widget.chatId);
    if (mounted) setState(() => _pinned = pinned);
  }

  void _onHistory() {
    if (!mounted) return;
    setState(() {});
  }

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < 600) unawaited(_history.loadOlder());
    if (position.pixels < 200 && _history.hasNewer) unawaited(_history.loadNewer());
    final show = position.pixels > 600 || _history.hasNewer;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
  }

  @override
  void dispose() {
    if (widget.topicId != null && _account.activeTopics[widget.chatId] == widget.topicId) {
      _account.activeTopics.remove(widget.chatId);
    }
    _openChat.close(widget.chatId);
    _history
      ..removeListener(_onHistory)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _jumpTo(int messageId) async {
    final found = await _history.jumpTo(messageId);
    if (!mounted) return;
    if (!found) {
      showToast(context, context.t('message_not_found'));
      return;
    }
    setState(() => _highlighted = messageId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final key = _itemKeys[messageId];
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(key!.currentContext!, alignment: 0.5, duration: const Duration(milliseconds: 300));
    } else {
      final index = _history.indexOf(messageId);
      if (index >= 0 && _scroll.hasClients) {
        await _scroll.animateTo(index * 80.0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    }
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlighted = null);
    });
  }

  Future<void> _scrollToBottom() async {
    if (_history.hasNewer) await _history.jumpToLatest();
    if (_scroll.hasClients) await _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void _toggleSelected(td.Message message) {
    setState(() {
      if (!_selected.remove(message.id)) _selected.add(message.id);
    });
  }

  List<td.Message> get _selectedMessages => _history.messages.where((m) => _selected.contains(m.id)).toList()
    ..sort((a, b) => a.id.compareTo(b.id));

  // ------------------------------------------------------------------ message actions

  Future<void> _showMessageMenu(td.Message message) async {
    if (isServiceMessage(message)) return;
    HapticFeedback.selectionClick();
    final s = context.s;
    final chat = _account.chats[widget.chatId];
    if (chat == null) return;
    // A kept copy of a deleted message: Telegram no longer knows it, so only local actions apply.
    final deleted = _account.archive.isDeleted(message.chatId, message.id);
    final hasVersions = _account.archive.versionsOf(message.chatId, message.id).isNotEmpty;
    final marked = ref.read(markedMessagesProvider.notifier).isMarked(message.chatId, message.id);
    td.MessageProperties? props;
    List<String> reactions = const ['👍', '❤', '🔥', '🥰', '👏', '😁', '🤔', '😢', '🎉', '🙏'];
    if (!deleted) {
      try {
        props = await _account.send<td.MessageProperties>(td.GetMessageProperties(chatId: message.chatId, messageId: message.id));
        final available = await _account.send<td.AvailableReactions>(
          td.GetMessageAvailableReactions(chatId: message.chatId, messageId: message.id, rowSize: 8),
        );
        final emojis = [...available.topReactions, ...available.popularReactions]
            .where((r) => !r.needsPremium)
            .map((r) => r.type)
            .whereType<td.ReactionTypeEmoji>()
            .map((r) => r.emoji)
            .toSet()
            .toList();
        if (emojis.isNotEmpty) reactions = emojis.take(12).toList();
      } on TdException catch (error) {
        debugPrint('message properties failed: $error');
      }
    }
    if (!mounted) return;
    final text = messageText(message);
    final failed = message.sendingState is td.MessageSendingStateFailed;
    final blockedFile = ref.read(settingsProvider).fileGuard.checkMessage(message, _account.myId) != null;
    final showReactions = !deleted && (chat.availableReactions is! td.ChatAvailableReactionsSome ||
        (chat.availableReactions as td.ChatAvailableReactionsSome).reactions.isNotEmpty);
    final items = deleted
        ? <_MenuEntry>[
            if (text.isNotEmpty) (Icons.copy_rounded, s.t('copy'), 'copy'),
            if (hasVersions) (Icons.history_rounded, s.t('edit_history'), 'history'),
            (Icons.delete_forever_rounded, s.t('remove_copy'), 'forget:destructive'),
          ]
        : <_MenuEntry>[
      if (failed) (Icons.refresh_rounded, s.t('retry'), 'retry'),
      if (props?.canBeReplied ?? true) (Icons.reply_rounded, s.t('reply'), 'reply'),
      if (text.isNotEmpty && (props?.canBeCopied ?? true)) (Icons.copy_rounded, s.t('copy'), 'copy'),
      if (text.isNotEmpty) (Icons.translate_rounded, s.t('translate'), 'translate'),
      if (text.length > 300) (Icons.summarize_rounded, s.t('ai_summarize'), 'summarize'),
      if (props?.canBeEdited ?? false) (Icons.edit_rounded, s.t('edit'), 'edit'),
      if (hasVersions) (Icons.history_rounded, s.t('edit_history'), 'history'),
      (marked ? Icons.star_rounded : Icons.star_outline_rounded, s.t(marked ? 'unmark_message' : 'mark_message'), 'mark'),
      if (props?.canBePinned ?? false)
        (message.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded, s.t(message.isPinned ? 'unpin' : 'pin'), 'pin'),
      if (props?.canBeForwarded ?? true) (Icons.forward_rounded, s.t('forward'), 'forward'),
      if (props?.canGetLink ?? false) (Icons.link_rounded, s.t('copy_link'), 'link'),
      if (text.isNotEmpty) (Icons.share_rounded, s.t('share'), 'share'),
      if (!blockedFile && _isGalleryMedia(message) && (props?.canBeSaved ?? message.canBeSaved))
        (Icons.download_rounded, s.t('save_to_gallery'), 'save'),
      if (!blockedFile && (message.content is td.MessageDocument || message.content is td.MessageAudio))
        (Icons.file_download_outlined, s.t('download'), 'download'),
      (Icons.check_circle_outline_rounded, s.t('select'), 'select'),
      if ((props?.canBeDeletedOnlyForSelf ?? true) || (props?.canBeDeletedForAllUsers ?? false))
        (Icons.delete_rounded, s.t('delete'), 'delete:destructive'),
    ];
    Widget reactionRow(BuildContext context) => SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final emoji in reactions)
                InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.pop(context, 'react:$emoji'),
                  child: Padding(padding: const EdgeInsets.all(8), child: Text(emoji, style: const TextStyle(fontSize: 28))),
                ),
            ],
          ),
        );
    final String? action;
    if (isDesktop) {
      // Telegram Desktop style: a compact menu at the pointer instead of a bottom sheet.
      final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
      final at = overlay.globalToLocal(_lastPointer);
      action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
        items: [
          // A Row, not a ListView: popup menus measure intrinsic widths, which viewports can't report.
          if (showReactions)
            PopupMenuItem<String>(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Builder(
                builder: (context) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final emoji in reactions.take(7))
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.pop(context, 'react:$emoji'),
                        // Opaque color: a disabled menu item would otherwise fade the emoji.
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(emoji, style: TextStyle(fontSize: 22, color: Theme.of(context).colorScheme.onSurface)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          for (final (icon, label, value) in items)
            PopupMenuItem<String>(
              value: value,
              height: 40,
              child: _menuRow(context, icon, label, destructive: value.endsWith(':destructive')),
            ),
        ],
      );
    } else {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showReactions) reactionRow(context),
                for (final (icon, label, value) in items)
                  ListTile(
                    leading: _menuRow(context, icon, null, destructive: value.endsWith(':destructive')),
                    title: _menuLabel(context, label, destructive: value.endsWith(':destructive')),
                    onTap: () => Navigator.pop(context, value),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (action == null || !mounted) return;
    await _runAction(action.replaceFirst(':destructive', ''), message, props);
  }

  /// Menu entry icon, optionally followed by its label (desktop popup rows).
  Widget _menuRow(BuildContext context, IconData icon, String? label, {bool destructive = false}) {
    final color = destructive ? Theme.of(context).colorScheme.error : Theme.of(context).listTileTheme.iconColor;
    if (label == null) return Icon(icon, color: color);
    return Row(children: [Icon(icon, size: 20, color: color), const SizedBox(width: 14), _menuLabel(context, label, destructive: destructive)]);
  }

  Widget _menuLabel(BuildContext context, String label, {bool destructive = false}) =>
      Text(label, style: TextStyle(color: destructive ? Theme.of(context).colorScheme.error : null));

  Future<void> _runAction(String action, td.Message message, td.MessageProperties? props) async {
    final s = context.s;
    final settings = ref.read(settingsProvider);
    if (action.startsWith('react:')) {
      await guard(context, () => _account.toggleReaction(message, action.substring(6)));
      return;
    }
    switch (action) {
      case 'retry':
        await guard(context, () => _account.resend(message));
      case 'reply':
        setState(() {
          _editing = null;
          _replyTo = message;
        });
      case 'copy':
        await Clipboard.setData(ClipboardData(text: messageText(message)));
        if (mounted) showToast(context, s.t('copied'));
      case 'translate':
        final translations = ref.read(translationsProvider.notifier);
        if (ref.read(translationsProvider).containsKey(message.id)) {
          translations.set(message.id, null);
          return;
        }
        final translated = await guard(context, () => _account.translateMessage(message, settings.translateTo));
        if (translated != null) translations.set(message.id, translated);
      case 'summarize':
        final summary = await guard(context, () => _account.summarize(message, settings.translateTo));
        if (summary != null && mounted) {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Row(children: [const Icon(Icons.auto_awesome_rounded), const SizedBox(width: 8), Text(s.t('ai_summary'))]),
              content: SingleChildScrollView(child: SelectableText(summary)),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
            ),
          );
        }
      case 'edit':
        setState(() {
          _replyTo = null;
          _editing = message;
        });
      case 'pin':
        await guard(context, () => _account.setPinned(message, !message.isPinned));
        await _refreshPinned();
      case 'forward':
        await _forward(_albumOf(message));
      case 'link':
        final link = await guard(context, () => _account.messageLink(message));
        if (link != null) {
          await Clipboard.setData(ClipboardData(text: link));
          if (mounted) showToast(context, s.t('link_copied'));
        }
      case 'share':
        await SharePlus.instance.share(ShareParams(text: messageText(message)));
      case 'select':
        _toggleSelected(message);
      case 'save':
        for (final item in _albumOf(message).where(_isGalleryMedia)) {
          final file = mediaFileOf(item);
          if (file == null || !mounted) continue;
          await saveMediaToGallery(context, ref, file, isVideo: item.content is! td.MessagePhoto);
        }
      case 'download':
        final file = mediaFileOf(message);
        if (file != null) {
          await guard(context, () => _account.addToDownloads(message, file.id, priority: 32));
          if (mounted) showToast(context, s.t('download_started'));
        }
      case 'delete':
        await _delete(_albumOf(message), canRevoke: props?.canBeDeletedForAllUsers ?? false, onlySelf: props?.canBeDeletedOnlyForSelf ?? true);
      case 'history':
        await _showEditHistory(message);
      case 'mark':
        final marks = ref.read(markedMessagesProvider.notifier);
        final wasMarked = marks.isMarked(message.chatId, message.id);
        marks.toggle(message.chatId, message.id);
        if (mounted) showToast(context, s.t(wasMarked ? 'unmarked' : 'marked'));
      case 'forget':
        _history.dismissDeleted(message.id);
    }
  }

  /// Every version of an edited message, oldest first, ending with the current one.
  Future<void> _showEditHistory(td.Message message) {
    final s = context.s;
    final versions = [
      ..._account.archive.versionsOf(message.chatId, message.id),
      (content: message.content, date: message.editDate > 0 ? message.editDate : message.date),
    ];
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('edit_history')),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (index, version) in versions.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: SelectableText(contentPreview(version.content, s) ?? ''),
                  subtitle: Text([
                    if (index == versions.length - 1) s.t('edit_history_current'),
                    '${formatDayHeader(version.date, s)} ${formatTime(version.date, s.locale)}',
                  ].join(' · ')),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
      ),
    );
  }

  static bool _isGalleryMedia(td.Message m) =>
      m.content is td.MessagePhoto || m.content is td.MessageVideo || m.content is td.MessageAnimation || m.content is td.MessageVideoNote;

  /// The message plus the rest of its media album, oldest first.
  List<td.Message> _albumOf(td.Message message) {
    if (message.mediaAlbumId == 0) return [message];
    return _history.messages.where((m) => m.mediaAlbumId == message.mediaAlbumId).toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> _forward(List<td.Message> messages) async {
    final single = messages.length == 1 && messages.first.content is td.MessageText ? messageText(messages.first) : null;
    final request = await Navigator.of(context).push<ForwardRequest>(MaterialPageRoute(
      builder: (_) => ForwardPickerScreen(
        multiple: true,
        hasCaption: messages.any((m) => captionOf(m.content)?.text.isNotEmpty ?? false),
        editableText: single,
      ),
    ));
    if (request == null || !mounted) return;
    final ids = messages.map((m) => m.id).toList();
    await guard(context, () async {
      for (final target in request.chatIds) {
        final edited = request.editedText;
        if (edited != null) {
          await _account.sendText(target, edited);
        } else {
          await _account.forward(widget.chatId, ids, target, hideSender: request.hideSender, removeCaption: request.removeCaption);
        }
      }
    });
    if (!mounted) return;
    setState(_selected.clear);
    showToast(context, context.t('forwarded'));
  }

  Future<void> _delete(List<td.Message> messages, {required bool canRevoke, required bool onlySelf}) async {
    final s = context.s;
    final chat = _account.chats[widget.chatId]!;
    var revoke = canRevoke && !onlySelf;
    final peer = _account.privateUser(chat);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(s.count('delete_messages', messages.length)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('delete_messages_confirm')),
              if (canRevoke && onlySelf)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: revoke,
                  onChanged: (v) => setDialogState(() => revoke = v ?? false),
                  title: Text(peer != null ? s.t('delete_also_for', {'name': peer.firstName}) : s.t('delete_for_everyone')),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: Text(s.t('delete')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await guard(context, () => _account.deleteMessages(widget.chatId, messages.map((m) => m.id).toList(), revoke: revoke));
    if (mounted) setState(_selected.clear);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider(widget.chatId));
    ref.listen(settingsProvider.select((s) => s.ghostMode), (_, ghost) => _history.ghostMode = ghost);
    final s = context.s;
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final selecting = _selected.isNotEmpty;
    final markupMessage = _account.replyMarkupMessages[chat.id];
    if (markupMessage?.id != _seenMarkupId) {
      // A new keyboard from the bot is shown again even if the previous one was hidden.
      _seenMarkupId = markupMessage?.id;
      _replyKeyboardHidden = false;
    }
    final replyKeyboard = switch (markupMessage?.replyMarkup) {
      final td.ReplyMarkupShowKeyboard keyboard when keyboard.rows.isNotEmpty => keyboard,
      _ => null,
    };
    final showStart = _history.initialized && _history.messages.isEmpty && _account.isBot(_account.privateUser(chat));
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(_selected.clear);
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _onEscape},
        child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _lastPointer = event.position,
        child: Scaffold(
        // Behind the floating header pills: the wallpaper's base color, so they read as floating over the chat.
        backgroundColor: context.chatColors.chatBackground,
        appBar: selecting ? _selectionBar(s) : _chatBar(chat, s),
        body: Column(
          children: [
            if (_pinned != null) _PinnedBar(message: _pinned!, onTap: () => _jumpTo(_pinned!.id), onClose: () => setState(() => _pinned = null)),
            Expanded(
              child: ChatBackground(
                child: Stack(
                  children: [
                    _messageList(chat),
                    if (replyKeyboard != null && !selecting)
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'bot_keyboard',
                          tooltip: s.t('bot_keyboard'),
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          foregroundColor: Theme.of(context).colorScheme.primary,
                          onPressed: () => setState(() => _replyKeyboardHidden = !_replyKeyboardHidden),
                          child: Icon(_replyKeyboardHidden ? Icons.keyboard_rounded : Icons.keyboard_hide_rounded),
                        ),
                      ),
                    if (_showScrollDown)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'scroll_down',
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          foregroundColor: Theme.of(context).hintColor,
                          onPressed: _scrollToBottom,
                          child: Badge(
                            isLabelVisible: chat.unreadCount > 0,
                            label: Text(formatCount(chat.unreadCount)),
                            child: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!selecting && replyKeyboard != null && markupMessage != null && !_replyKeyboardHidden)
              ReplyKeyboardPanel(
                chat: chat,
                markupMessage: markupMessage,
                keyboard: replyKeyboard,
                onSendText: (text) => _sendKeyboardText(chat, markupMessage, text),
                onHide: () => setState(() => _replyKeyboardHidden = true),
              ),
            if (!selecting && showStart)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => guard(context, () => _account.startBot(_account.privateUser(chat)!.id, chat.id)),
                    child: Text(s.t('bot_start')),
                  ),
                ),
              )
            else if (!selecting)
              Composer(
                key: _composerKey,
                chat: chat,
                replyTo: _replyTo,
                editing: _editing,
                onCancelReply: () => setState(() => _replyTo = null),
                onCancelEdit: () => setState(() => _editing = null),
                onSent: () => unawaited(_scrollToBottom()),
              ),
          ],
        ),
      ),
      ),
      ),
    );
  }

  /// Esc peels one layer at a time: selection, edit, reply, then the chat itself.
  void _onEscape() {
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
    } else if (_editing != null) {
      setState(() => _editing = null);
    } else if (_replyTo != null) {
      setState(() => _replyTo = null);
    } else {
      closeChat(context);
    }
  }

  PreferredSizeWidget _chatBar(td.Chat chat, Strings s) {
    final account = _account;
    final action = chatActionText(chat, account, s);
    final subtitle = widget.topicName != null ? chatTitle(chat, account, s) : (action ?? chatSubtitle(chat, account, s));
    // Accent bars (phones, dark mode) get floating branded pills; desktop's light bars stay classic.
    if (context.onAppBar == Colors.white) return _pillBar(chat, s, action, subtitle);
    return AppBar(
      // No back button when the chat is the split-view pane's root page.
      titleSpacing: Navigator.canPop(context) ? 0 : 12,
      title: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: chat.id))),
        child: Row(
          children: [
            ChatAvatar(chatId: chat.id, size: 40, showOnline: false),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.topicName ?? chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        // Typing/recording status stands out: bright green on accent bars, the accent on light bars.
                        color: action == null
                            ? context.onAppBarMuted
                            : (context.onAppBar == Colors.white ? Colors.lightGreenAccent : Theme.of(context).colorScheme.primary),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_callableUser(chat) case final user?)
          IconButton(icon: const Icon(Icons.call_rounded), tooltip: s.t('call'), onPressed: () => _callOptions(user, s)),
        _chatMenu(chat, s),
      ],
    );
  }

  /// Telegram shows call buttons for people (not bots or Saved Messages).
  td.User? _callableUser(td.Chat chat) {
    final user = _account.privateUser(chat);
    if (user == null || _account.isBot(user) || _account.isSavedMessages(chat)) return null;
    return user;
  }

  /// Phone header: an accent band behind the status bar and three floating pills with open space
  /// between them (back · avatar and name · call and menu), over the chat wallpaper.
  PreferredSizeWidget _pillBar(td.Chat chat, Strings s, String? action, String subtitle) {
    final account = _account;
    final canPop = Navigator.canPop(context);
    final user = _callableUser(chat);
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      toolbarHeight: 66,
      titleSpacing: 8,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      flexibleSpace: const BrandStatusBand(),
      title: Row(
        children: [
          if (canPop) ...[
            BrandPill(
              circle: true,
              onTap: () => Navigator.maybePop(context),
              child: Icon(Icons.arrow_back_rounded, color: Colors.white, semanticLabel: MaterialLocalizations.of(context).backButtonTooltip),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: BrandPill(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: chat.id))),
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                children: [
                  GoldRing(width: 1.5, child: ChatAvatar(chatId: chat.id, size: 38, showOnline: false)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.topicName ?? chatTitle(chat, account, s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // Typing/recording status stands out in bright green.
                            style: TextStyle(fontSize: 12.5, color: action == null ? Colors.white70 : Colors.lightGreenAccent),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          BrandPill(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IconTheme.merge(
              data: const IconThemeData(color: Colors.white),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (user != null)
                    IconButton(icon: const Icon(Icons.call_rounded), tooltip: s.t('call'), onPressed: () => _callOptions(user, s)),
                  _chatMenu(chat, s),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Chat ⋮ menu with icons, following aka: mute, video call, search, marks, first message, wallpaper, clear, delete.
  Widget _chatMenu(td.Chat chat, Strings s) {
    final account = _account;
    final muted = account.isMuted(chat);
    final user = _callableUser(chat);
    final error = Theme.of(context).colorScheme.error;
    PopupMenuItem<String> item(String value, IconData icon, String label, {Color? color, bool chevron = false}) => PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 22, color: color ?? Theme.of(context).hintColor),
              const SizedBox(width: 16),
              Expanded(child: Text(label, style: TextStyle(color: color))),
              if (chevron) Icon(Icons.chevron_right_rounded, size: 20, color: Theme.of(context).hintColor),
            ],
          ),
        );
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) => _onMenu(value, chat, s),
      itemBuilder: (context) => [
        item('mute', muted ? Icons.volume_up_rounded : Icons.volume_off_rounded, s.t(muted ? 'unmute' : 'mute'), chevron: !muted),
        const PopupMenuDivider(),
        if (user != null) item('video', Icons.videocam_outlined, s.t('video_call')),
        item('search', Icons.search_rounded, s.t('search')),
        item('marked', Icons.star_outline_rounded, s.t('find_marked')),
        item('first', Icons.vertical_align_top_rounded, s.t('go_to_first')),
        if (chat.hasScheduledMessages) item('scheduled', Icons.schedule_rounded, s.t('scheduled_messages')),
        item('wallpaper', Icons.wallpaper_rounded, s.t('chat_background')),
        item('clear', Icons.cleaning_services_rounded, s.t('clear_history')),
        item('delete', Icons.delete_outline_rounded, s.t(account.privateUser(chat) != null ? 'delete_chat' : 'leave'), color: error),
      ],
    );
  }

  Future<void> _onMenu(String value, td.Chat chat, Strings s) async {
    final account = _account;
    switch (value) {
      case 'mute':
        if (account.isMuted(chat)) {
          await guard(context, () => account.setMuted(chat, 0));
        } else {
          final seconds = await _pickMuteDuration(s);
          if (seconds != null && mounted) await guard(context, () => account.setMuted(chat, seconds));
        }
      case 'video':
        showToast(context, s.t('calls_soon'));
      case 'search':
        final id = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => ChatSearchScreen(chatId: chat.id)));
        if (id != null && mounted) await _jumpTo(id);
      case 'marked':
        final id = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => MarkedMessagesScreen(chatId: chat.id)));
        if (id != null && mounted) await _jumpTo(id);
      case 'first':
        await _jumpToFirst(chat);
      case 'scheduled':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ScheduledMessagesScreen(chatId: chat.id)));
      case 'wallpaper':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WallpaperScreen()));
      case 'clear':
        final ok = await confirm(context, title: s.t('clear_history'), message: s.t('clear_history_confirm'), destructive: true);
        if (ok && mounted) await guard(context, () => account.clearHistory(chat));
      case 'delete':
        final ok = await confirm(
          context,
          title: s.t('delete_chat_confirm_title'),
          message: s.t('delete_chat_confirm', {'name': chatTitle(chat, account, s)}),
          destructive: true,
        );
        if (ok && mounted) {
          await guard(context, () => account.deleteChat(chat));
          if (mounted) closeChat(context);
        }
    }
  }

  /// Mute durations as in Telegram; null when dismissed.
  Future<int?> _pickMuteDuration(Strings s) => showModalBottomSheet<int>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (seconds, key) in const [(3600, 'mute_1h'), (8 * 3600, 'mute_8h'), (2 * 86400, 'mute_2d'), (muteForever, 'mute_forever')])
                ListTile(
                  leading: Icon(seconds == muteForever ? Icons.notifications_off_rounded : Icons.timer_outlined),
                  title: Text(s.t(key)),
                  onTap: () => Navigator.pop(context, seconds),
                ),
            ],
          ),
        ),
      );

  /// Oldest message: history from message id 1 with one newer message included.
  Future<void> _jumpToFirst(td.Chat chat) async {
    final page = await guard(
      context,
      () => _account.send<td.Messages>(td.GetChatHistory(chatId: chat.id, fromMessageId: 1, offset: -1, limit: 1, onlyLocal: false)),
    );
    final first = page?.messages?.firstOrNull;
    if (first != null && mounted) await _jumpTo(first.id);
  }

  /// Voice/video calls over Telegram are not built yet (they need the tgcalls media stack),
  /// so they say so; a visible phone number can still be dialled over the SIM.
  Future<void> _callOptions(td.User user, Strings s) async {
    final phone = user.phoneNumber;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.call_rounded, color: Theme.of(context).colorScheme.primary),
              title: Text(s.t('call_voice')),
              subtitle: Text(s.t('calls_soon')),
              onTap: () => Navigator.pop(context, 'soon'),
            ),
            ListTile(
              leading: Icon(Icons.videocam_rounded, color: Theme.of(context).colorScheme.primary),
              title: Text(s.t('call_video')),
              subtitle: Text(s.t('calls_soon')),
              onTap: () => Navigator.pop(context, 'soon'),
            ),
            if (phone.isNotEmpty)
              ListTile(
                leading: Icon(Icons.sim_card_rounded, color: Theme.of(context).hintColor),
                title: Text(s.t('call_phone')),
                subtitle: Text('+$phone'),
                onTap: () => Navigator.pop(context, 'phone'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'soon') return showToast(context, s.t('calls_soon'));
    final launched = await launchUrl(Uri(scheme: 'tel', path: '+$phone'));
    if (!launched && mounted) showToast(context, s.t('call_phone_failed'));
  }

  PreferredSizeWidget _selectionBar(Strings s) {
    final messages = _selectedMessages;
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(_selected.clear)),
      title: Text('${messages.length}'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy_rounded),
          onPressed: () async {
            final text = messages.map(messageText).where((t) => t.isNotEmpty).join('\n\n');
            await Clipboard.setData(ClipboardData(text: text));
            if (!mounted) return;
            setState(_selected.clear);
            showToast(context, s.t('copied'));
          },
        ),
        IconButton(icon: const Icon(Icons.forward_rounded), onPressed: () => _forward(messages)),
        IconButton(
          icon: const Icon(Icons.delete_rounded),
          onPressed: () => _delete(messages, canRevoke: messages.every((m) => m.isOutgoing), onlySelf: true),
        ),
      ],
    );
  }

  Widget _messageList(td.Chat chat) {
    final messages = _history.messages;
    final s = context.s;
    if (!_history.initialized) return const Center(child: CircularProgressIndicator());
    if (messages.isEmpty) {
      if (_account.privateUser(chat) != null && !_account.isSavedMessages(chat) && _account.canSendMessages(chat) && !_account.isBot(_account.privateUser(chat))) {
        return Center(child: _EmptyChatCard(onGreet: () => guard(context, () => _account.sendText(chat.id, '👋'))));
      }
      return Center(
        child: ServiceMessage(text: s.t(_account.isSavedMessages(chat) ? 'saved_empty' : 'no_messages')),
      );
    }
    final group = _account.isGroup(chat);
    final sponsoredSlots = _history.sponsored.isNotEmpty && !_history.hasNewer ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sponsoredSlots + messages.length + (_history.hasOlder ? 1 : 0),
      itemBuilder: (context, rawIndex) {
        // Telegram sponsored message goes after the newest ordinary message (bottom of a reversed list).
        if (rawIndex < sponsoredSlots) {
          final sponsored = _history.sponsored.first;
          return SponsoredBubble(key: ValueKey('ad_${sponsored.messageId}'), message: sponsored, history: _history);
        }
        final index = rawIndex - sponsoredSlots;
        if (index == messages.length) {
          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final message = messages[index];
        // Media albums: the newest message of the run draws the whole grid, the others collapse.
        final albumId = message.mediaAlbumId;
        List<td.Message>? album;
        var olderIndex = index + 1;
        if (albumId != 0) {
          if (index > 0 && messages[index - 1].mediaAlbumId == albumId) return SizedBox.shrink(key: ValueKey('album_${message.id}'));
          var end = index;
          while (end + 1 < messages.length && messages[end + 1].mediaAlbumId == albumId) {
            end++;
          }
          if (end > index) {
            album = messages.sublist(index, end + 1).reversed.toList();
            olderIndex = end + 1;
            if (!message.isOutgoing) _history.markViewed(album.map((m) => m.id));
          }
        }
        final older = olderIndex < messages.length ? messages[olderIndex] : null;
        final newer = index > 0 ? messages[index - 1] : null;
        if (!message.isOutgoing) _history.markViewed([message.id]);
        final newDay = older == null || !isSameDay(older.date, message.date);
        final sameSenderAsOlder = older != null && !newDay && _account.senderKey(older.senderId) == _account.senderKey(message.senderId) && !isServiceMessage(older);
        final sameSenderAsNewer = newer != null && isSameDay(newer.date, message.date) &&
            _account.senderKey(newer.senderId) == _account.senderKey(message.senderId) && !isServiceMessage(newer);
        final key = _itemKeys.putIfAbsent(message.id, GlobalKey.new);

        Widget item;
        final service = serviceMessageText(message, _account, s);
        if (service != null) {
          item = ServiceMessage(text: service);
        } else {
          item = MessageBubble(
            message: message,
            chat: chat,
            showSender: group ? !sameSenderAsOlder : !sameSenderAsOlder,
            showTail: !sameSenderAsNewer,
            selected: _selected.contains(message.id) || _highlighted == message.id,
            onTap: () {
              if (_selected.isNotEmpty) _toggleSelected(message);
            },
            onLongPress: () => _selected.isNotEmpty ? _toggleSelected(message) : _showMessageMenu(message),
            onReplyTap: _jumpTo,
            onInsertText: _insertText,
            album: album,
          );
        }
        return Column(
          key: key,
          children: [
            if (newDay) ServiceMessage(text: formatDayHeader(message.date, s)),
            if (_history.firstUnreadId == message.id)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(vertical: 4),
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
                child: Text(s.t('unread_messages'), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ),
            item,
          ],
        );
      },
    );
  }
}

class _PinnedBar extends ConsumerWidget {
  const _PinnedBar({required this.message, required this.onTap, required this.onClose});

  final td.Message message;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Container(width: 2, height: 34, color: primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.t('pinned_message'), style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Text(messagePreview(message, account, s).replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(icon: const Icon(Icons.close_rounded, size: 20), onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

/// First-message card for an empty private chat (Telegram's greeting prompt).
class _EmptyChatCard extends StatelessWidget {
  const _EmptyChatCard({required this.onGreet});

  final VoidCallback onGreet;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      margin: const EdgeInsets.all(32),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s.t('no_messages'), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(s.t('empty_chat_hint'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(40),
            onTap: onGreet,
            child: const Padding(padding: EdgeInsets.all(8), child: Text('👋', style: TextStyle(fontSize: 56))),
          ),
        ],
      ),
    );
  }
}
