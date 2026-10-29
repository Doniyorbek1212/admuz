import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../profile/chat_info_screen.dart';
import '../settings/privacy_screen.dart' show promptText;
import 'checklist_creator.dart';

/// Telegram's "Replies" service account; its chat collects replies to the user's channel comments.
const repliesBotUserId = 1271266957;

/// Rewrites a sent checklist: title, tasks and who may add or tick them.
Future<void> editChecklist(BuildContext context, TelegramAccount account, td.Message message, td.Checklist checklist) async {
  final edited = await Navigator.of(context).push<td.InputChecklist>(
    MaterialPageRoute(builder: (_) => ChecklistCreatorScreen(initial: checklist)),
  );
  if (edited == null || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.Ok>(td.EditMessageChecklist(chatId: message.chatId, messageId: message.id, replyMarkup: null, checklist: edited)),
  );
}

/// Appends one task to someone's checklist when its author allowed others to add tasks.
Future<void> addChecklistTask(BuildContext context, TelegramAccount account, td.Message message, td.Checklist checklist) async {
  final s = context.s;
  final text = await promptText(context, title: s.t('checklist_add_task'), label: s.t('checklist_task'));
  if (text == null || text.isEmpty || !context.mounted) return;
  final nextId = checklist.tasks.fold(0, (max, task) => task.id > max ? task.id : max) + 1;
  await guard(
    context,
    () => account.send<td.Ok>(td.AddChecklistTasks(
      chatId: message.chatId,
      messageId: message.id,
      tasks: [td.InputChecklistTask(id: nextId, text: plainText(text))],
    )),
  );
}

/// Adds the user's own answer to a poll whose author allowed that.
Future<void> addPollOption(BuildContext context, TelegramAccount account, td.Message message) async {
  final s = context.s;
  final text = await promptText(context, title: s.t('poll_add_option'), label: s.t('poll_option'));
  if (text == null || text.isEmpty || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.Ok>(td.AddPollOption(
      chatId: message.chatId,
      messageId: message.id,
      option: td.InputPollOption(text: plainText(text), media: null),
    )),
  );
}

/// Long-press menu of a poll answer: who added it and, when allowed, deleting it.
Future<void> showPollOptionMenu(BuildContext context, TelegramAccount account, td.Message message, td.PollOption option) async {
  final s = context.s;
  final props = await guard(
    context,
    () => account.send<td.PollOptionProperties>(td.GetPollOptionProperties(chatId: message.chatId, messageId: message.id, pollOptionId: option.id)),
  );
  if (props == null || !context.mounted) return;
  final author = option.author;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(option.text.text, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (author != null) ListTile(leading: const Icon(Icons.person_outline_rounded), title: Text(s.t('poll_option_added_by', {'name': account.senderName(author)}))),
        ListTile(leading: const Icon(Icons.copy_rounded), title: Text(s.t('copy')), onTap: () => Navigator.pop(context, 'copy')),
        if (props.canBeDeleted)
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
      ]),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'copy':
      await Clipboard.setData(ClipboardData(text: option.text.text));
      if (context.mounted) showToast(context, s.t('copied'));
    case 'delete':
      await guard(context, () => account.send<td.Ok>(td.DeletePollOption(chatId: message.chatId, messageId: message.id, optionId: option.id)));
  }
}

/// The real person behind a channel post or anonymous admin message, when the chat reveals it.
Future<void> showMessageAuthor(BuildContext context, TelegramAccount account, td.Message message) async {
  final user = await guard(context, () => account.send<td.User>(td.GetMessageAuthor(chatId: message.chatId, messageId: message.id)));
  if (user == null || !context.mounted) return;
  final chat = await guard(context, () => account.openPrivateChat(user.id));
  if (chat == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: chat.id)));
}

/// HTML snippet that embeds a public post on a website.
Future<void> copyEmbedCode(BuildContext context, TelegramAccount account, td.Message message) async {
  final code = await guard(
    context,
    () => account.send<td.Text>(td.GetMessageEmbeddingCode(chatId: message.chatId, messageId: message.id, forAlbum: message.mediaAlbumId != 0)),
  );
  if (code == null || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: code.text));
  if (context.mounted) showToast(context, context.t('embed_copied'));
}

/// Fact-checkers attach, change or (empty text) remove the note shown under a post.
Future<void> editFactCheck(BuildContext context, TelegramAccount account, td.Message message) async {
  final s = context.s;
  final text = await promptText(context, title: s.t('fact_check'), label: s.t('fact_check_hint'), initial: message.factCheck?.text.text ?? '');
  if (text == null || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.Ok>(td.SetMessageFactCheck(chatId: message.chatId, messageId: message.id, text: text.isEmpty ? null : plainText(text))),
  );
}

/// "Replies" chat: blocks whoever wrote the original comment, optionally cleaning up after them.
Future<void> blockFromReplies(BuildContext context, TelegramAccount account, td.Message message) async {
  final s = context.s;
  var deleteMessage = true;
  var deleteAll = false;
  var reportSpam = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(s.t('block_user')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          CheckboxListTile(value: deleteMessage, title: Text(s.t('delete_this_message')), onChanged: (v) => setState(() => deleteMessage = v ?? false)),
          CheckboxListTile(value: deleteAll, title: Text(s.t('delete_all_from_user')), onChanged: (v) => setState(() => deleteAll = v ?? false)),
          CheckboxListTile(value: reportSpam, title: Text(s.t('report_spam')), onChanged: (v) => setState(() => reportSpam = v ?? false)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(s.t('block_user')),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.Ok>(td.BlockMessageSenderFromReplies(
      messageId: message.id,
      deleteMessage: deleteMessage,
      deleteAllMessages: deleteAll,
      reportSpam: reportSpam,
    )),
  );
}

const _paidReactionAmounts = [1, 10, 50, 100, 500, 1000];

/// Telegram star reaction: pick an amount and who it is shown from, with a short undo window before it is paid.
Future<void> sendPaidReaction(BuildContext context, TelegramAccount account, td.Message message) async {
  final s = context.s;
  final senders = await guard(
    context,
    () => account.send<td.MessageSenders>(td.GetChatAvailablePaidMessageReactionSenders(chatId: message.chatId)),
  );
  if (senders == null || !context.mounted) return;
  final me = message.interactionInfo?.reactions?.paidReactors.where((r) => r.isMe).firstOrNull;
  var amount = _paidReactionAmounts.first;
  var anonymous = me?.isAnonymous ?? false;
  // Null sender means "as myself"; a chat sender reacts on behalf of a channel the user owns.
  int? asChatId = switch (me?.senderId) { td.MessageSenderChat(:final chatId) => chatId, _ => null };
  td.PaidReactionType typeNow() => anonymous
      ? const td.PaidReactionTypeAnonymous()
      : asChatId == null
          ? const td.PaidReactionTypeRegular()
          : td.PaidReactionTypeChat(chatId: asChatId!);
  final picked = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(s.t('paid_reaction'), style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(s.t('paid_reaction_hint'), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              for (final value in _paidReactionAmounts)
                ChoiceChip(label: Text('$value ⭐'), selected: amount == value, onSelected: (_) => setState(() => amount = value)),
            ]),
            if (senders.senders.length > 1) ...[
              const SizedBox(height: 12),
              RadioGroup<int?>(
                groupValue: asChatId,
                onChanged: (v) => setState(() => asChatId = v),
                child: Column(children: [
                  for (final sender in senders.senders)
                    RadioListTile<int?>(
                      value: switch (sender) { td.MessageSenderChat(:final chatId) => chatId, _ => null },
                      enabled: !anonymous,
                      title: Text(account.senderName(sender)),
                    ),
                ]),
              ),
            ],
            SwitchListTile(
              title: Text(s.t('paid_reaction_anonymous')),
              value: anonymous,
              onChanged: (v) => setState(() => anonymous = v),
            ),
            if (me != null)
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('paid_reaction_save_visibility'))),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('paid_reaction_send', {'n': '$amount'}))),
          ]),
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  if (!picked) {
    await guard(context, () => account.send<td.Ok>(td.SetPaidMessageReactionType(chatId: message.chatId, messageId: message.id, type: typeNow())));
    return;
  }
  final added = await guard(context, () async {
    await account.send<td.Ok>(td.AddPendingPaidMessageReaction(chatId: message.chatId, messageId: message.id, starCount: amount, type: typeNow()));
    return true;
  });
  if (added != true || !context.mounted) return;
  // Telegram pays only after a few seconds so a mistaken tap can be taken back.
  final messenger = ScaffoldMessenger.of(context);
  var undone = false;
  final reason = await messenger
      .showSnackBar(SnackBar(
        content: Text(s.t('paid_reaction_sent', {'n': '$amount'})),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: s.t('undo'), onPressed: () => undone = true),
      ))
      .closed;
  try {
    if (undone || reason == SnackBarClosedReason.action) {
      await account.send<td.Ok>(td.RemovePendingPaidMessageReactions(chatId: message.chatId, messageId: message.id));
    } else {
      await account.send<td.Ok>(td.CommitPendingPaidMessageReactions(chatId: message.chatId, messageId: message.id));
    }
  } on TdException catch (error) {
    if (context.mounted) showError(context, error);
  }
}

/// Admin actions on one person's reaction: remove it, remove all their recent ones, or report it.
Future<void> moderateReaction(BuildContext context, TelegramAccount account, td.Message message, td.MessageSender sender, td.MessageProperties props) async {
  final s = context.s;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(account.senderName(sender), style: const TextStyle(fontWeight: FontWeight.w600))),
        if (props.canDeleteReactions) ...[
          ListTile(leading: const Icon(Icons.remove_circle_outline_rounded), title: Text(s.t('reaction_delete')), onTap: () => Navigator.pop(context, 'one')),
          ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: Text(s.t('reaction_delete_all_recent')), onTap: () => Navigator.pop(context, 'all')),
        ],
        if (props.canReportReactions)
          ListTile(leading: const Icon(Icons.flag_outlined), title: Text(s.t('report')), onTap: () => Navigator.pop(context, 'report')),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(switch (action) {
      'one' => td.DeleteMessageReactionsFromSender(chatId: message.chatId, messageId: message.id, senderId: sender),
      'all' => td.DeleteAllRecentMessageReactionsFromSender(chatId: message.chatId, senderId: sender),
      _ => td.ReportMessageReactions(chatId: message.chatId, messageId: message.id, senderId: sender),
    });
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t(action == 'report' ? 'report_sent' : 'done'));
}

/// Returned by [pickRecentDocument] when the user wants the system file picker instead.
const pickFromDevice = 'device';

/// Files the user sent recently anywhere, to resend without picking them again. Pops a [td.Document] or [pickFromDevice].
Future<Object?> pickRecentDocument(BuildContext context, TelegramAccount account) async {
  var recent = const <td.Message>[];
  try {
    recent = (await account.send<td.FoundMessages>(const td.SearchOutgoingDocumentMessages(query: '', limit: 20))).messages;
  } on TdException catch (error) {
    debugPrint('recent documents failed: $error');
  }
  final documents = [for (final m in recent) if (m.content case td.MessageDocument(:final document)) document];
  if (documents.isEmpty || !context.mounted) return pickFromDevice;
  final s = context.s;
  return showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: Text(s.t('choose_from_device'), style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, pickFromDevice),
          ),
          SectionHeader(s.t('recent_files')),
          for (final document in documents)
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(document.fileName.isEmpty ? s.t('file') : document.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(formatFileSize(document.document.size)),
              onTap: () => Navigator.pop(context, document),
            ),
        ]),
      ),
    ),
  );
}

/// Group members currently sharing their live location; tapping one jumps to that message.
Future<int?> pickLiveLocation(BuildContext context, TelegramAccount account, int chatId) async {
  final found = await guard(context, () => account.send<td.Messages>(td.SearchChatRecentLocationMessages(chatId: chatId, limit: 50)));
  if (found == null || !context.mounted) return null;
  final s = context.s;
  final messages = (found.messages ?? const <td.Message?>[]).whereType<td.Message>().toList();
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: messages.isEmpty
          ? Padding(padding: const EdgeInsets.all(24), child: Text(s.t('live_locations_empty'), textAlign: TextAlign.center))
          : ListView(shrinkWrap: true, children: [
              for (final message in messages)
                ListTile(
                  leading: const Icon(Icons.share_location_rounded),
                  title: Text(account.senderName(message.senderId)),
                  subtitle: Text(formatChatTime(message.date, s.locale)),
                  onTap: () => Navigator.pop(context, message.id),
                ),
            ]),
    ),
  );
}

/// Imports a chat exported from another messenger (e.g. WhatsApp "Export chat"): the .txt file plus its media.
Future<void> importChatHistory(BuildContext context, TelegramAccount account, int chatId) async {
  final s = context.s;
  final picked = await FilePicker.pickFiles();
  final paths = [for (final file in picked) ?file.path];
  if (paths.isEmpty || !context.mounted) return;
  final messageFile = paths.where((p) => p.toLowerCase().endsWith('.txt')).firstOrNull;
  if (messageFile == null) {
    showToast(context, s.t('import_need_txt'));
    return;
  }
  // TDLib recognises the export format from the first bytes of the file.
  final head = await File(messageFile).openRead(0, 1024).transform(const Utf8Decoder(allowMalformed: true)).join();
  if (!context.mounted) return;
  final type = await guard(context, () => account.send<td.MessageFileType>(td.GetMessageFileType(messageFileHead: head)));
  if (type == null || !context.mounted) return;
  if (type is td.MessageFileTypeUnknown) {
    showToast(context, s.t('import_unknown_format'));
    return;
  }
  final warning = await guard(context, () => account.send<td.Text>(td.GetMessageImportConfirmationText(chatId: chatId)));
  if (warning == null || !context.mounted) return;
  final source = switch (type) {
    td.MessageFileTypePrivate(:final name) => name,
    td.MessageFileTypeGroup(:final title) => title,
    _ => '',
  };
  final ok = await confirm(context, title: s.t('import_history'), message: [if (source.isNotEmpty) source, warning.text].join('\n\n'), confirmLabel: s.t('import'));
  if (!ok || !context.mounted) return;
  showToast(context, s.t('import_started'));
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.ImportMessages(
      chatId: chatId,
      messageFile: td.InputFileLocal(path: messageFile),
      attachedFiles: [for (final path in paths) if (path != messageFile) td.InputFileLocal(path: path)],
    ));
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('import_done'));
}

/// Lets the user trim a message down to the part they want to quote; TDLib finds where that part sits.
Future<td.InputTextQuote?> pickReplyQuote(BuildContext context, TelegramAccount account, td.Message message) async {
  final full = captionOf(message.content);
  if (full == null || full.text.isEmpty) return null;
  final s = context.s;
  final picked = await promptText(context, title: s.t('reply_quote'), label: s.t('reply_quote_hint'), initial: full.text);
  if (picked == null || picked.isEmpty || !context.mounted) return null;
  final found = await guard(
    context,
    () => account.send<td.FoundPosition>(td.SearchQuote(text: full, quote: plainText(picked), quotePosition: 0)),
  );
  if (found == null) return null;
  return td.InputTextQuote(text: plainText(picked), position: found.position);
}

/// A note that appears in this chat on this device only; it is never sent to anyone.
Future<void> addLocalNote(BuildContext context, TelegramAccount account, int chatId) async {
  final s = context.s;
  final text = await promptText(context, title: s.t('local_note'), label: s.t('local_note_hint'));
  if (text == null || text.isEmpty || !context.mounted) return;
  await guard(
    context,
    () => account.send<td.Message>(td.AddLocalMessage(
      chatId: chatId,
      senderId: td.MessageSenderUser(userId: account.myId),
      replyTo: null,
      disableNotification: true,
      inputMessageContent: td.InputMessageText(text: formattedText(text), linkPreviewOptions: null, clearDraft: false),
    )),
  );
}

/// Reports how long a channel post stayed on screen, which Telegram uses for post statistics.
/// The post counts as viewed from its first layout until it scrolls out of the list (capped at 5 minutes).
class ViewMetricsReporter extends StatefulWidget {
  const ViewMetricsReporter({super.key, required this.account, required this.message, required this.child});

  final TelegramAccount account;
  final td.Message message;
  final Widget child;

  @override
  State<ViewMetricsReporter> createState() => _ViewMetricsReporterState();
}

class _ViewMetricsReporterState extends State<ViewMetricsReporter> {
  static const _minViewMs = 300;
  static const _maxViewMs = 5 * 60 * 1000;

  final _shown = Stopwatch()..start();
  int _heightPerMille = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject() as RenderBox?;
      if (!mounted || box == null || !box.hasSize) return;
      final viewport = MediaQuery.sizeOf(context).height;
      if (viewport > 0) _heightPerMille = (box.size.height * 1000 / viewport).round().clamp(0, 1000);
    });
  }

  @override
  void dispose() {
    final elapsed = _shown.elapsedMilliseconds;
    if (elapsed >= _minViewMs) {
      final ms = elapsed > _maxViewMs ? _maxViewMs : elapsed;
      widget.account
          .send<td.Ok>(td.SendMessageViewMetrics(
            chatId: widget.message.chatId,
            messageId: widget.message.id,
            timeInViewMs: ms,
            activeTimeInViewMs: ms,
            heightToViewportRatioPerMille: _heightPerMille,
            seenRangeRatioPerMille: 1000,
          ))
          .ignore();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
