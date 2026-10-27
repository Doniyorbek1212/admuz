import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../chat/call_options.dart';
import '../chat/media_viewers.dart';
import '../chat/message_extras.dart';
import '../settings/premium_extras.dart';
import '../chat/message_content.dart';
import '../contacts/contacts_screen.dart';
import '../home/home_screen.dart';
import 'admin_screens.dart';
import '../stories/story_archive.dart';
import 'user_profile_extras.dart';

/// Extra info shown on profiles: bio/description, invite link, member list.
class _ProfileDetails {
  const _ProfileDetails({this.about = '', this.inviteLink, this.members = const [], this.birthdate, this.commonGroups = 0, this.note});

  final td.FormattedText? note;
  final String about;
  final String? inviteLink;
  final List<td.ChatMember> members;
  final td.Birthdate? birthdate;
  final int commonGroups;
}

final _detailsProvider = FutureProvider.autoDispose.family<_ProfileDetails, int>((ref, chatId) async {
  final account = ref.watch(accountProvider);
  final chat = await account.getChat(chatId);
  final user = account.privateUser(chat);
  if (user != null) {
    final info = await account.send<td.UserFullInfo>(td.GetUserFullInfo(userId: user.id));
    final about = info.bio?.text ?? info.botInfo?.description ?? '';
    return _ProfileDetails(about: about, birthdate: info.birthdate, commonGroups: info.groupInCommonCount, note: info.note);
  }
  final supergroup = account.supergroupOf(chat);
  if (supergroup != null) {
    final info = await account.send<td.SupergroupFullInfo>(td.GetSupergroupFullInfo(supergroupId: supergroup.id));
    var members = <td.ChatMember>[];
    if (info.canGetMembers && !supergroup.isChannel) {
      try {
        final result = await account.send<td.ChatMembers>(
          td.GetSupergroupMembers(supergroupId: supergroup.id, filter: const td.SupergroupMembersFilterRecent(), offset: 0, limit: 200),
        );
        members = result.members;
      } on TdException catch (error) {
        debugPrint('members failed: $error');
      }
    }
    return _ProfileDetails(about: info.description, inviteLink: info.inviteLink?.inviteLink, members: members);
  }
  final basic = account.basicGroupOf(chat);
  if (basic != null) {
    final info = await account.send<td.BasicGroupFullInfo>(td.GetBasicGroupFullInfo(basicGroupId: basic.id));
    return _ProfileDetails(about: info.description, inviteLink: info.inviteLink?.inviteLink, members: info.members);
  }
  return const _ProfileDetails();
});

class ChatInfoScreen extends ConsumerWidget {
  const ChatInfoScreen({super.key, required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    final account = ref.watch(accountProvider);
    final details = ref.watch(_detailsProvider(chatId));
    final s = context.s;
    final theme = Theme.of(context);
    if (chat == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final user = account.privateUser(chat);
    final username = account.usernameOf(chat);
    final muted = account.isMuted(chat);
    final canEdit = account.isAdmin(chat) && user == null;
    final info = details.value;

    final callable = user != null && !account.isBot(user) && !account.isSavedMessages(chat) && user.id != account.myId;
    final infoTiles = <Widget>[
      if (user != null && user.phoneNumber.isNotEmpty)
        _InfoTile(icon: Icons.phone_rounded, title: '+${user.phoneNumber}', subtitle: s.t('mobile'), copy: '+${user.phoneNumber}'),
      if (info != null && info.about.isNotEmpty)
        _InfoTile(icon: Icons.info_outline_rounded, title: info.about, subtitle: s.t(user != null ? 'bio' : 'description'), copy: info.about),
      if (username != null)
        _InfoTile(icon: Icons.alternate_email_rounded, title: '@$username', subtitle: s.t('username'), copy: 'https://t.me/$username', share: true),
      if (info?.birthdate case final birthdate?) _InfoTile(icon: Icons.cake_rounded, title: _birthdayText(birthdate, s), subtitle: s.t('birthday')),
      if (info?.inviteLink case final link?) _InfoTile(icon: Icons.link_rounded, title: link, subtitle: s.t('invite_link'), copy: link, share: true),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: theme.colorScheme.onSurface,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        actionsIconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditChatScreen(chatId: chatId))),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverList.list(
            children: [
              // aka-style header: centered avatar, name, status, then quick actions.
              Center(
                child: GestureDetector(
                  onTap: chat.photo == null
                      ? null
                      : user != null
                          ? () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => _ProfilePhotosScreen(userId: user.id)))
                          : () => openPhotoViewer(context, chat.photo!.big, chat.photo!.minithumbnail),
                  child: Hero(
                    tag: 'avatar_$chatId',
                    child: GoldRing(width: 2.5, child: ChatAvatar(chatId: chatId, size: 116, showOnline: false)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  chatTitle(chat, account, s),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                chatSubtitle(chat, account, s),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: theme.hintColor),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _ActionTile(icon: Icons.chat_bubble_rounded, label: s.t('message'), onTap: () => Navigator.pop(context)),
                    _ActionTile(
                      icon: muted ? Icons.notifications_off_rounded : Icons.notifications_rounded,
                      label: s.t(muted ? 'unmute_short' : 'mute_short'),
                      onTap: () => guard(context, () => account.setMuted(chat, muted ? 0 : muteForever)),
                    ),
                    if (callable) ...[
                      _ActionTile(icon: Icons.call_rounded, label: s.t('call'), onTap: () => showCallOptions(context, user)),
                      _ActionTile(icon: Icons.videocam_rounded, label: s.t('video'), onTap: () => startTelegramCall(context, user.id, video: true)),
                    ] else if (user == null && account.isMember(chat) && !account.isSavedMessages(chat))
                      _ActionTile(
                        icon: Icons.logout_rounded,
                        label: s.t('leave'),
                        color: theme.colorScheme.error,
                        onTap: () async {
                          final ok = await confirm(context, title: s.t('leave'), message: s.t('leave_confirm'), destructive: true);
                          if (!ok || !context.mounted) return;
                          await guard(context, () => account.deleteChat(chat));
                          if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                        },
                      ),
                  ],
                ),
              ),
              if (infoTiles.isNotEmpty) _ProfileCard(children: infoTiles),
              _ProfileCard(
                children: [
                  if (user == null && account.isAdmin(chat))
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_rounded),
                      title: Text(s.t('manage')),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ManageChatScreen(chatId: chatId))),
                    ),
                  if (user != null && user.id != account.myId) ...[
                    if (!account.isBot(user))
                      UserNoteTile(account: account, userId: user.id, note: info?.note, onChanged: () => ref.invalidate(_detailsProvider(chatId))),
                    if (user.isContact && info != null && info.birthdate == null && !account.isBot(user))
                      ListTile(leading: const Icon(Icons.cake_outlined), title: Text(s.t('birthday_suggest')), onTap: () => suggestBirthdate(context, account, user.id)),
                    if (user.isContact)
                      ListTile(
                        leading: const Icon(Icons.person_remove_rounded),
                        title: Text(s.t('delete_contact')),
                        onTap: () async {
                          final ok = await confirm(context, title: s.t('delete_contact'), message: chatTitle(chat, account, s), destructive: true);
                          if (ok && context.mounted) await guard(context, () => account.send<td.Ok>(td.RemoveContacts(userIds: [user.id])));
                        },
                      ),
                    if (!user.isContact)
                      ListTile(
                        leading: const Icon(Icons.person_add_rounded),
                        title: Text(s.t('add_contact')),
                        onTap: () => guard(
                          context,
                          () => account.send<td.Ok>(
                            td.AddContact(
                              userId: user.id,
                              contact: td.ImportedContact(phoneNumber: user.phoneNumber, firstName: user.firstName, lastName: user.lastName, note: null),
                              sharePhoneNumber: false,
                            ),
                          ),
                        ),
                      ),
                    if (chat.type is td.ChatTypePrivate && !account.isBot(user))
                      ListTile(
                        leading: const Icon(Icons.lock_rounded),
                        title: Text(s.t('start_secret_chat')),
                        onTap: () async {
                          final ok = await confirm(context, title: s.t('start_secret_chat'), message: s.t('secret_chat_confirm', {'name': user.firstName}));
                          if (!ok || !context.mounted) return;
                          final secret = await guard(context, () => account.createSecretChat(user.id));
                          if (secret == null || !context.mounted) return;
                          Navigator.of(context).popUntil((route) => route.isFirst);
                          openChat(context, secret.id);
                        },
                      ),
                    ListTile(
                      leading: Icon(Icons.block_rounded, color: theme.colorScheme.error),
                      title: Text(s.t(chat.blockList != null ? 'unblock' : 'block'), style: TextStyle(color: theme.colorScheme.error)),
                      onTap: () => guard(
                        context,
                        () => account.send<td.Ok>(
                          td.SetMessageSenderBlockList(
                            senderId: td.MessageSenderUser(userId: user.id),
                            blockList: chat.blockList != null ? null : const td.BlockListMain(),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if ((user != null && !account.isBot(user) && !account.isSavedMessages(chat)) || account.isChannel(chat))
                    ListTile(
                      leading: const Icon(Icons.motion_photos_on_outlined),
                      title: Text(s.t('stories')),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ChatStoriesScreen(chatId: chatId, canManage: user?.id == account.myId || (user == null && account.isAdmin(chat))),
                      )),
                    ),
                  if (info != null && info.commonGroups > 0 && user != null)
                    ListTile(
                      leading: const Icon(Icons.groups_rounded),
                      title: Text(s.t('groups_in_common')),
                      trailing: Text('${info.commonGroups}'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _CommonGroupsScreen(userId: user.id))),
                    ),
                  if (account.isChannel(chat) || account.supergroupOf(chat) != null)
                    ListTile(
                      leading: const Icon(Icons.bolt_rounded),
                      title: Text(s.t('boost')),
                      onTap: () => showBoostSheet(context, account, chatId),
                    ),
                  if (chat.canBeReported)
                    ListTile(
                      leading: Icon(Icons.flag_outlined, color: theme.colorScheme.error),
                      title: Text(s.t('report'), style: TextStyle(color: theme.colorScheme.error)),
                      onTap: () => reportChat(context, account, chatId),
                    ),
                  if (user == null && account.isMember(chat) && !account.isSavedMessages(chat))
                    ListTile(
                      leading: Icon(Icons.logout_rounded, color: theme.colorScheme.error),
                      title: Text(s.t(account.isChannel(chat) ? 'leave_channel' : 'leave_group'), style: TextStyle(color: theme.colorScheme.error)),
                      onTap: () async {
                        final ok = await confirm(context, title: s.t('leave'), message: s.t('leave_confirm'), destructive: true);
                        if (!ok || !context.mounted) return;
                        await guard(context, () => account.deleteChat(chat));
                        if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _SharedMediaSection(chatId: chatId),
              if (account.isChannel(chat)) _SimilarChannels(chatId: chatId),
              if (info != null && info.members.isNotEmpty) ...[
                const Divider(),
                Row(
                  children: [
                    Expanded(child: SectionHeader(s.count('members', account.memberCount(chat)))),
                    if (account.isAdmin(chat) || chat.permissions.canInviteUsers)
                      TextButton.icon(
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(s.t('add_members')),
                        onPressed: () async {
                          final ids = await Navigator.of(context).push<List<int>>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickMany: true)));
                          if (ids == null || ids.isEmpty || !context.mounted) return;
                          await guard(context, () => account.send<td.FailedToAddMembers>(td.AddChatMembers(chatId: chatId, userIds: ids)));
                          ref.invalidate(_detailsProvider(chatId));
                        },
                      ),
                  ],
                ),
                for (final member in info.members)
                  if (member.memberId case td.MessageSenderUser(:final userId))
                    _MemberTile(userId: userId, status: member.status, chat: chat, account: account, onChanged: () => ref.invalidate(_detailsProvider(chatId))),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ],
      ),
    );
  }
}

final _similarProvider = FutureProvider.autoDispose.family<List<td.Chat>, int>((ref, chatId) => ref.watch(accountProvider).similarChats(chatId));

/// Horizontal strip of channels Telegram recommends next to this one.
class _SimilarChannels extends ConsumerWidget {
  const _SimilarChannels({required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final similar = ref.watch(_similarProvider(chatId)).value ?? const [];
    if (similar.isEmpty) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        SectionHeader(s.t('similar_channels')),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: similar.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final chat = similar[index];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  unawaited(account.similarChatOpened(chatId, chat.id));
                  openChat(context, chat.id);
                },
                child: SizedBox(
                  width: 80,
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      ChatAvatar(chatId: chat.id, size: 56, showOnline: false),
                      const SizedBox(height: 6),
                      Text(chat.title, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Swipeable history of a user's profile photos; on your own profile each one can be deleted.
class _ProfilePhotosScreen extends ConsumerStatefulWidget {
  const _ProfilePhotosScreen({required this.userId});

  final int userId;

  @override
  ConsumerState<_ProfilePhotosScreen> createState() => _ProfilePhotosScreenState();
}

class _ProfilePhotosScreenState extends ConsumerState<_ProfilePhotosScreen> {
  List<td.ChatPhoto>? _photos;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(
      context,
      () => ref.read(accountProvider).send<td.ChatPhotos>(td.GetUserProfilePhotos(userId: widget.userId, offset: 0, limit: 100)),
    );
    if (mounted) setState(() => _photos = result?.photos ?? const []);
  }

  Future<void> _delete(td.ChatPhoto photo) async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('delete_photo'), destructive: true);
    if (!ok || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.DeleteProfilePhoto(profilePhotoId: photo.id)));
    _index = 0;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final photos = _photos;
    final mine = widget.userId == ref.watch(accountProvider).myId;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(photos == null || photos.isEmpty ? '' : '${_index + 1} / ${photos.length}'),
        actions: [
          if (mine && photos != null && photos.isNotEmpty)
            IconButton(tooltip: s.t('delete'), icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _delete(photos[_index])),
        ],
      ),
      body: photos == null
          ? const Center(child: CircularProgressIndicator())
          : photos.isEmpty
              ? Center(child: Text(s.t('nothing_here'), style: const TextStyle(color: Colors.white70)))
              : PageView.builder(
                  itemCount: photos.length,
                  onPageChanged: (index) => setState(() => _index = index),
                  itemBuilder: (context, index) {
                    final photo = photos[index];
                    final biggest = photo.sizes.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
                    return InteractiveViewer(
                      child: Center(child: TdImage(file: biggest.photo, minithumbnail: photo.minithumbnail, fit: BoxFit.contain)),
                    );
                  },
                ),
    );
  }
}

class _CommonGroupsScreen extends ConsumerWidget {
  const _CommonGroupsScreen({required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('groups_in_common'))),
      body: FutureBuilder<td.Chats>(
        future: account.send<td.Chats>(td.GetGroupsInCommon(userId: userId, offsetChatId: 0, limit: 100)),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text(s.t('err_GENERIC')));
          final ids = snapshot.data?.chatIds;
          if (ids == null) return const Center(child: CircularProgressIndicator());
          if (ids.isEmpty) return Center(child: Text(s.t('nothing_here')));
          return ListView(
            children: [
              for (final id in ids)
                ListTile(
                  leading: ChatAvatar(chatId: id, size: 44, showOnline: false),
                  title: Text(account.chats[id]?.title ?? ''),
                  onTap: () => openChat(context, id),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "14 fev 1992 (34 yosh)" like aka; without a year just the day and month.
String _birthdayText(td.Birthdate birthdate, Strings s) {
  final year = birthdate.year > 0 ? birthdate.year : 2000;
  final date = DateTime(year, birthdate.month, birthdate.day);
  if (birthdate.year <= 0) return DateFormat.MMMd(s.locale).format(date);
  final now = DateTime.now();
  final hadBirthday = now.month > date.month || (now.month == date.month && now.day >= date.day);
  final age = now.year - date.year - (hadBirthday ? 0 : 1);
  return '${DateFormat.yMMMd(s.locale).format(date)} (${s.t('years_old', {'n': '$age'})})';
}

/// Rounded quick-action tile under the profile name (Message, Mute, Call, Video).
class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: tint.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: tint.withValues(alpha: 0.18)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Column(
                children: [
                  Icon(icon, color: tint, size: 26),
                  const SizedBox(height: 6),
                  // Shrinks long labels ("Sukut qilish") instead of cutting them.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color ?? theme.colorScheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded card grouping profile rows, with the brand's gold hairline.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const SizedBox.shrink()
      : Container(
          margin: const EdgeInsets.fromLTRB(14, 16, 14, 0),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Theme.of(context).dividerColor),
            boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Column(children: children),
        );
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.title, required this.subtitle, this.copy, this.share = false});

  final IconData icon;
  final String title;
  final String subtitle;
  final String? copy;
  final bool share;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: SelectableText(title),
    subtitle: Text(subtitle),
    trailing: share
        ? IconButton(
            icon: const Icon(Icons.share_rounded),
            onPressed: () => SharePlus.instance.share(ShareParams(text: copy)),
          )
        : null,
    onLongPress: copy == null
        ? null
        : () {
            Clipboard.setData(ClipboardData(text: copy!));
            showToast(context, context.t('copied'));
          },
  );
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.userId, required this.status, required this.chat, required this.account, required this.onChanged});

  final int userId;
  final td.ChatMemberStatus status;
  final td.Chat chat;
  final TelegramAccount account;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider(userId));
    final s = context.s;
    if (user == null) return const SizedBox.shrink();
    final role = switch (status) {
      td.ChatMemberStatusCreator() => s.t('owner'),
      td.ChatMemberStatusAdministrator() => s.t('admin'),
      _ => null,
    };
    final canKick = account.isAdmin(chat) && userId != account.myId && status is! td.ChatMemberStatusCreator;
    return ListTile(
      leading: UserAvatar(userId: userId, size: 42),
      title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(formatUserStatus(user, s)),
      trailing: role != null ? Text(role, style: TextStyle(color: Theme.of(context).hintColor)) : null,
      onTap: userId == account.myId
          ? null
          : () async {
              final private = await guard(context, () => account.openPrivateChat(userId));
              if (private != null && context.mounted) openChat(context, private.id);
            },
      onLongPress: !canKick
          ? null
          : () async {
              final ok = await confirm(context, title: s.t('remove_member'), message: user.firstName, destructive: true);
              if (!ok || !context.mounted) return;
              await guard(
                context,
                () => account.send<td.Ok>(
                  td.BanChatMember(
                    chatId: chat.id,
                    memberId: td.MessageSenderUser(userId: userId),
                    bannedUntilDate: 0,
                    revokeMessages: false,
                  ),
                ),
              );
              onChanged();
            },
    );
  }
}

td.SearchMessagesFilter _mediaFilter(String tab) => switch (tab) {
      'files' => const td.SearchMessagesFilterDocument(),
      'links' => const td.SearchMessagesFilterUrl(),
      'voice' => const td.SearchMessagesFilterVoiceNote(),
      'music' => const td.SearchMessagesFilterAudio(),
      _ => const td.SearchMessagesFilterPhotoAndVideo(),
    };

/// Server count of a shared-media tab, shown on its chip.
final _sharedCountProvider = FutureProvider.autoDispose.family<int, (int, String)>((ref, key) async {
  final count = await ref.watch(accountProvider).send<td.Count>(
        td.GetChatMessageCount(chatId: key.$1, topicId: null, filter: _mediaFilter(key.$2), returnLocal: false),
      );
  return count.count;
});

final _sharedMediaProvider = FutureProvider.autoDispose.family<List<td.Message>, (int, String)>((ref, key) async {
  final account = ref.watch(accountProvider);
  final filter = _mediaFilter(key.$2);
  final result = await account.send<td.FoundChatMessages>(
    td.SearchChatMessages(chatId: key.$1, topicId: null, query: '', senderId: null, fromMessageId: 0, offset: 0, limit: 60, filter: filter),
  );
  return result.messages;
});

class _SharedMediaSection extends ConsumerStatefulWidget {
  const _SharedMediaSection({required this.chatId});

  final int chatId;

  @override
  ConsumerState<_SharedMediaSection> createState() => _SharedMediaSectionState();
}

class _SharedMediaSectionState extends ConsumerState<_SharedMediaSection> {
  String _tab = 'media';

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final messages = ref.watch(_sharedMediaProvider((widget.chatId, _tab)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final tab in const ['media', 'files', 'links', 'voice', 'music'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (ref.watch(_sharedCountProvider((widget.chatId, tab))).value) {
                      final n? when n > 0 => '${s.t('shared_$tab')} $n',
                      _ => s.t('shared_$tab'),
                    }),
                    selected: _tab == tab,
                    onSelected: (_) => setState(() => _tab = tab),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        messages.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(padding: const EdgeInsets.all(16), child: Text(errorText(context, error))),
          data: (list) {
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(s.t('nothing_here'), style: TextStyle(color: Theme.of(context).hintColor)),
                ),
              );
            }
            if (_tab == 'media') {
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: list.length,
                itemBuilder: (context, index) => _MediaCell(message: list[index]),
              );
            }
            return Column(
              children: [
                for (final message in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: _tab == 'links'
                        ? FormattedTextView(
                            text: (message.content is td.MessageText)
                                ? (message.content as td.MessageText).text
                                : (captionOf(message.content) ?? const td.FormattedText(text: '', entities: [])),
                          )
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: MessageMedia(message: message, maxWidth: 300),
                          ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MediaCell extends StatelessWidget {
  const _MediaCell({required this.message});

  final td.Message message;

  @override
  Widget build(BuildContext context) {
    final content = message.content;
    if (content is td.MessagePhoto) {
      final small = bestPhotoSize(content.photo, target: 320);
      final full = bestPhotoSize(content.photo, target: 2560);
      if (small == null || full == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: () => openPhotoViewer(context, full.photo, content.photo.minithumbnail),
        child: TdImage(file: small.photo, minithumbnail: content.photo.minithumbnail),
      );
    }
    if (content is td.MessageVideo) {
      final thumb = content.video.thumbnail;
      return GestureDetector(
        onTap: () => openVideoPlayer(context, content.video.video),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb != null && thumb.format is! td.ThumbnailFormatMpeg4)
              TdImage(file: thumb.file, minithumbnail: content.video.minithumbnail)
            else
              const ColoredBox(color: Colors.black26),
            const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 36)),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

// ------------------------------------------------------------------ edit group/channel

class EditChatScreen extends ConsumerStatefulWidget {
  const EditChatScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<EditChatScreen> createState() => _EditChatScreenState();
}

class _EditChatScreenState extends ConsumerState<EditChatScreen> {
  late final _title = TextEditingController(text: ref.read(accountProvider).chats[widget.chatId]?.title ?? '');
  final _description = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ref.read(_detailsProvider(widget.chatId).future).then((d) {
      if (mounted) _description.text = d.about;
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _changePhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
    if (file == null || !mounted) return;
    await guard(
      context,
      () => ref
          .read(accountProvider)
          .send<td.Ok>(
            td.SetChatPhoto(
              chatId: widget.chatId,
              photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: file.path)),
            ),
          ),
    );
  }

  Future<void> _save() async {
    final account = ref.read(accountProvider);
    final chat = account.chats[widget.chatId];
    if (chat == null) return;
    setState(() => _saving = true);
    final ok = await guard(context, () async {
      if (_title.text.trim() != chat.title) {
        await account.send<td.Ok>(td.SetChatTitle(chatId: chat.id, title: _title.text.trim()));
      }
      await account.send<td.Ok>(td.SetChatDescription(chatId: chat.id, description: _description.text.trim()));
      return true;
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok == true) {
      ref.invalidate(_detailsProvider(widget.chatId));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('edit')),
        actions: [IconButton(icon: const Icon(Icons.check_rounded), onPressed: _saving ? null : _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: _changePhoto,
              child: Stack(
                children: [
                  ChatAvatar(chatId: widget.chatId, size: 96, showOnline: false),
                  const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 16, child: Icon(Icons.camera_alt_rounded, size: 18))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _title,
            decoration: InputDecoration(labelText: s.t('title')),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _description,
            maxLines: 4,
            minLines: 2,
            decoration: InputDecoration(labelText: s.t('description')),
          ),
        ],
      ),
    );
  }
}
