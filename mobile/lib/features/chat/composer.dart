import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/live_location.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../core/video_note_crop.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../webapp/web_app_screen.dart';
import 'article_editor.dart';
import 'attach_sheet.dart';
import 'checklist_creator.dart';
import '../settings/business_quick_replies.dart';
import '../settings/business_settings.dart';
import 'composer_panels.dart';
import 'contact_picker.dart';
import 'location_picker.dart';
import 'poll_creator.dart';

class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.chat,
    required this.replyTo,
    required this.editing,
    required this.onCancelReply,
    required this.onCancelEdit,
    required this.onSent,
  });

  final td.Chat chat;
  final td.Message? replyTo;
  final td.Message? editing;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onSent;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  AudioRecorder? _recorder;
  late final TelegramAccount _account;
  bool _showEmoji = false;
  bool _hasText = false;
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _draftTimer;

  // Suggestions above the input: "@mention" members and "@bot query" inline results.
  List<td.ChatMember> _mentions = const [];
  td.User? _inlineBot;
  td.InlineQueryResults? _inlineResults;
  String _inlineQuery = '';
  Timer? _suggestTimer;
  int _suggestGeneration = 0;

  /// Preview of the first link in the draft; closing it sends the message without a preview.
  td.LinkPreview? _preview;
  String? _previewUrl;
  bool _previewClosed = false;
  Timer? _previewTimer;
  static final _urlPattern = RegExp(r'(https?://|t\.me/|www\.)\S+', caseSensitive: false);

  /// Commands and menu button of the bot in a private bot chat.
  td.BotInfo? _botInfo;
  List<td.BotCommand> _commandMatches = const [];

  // Voice recording state.
  bool _recording = false;
  DateTime? _recordStart;
  String? _recordPath;
  final List<int> _waveform = [];
  StreamSubscription<Amplitude>? _amplitudeSub;
  Timer? _recordTicker;
  double _dragOffset = 0;

  /// Finger still on the mic; a recorder that finishes starting after release is discarded.
  bool _pressing = false;

  /// Slid up while recording: keeps recording hands-free until send or cancel is tapped.
  bool _locked = false;
  static const _cancelDistance = 120.0;
  static const _lockDistance = 80.0;

  /// Tapping the mic switches it to round video messages (and back), as in Telegram.
  bool _videoMode = false;
  bool _recordingVideo = false;
  CameraController? _camera;

  /// Recording overlay (round camera preview, camera/flash buttons, lock pill) and the mic tooltip.
  OverlayEntry? _cameraOverlay;
  OverlayEntry? _tip;
  Timer? _tipTimer;

  /// Front camera: the overlay turns white to light the face; back camera: torch.
  bool _flash = false;
  static const _videoNoteLimit = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    // Resolved while mounted: dispose() must not use ref.
    _account = ref.read(accountProvider);
    final draft = widget.chat.draftMessage?.content;
    if (draft is td.DraftMessageContentText) {
      _controller.text = draft.text.text;
      _hasText = _controller.text.trim().isNotEmpty;
    }
    _controller.addListener(_onChanged);
    final bot = _account.privateUser(widget.chat);
    if (_account.isBot(bot)) {
      unawaited(_account.botInfo(bot!.id).then((info) {
        if (mounted) setState(() => _botInfo = info);
      }));
    } else if (bot != null && _account.me?.isPremium == true && _account.quickReplies.isEmpty) {
      _account.send<td.Ok>(const td.LoadQuickReplyShortcuts()).ignore();
    }
    _focus.addListener(() {
      if (_focus.hasFocus && _showEmoji) setState(() => _showEmoji = false);
    });
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.editing != null && widget.editing!.id != old.editing?.id) {
      final content = widget.editing!.content;
      final formatted = content is td.MessageText ? content.text : captionOf(content);
      _controller.text = formatted == null ? '' : toMarkdown(formatted);
      _focus.requestFocus();
    } else if (widget.editing == null && old.editing != null) {
      _controller.clear();
    }
    if (widget.replyTo != null && widget.replyTo!.id != old.replyTo?.id) _focus.requestFocus();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _suggestTimer?.cancel();
    _previewTimer?.cancel();
    if (widget.editing == null) {
      unawaited(_account.saveDraft(widget.chat.id, _controller.text, replyToMessageId: widget.replyTo?.id));
    }
    _amplitudeSub?.cancel();
    _recordTicker?.cancel();
    unawaited(_recorder?.dispose());
    _cameraOverlay?.remove();
    _tipTimer?.cancel();
    _tip?.remove();
    unawaited(_camera?.dispose());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Inserts text at the cursor (used by the AI tools and mentions).
  void setText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _onChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    final account = ref.read(accountProvider);
    final ghost = ref.read(settingsProvider).ghostMode;
    if (hasText && !ghost && DateTime.now().difference(_lastTyping) > const Duration(seconds: 4)) {
      _lastTyping = DateTime.now();
      unawaited(account.sendTyping(widget.chat.id, const td.ChatActionTyping()));
    }
    if (widget.editing == null) {
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) unawaited(account.saveDraft(widget.chat.id, _controller.text, replyToMessageId: widget.replyTo?.id));
      });
    }
      _scheduleSuggestions();
    _schedulePreview();
  }

  void _schedulePreview() {
    final url = _urlPattern.firstMatch(_controller.text)?.group(0);
    if (url == _previewUrl) return;
    _previewUrl = url;
    _previewTimer?.cancel();
    if (url == null) {
      if (_preview != null || _previewClosed) {
        setState(() {
          _preview = null;
          _previewClosed = false;
        });
      }
      return;
    }
    _previewTimer = Timer(const Duration(milliseconds: 700), () async {
      final text = _controller.text;
      td.LinkPreview? preview;
      try {
        preview = await _account.send<td.LinkPreview>(td.GetLinkPreview(text: td.FormattedText(text: text, entities: const []), linkPreviewOptions: null));
      } on TdException {
        preview = null; // 404: the link has no preview.
      }
      if (mounted && _previewUrl == url) {
        setState(() {
          _preview = preview;
          _previewClosed = false;
        });
      }
    });
  }

  static final _inlinePattern = RegExp(r'^@([A-Za-z0-9_]{3,32}) (.*)$', dotAll: true);
  static final _mentionPattern = RegExp(r'(?:^|\s)@([A-Za-z0-9_]*)$');

  void _scheduleSuggestions() {
    _suggestTimer?.cancel();
    final text = _controller.text;
    final commands = _botInfo?.commands ?? _quickReplyCommands();
    final commandQuery = RegExp(r'^/(\w*)$').firstMatch(text);
    final matches = commandQuery == null
        ? const <td.BotCommand>[]
        : commands.where((c) => c.command.startsWith(commandQuery.group(1)!.toLowerCase())).toList();
    if (matches.length != _commandMatches.length || matches.isNotEmpty) setState(() => _commandMatches = matches);
    final inline = _inlinePattern.firstMatch(text);
    final cursor = _controller.selection.baseOffset;
    final beforeCursor = cursor >= 0 && cursor <= text.length ? text.substring(0, cursor) : text;
    final mention = inline == null ? _mentionPattern.firstMatch(beforeCursor) : null;
    if (inline == null && mention == null) {
      if (_mentions.isNotEmpty || _inlineResults != null || _inlineBot != null) {
        setState(() {
          _mentions = const [];
          _inlineResults = null;
          _inlineBot = null;
        });
      }
      return;
    }
    final generation = ++_suggestGeneration;
    _suggestTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        if (inline != null) {
          await _loadInline(inline.group(1)!, inline.group(2)!, generation);
        } else if (_account.isGroup(widget.chat)) {
          final members = await _account.mentionCandidates(widget.chat.id, mention!.group(1)!);
          if (mounted && generation == _suggestGeneration) setState(() => _mentions = members);
        }
      } on TdException catch (error) {
        debugPrint('suggestions failed: $error');
      }
    });
  }

  Future<void> _loadInline(String username, String query, int generation) async {
    var bot = _inlineBot;
    if (bot == null || bot.usernames?.activeUsernames.contains(username) != true) {
      bot = await _account.inlineBot(username);
    }
    if (!mounted || generation != _suggestGeneration) return;
    if (bot == null) {
      setState(() {
        _inlineBot = null;
        _inlineResults = null;
      });
      return;
    }
    final results = await _account.inlineResults(bot.id, widget.chat.id, query);
    if (!mounted || generation != _suggestGeneration) return;
    setState(() {
      _inlineBot = bot;
      _inlineQuery = query;
      _inlineResults = results;
      _mentions = const [];
    });
  }

  Future<void> _loadMoreInline() async {
    final bot = _inlineBot;
    final current = _inlineResults;
    if (bot == null || current == null || current.nextOffset.isEmpty) return;
    final offset = current.nextOffset;
    try {
      final more = await _account.inlineResults(bot.id, widget.chat.id, _inlineQuery, offset: offset);
      if (!mounted || _inlineResults?.nextOffset != offset) return;
      setState(() => _inlineResults = more.copyWith(results: [...current.results, ...more.results]));
    } on TdException catch (error) {
      debugPrint('inline more failed: $error');
    }
  }

  void _pickMention(td.User user) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset.clamp(0, text.length);
    final before = text.substring(0, cursor);
    final at = before.lastIndexOf('@');
    if (at < 0) return;
    final username = user.usernames?.activeUsernames.firstOrNull;
    // Users without a username are mentioned by name via a tg://user link (a MentionName entity on send).
    final insert = username != null ? '@$username ' : '[${user.firstName}](tg://user?id=${user.id}) ';
    final next = text.substring(0, at) + insert + text.substring(cursor);
    _controller.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: at + insert.length));
    setState(() => _mentions = const []);
  }

  Future<void> _sendInlineResult(int queryId, String resultId) async {
    final replyId = widget.replyTo?.id;
    _controller.clear();
    widget.onCancelReply();
    widget.onSent();
    setState(() {
      _inlineResults = null;
      _inlineBot = null;
    });
    await guard(context, () => _account.sendInlineResult(widget.chat.id, queryId, resultId, replyToId: replyId));
  }

  /// Business quick replies offered as "/name" in chats with people (Telegram allows them only there).
  List<td.BotCommand> _quickReplyCommands() {
    final user = _account.privateUser(widget.chat);
    if (user == null || _account.isBot(user) || _account.isSavedMessages(widget.chat)) return const [];
    return [
      for (final q in _account.quickReplies.values)
        if (q.name != greetingShortcut && q.name != awayShortcut) td.BotCommand(command: q.name, description: quickReplyPreview(q.firstMessage, context.s), isEphemeral: false),
    ];
  }

  Future<void> _sendCommand(td.BotCommand command) async {
    _controller.clear();
    setState(() => _commandMatches = const []);
    widget.onSent();
    final quickReply = _botInfo == null ? _account.quickReplies.values.where((q) => q.name == command.command).firstOrNull : null;
    if (quickReply != null) {
      await guard(context, () => _account.send<td.Messages>(td.SendQuickReplyShortcutMessages(chatId: widget.chat.id, shortcutId: quickReply.id, sendingId: 0)));
      return;
    }
    await guard(context, () => _account.sendText(widget.chat.id, '/${command.command}'));
  }

  /// Bot menu: the bot's Mini App when it defines one, otherwise its command list.
  Future<void> _openBotMenu() async {
    final info = _botInfo;
    final bot = _account.privateUser(widget.chat);
    if (info == null || bot == null) return;
    final menu = info.menuButton;
    if (menu != null && menu.url.isNotEmpty) {
      await openInlineWebApp(context, ref, chatId: widget.chat.id, botUserId: bot.id, url: menu.url);
      return;
    }
    final command = await showModalBottomSheet<td.BotCommand>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
          child: _CommandList(commands: info.commands, onPick: (c) => Navigator.pop(context, c), maxHeight: double.infinity),
        ),
      ),
    );
    if (command != null && mounted) await _sendCommand(command);
  }

  /// aka-style guard against accidental taps: asks before sending when the matching setting is on.
  Future<bool> _confirmSend(bool enabled, String what) async {
    if (!enabled) return true;
    final s = context.s;
    return confirm(context, title: s.t('confirm_send_title'), message: s.t('confirm_send_$what'));
  }

  Future<void> _sendSticker(td.Sticker sticker) async {
    if (!await _confirmSend(ref.read(settingsProvider).confirmSticker, 'sticker') || !mounted) return;
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    await guard(context, () => _account.sendSticker(widget.chat.id, sticker, replyToId: replyId));
  }

  Future<void> _sendAnimation(td.Animation animation) async {
    if (!await _confirmSend(ref.read(settingsProvider).confirmGif, 'gif') || !mounted) return;
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    await guard(context, () => _account.sendAnimation(widget.chat.id, animation, replyToId: replyId));
  }

  /// Wraps the selection in Telegram markdown markers (parsed into entities on send).
  void _wrapSelection(String left, [String? right]) {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final replacement = '$left${selection.textInside(value.text)}${right ?? left}';
    _controller.value = TextEditingValue(
      text: selection.textBefore(value.text) + replacement + selection.textAfter(value.text),
      selection: TextSelection.collapsed(offset: selection.start + replacement.length),
    );
  }

  Future<void> _insertLink() async {
    final selection = _controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final urlController = TextEditingController(text: 'https://');
    final s = context.s;
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('format_link')),
        content: TextField(controller: urlController, autofocus: true, keyboardType: TextInputType.url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, urlController.text.trim()), child: Text(s.t('ok'))),
        ],
      ),
    );
    urlController.dispose();
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !mounted) return;
    _controller.selection = selection;
    _wrapSelection('[', ']($url)');
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final s = context.s;
    final hasSelection = !state.textEditingValue.selection.isCollapsed;
    ContextMenuButtonItem format(String key, VoidCallback apply) => ContextMenuButtonItem(
          label: s.t(key),
          onPressed: () {
            ContextMenuController.removeAny();
            apply();
          },
        );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ...state.contextMenuButtonItems,
        if (hasSelection) ...[
          format('format_bold', () => _wrapSelection('**')),
          format('format_italic', () => _wrapSelection('__')),
          format('format_strike', () => _wrapSelection('~~')),
          format('format_spoiler', () => _wrapSelection('||')),
          format('format_code', () => _wrapSelection('`')),
          format('format_link', () => unawaited(_insertLink())),
        ],
      ],
    );
  }

  /// Hardware keyboards: Enter sends (when enabled), Shift+Enter inserts a new line.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event is! KeyDownEvent || !enter || HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (!ref.read(settingsProvider).sendByEnter || _controller.value.composing.isValid) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  Future<void> _send({bool silent = false, int? scheduleAt}) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final account = ref.read(accountProvider);
    final editing = widget.editing;
    if (editing != null) {
      final ok = await guard(context, () async {
        await account.editText(editing, text);
        return true;
      });
      if (ok == null) return;
      _controller.clear();
      widget.onCancelEdit();
      return;
    }
    final disablePreview = _previewClosed;
    _controller.clear();
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    // Telegram limits a message to 4096 characters; split longer texts.
    for (var start = 0; start < text.length; start += 4096) {
      final part = text.substring(start, min(text.length, start + 4096));
      final sent = await guard(
        context,
        () => account.sendText(
          widget.chat.id,
          part,
          replyToId: start == 0 ? replyId : null,
          silent: silent,
          scheduleAt: scheduleAt,
          disablePreview: disablePreview,
        ),
      );
      if (sent == null) {
        if (mounted && _controller.text.isEmpty) setText(text);
        return;
      }
    }
  }

  /// Long-press on send: silent or scheduled sending.
  Future<void> _sendOptions() async {
    final s = context.s;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_off_rounded),
              title: Text(s.t('send_silent')),
              onTap: () => Navigator.pop(context, 'silent'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_rounded),
              title: Text(s.t('send_scheduled')),
              onTap: () => Navigator.pop(context, 'schedule'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'silent') {
      await _send(silent: true);
      return;
    }
    final at = await pickScheduleTime(context);
    if (at != null && mounted) {
      await _send(scheduleAt: at);
      if (mounted) showToast(context, s.t('message_scheduled'));
    }
  }

  // ------------------------------------------------------------------ attachments

  /// "Send as": the user or one of their channels, for chats that allow choosing.
  Future<void> _pickSender() async {
    final s = context.s;
    final senders = await guard(context, () => _account.send<td.ChatMessageSenders>(td.GetChatAvailableMessageSenders(chatId: widget.chat.id)));
    if (senders == null || !mounted) return;
    final current = widget.chat.messageSenderId;
    final chosen = await showModalBottomSheet<td.MessageSender>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(s.t('send_as'), style: Theme.of(context).textTheme.titleMedium)),
            for (final option in senders.senders)
              ListTile(
                leading: switch (option.sender) {
                  td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 40, showOnline: false),
                  td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 40, showOnline: false),
                  _ => const Icon(Icons.person_rounded),
                },
                title: Text(_account.senderName(option.sender)),
                subtitle: option.needsPremium ? Text(s.t('premium_only')) : null,
                trailing: option.sender == current ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.pop(context, option.sender),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == current || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.SetChatMessageSender(chatId: widget.chat.id, messageSenderId: chosen)));
  }

  Future<void> _attach() async {
    // The in-app gallery needs media permissions only granted on phones; desktop keeps the system pickers.
    final bots = ref.read(accountProvider).attachmentMenuBots.where((b) => b.showInAttachmentMenu && _botFitsChat(b)).toList();
    final choice = isDesktop ? const AttachAction('system_gallery') : await showAttachSheet(context, bots: bots);
    if (choice == null || !mounted) return;
    final account = ref.read(accountProvider);
    final chatId = widget.chat.id;
    final replyId = widget.replyTo?.id;
    final picker = ImagePicker();
    switch (choice) {
      case AttachMedia():
        await _sendMedia(choice);
      case AttachAction(action: 'system_gallery'):
        final files = await picker.pickMultipleMedia(imageQuality: 90);
        await _sendMedia(AttachMedia(
          media: [for (final file in files) PickedMedia(path: file.path, isVideo: _isVideoPath(file.path))],
          caption: '',
        ));
      case AttachAction(action: 'camera'):
        final file = await picker.pickImage(source: ImageSource.camera, imageQuality: 90);
        if (file != null && mounted) await guard(context, () => account.sendPhoto(chatId, file.path, replyToId: replyId));
      case AttachAction(action: 'record_video'):
        final file = await picker.pickVideo(source: ImageSource.camera);
        if (file != null && mounted) await guard(context, () => account.sendVideo(chatId, file.path, replyToId: replyId));
      case AttachAction(action: 'file'):
        final files = await FilePicker.pickFiles();
        for (final file in files) {
          final path = file.path;
          if (path == null || !mounted) continue;
          await guard(context, () => account.sendDocument(chatId, path, replyToId: replyId));
        }
      case AttachAction(action: 'music'):
        final files = await FilePicker.pickFiles(type: FileType.audio);
        for (final file in files) {
          final path = file.path;
          if (path == null || !mounted) continue;
          await guard(context, () => account.sendAudio(chatId, path, replyToId: replyId));
        }
      case AttachAction(action: 'location'):
        await _sendLocation();
      case AttachAction(action: 'poll'):
        await _createPoll();
      case AttachAction(action: 'article'):
        final text = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ArticleEditorScreen()));
        if (text != null && mounted) await guard(context, () => account.sendText(chatId, text, replyToId: replyId));
      case AttachAction(action: 'checklist'):
        final checklist = await Navigator.of(context).push<td.InputChecklist>(MaterialPageRoute(builder: (_) => const ChecklistCreatorScreen()));
        if (checklist != null && mounted) {
          await guard(context, () => account.sendContent(chatId, td.InputMessageChecklist(checklist: checklist), replyToId: replyId));
        }
      case AttachAction(:final action) when action.startsWith('bot:'):
        final botId = int.tryParse(action.substring(4));
        if (botId != null) await openInlineWebApp(context, ref, chatId: chatId, botUserId: botId, url: '');
        return;
      case AttachAction(action: 'contact'):
        final contact = await Navigator.of(context).push<td.Contact>(
          MaterialPageRoute(builder: (_) => const ContactPickerScreen()),
        );
        if (contact != null && mounted) {
          await guard(context, () => account.sendContent(chatId, td.InputMessageContact(contact: contact), replyToId: replyId));
        }
      case AttachAction():
        return;
    }
    widget.onCancelReply();
    widget.onSent();
  }

  /// Whether an attach-menu Mini App works in this kind of chat (TDLib's supports* flags).
  bool _botFitsChat(td.AttachmentMenuBot bot) {
    final account = ref.read(accountProvider);
    final chat = widget.chat;
    return switch (chat.type) {
      td.ChatTypePrivate(:final userId) when userId == account.myId => bot.supportsSelfChat,
      td.ChatTypePrivate() when account.isBot(account.privateUser(chat)) => bot.supportsBotChats,
      td.ChatTypePrivate() || td.ChatTypeSecret() => bot.supportsUserChats,
      td.ChatTypeSupergroup(:final isChannel) when isChannel => bot.supportsChannelChats,
      _ => bot.supportsGroupChats,
    };
  }

  /// Photos/videos go out as albums of up to 10 with the caption on the first one, like Telegram;
  /// "without compression" sends the originals as files.
  Future<void> _sendMedia(AttachMedia pick) async {
    final account = ref.read(accountProvider);
    final chatId = widget.chat.id;
    final replyId = widget.replyTo?.id;
    if (pick.asFiles) {
      for (var i = 0; i < pick.media.length; i++) {
        if (!mounted) return;
        final caption = i == pick.media.length - 1 ? pick.caption : '';
        await guard(context, () => account.sendDocument(chatId, pick.media[i].path,
            caption: caption, replyToId: i == 0 ? replyId : null, silent: pick.silent));
      }
      return;
    }
    for (var start = 0; start < pick.media.length; start += 10) {
      final batch = pick.media.sublist(start, min(pick.media.length, start + 10));
      if (!mounted) return;
      await guard(context, () => account.sendAlbum(
            chatId,
            [
              for (final (i, m) in batch.indexed)
                m.isVideo
                    ? videoContent(m.path, caption: start + i == 0 ? pick.caption : '', width: m.width, height: m.height, duration: m.duration)
                    : photoContent(m.path, caption: start + i == 0 ? pick.caption : '', width: m.width, height: m.height),
            ],
            replyToId: start == 0 ? replyId : null,
            silent: pick.silent,
          ));
    }
  }

  static bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.mkv') || lower.endsWith('.webm') ||
        lower.endsWith('.3gp');
  }

  /// Telegram's location tab: a map of where you are, then send it once or share it live.
  Future<void> _sendLocation() async {
    final s = context.s;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (mounted) showToast(context, s.t('location_permission'));
      return;
    }
    if (!mounted) return;
    final account = ref.read(accountProvider);
    final chatId = widget.chat.id;
    final choice = await Navigator.of(context).push<LocationChoice>(MaterialPageRoute(builder: (_) => LocationPickerScreen(chatId: chatId)));
    if (choice == null || !mounted) return;
    switch (choice) {
      case PointChoice(:final latitude, :final longitude):
        await guard(context, () => account.sendLocation(chatId, latitude, longitude));
      case VenueChoice(:final venue):
        await guard(context, () => account.sendContent(chatId, td.InputMessageVenue(venue: venue)));
      case LiveChoice(:final minutes):
        final ok = await guard(context, () => LiveLocationService.instance.start(_account, chatId, Duration(minutes: minutes)));
        if (ok == false && mounted) showToast(context, s.t('location_permission'));
    }
  }

  Future<void> _createPoll() async {
    final poll = await Navigator.of(context).push<PollDraft>(MaterialPageRoute(builder: (_) => const PollCreatorScreen()));
    if (poll == null || !mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).sendPoll(
            widget.chat.id,
            poll.question,
            poll.options,
            anonymous: poll.anonymous,
            multiple: poll.multiple,
            correctOption: poll.correctOption,
            explanation: poll.explanation,
          ),
    );
  }

  // ------------------------------------------------------------------ voice notes

  Future<void> _startRecording() async {
    if (_recording) return;
    if (_videoMode) return _startVideoNote();
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      if (mounted) showToast(context, context.t('mic_permission'));
      return;
    }
    final opus = Platform.isAndroid && await recorder.isEncoderSupported(AudioEncoder.opus);
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.${opus ? 'ogg' : 'm4a'}';
    await recorder.start(
      RecordConfig(encoder: opus ? AudioEncoder.opus : AudioEncoder.aacLc, numChannels: 1, sampleRate: 48000, bitRate: 64000),
      path: path,
    );
    HapticFeedback.mediumImpact();
    _waveform.clear();
    _amplitudeSub = recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
      // dBFS (-160..0) mapped to Telegram's 0..31 waveform scale.
      _waveform.add((((amp.current + 50) / 50).clamp(0.0, 1.0) * 31).round());
    });
    _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) => setState(() {}));
    if (!ref.read(settingsProvider).ghostMode) {
      unawaited(ref.read(accountProvider).sendTyping(widget.chat.id, const td.ChatActionRecordingVoiceNote()));
    }
    final startedAt = DateTime.now();
    setState(() {
      _recording = true;
      _recordStart = startedAt;
      _recordPath = path;
      _dragOffset = 0;
      _locked = false;
    });
    _showRecordingOverlay(null, startedAt);
    // Released while the permission check / recorder start was still running: a tap, not a recording.
    if (!_pressing) await _stopRecording(send: false);
  }

  /// Voice: just the slide-up lock pill; video: also the dimmed round preview with camera/flash buttons.
  void _showRecordingOverlay(CameraController? camera, DateTime startedAt) {
    _cameraOverlay?.remove();
    _cameraOverlay = OverlayEntry(
      builder: (_) => _RecordingOverlay(
        controller: camera,
        startedAt: startedAt,
        limit: _videoNoteLimit,
        isLocked: () => _locked,
        flashOn: () => _flash,
        onSwitchCamera: camera == null ? null : _switchCamera,
        onFlash: camera == null ? null : _toggleFlash,
      ),
    );
    Overlay.of(context).insert(_cameraOverlay!);
  }

  void _hideRecordingOverlay() {
    _cameraOverlay?.remove();
    _cameraOverlay = null;
  }

  Future<void> _switchCamera() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      final current = camera.description.lensDirection;
      final next = (await availableCameras()).where((c) => c.lensDirection != current).firstOrNull;
      if (next == null) return;
      // Continues the same recording with the other camera.
      await camera.setDescription(next);
      if (_flash) await _applyTorch(camera);
    } on CameraException catch (error) {
      debugPrint('camera switch failed: $error');
    }
    _cameraOverlay?.markNeedsBuild();
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;
    setState(() => _flash = !_flash);
    await _applyTorch(camera);
    _cameraOverlay?.markNeedsBuild();
  }

  Future<void> _applyTorch(CameraController camera) async {
    if (camera.description.lensDirection != CameraLensDirection.back) return;
    try {
      await camera.setFlashMode(_flash ? FlashMode.torch : FlashMode.off);
    } on CameraException catch (error) {
      debugPrint('torch failed: $error');
    }
  }

  /// Short hint bubble above the mic button (aka/Telegram style) instead of a bottom toast.
  void _showMicTip(String text) {
    _tipTimer?.cancel();
    _tip?.remove();
    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom + media.viewInsets.bottom + 72;
    _tip = OverlayEntry(
      builder: (context) => Positioned(
        left: 48,
        right: 10,
        bottom: bottom,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: const Color(0xEE262D36),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3)),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_tip!);
    _tipTimer = Timer(const Duration(seconds: 3), () {
      _tip?.remove();
      _tip = null;
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    if (_recordingVideo) return _stopVideoNote(send: send);
    _hideRecordingOverlay();
    await _amplitudeSub?.cancel();
    _recordTicker?.cancel();
    final path = await _recorder?.stop() ?? _recordPath;
    final duration = DateTime.now().difference(_recordStart!);
    if (!mounted) return;
    setState(() {
      _recording = false;
      _locked = false;
      _dragOffset = 0;
    });
    if (!send || path == null || duration < const Duration(milliseconds: 700)) {
      if (path != null) unawaited(File(path).delete().catchError((Object _) => File(path)));
      return;
    }
    // Downsample to Telegram's 100-sample waveform.
    final samples = _waveform.isEmpty
        ? <int>[]
        : List<int>.generate(100, (i) => _waveform[(i * _waveform.length / 100).floor()]);
    if (!mounted) return;
    if (!await _confirmSend(ref.read(settingsProvider).confirmVoice, 'voice') || !mounted) {
      unawaited(File(path).delete().catchError((Object _) => File(path)));
      return;
    }
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    await guard(
      context,
      () => ref.read(accountProvider).sendVoice(widget.chat.id, path, durationSeconds: max(1, duration.inSeconds), waveform: samples, replyToId: replyId),
    );
  }

  // ------------------------------------------------------------------ round video messages

  Future<void> _startVideoNote() async {
    final s = context.s;
    final CameraController controller;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) showToast(context, s.t('camera_unavailable'));
        return;
      }
      final camera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cameras.first);
      controller = CameraController(camera, ResolutionPreset.medium);
      // Asks for camera and microphone access on first use.
      await controller.initialize();
    } on CameraException catch (error) {
      debugPrint('video note camera failed: $error');
      if (mounted) showToast(context, s.t(error.code.contains('Denied') ? 'camera_permission' : 'camera_unavailable'));
      return;
    }
    if (!mounted || !_pressing) {
      // Released (or left the chat) while the camera was starting: nothing to record.
      await controller.dispose();
      return;
    }
    try {
      await controller.startVideoRecording();
    } on CameraException catch (error) {
      debugPrint('video note recording failed: $error');
      await controller.dispose();
      if (mounted) showToast(context, s.t('camera_unavailable'));
      return;
    }
    if (!mounted) {
      unawaited(controller.dispose());
      return;
    }
    _camera = controller;
    HapticFeedback.mediumImpact();
    final startedAt = DateTime.now();
    _flash = false;
    _showRecordingOverlay(controller, startedAt);
    _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {});
      // Telegram caps round videos at one minute: send what was recorded.
      if (DateTime.now().difference(startedAt) >= _videoNoteLimit) unawaited(_stopRecording(send: true));
    });
    if (!ref.read(settingsProvider).ghostMode) {
      unawaited(ref.read(accountProvider).sendTyping(widget.chat.id, const td.ChatActionRecordingVideoNote()));
    }
    setState(() {
      _recording = true;
      _recordingVideo = true;
      _recordStart = startedAt;
      _dragOffset = 0;
      _locked = false;
    });
    if (!_pressing) await _stopRecording(send: false);
  }

  Future<void> _stopVideoNote({required bool send}) async {
    _recordTicker?.cancel();
    _hideRecordingOverlay();
    _flash = false;
    final controller = _camera;
    _camera = null;
    final duration = DateTime.now().difference(_recordStart ?? DateTime.now());
    if (mounted) {
      setState(() {
        _recording = false;
        _recordingVideo = false;
        _locked = false;
        _dragOffset = 0;
      });
    }
    if (controller == null) return;
    XFile? file;
    try {
      file = await controller.stopVideoRecording();
    } on CameraException catch (error) {
      debugPrint('video note stop failed: $error');
    } finally {
      await controller.dispose();
    }
    if (file == null) return;
    if (!send || duration < const Duration(seconds: 1) || !mounted) {
      unawaited(File(file.path).delete().catchError((Object _) => File(file!.path)));
      return;
    }
    final replyId = widget.replyTo?.id;
    widget.onCancelReply();
    widget.onSent();
    // Square or Telegram delivers it as an ordinary video; without a crop it is still sent (as a video).
    final square = await cropVideoNoteSquare(file.path);
    if (square != null) unawaited(File(file.path).delete().catchError((Object _) => File(file!.path)));
    if (!mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).sendVideoNote(
            widget.chat.id,
            square ?? file!.path,
            durationSeconds: max(1, duration.inSeconds),
            length: videoNoteSize,
            replyToId: replyId,
          ),
    );
  }

  // ------------------------------------------------------------------ Telegram AI

  Future<void> _aiTools() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final account = ref.read(accountProvider);
    final s = context.s;
    final styles = account.compositionStyles;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: const Icon(Icons.spellcheck_rounded), title: Text(s.t('ai_fix')), onTap: () => Navigator.pop(context, 'fix')),
              ListTile(
                leading: const Icon(Icons.translate_rounded),
                title: Text(s.t('ai_translate_to', {'lang': Strings.languageNames[s.locale] ?? s.locale})),
                onTap: () => Navigator.pop(context, 'translate'),
              ),
              ListTile(
                leading: const Icon(Icons.emoji_emotions_rounded),
                title: Text(s.t('ai_add_emoji')),
                onTap: () => Navigator.pop(context, 'emoji'),
              ),
              for (final style in styles)
                ListTile(
                  leading: const Icon(Icons.auto_awesome_rounded),
                  title: Text(style.title),
                  onTap: () => Navigator.pop(context, 'style:${style.name}'),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final settings = ref.read(settingsProvider);
    final result = await guard(context, () {
      if (choice == 'fix') return account.fixWithAi(text);
      if (choice == 'translate') return account.translate(text, settings.localeCode);
      if (choice == 'emoji') return account.composeWithAi(text, addEmojis: true);
      return account.composeWithAi(text, styleName: choice.substring(6));
    });
    if (result != null && mounted) setText(result);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final settings = ref.watch(settingsProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final chat = widget.chat;

    if (!account.isMember(chat) &&
        (account.isChannel(chat) || account.isGroup(chat))) {
      return _BottomAction(
        label: s.t(account.isChannel(chat) ? 'join_channel' : 'join_group'),
        onTap: () => guard(context, () => account.send<td.Ok>(td.JoinChat(chatId: chat.id))),
      );
    }
    if (!account.canSendMessages(chat)) {
      final muted = account.isMuted(chat);
      if (account.isChannel(chat)) {
        return _BottomAction(
          label: s.t(muted ? 'unmute' : 'mute'),
          onTap: () => guard(context, () => account.setMuted(chat, muted ? 0 : muteForever)),
        );
      }
      if (chat.type is td.ChatTypeSecret) {
        final state = account.secretChatOf(chat)?.state;
        return _BottomAction(label: s.t(state is td.SecretChatStateClosed ? 'secret_closed' : 'secret_pending'), onTap: null);
      }
      final user = account.privateUser(chat);
      if (user != null && chat.blockList != null) {
        return _BottomAction(
          label: s.t('unblock'),
          onTap: () => guard(context, () => account.send<td.Ok>(
                td.SetMessageSenderBlockList(senderId: td.MessageSenderUser(userId: user.id), blockList: null),
              )),
        );
      }
      return _BottomAction(label: s.t('cannot_send'), onTap: null);
    }

    final reference = widget.editing ?? widget.replyTo;
    // Phones: the field floats as a pill over the chat (aka style); desktop keeps the docked bar.
    return Material(
      color: isDesktop ? theme.colorScheme.surface : Colors.transparent,
      shape: isDesktop ? Border(top: BorderSide(color: theme.dividerColor, width: 0.5)) : null,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_commandMatches.isNotEmpty)
              _CommandList(commands: _commandMatches, onPick: _sendCommand)
            else if (_inlineResults != null)
              InlineResultsPanel(
                results: _inlineResults!,
                onPick: (id) => _sendInlineResult(_inlineResults!.inlineQueryId, id),
                onLoadMore: _loadMoreInline,
              )
            else if (_mentions.isNotEmpty)
              MentionSuggestions(members: _mentions, onPick: _pickMention),
            if (_preview case final preview? when !_previewClosed && widget.editing == null)
              Material(
                color: theme.colorScheme.surfaceContainerHighest,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.link_rounded, color: theme.colorScheme.primary),
                  title: Text(preview.title.isNotEmpty ? preview.title : preview.siteName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    preview.description.text.isNotEmpty ? preview.description.text : preview.displayUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: s.t('link_preview_remove'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _previewClosed = true),
                  ),
                ),
              ),
            if (reference != null)
              _ReferenceBar(
                message: reference,
                editing: widget.editing != null,
                onClose: widget.editing != null ? widget.onCancelEdit : widget.onCancelReply,
              ),
            Padding(
              padding: isDesktop ? const EdgeInsets.all(4) : const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: _composerRow(s, settings),
            ),
            if (_showEmoji)
              MediaPanel(
                controller: _controller,
                chatId: widget.chat.id,
                onSticker: _sendSticker,
                onAnimation: _sendAnimation,
                onInlineResult: _sendInlineResult,
              ),
          ],
        ),
      ),
    );
  }

  /// The trailing send/mic button keeps its place in the tree while recording: replacing it mid-press
  /// would drop the long-press gesture, so release and slide would never reach the recorder.
  Widget _composerRow(Strings s, AppSettings settings) {
    final theme = Theme.of(context);
    final fields = _recording ? _recordingInfo(s) : _inputRow(s, settings);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: isDesktop
              ? fields
              : Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
                  ),
                  child: fields,
                ),
        ),
        if (!isDesktop) const SizedBox(width: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
          child: (_hasText || widget.editing != null) && !_recording
              ? GestureDetector(
                  key: const ValueKey('send'),
                  onLongPress: widget.editing == null ? _sendOptions : null,
                  onSecondaryTap: widget.editing == null ? _sendOptions : null,
                  child: isDesktop
                      ? IconButton(
                          icon: Icon(widget.editing != null ? Icons.check_circle_rounded : Icons.send_rounded, color: theme.colorScheme.primary),
                          onPressed: _send,
                        )
                      : _RoundButton(onTap: _send, child: Icon(widget.editing != null ? Icons.check_rounded : Icons.send_rounded, color: Colors.white)),
                )
              : _micButton(theme),
        ),
      ],
    );
  }

  Widget _inputRow(Strings s, AppSettings settings) {
    final theme = Theme.of(context);
    final botMenu = _botInfo?.menuButton;
    final hasBotMenu = !_hasText && ((botMenu != null && botMenu.url.isNotEmpty) || (_botInfo?.commands.isNotEmpty ?? false));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (hasBotMenu)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 0, 6),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              onPressed: _openBotMenu,
              icon: Icon(botMenu != null && botMenu.url.isNotEmpty ? Icons.apps_rounded : Icons.menu_rounded, size: 18),
              label: Text(botMenu != null && botMenu.text.isNotEmpty ? botMenu.text : s.t('bot_menu'), style: const TextStyle(fontSize: 14)),
            ),
          ),
        if (widget.chat.messageSenderId case final sender? when widget.editing == null)
          IconButton(
            tooltip: s.t('send_as'),
            onPressed: _pickSender,
            icon: switch (sender) {
              td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 28, showOnline: false),
              td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 28, showOnline: false),
              _ => const Icon(Icons.person_rounded),
            },
          ),
        IconButton(
          icon: Icon(_showEmoji ? Icons.keyboard_rounded : Icons.emoji_emotions_outlined, color: theme.hintColor),
          onPressed: () {
            setState(() => _showEmoji = !_showEmoji);
            if (_showEmoji) {
              _focus.unfocus();
            } else {
              _focus.requestFocus();
            }
          },
        ),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            textInputAction: settings.sendByEnter ? TextInputAction.send : TextInputAction.newline,
            onSubmitted: settings.sendByEnter ? (_) => _send() : null,
            style: TextStyle(fontSize: 16 * settings.textScale),
            contextMenuBuilder: _contextMenu,
            decoration: InputDecoration(
              hintText: switch (_inlineBot?.type) {
                td.UserTypeBot(:final inlineQueryPlaceholder) when _inlineQuery.isEmpty && inlineQueryPlaceholder.isNotEmpty =>
                  inlineQueryPlaceholder,
                _ => s.t('message_hint'),
              },
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (_hasText && widget.editing == null)
          IconButton(
            tooltip: 'Telegram AI',
            icon: Icon(Icons.auto_awesome_rounded, color: theme.colorScheme.primary),
            onPressed: _aiTools,
          ),
        if (!_hasText && widget.editing == null)
          IconButton(icon: Icon(Icons.attach_file_rounded, color: theme.hintColor), onPressed: _attach),
      ],
    );
  }

  /// Hold to record, slide left to cancel, slide up to lock; while locked a tap sends.
  Widget _micButton(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    // Halo while recording: follows the voice level, or breathes slowly for video.
    final pulse = !_recording
        ? 0.0
        : (_recordingVideo || _waveform.isEmpty ? (sin(DateTime.now().millisecondsSinceEpoch / 320) + 1) / 2 : _waveform.last / 31);
    return GestureDetector(
      key: const ValueKey('mic'),
      onTap: () {
        if (_recording && _locked) {
          unawaited(_stopRecording(send: true));
        } else if (!_recording) {
          HapticFeedback.selectionClick();
          setState(() => _videoMode = !_videoMode);
          _showMicTip(context.t(_videoMode ? 'hold_to_record_video' : 'hold_to_record'));
        }
      },
      onLongPressStart: (_) {
        _pressing = true;
        unawaited(_startRecording());
      },
      onLongPressMoveUpdate: (details) {
        if (!_recording || _locked) return;
        final offset = details.offsetFromOrigin;
        if (offset.dy < -_lockDistance) {
          HapticFeedback.selectionClick();
          setState(() {
            _locked = true;
            _dragOffset = 0;
          });
          return;
        }
        setState(() => _dragOffset = min(0, offset.dx));
        if (_dragOffset < -_cancelDistance) unawaited(_stopRecording(send: false));
      },
      onLongPressEnd: (_) {
        _pressing = false;
        if (_recording && !_locked) unawaited(_stopRecording(send: _dragOffset > -_cancelDistance));
      },
      onLongPressCancel: () => _pressing = false,
      // Phones: always a round accent button beside the floating field (aka style); desktop: a plain icon until recording.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: _recording ? 60 : (isDesktop ? 48 : 52),
        height: _recording ? 60 : (isDesktop ? 48 : 52),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: _recording || !isDesktop ? brandGradient(primary, vertical: true) : null,
          boxShadow: [
            if (_recording) BoxShadow(color: primary.withValues(alpha: 0.28), spreadRadius: 6 + 14 * pulse),
            if (_recording || !isDesktop)
              BoxShadow(color: primary.withValues(alpha: _recording ? 0.45 : 0.3), blurRadius: _recording ? 16 : 10, offset: const Offset(0, 4)),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
          child: Icon(
            _recording && _locked
                ? Icons.send_rounded
                : (_videoMode ? Icons.photo_camera_outlined : Icons.mic_rounded),
            key: ValueKey('$_videoMode$_locked$_recording'),
            color: _recording || !isDesktop ? Colors.white : theme.hintColor,
          ),
        ),
      ),
    );
  }

  /// Recording strip left of the mic: blinking dot, timer, then the slide hint or (locked) cancel.
  Widget _recordingInfo(Strings s) {
    final theme = Theme.of(context);
    final elapsed = DateTime.now().difference(_recordStart ?? DateTime.now());
    final tenths = (elapsed.inMilliseconds % 1000) ~/ 100;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 14),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: (elapsed.inMilliseconds ~/ 500).isEven ? 1 : 0.2,
            child: const Icon(Icons.fiber_manual_record_rounded, color: Colors.redAccent, size: 14),
          ),
          const SizedBox(width: 8),
          Text(
            '${formatDuration(elapsed)},$tenths',
            style: const TextStyle(fontSize: 15.5, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          Expanded(
            child: _locked
                ? Center(
                    child: TextButton(
                      onPressed: () => _stopRecording(send: false),
                      child: Text(s.t('cancel').toUpperCase(), style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  )
                : Transform.translate(
                    offset: Offset(max(-80, _dragOffset / 2), 0),
                    child: Opacity(
                      opacity: (1 + _dragOffset / _cancelDistance).clamp(0.3, 1.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chevron_left_rounded, color: theme.hintColor),
                          Flexible(
                            child: Text(s.t('slide_to_cancel'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.hintColor)),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          // The slide-up lock pill floats above the mic (recording overlay).
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Round accent send button beside the floating field, matching the mic button.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: brandGradient(primary, vertical: true),
        boxShadow: [BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Center(child: child)),
      ),
    );
  }
}

/// Overlay while recording, as in aka/Telegram. Voice: a "slide up to lock" pill above the mic.
/// Video: also the dimmed screen with a large round camera preview and a thin progress ring, plus
/// camera-switch and flash buttons. Only those buttons take touches; the rest passes through so the
/// mic underneath keeps handling slide-to-cancel, lock and send.
class _RecordingOverlay extends StatefulWidget {
  const _RecordingOverlay({
    required this.controller,
    required this.startedAt,
    required this.limit,
    required this.isLocked,
    required this.flashOn,
    this.onSwitchCamera,
    this.onFlash,
  });

  /// Null for voice recordings.
  final CameraController? controller;
  final DateTime startedAt;
  final Duration limit;
  final bool Function() isLocked;
  final bool Function() flashOn;
  final VoidCallback? onSwitchCamera;
  final VoidCallback? onFlash;

  @override
  State<_RecordingOverlay> createState() => _RecordingOverlayState();
}

class _RecordingOverlayState extends State<_RecordingOverlay> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // Drives the progress ring and picks up lock/flash changes from the composer.
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final controller = widget.controller;
    // Top of the floating composer (52 px field + 8 px margin above the system inset / keyboard).
    final composerTop = media.padding.bottom + media.viewInsets.bottom + 64;
    final flash = widget.flashOn();
    final front = controller?.description.lensDirection == CameraLensDirection.front;
    return Stack(
      children: [
        if (controller != null) ...[
          Positioned.fill(
            child: IgnorePointer(
              // Front-camera "flash" lights the face with a white screen.
              child: ColoredBox(color: flash && front ? Colors.white : Colors.black.withValues(alpha: 0.6)),
            ),
          ),
          Positioned.fill(child: IgnorePointer(child: _preview(context, controller))),
          Positioned(
            left: 12,
            bottom: composerTop + 14,
            child: Container(
              decoration: BoxDecoration(color: const Color(0xCC1E2630), borderRadius: BorderRadius.circular(28)),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.flip_camera_android_rounded, color: Colors.white),
                    onPressed: widget.onSwitchCamera,
                  ),
                  IconButton(
                    icon: Icon(flash ? Icons.flash_on_rounded : Icons.flash_off_rounded, color: flash ? const Color(0xFFFFC94D) : Colors.white),
                    onPressed: widget.onFlash,
                  ),
                ],
              ),
            ),
          ),
        ],
        if (!widget.isLocked())
          Positioned(
            right: 14,
            bottom: composerTop + 26,
            child: IgnorePointer(
              child: Container(
                width: 44,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Theme.of(context).dividerColor),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 3))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                    Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: Theme.of(context).hintColor),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _preview(BuildContext context, CameraController controller) {
    final screen = MediaQuery.sizeOf(context);
    final diameter = min(screen.width * 0.9, 420.0);
    final elapsed = DateTime.now().difference(widget.startedAt);
    final progress = (elapsed.inMilliseconds / widget.limit.inMilliseconds).clamp(0.0, 1.0);
    // Reported in sensor (landscape) orientation; swapped for the portrait preview.
    final preview = controller.value.previewSize;
    return Align(
      alignment: const Alignment(0, -0.25),
      child: SizedBox.square(
        dimension: diameter + 12,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CircularProgressIndicator(value: progress, strokeWidth: 3, color: Colors.white, strokeCap: StrokeCap.round),
            Padding(
              padding: const EdgeInsets.all(6),
              child: ClipOval(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: preview?.height ?? diameter,
                    height: preview?.width ?? diameter,
                    child: CameraPreview(controller),
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

class _BottomAction extends StatelessWidget {
  const _BottomAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Center(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: onTap == null ? Theme.of(context).hintColor : Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _ReferenceBar extends ConsumerWidget {
  const _ReferenceBar({required this.message, required this.editing, required this.onClose});

  final td.Message message;
  final bool editing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(
        children: [
          Icon(editing ? Icons.edit_rounded : Icons.reply_rounded, color: primary),
          const SizedBox(width: 10),
          Container(width: 2, height: 36, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing ? s.t('editing') : account.senderName(message.senderId),
                  style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                Text(
                  messagePreview(message, account, s).replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded), onPressed: onClose),
        ],
      ),
    );
  }
}

/// Date + time picker for scheduled messages; returns a unix timestamp in the future or null.
Future<int?> pickScheduleTime(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10))));
  if (time == null) return null;
  final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!at.isAfter(now.add(const Duration(seconds: 30)))) return null;
  return at.millisecondsSinceEpoch ~/ 1000;
}

class _CommandList extends StatelessWidget {
  const _CommandList({required this.commands, required this.onPick, this.maxHeight = 220});

  final List<td.BotCommand> commands;
  final void Function(td.BotCommand command) onPick;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: commands.length,
          itemBuilder: (context, index) {
            final command = commands[index];
            return ListTile(
              dense: true,
              title: Text('/${command.command}', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
              subtitle: command.description.isEmpty ? null : Text(command.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => onPick(command),
            );
          },
        ),
      );
}
