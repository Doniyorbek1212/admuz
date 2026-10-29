import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../profile/statistics_screen.dart' show StatGraphCard;
import '../settings/misc_extras.dart' show UsdHint;
import 'message_content.dart';
import 'message_tools.dart';

/// Receipt of a completed payment, opened from its "You paid …" service message.
Future<void> showPaymentReceipt(BuildContext context, TelegramAccount account, td.Message message) async {
  final receipt = await guard(context, () => account.send<td.PaymentReceipt>(td.GetPaymentReceipt(chatId: message.chatId, messageId: message.id)));
  if (receipt == null || !context.mounted) return;
  final s = context.s;
  final total = switch (receipt.type) {
    td.PaymentReceiptTypeStars(:final starCount) => '$starCount ⭐',
    td.PaymentReceiptTypeRegular(:final invoice, :final tipAmount) =>
      formatInvoiceAmount(invoice.priceParts.fold<int>(0, (sum, p) => sum + p.amount) + tipAmount, invoice.currency),
    _ => '',
  };
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(receipt.productInfo.title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: receipt.productInfo.description.text.isEmpty ? null : Text(receipt.productInfo.description.text),
        ),
        ListTile(
          dense: true,
          title: Text(s.t('receipt_total')),
          trailing: Text(total, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: switch (receipt.type) {
            td.PaymentReceiptTypeRegular(:final invoice, :final tipAmount) =>
              UsdHint(amount: invoice.priceParts.fold<int>(0, (sum, p) => sum + p.amount) + tipAmount, currency: invoice.currency),
            _ => null,
          },
        ),
        ListTile(dense: true, title: Text(s.t('receipt_seller')), trailing: Text(account.userName(receipt.sellerBotUserId))),
        ListTile(dense: true, title: Text(s.t('date')), trailing: Text(formatChatTime(receipt.date, s.locale))),
        if (receipt.type case td.PaymentReceiptTypeStars(:final transactionId))
          ListTile(dense: true, title: Text(s.t('receipt_transaction')), subtitle: SelectableText(transactionId)),
      ]),
    ),
  );
}

/// Who voted for each option of a public poll.
Future<void> showPollVoters(BuildContext context, TelegramAccount account, td.Message message, td.Poll poll) async {
  final results = await guard(
    context,
    () => Future.wait([
      for (var i = 0; i < poll.options.length; i++)
        poll.options[i].voterCount == 0
            ? Future.value(const td.PollVoters(totalCount: 0, voters: []))
            : account.send<td.PollVoters>(td.GetPollVoters(chatId: message.chatId, messageId: message.id, optionId: i, offset: 0, limit: 50)),
    ]),
  );
  if (results == null || !context.mounted) return;
  final s = context.s;
  // Votes over time; Telegram gives it to the poll's author and channel admins only.
  td.StatisticalGraph? graph;
  try {
    final dark = Theme.of(context).brightness == Brightness.dark;
    graph = (await account.send<td.PollVoteStatistics>(td.GetPollVoteStatistics(chatId: message.chatId, messageId: message.id, isDark: dark))).voteGraph;
  } on TdException catch (error) {
    debugPrint('poll vote statistics: $error');
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(shrinkWrap: true, children: [
          if (graph != null && graph is! td.StatisticalGraphError)
            StatGraphCard(chatId: message.chatId, title: s.t('poll_vote_graph'), graph: graph),
          for (var i = 0; i < poll.options.length; i++)
            if (results[i].voters.isNotEmpty) ...[
              SectionHeader('${poll.options[i].text.text} — ${s.count('votes', results[i].totalCount)}'),
              for (final voter in results[i].voters)
                ListTile(
                  dense: true,
                  leading: switch (voter.voterId) {
                    td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 34, showOnline: false),
                    td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 34, showOnline: false),
                    _ => const SizedBox.square(dimension: 34),
                  },
                  title: Text(account.senderName(voter.voterId)),
                  trailing: Text(formatChatTime(voter.date, s.locale), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                ),
            ],
        ]),
      ),
    ),
  );
}

/// Walks the server-driven report flow (reason → optional details) for a chat or some of its messages.
Future<void> reportChat(BuildContext context, TelegramAccount account, int chatId, {List<int> messageIds = const []}) async {
  final s = context.s;
  var optionId = '';
  var text = '';
  // The server asks at most a few nested questions; the cap guards against a loop.
  for (var step = 0; step < 6; step++) {
    final td.ReportChatResult result;
    try {
      result = await account.reportChat(chatId, messageIds: messageIds, optionId: optionId, text: text);
    } on TdException catch (error) {
      if (context.mounted) showError(context, error);
      return;
    }
    if (!context.mounted) return;
    switch (result) {
      case td.ReportChatResultOk():
        showToast(context, s.t('report_sent'));
        return;
      case td.ReportChatResultOptionRequired(:final title, :final options):
        final chosen = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(padding: const EdgeInsets.all(12), child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                  for (final option in options)
                    ListTile(title: Text(option.text), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.pop(context, option.id)),
                ],
              ),
            ),
          ),
        );
        if (chosen == null) return;
        optionId = chosen;
      case td.ReportChatResultTextRequired(optionId: final id, :final isOptional):
        if (!context.mounted) return;
        final details = await _askReportDetails(context, optional: isOptional ?? false);
        if (details == null) return;
        optionId = id;
        text = details;
      case td.ReportChatResultMessagesRequired():
        // Only reachable when reporting a whole chat; the user picks messages via selection mode instead.
        showToast(context, s.t('report_pick_messages'));
        return;
    }
  }
}

Future<String?> _askReportDetails(BuildContext context, {required bool optional}) {
  final s = context.s;
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('report_details')),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 1024,
        maxLines: 4,
        minLines: 2,
        decoration: InputDecoration(hintText: s.t(optional ? 'report_details_optional' : 'report_details_hint')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isEmpty && !optional) return;
            Navigator.pop(context, value);
          },
          child: Text(s.t('send')),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Who has seen an outgoing message: viewer list in groups, read time in private chats.
Future<void> showMessageSeen(BuildContext context, TelegramAccount account, td.Message message, td.MessageProperties props) async {
  final s = context.s;
  if (props.canGetViewers) {
    final viewers = await guard(context, () => account.messageViewers(message));
    if (viewers == null || !context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: viewers.isEmpty
            ? Padding(padding: const EdgeInsets.all(24), child: Text(s.t('seen_nobody')))
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(s.count('seen_by', viewers.length), style: Theme.of(context).textTheme.titleMedium),
                  ),
                  for (final viewer in viewers)
                    ListTile(
                      leading: UserAvatar(userId: viewer.userId, size: 40, showOnline: false),
                      title: Text(account.userName(viewer.userId)),
                      subtitle: Text(_when(viewer.viewDate, s)),
                    ),
                ],
              ),
      ),
    );
    return;
  }
  final date = await guard(context, () => account.messageReadDate(message));
  if (date == null || !context.mounted) return;
  showToast(context, switch (date) {
    td.MessageReadDateRead(:final readDate) => s.t('read_at', {'time': _when(readDate, s)}),
    td.MessageReadDateUnread() => s.t('read_not_yet'),
    td.MessageReadDateTooOld() => s.t('read_too_old'),
    td.MessageReadDateUserPrivacyRestricted() => s.t('read_hidden_by_user'),
    td.MessageReadDateMyPrivacyRestricted() => s.t('read_hidden_by_me'),
    _ => s.t('read_not_yet'),
  });
}

/// Who put which reaction on a message (groups only; channels keep reactions anonymous).
/// Admins can tap a row to remove or report that person's reaction.
Future<void> showAddedReactions(BuildContext context, TelegramAccount account, td.Message message, {td.MessageProperties? props}) async {
  final canModerate = (props?.canDeleteReactions ?? false) || (props?.canReportReactions ?? false);
  final s = context.s;
  final result = await guard(
    context,
    () => account.send<td.AddedReactions>(td.GetMessageAddedReactions(chatId: message.chatId, messageId: message.id, reactionType: null, offset: '', limit: 100)),
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
            child: Text(s.count('reactions_count', result.totalCount), style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final reaction in result.reactions)
            ListTile(
              leading: switch (reaction.senderId) {
                td.MessageSenderUser(:final userId) => UserAvatar(userId: userId, size: 40, showOnline: false),
                td.MessageSenderChat(:final chatId) => ChatAvatar(chatId: chatId, size: 40, showOnline: false),
                _ => const SizedBox.square(dimension: 40),
              },
              title: Text(account.senderName(reaction.senderId)),
              subtitle: Text(_when(reaction.date, s)),
              trailing: Text(switch (reaction.type) { td.ReactionTypeEmoji(:final emoji) => emoji, _ => '⭐' }, style: const TextStyle(fontSize: 22)),
              onTap: canModerate && props != null ? () => moderateReaction(context, account, message, reaction.senderId, props) : null,
            ),
        ],
      ),
    ),
  );
}

/// Admin tools for a member's message in a supergroup: report spam and/or wipe everything they sent.
Future<void> moderateSender(BuildContext context, TelegramAccount account, td.Message message) async {
  final s = context.s;
  final chat = account.chats[message.chatId];
  final supergroupId = switch (chat?.type) { td.ChatTypeSupergroup(:final supergroupId) => supergroupId, _ => 0 };
  if (supergroupId == 0) return;
  var report = true;
  var deleteAll = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(account.senderName(message.senderId)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(value: report, title: Text(s.t('report_spam')), onChanged: (v) => setState(() => report = v ?? false)),
            CheckboxListTile(value: deleteAll, title: Text(s.t('delete_all_from_user')), onChanged: (v) => setState(() => deleteAll = v ?? false)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(s.t('ok')),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await guard(context, () async {
    if (report) await account.send<td.Ok>(td.ReportSupergroupSpam(supergroupId: supergroupId, messageIds: [message.id]));
    if (deleteAll) await account.send<td.Ok>(td.DeleteChatMessagesBySender(chatId: message.chatId, senderId: message.senderId));
  });
}

String _when(int unix, Strings s) => '${formatDayHeader(unix, s)} ${formatTime(unix, s.locale)}';

/// A checklist message: title, tasks with tick boxes, and a done counter.
class ChecklistView extends ConsumerWidget {
  const ChecklistView({super.key, required this.message, required this.checklist});

  final td.Message message;
  final td.Checklist checklist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final theme = Theme.of(context);
    final done = checklist.tasks.where((t) => t.completionDate > 0).length;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(checklist.title.text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(
            s.t('checklist_progress', {'done': '$done', 'total': '${checklist.tasks.length}'}),
            style: TextStyle(fontSize: 12.5, color: theme.hintColor),
          ),
          const SizedBox(height: 6),
          for (final task in checklist.tasks)
            InkWell(
              onTap: checklist.canMarkTasksAsDone
                  ? () => guard(context, () => account.markChecklistTask(message, task.id, done: task.completionDate == 0))
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      task.completionDate > 0 ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: task.completionDate > 0 ? theme.colorScheme.primary : theme.hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.text.text,
                            style: task.completionDate > 0 ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.hintColor) : null,
                          ),
                          if (checklist.othersCanMarkTasksAsDone && task.completedBy != null)
                            Text(account.senderName(task.completedBy!), style: TextStyle(fontSize: 12, color: theme.hintColor)),
                        ],
                      ),
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
