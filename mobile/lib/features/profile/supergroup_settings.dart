import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../chat/sticker_sets.dart' show pickInstalledStickerSet;
import '../settings/premium_extras.dart' show showEmojiStatusPicker;
import '../settings/privacy_screen.dart' show promptText;
import '../chat/location_picker.dart';
import '../settings/stars_extras.dart' show setGroupMessagePrice, setUnrestrictBoostCount;
import 'community_screen.dart';
import 'profile_more.dart';
import 'user_profile_extras.dart';

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
            tile('direct', 'channel_direct_messages', 'channel_direct_messages_hint', value('direct', group.hasDirectMessagesGroup),
                (on) => account.send<td.Ok>(td.SetChatDirectMessagesGroup(chatId: widget.chatId, isEnabled: on, paidMessageStarCount: 0))),
            if (value('direct', group.hasDirectMessagesGroup))
              ListTile(
                title: Text(s.t('channel_direct_messages_price')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final text = await promptText(context, title: s.t('channel_direct_messages_price'), label: '⭐', keyboard: TextInputType.number);
                  final stars = int.tryParse(text ?? '');
                  if (stars == null || !context.mounted) return;
                  await guard(context, () => account.send<td.Ok>(td.SetChatDirectMessagesGroup(chatId: widget.chatId, isEnabled: true, paidMessageStarCount: stars)));
                },
              ),
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
          if (group.usernames case final names? when canChangeInfo && names.activeUsernames.length + names.disabledUsernames.length > 1)
            ListTile(
              title: Text(s.t('usernames')),
              trailing: Text('${names.activeUsernames.length}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => UsernamesScreen(account: account, usernames: names, supergroupId: id)),
              ),
            ),
          if (full != null && full.canSetStickerSet && canChangeInfo) ...[
            _StickerSetTile(
              title: s.t('group_sticker_set'),
              setId: full.stickerSetId,
              onTap: () async {
                final picked = await pickInstalledStickerSet(context, const td.StickerTypeRegular());
                if (picked == null || !context.mounted) return;
                await guard(context, () => account.send<td.Ok>(td.SetSupergroupStickerSet(supergroupId: id, stickerSetId: picked)));
                await _loadFull();
              },
            ),
            _StickerSetTile(
              title: s.t('group_emoji_set'),
              setId: full.customEmojiStickerSetId,
              onTap: () async {
                final picked = await pickInstalledStickerSet(context, const td.StickerTypeCustomEmoji());
                if (picked == null || !context.mounted) return;
                await guard(context, () => account.send<td.Ok>(td.SetSupergroupCustomEmojiStickerSet(supergroupId: id, customEmojiStickerSetId: picked)));
                await _loadFull();
              },
            ),
          ],
          if (group.isChannel && canChangeInfo)
            tile('translate', 'auto_translation', 'auto_translation_hint', value('translate', group.hasAutomaticTranslation),
                (on) => account.send<td.Ok>(td.ToggleSupergroupHasAutomaticTranslation(supergroupId: id, hasAutomaticTranslation: on))),
          // Telegram reveals this flag to the owner only.
          if (group.isChannel && isOwner && full != null)
            tile('ads', 'channel_ads', 'channel_ads_hint', value('ads', full.canHaveSponsoredMessages),
                (on) => account.send<td.Ok>(td.ToggleSupergroupCanHaveSponsoredMessages(supergroupId: id, canHaveSponsoredMessages: on))),
          if (group.isChannel && canChangeInfo && full != null)
            ListTile(
              title: Text(s.t('main_profile_tab')),
              subtitle: Text(s.t(profileTabLabel(full.mainProfileTab) ?? 'auto')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _pickMainTab(full.mainProfileTab),
            ),
          if (full != null && (full.communityId != 0 || isOwner))
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text(s.t(full.communityId != 0 ? 'community' : 'community_create')),
              subtitle: Text(full.communityId != 0 ? (account.communities[full.communityId]?.name ?? '') : s.t('community_create_hint')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                if (full.communityId != 0) {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommunityScreen(communityId: full.communityId)));
                } else {
                  await createCommunityFor(context, account, widget.chatId, chat.title);
                }
                await _loadFull();
              },
            ),
          if (full != null && full.canSetLocation && group.hasLocation)
            ListTile(
              title: Text(s.t('group_location')),
              subtitle: Text(full.location?.address ?? s.t('none')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _setLocation,
            ),
          if (!group.isChannel && canRestrict && full != null)
            ListTile(
              title: Text(s.t('boost_unrestrict')),
              subtitle: Text(full.unrestrictBoostCount == 0 ? s.t('off') : '${full.unrestrictBoostCount}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                await setUnrestrictBoostCount(context, account, id, full.unrestrictBoostCount);
                await _loadFull();
              },
            ),
          if (!group.isChannel && full != null && full.canEnablePaidMessages)
            ListTile(
              title: Text(s.t('group_message_price')),
              subtitle: Text(group.paidMessageStarCount == 0 ? s.t('free') : '${group.paidMessageStarCount} ⭐'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => setGroupMessagePrice(context, account, widget.chatId, group.paidMessageStarCount),
            ),
          if (isOwner && !group.isChannel && !group.isBroadcastGroup)
            ListTile(
              title: Text(s.t('broadcast_group')),
              subtitle: Text(s.t('broadcast_group_hint')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('broadcast_group'), message: s.t('broadcast_group_confirm'), destructive: true);
                if (ok && context.mounted) await guard(context, () => account.send<td.Ok>(td.ToggleSupergroupIsBroadcastGroup(supergroupId: id)));
              },
            ),
          if (group.isChannel && canChangeInfo)
            ListTile(
              title: Text(s.t('channel_emoji_status')),
              subtitle: Text(s.t('channel_emoji_status_hint')),
              onTap: () => showEmojiStatusPicker(context, chatId: widget.chatId),
            ),
          if (full == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}

extension on _SupergroupSettingsScreenState {
  int? get _supergroupId {
    final account = ref.read(accountProvider);
    final chat = account.chats[widget.chatId];
    return chat == null ? null : account.supergroupOf(chat)?.id;
  }

  Future<void> _pickMainTab(td.ProfileTab? current) async {
    final s = context.s;
    final id = _supergroupId;
    if (id == null) return;
    final picked = await showModalBottomSheet<td.ProfileTab>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final (label, tab) in profileTabs)
            ListTile(
              title: Text(s.t(label)),
              trailing: current.runtimeType == tab.runtimeType ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, tab),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetSupergroupMainProfileTab(supergroupId: id, mainProfileTab: picked)));
    await _loadFull();
  }

  /// Location-based groups: move the group's point on the map and rename its address.
  Future<void> _setLocation() async {
    final choice = await Navigator.of(context).push<LocationChoice>(MaterialPageRoute(builder: (_) => LocationPickerScreen(chatId: widget.chatId)));
    if (!mounted) return;
    final (lat, lon, address) = switch (choice) {
      PointChoice(:final latitude, :final longitude) => (latitude, longitude, ''),
      VenueChoice(:final venue) => (venue.location.latitude, venue.location.longitude, venue.address),
      _ => (null, null, ''),
    };
    if (lat == null || lon == null) return;
    final s = context.s;
    final text = await promptText(context, title: s.t('group_location'), label: s.t('address'), initial: address);
    if (text == null || text.trim().isEmpty || !mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).send<td.Ok>(td.SetChatLocation(
            chatId: widget.chatId,
            location: td.ChatLocation(location: td.Location(latitude: lat, longitude: lon, horizontalAccuracy: 0), address: text.trim()),
          )),
    );
    await _loadFull();
  }
}

/// A group's sticker or emoji pack setting, showing the pack's short name (looked up by id).
class _StickerSetTile extends ConsumerWidget {
  const _StickerSetTile({required this.title, required this.setId, required this.onTap});

  final String title;
  final int setId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = setId == 0 ? null : ref.watch(_stickerSetNameProvider(setId)).value;
    return ListTile(
      title: Text(title),
      subtitle: Text(setId == 0 ? context.t('none') : (name ?? '…')),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

final _stickerSetNameProvider = FutureProvider.autoDispose.family<String?, int>((ref, setId) async {
  try {
    return (await ref.watch(accountProvider).send<td.Text>(td.GetStickerSetName(setId: setId))).text;
  } on TdException {
    return null;
  }
});
