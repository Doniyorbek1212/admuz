import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart';

/// Private note about a contact, visible only to the user.
class UserNoteTile extends StatelessWidget {
  const UserNoteTile({super.key, required this.account, required this.userId, required this.note, required this.onChanged});

  final TelegramAccount account;
  final int userId;
  final td.FormattedText? note;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final text = note?.text ?? '';
    return ListTile(
      leading: const Icon(Icons.sticky_note_2_outlined),
      title: Text(text.isEmpty ? s.t('user_note_add') : text),
      subtitle: text.isEmpty ? null : Text(s.t('user_note')),
      onTap: () async {
        final next = await promptText(context, title: s.t('user_note'), label: s.t('user_note_hint'), initial: text);
        if (next == null || !context.mounted) return;
        await guard(context, () => account.send<td.Ok>(td.SetUserNote(userId: userId, note: plainText(next.trim()))));
        onChanged();
      },
    );
  }
}

/// Several usernames (collectible ones included): switch each on/off and drag the active ones into order.
/// With [supergroupId] it edits a group/channel's usernames instead of the user's own.
class UsernamesScreen extends StatefulWidget {
  const UsernamesScreen({super.key, required this.account, required this.usernames, this.supergroupId});

  final TelegramAccount account;
  final td.Usernames usernames;
  final int? supergroupId;

  @override
  State<UsernamesScreen> createState() => _UsernamesScreenState();
}

class _UsernamesScreenState extends State<UsernamesScreen> {
  late List<String> _active = [...widget.usernames.activeUsernames];
  late List<String> _disabled = [...widget.usernames.disabledUsernames];

  Future<void> _toggle(String name, bool on) async {
    final group = widget.supergroupId;
    final ok = await guard(context, () async {
      await widget.account.send<td.Ok>(group == null
          ? td.ToggleUsernameIsActive(username: name, isActive: on)
          : td.ToggleSupergroupUsernameIsActive(supergroupId: group, username: name, isActive: on));
      return true;
    });
    if (ok != true || !mounted) return;
    setState(() {
      if (on) {
        _disabled = [..._disabled]..remove(name);
        _active = [..._active, name];
      } else {
        _active = [..._active]..remove(name);
        _disabled = [..._disabled, name];
      }
    });
  }

  Future<void> _reorder(int from, int to) async {
    setState(() => _active.insert(to, _active.removeAt(from)));
    final group = widget.supergroupId;
    await guard(
      context,
      () => widget.account.send<td.Ok>(group == null
          ? td.ReorderActiveUsernames(usernames: _active)
          : td.ReorderSupergroupActiveUsernames(supergroupId: group, usernames: _active)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final group = widget.supergroupId;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('usernames')),
        actions: [
          if (group != null && _active.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await confirm(context, title: s.t('usernames_disable_all'), destructive: true);
                if (!ok || !context.mounted) return;
                final done = await guard(context, () async {
                  await widget.account.send<td.Ok>(td.DisableAllSupergroupUsernames(supergroupId: group));
                  return true;
                });
                if (done == true && mounted) {
                  setState(() {
                    _disabled = [..._disabled, ..._active];
                    _active = [];
                  });
                }
              },
              child: Text(s.t('usernames_disable_all')),
            ),
        ],
      ),
      body: ListView(children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(s.t('usernames_hint'), style: TextStyle(color: Theme.of(context).hintColor))),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: _reorder,
          children: [
            for (final name in _active)
              SwitchListTile(key: ValueKey(name), title: Text('@$name'), value: true, onChanged: (on) => _toggle(name, on)),
          ],
        ),
        for (final name in _disabled) SwitchListTile(title: Text('@$name'), value: false, onChanged: (on) => _toggle(name, on)),
      ]),
    );
  }
}

/// Lets the user suggest a birthday to a contact who has not set one.
Future<void> suggestBirthdate(BuildContext context, TelegramAccount account, int userId) async {
  final now = DateTime.now();
  final day = await showDatePicker(context: context, firstDate: DateTime(1900), lastDate: now, initialDate: DateTime(now.year - 20));
  if (day == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.SuggestUserBirthdate(userId: userId, birthdate: td.Birthdate(day: day.day, month: day.month, year: day.year)));
    return true;
  });
  if (done == true && context.mounted) showToast(context, context.t('birthday_suggested'));
}

/// Owner hands the group or channel to another admin; Telegram asks for the 2-step password.
Future<bool> transferOwnership(BuildContext context, TelegramAccount account, int chatId, int userId) async {
  final s = context.s;
  final check = await guard(context, () => account.send<td.CanTransferOwnershipResult>(const td.CanTransferOwnership()));
  if (check == null || !context.mounted) return false;
  final problem = switch (check) {
    td.CanTransferOwnershipResultPasswordNeeded() => s.t('transfer_need_password'),
    td.CanTransferOwnershipResultPasswordTooFresh(:final retryAfter) => s.t('transfer_wait', {'n': '${(retryAfter / 3600).ceil()}'}),
    td.CanTransferOwnershipResultSessionTooFresh(:final retryAfter) => s.t('transfer_wait', {'n': '${(retryAfter / 3600).ceil()}'}),
    _ => null,
  };
  if (problem != null) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('transfer_ownership')),
        content: Text(problem),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
      ),
    );
    return false;
  }
  final ok = await confirm(context, title: s.t('transfer_ownership'), message: s.t('transfer_confirm', {'name': account.userName(userId)}), destructive: true);
  if (!ok || !context.mounted) return false;
  final password = await _askPassword(context);
  if (password == null || !context.mounted) return false;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.TransferChatOwnership(chatId: chatId, userId: userId, password: password));
    return true;
  });
  return done == true;
}

Future<String?> _askPassword(BuildContext context) {
  final controller = TextEditingController();
  final s = context.s;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('transfer_ownership')),
      content: TextField(controller: controller, obscureText: true, autofocus: true, decoration: InputDecoration(labelText: s.t('password'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(s.t('ok'))),
      ],
    ),
  ).whenComplete(controller.dispose);
}
