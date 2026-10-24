import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Group/channel switches stored on the supergroup: signatures, history, joining, anti-spam, forum mode.
class SupergroupSettingsScreen extends ConsumerStatefulWidget {
  const SupergroupSettingsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<SupergroupSettingsScreen> createState() => _SupergroupSettingsScreenState();
}

class _SupergroupSettingsScreenState extends ConsumerState<SupergroupSettingsScreen> {
  td.SupergroupFullInfo? _full;
  // Values just switched here, shown until TDLib's own update reaches the cached supergroup.
  final Map<String, bool> _pending = {};

  @override
  void initState() {
    super.initState();
    _loadFull();
  }

  Future<void> _loadFull() async {
    final account = ref.read(accountProvider);
    final chat = account.chats[widget.chatId];
    final group = chat == null ? null : account.supergroupOf(chat);
    if (group == null) return;
    final full = await guard(context, () => account.supergroupInfo(group.id));
    if (full != null && mounted) setState(() => _full = full);
  }

  Future<void> _toggle(String key, bool value, Future<void> Function() action) async {
    final ok = await guard(context, () async {
      await action();
      return true;
    });
    if (ok == true && mounted) setState(() => _pending[key] = value);
    if (ok == true && (key == 'history' || key == 'antispam' || key == 'hidden')) await _loadFull();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final chat = ref.watch(chatProvider(widget.chatId));
    final s = context.s;
    final group = chat == null ? null : account.supergroupOf(chat);
    if (chat == null || group == null) return Scaffold(appBar: AppBar(), body: Center(child: Text(s.t('nothing_here'))));
    final full = _full;
    final status = group.status;
    final isOwner = status is td.ChatMemberStatusCreator;
    final rights = status is td.ChatMemberStatusAdministrator ? status.rights : null;
    final canChangeInfo = isOwner || (rights?.canChangeInfo ?? false);
    final canRestrict = isOwner || (rights?.canRestrictMembers ?? false);
    bool value(String key, bool fallback) => _pending[key] ?? fallback;
    final sign = value('sign', group.signMessages);
    final id = group.id;

    Widget tile(String key, String title, String? hint, bool current, Future<void> Function(bool) set) => SwitchListTile(
          title: Text(s.t(title)),
          subtitle: hint == null ? null : Text(s.t(hint)),
          value: current,
          onChanged: (on) => _toggle(key, on, () => set(on)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(s.t('group_settings'))),
      body: ListView(
        children: [
          if (group.isChannel && canChangeInfo) ...[
            tile('sign', 'sign_messages', 'sign_messages_hint', sign, (on) => account.setSignMessages(id, sign: on, showProfile: on && value('profile', group.showMessageSender))),
            if (sign)
              tile('profile', 'show_author_profile', 'show_author_profile_hint', value('profile', group.showMessageSender),
                  (on) => account.setSignMessages(id, sign: true, showProfile: on)),
          ],
          if (!group.isChannel) ...[
            if (canChangeInfo && full != null)
              tile('history', 'history_for_new_members', 'history_for_new_members_hint', value('history', full.isAllHistoryAvailable),
                  (on) => account.send<td.Ok>(td.ToggleSupergroupIsAllHistoryAvailable(supergroupId: id, isAllHistoryAvailable: on))),
            if (canRestrict && group.hasLinkedChat)
              tile('join_send', 'join_to_send', 'join_to_send_hint', value('join_send', group.joinToSendMessages),
                  (on) => account.send<td.Ok>(td.ToggleSupergroupJoinToSendMessages(supergroupId: id, joinToSendMessages: on))),
            if (canRestrict && full != null && full.canToggleAggressiveAntiSpam)
              tile('antispam', 'aggressive_antispam', 'aggressive_antispam_hint', value('antispam', full.hasAggressiveAntiSpamEnabled),
                  (on) => account.send<td.Ok>(td.ToggleSupergroupHasAggressiveAntiSpamEnabled(supergroupId: id, hasAggressiveAntiSpamEnabled: on))),
            if (full != null && full.canHideMembers)
              tile('hidden', 'hide_members', 'hide_members_hint', value('hidden', full.hasHiddenMembers),
                  (on) => account.send<td.Ok>(td.ToggleSupergroupHasHiddenMembers(supergroupId: id, hasHiddenMembers: on))),
            if (isOwner && !group.hasLinkedChat)
              tile('forum', 'topics_mode', 'topics_mode_hint', value('forum', group.isForum),
                  (on) => account.send<td.Ok>(td.ToggleSupergroupIsForum(supergroupId: id, isForum: on, hasForumTabs: false))),
          ],
          // Telegram offers join approval only where people can join without an invite link.
          if (canRestrict && !group.isChannel && (group.hasLinkedChat || (group.usernames?.activeUsernames.isNotEmpty ?? false)))
            tile('join_request', 'approve_new_members', 'approve_new_members_hint', value('join_request', group.joinByRequest),
                (on) => account.send<td.Ok>(td.ToggleSupergroupJoinByRequest(supergroupId: id, joinByRequest: on, guardBotUserId: 0, applyToInviteLinks: false))),
          if (full == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}
