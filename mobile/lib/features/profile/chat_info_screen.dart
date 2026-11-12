import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import 'members_grid.dart';
import 'uzaro_username.dart';
import '../../state/telegram.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../chat/call_options.dart';
import '../chat/media_viewers.dart';
import '../chat/message_extras.dart';
import '../settings/premium_extras.dart';
import '../chat/message_content.dart';
import '../chat/sticker_extras.dart' show pickPhotoSource;
import '../contacts/contacts_screen.dart';
import '../home/home_screen.dart';
import 'admin_screens.dart';
import '../stories/story_archive.dart';
import '../webapp/bot_extras.dart' show BotProfileExtras;
import '../settings/misc_extras.dart' show showCollectibleInfo;
import '../settings/gifts_extras.dart' show OwnerGiftsScreen;
import '../settings/stars_extras.dart' show paidMessageRevenueProvider;
import '../../core/api/sado_api.dart';
import '../gifts/gift_widgets.dart';
import '../gifts/profile_background.dart';
import '../gifts/gift_showcase.dart' show giftRecipientOf;
import '../../widgets/emoji_pattern.dart';
import '../gifts/uzaro_badge.dart' show NameBadges;
import '../../state/settings.dart';
import '../settings/message_tone_picker.dart';
import 'profile_business.dart';
import 'profile_media.dart';
import 'profile_more.dart';
import 'user_profile_extras.dart';

/// Extra info shown on profiles: bio/description, invite link, member list.
class _ProfileDetails {
  const _ProfileDetails({this.about = '', this.inviteLink, this.members = const [], this.birthdate, this.commonGroups = 0, this.note, this.incomingPaidStars = 0, this.personalChatId = 0, this.userInfo});

  /// Full info of a private chat's user (bots need it for their extra rows).
  final td.UserFullInfo? userInfo;

  /// Channel the user shows on their profile; 0 if none.
  final int personalChatId;

  /// Stars this person pays the user per message (set by the user's own privacy settings).
  final int incomingPaidStars;

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
    return _ProfileDetails(about: about, birthdate: info.birthdate, commonGroups: info.groupInCommonCount, note: info.note, incomingPaidStars: info.incomingPaidMessageStarCount, personalChatId: info.personalChatId, userInfo: info);
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
        _InfoTile(icon: Icons.info_outline_rounded, title: info.about, subtitle: s.t(user != null ? 'bio' : 'description'), copy: info.about, links: true),
      if (username != null)
        _InfoTile(
          icon: Icons.alternate_email_rounded,
          title: '@$username',
          subtitle: s.t('username'),
          copy: 'https://t.me/$username',
          share: true,
          // Usernames bought on Fragment show their purchase details.
          onInfo: () => showCollectibleInfo(context, account, td.CollectibleItemTypeUsername(username: username), '@$username'),
        ),
      if (user != null && !account.isBot(user))
        if (ref.watch(uzaroNameOfProvider(user.id)).value case final uzaroName?)
          _InfoTile(icon: Icons.verified_rounded, title: '@$uzaroName', subtitle: s.t('uzaro_username'), copy: '@$uzaroName'),
      if (info?.birthdate case final birthdate?) _InfoTile(icon: Icons.cake_rounded, title: _birthdayText(birthdate, s), subtitle: s.t('birthday')),
      if (info?.inviteLink case final link?) _InfoTile(icon: Icons.link_rounded, title: link, subtitle: s.t('invite_link'), copy: link, share: true),
      if (info?.userInfo?.businessInfo case final business?) ...[
        if (business.openingHours?.openingHours.isNotEmpty ?? false) BusinessHoursTile(info: business),
        if (business.location case final place? when place.address.isNotEmpty) BusinessLocationTile(location: place),
      ],
    ];

    // UZARO extras of a person, group or channel: gifts around the avatar and the picked background (not bots, Saved Messages).
    final giftsFor = giftRecipientOf(account, chat);
    final canGift = giftsFor != null && ref.read(sadoApiProvider).configured;
    void sendGift() {
      if (giftsFor != null) sendUzaroGift(context, recipientId: giftsFor, name: chatTitle(chat, account, s));
    }
    final style = giftsFor == null ? null : ref.watch(userGiftsProvider(giftsFor)).value;
    final background = style?.background;
    final pattern = style?.pattern;
    final onHeader = background == null ? theme.colorScheme.onSurface : Colors.white;
    final headerTop = MediaQuery.paddingOf(context).top + kToolbarHeight;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: onHeader,
        iconTheme: IconThemeData(color: onHeader),
        actionsIconTheme: IconThemeData(color: onHeader),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditChatScreen(chatId: chatId))),
            ),
          if (!account.isSavedMessages(chat))
            IconButton(
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => SafeArea(child: SingleChildScrollView(child: _ProfileMenu(chatId: chatId))),
              ),
            ),
        ],
      ),
      body: Stack(children: [
      if (background != null)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: headerTop + 400,
          child: DecoratedBox(decoration: BoxDecoration(gradient: profileGradient(background, theme.scaffoldBackgroundColor))),
        ),
      // The picked sticker or emoji around the avatar (stays put while the page scrolls, like the background).
      if (pattern != null)
        Positioned(
          top: headerTop - 36,
          left: 0,
          right: 0,
          height: 116 + 120,
          child: EmojiPattern(pattern: pattern, spots: headerPatternSpots),
        ),
      CustomScrollView(
        slivers: [
          SliverList.list(
            children: [
              // The app bar floats over the body (so a background reaches the top edge).
              SizedBox(height: headerTop),
              // aka-style header: centered avatar, name, status, then quick actions.
              Center(
                child: _withGifts(
                  giftsFor,
                  GestureDetector(
                    onTap: chat.photo == null
                        ? null
                        : user != null
                            ? () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => ProfilePhotosScreen(userId: user.id, chatId: chatId)))
                            : () => openPhotoViewer(context, chat.photo!.big, chat.photo!.minithumbnail),
                    child: Hero(
                      tag: 'avatar_$chatId',
                      child: GoldRing(width: 2.5, child: ChatAvatar(chatId: chatId, size: 116, showOnline: false)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(
                    child: Text(
                      chatTitle(chat, account, s),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: onHeader),
                    ),
                  ),
                  NameBadges(chat: chat, size: 24),
                ]),
              ),
              const SizedBox(height: 4),
              Text(
                chatSubtitle(chat, account, s),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: background == null ? theme.hintColor : Colors.white70),
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
                    if (canGift && (callable || user == null))
                      _ActionTile(icon: Icons.card_giftcard_rounded, label: s.t('gift_short'), onTap: sendGift),
                    if (callable) ...[
                      _ActionTile(icon: Icons.videocam_rounded, label: s.t('video'), onTap: () => startTelegramCall(context, user.id, video: true)),
                      _ActionTile(icon: Icons.call_rounded, label: s.t('call'), onTap: () => showCallOptions(context, user)),
                    ] else if (user == null && account.isMember(chat) && !account.isSavedMessages(chat))
                      _ActionTile(
                        icon: Icons.logout_rounded,
                        label: s.t('leave'),
                        color: theme.colorScheme.error,
                        onTap: () async {
                          final ok = await confirmLeaveChat(context, account, chat);
                          if (!ok || !context.mounted) return;
                          await guard(context, () => account.deleteChat(chat));
                          if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                        },
                      ),
                  ],
                ),
              ),
              // Telegram order: the profile track, the personal channel, then the details.
              if (user != null && !account.isBot(user)) ProfileMusicChip(userId: user.id, color: background == null ? null : Colors.white),
              if (user != null && (info?.personalChatId ?? 0) != 0)
                _ProfileCard(children: [PersonalChannelCard(userId: user.id, channelChatId: info!.personalChatId)]),
              if (infoTiles.isNotEmpty) _ProfileCard(children: infoTiles),
              if (user != null && account.isBot(user) && !account.isSavedMessages(chat))
                _ProfileCard(children: [BotProfileExtras(bot: user, chatId: chatId, info: info?.userInfo)]),
              _ProfileCard(
                children: [
                  if (!account.isSavedMessages(chat)) _ChatToneTile(chatId: chatId),
                  if (user == null && account.isAdmin(chat))
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_rounded),
                      title: Text(s.t('manage')),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ManageChatScreen(chatId: chatId))),
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
                        final ok = await confirmLeaveChat(context, account, chat);
                        if (!ok || !context.mounted) return;
                        await guard(context, () => account.deleteChat(chat));
                        if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Members are the first tab of the media strip, so big groups don't bury them under the media grid.
              _SharedMediaSection(
                chatId: chatId,
                onStories: (user != null && !account.isBot(user) && !account.isSavedMessages(chat)) || account.isChannel(chat)
                    ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ChatStoriesScreen(chatId: chatId, canManage: user?.id == account.myId || (user == null && account.isAdmin(chat))),
                        ))
                    : null,
                membersLabel: s.count('members', account.memberCount(chat)),
                members: info == null || info.members.isEmpty
                    ? null
                    : Column(children: [
                Row(
                  children: [
                    const Spacer(),
                    IconButton(
                      tooltip: s.t(ref.watch(membersGridProvider) ? 'members_list' : 'members_grid'),
                      icon: Icon(ref.watch(membersGridProvider) ? Icons.view_list_rounded : Icons.grid_view_rounded),
                      onPressed: () => ref.read(membersGridProvider.notifier).toggle(),
                    ),
                    if (account.isAdmin(chat) || chat.permissions.canInviteUsers)
                      TextButton.icon(
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(s.t('add_members')),
                        onPressed: () async {
                          final ids = await Navigator.of(context).push<List<int>>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickMany: true)));
                          if (ids == null || ids.isEmpty || !context.mounted) return;
                          // AddChatMembers is for supergroups; basic groups take one user at a time and can show them recent history.
                          await guard(context, () async {
                            if (account.supergroupOf(chat) != null) return account.send<td.FailedToAddMembers>(td.AddChatMembers(chatId: chatId, userIds: ids));
                            for (final id in ids) {
                              await account.send<td.FailedToAddMembers>(td.AddChatMember(chatId: chatId, userId: id, forwardLimit: 100));
                            }
                            return null;
                          });
                          ref.invalidate(_detailsProvider(chatId));
                        },
                      ),
                  ],
                ),
                if (ref.watch(membersGridProvider))
                  MembersGrid(
                    members: [for (final m in info.members) if (m.memberId is td.MessageSenderUser) m],
                    cell: (member) => _MemberTile(
                      userId: (member.memberId as td.MessageSenderUser).userId,
                      status: member.status,
                      chat: chat,
                      account: account,
                      onChanged: () => ref.invalidate(_detailsProvider(chatId)),
                      grid: true,
                    ),
                  )
                else
                  for (final member in info.members)
                    if (member.memberId case td.MessageSenderUser(:final userId))
                      _MemberTile(userId: userId, status: member.status, chat: chat, account: account, onChanged: () => ref.invalidate(_detailsProvider(chatId))),
                    ]),
              ),
              if (account.isChannel(chat)) _SimilarChannels(chatId: chatId),
              const SizedBox(height: 32),
            ],
          ),
        ],
      ),
      ]),
    );
  }
}

final _similarCountProvider = FutureProvider.autoDispose.family<int, int>(
  (ref, chatId) async => (await ref.watch(accountProvider).send<td.Count>(td.GetChatSimilarChatCount(chatId: chatId, returnLocal: false))).count,
);

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
        SectionHeader(switch (ref.watch(_similarCountProvider(chatId)).value) {
          final n? when n > similar.length => '${s.t('similar_channels')} · $n',
          _ => s.t('similar_channels'),
        }),
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
class ProfilePhotosScreen extends ConsumerStatefulWidget {
  const ProfilePhotosScreen({super.key, required this.userId, required this.chatId});

  final int userId;

  /// Private chat with the user, needed to report a photo.
  final int chatId;

  @override
  ConsumerState<ProfilePhotosScreen> createState() => ProfilePhotosScreenState();
}

class ProfilePhotosScreenState extends ConsumerState<ProfilePhotosScreen> {
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
          if (!mine && photos != null && photos.isNotEmpty)
            IconButton(
              tooltip: s.t('report'),
              icon: const Icon(Icons.flag_outlined),
              onPressed: () {
                final photo = photos[_index];
                final biggest = photo.sizes.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
                reportChatPhoto(context, ref.read(accountProvider), widget.chatId, biggest.photo.id);
              },
            ),
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
/// A person's UZARO gifts float around their avatar (their premium video plays on open);
/// groups, bots and Saved Messages ([telegramId] null) get none.
Widget _withGifts(int? telegramId, Widget avatar) =>
    telegramId == null ? avatar : GiftOrbit(telegramId: telegramId, avatarSize: 116, playVideo: true, child: avatar);

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
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Theme.of(context).dividerColor),
            boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          // ListTile ink paints on the nearest Material; without this the card's colour hides it.
          child: Material(type: MaterialType.transparency, child: Column(children: children)),
        );
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.title, required this.subtitle, this.copy, this.share = false, this.onInfo, this.links = false});

  final VoidCallback? onInfo;

  /// Links and @mentions in the text open on tap, as in Telegram (bio, group description).
  final bool links;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? copy;
  final bool share;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: links ? FormattedTextView(text: linkified(title)) : SelectableText(title),
    subtitle: Text(subtitle),
    onTap: onInfo,
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
  const _MemberTile({required this.userId, required this.status, required this.chat, required this.account, required this.onChanged, this.grid = false});

  final int userId;
  final td.ChatMemberStatus status;
  final td.Chat chat;
  final TelegramAccount account;
  final VoidCallback onChanged;

  /// Avatar-and-name cell of the members grid instead of a list row.
  final bool grid;

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
    final onTap = userId == account.myId
        ? null
        : () async {
            final private = await guard(context, () => account.openPrivateChat(userId));
            if (private != null && context.mounted) openChat(context, private.id);
          };
    final onLongPress = !canKick ? null : () => _remove(context, user);
    if (grid) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            UserAvatar(userId: userId, size: 54),
            const SizedBox(height: 6),
            Text(user.firstName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      );
    }
    return ListTile(
      leading: UserAvatar(userId: userId, size: 42),
      title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(formatUserStatus(user, s)),
      trailing: role != null ? Text(role, style: TextStyle(color: Theme.of(context).hintColor)) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Future<void> _remove(BuildContext context, td.User user) async {
    final s = context.s;
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

/// Stories posted to a chat's page, shown under the profile's "stories" tab.
final _postedStoriesProvider = FutureProvider.autoDispose.family<td.Stories, int>((ref, chatId) {
  return ref.watch(accountProvider).send<td.Stories>(td.GetChatPostedToChatPageStories(chatId: chatId, fromStoryId: 0, limit: 100));
});

class _SharedMediaSection extends ConsumerStatefulWidget {
  const _SharedMediaSection({required this.chatId, this.onStories, this.members, this.membersLabel = ''});

  final int chatId;

  /// Opens the full stories screen (archive, albums); non-null adds a leading "stories" tab.
  final VoidCallback? onStories;

  /// The group's member list, shown under a leading "members" tab when present.
  final Widget? members;
  final String membersLabel;

  @override
  ConsumerState<_SharedMediaSection> createState() => _SharedMediaSectionState();
}

class _SharedMediaSectionState extends ConsumerState<_SharedMediaSection> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final members = widget.members;
    // Groups open on their members, like Telegram; everything else on media.
    final tab = _picked ?? (members != null ? 'members' : 'media');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (widget.onStories != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (ref.watch(_postedStoriesProvider(widget.chatId)).value?.totalCount) {
                      final n? when n > 0 => '${s.t('stories')} $n',
                      _ => s.t('stories'),
                    }),
                    selected: tab == 'stories',
                    onSelected: (_) => setState(() => _picked = 'stories'),
                  ),
                ),
              if (members != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(widget.membersLabel),
                    selected: tab == 'members',
                    onSelected: (_) => setState(() => _picked = 'members'),
                  ),
                ),
              for (final kind in const ['media', 'files', 'links', 'voice', 'music'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (ref.watch(_sharedCountProvider((widget.chatId, kind))).value) {
                      final n? when n > 0 => '${s.t('shared_$kind')} $n',
                      _ => s.t('shared_$kind'),
                    }),
                    selected: tab == kind,
                    onSelected: (_) => setState(() => _picked = kind),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (tab == 'members' && members != null)
          members
        else if (tab == 'stories')
          _stories(context)
        else
          _messages(context, tab),
      ],
    );
  }

  /// Posted stories in place, plus a link to the full screen for the archive and albums.
  Widget _stories(BuildContext context) {
    final s = context.s;
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(onPressed: widget.onStories, icon: const Icon(Icons.open_in_full_rounded, size: 18), label: Text(s.t('more'))),
      ),
      ref.watch(_postedStoriesProvider(widget.chatId)).when(
            loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            error: (error, _) => Padding(padding: const EdgeInsets.all(16), child: Text(errorText(context, error))),
            data: (stories) => StoryGrid(chatId: widget.chatId, stories: stories.stories, pinned: stories.pinnedStoryIds, embedded: true),
          ),
    ]);
  }

  Widget _messages(BuildContext context, String tab) {
    final s = context.s;
    return ref.watch(_sharedMediaProvider((widget.chatId, tab))).when(
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
            if (tab == 'media') {
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: list.length,
                itemBuilder: (context, index) => _MediaCell(message: list[index]),
              );
            }
            return Column(
              children: [
                for (final message in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: tab == 'links'
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
    // Gallery photo, or an emoji avatar (set inside pickPhotoSource).
    final path = await pickPhotoSource(context, ref.read(accountProvider), chatId: widget.chatId);
    if (path == null || !mounted) return;
    await guard(
      context,
      () => ref
          .read(accountProvider)
          .send<td.Ok>(
            td.SetChatPhoto(
              chatId: widget.chatId,
              photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: path)),
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

/// The profile's "⋮" menu: the rarer per-chat actions, kept out of the profile body.
/// Watches its own providers so labels (block/unblock, note) stay current while the sheet is open.
class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu({required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider(chatId));
    if (chat == null) return const SizedBox.shrink();
    final account = ref.watch(accountProvider);
    final info = ref.watch(_detailsProvider(chatId)).value;
    final user = account.privateUser(chat);
    final s = context.s;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (user != null && user.id != account.myId) ...[
          if (!account.isBot(user))
            UserNoteTile(account: account, userId: user.id, note: info?.note, onChanged: () => ref.invalidate(_detailsProvider(chatId))),
          if ((info?.incomingPaidStars ?? 0) > 0)
            ListTile(
              leading: const Icon(Icons.money_off_rounded),
              title: Text(s.t('allow_free_messages')),
              subtitle: Text(s.t('paid_messages_cost', {'n': '${info!.incomingPaidStars}'})),
              onTap: () async {
                if (await allowFreeMessages(context, account, user.id) && context.mounted) ref.invalidate(_detailsProvider(chatId));
              },
            ),
          if (!account.isBot(user)) ProfileAudiosTile(userId: user.id),
          if (!account.isBot(user))
            ListTile(
              leading: const Icon(Icons.redeem_outlined),
              title: Text(s.t('gifts_title')),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OwnerGiftsScreen(ownerId: td.MessageSenderUser(userId: user.id)))),
            ),
          if (ref.watch(paidMessageRevenueProvider(user.id)).value case final earned? when earned > 0)
            ListTile(leading: const Icon(Icons.star_rounded, color: Color(0xFFF5B830)), title: Text(s.t('paid_revenue_from', {'n': '$earned'}))),
          if (user.isContact && !account.isBot(user)) ...[
            ListTile(
              leading: const Icon(Icons.face_retouching_natural_outlined),
              title: Text(s.t('personal_photo_set')),
              subtitle: Text(s.t('personal_photo_hint')),
              onTap: () => setPersonalContactPhoto(context, account, user.id, remove: false),
              onLongPress: () => setPersonalContactPhoto(context, account, user.id, remove: true),
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: Text(s.t('photo_suggest')),
              onTap: () => suggestProfilePhoto(context, account, user.id),
            ),
          ],
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
              onTap: () => openSecretChatWith(context, account, user),
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
        if (chat.type case td.ChatTypeSecret(:final secretChatId))
          ListTile(
            leading: const Icon(Icons.key_rounded),
            title: Text(s.t('encryption_key')),
            onTap: () => showSecretChatKey(context, account, secretChatId),
          ),
        if (user == null && !account.isSavedMessages(chat)) TranslatableTile(chatId: chatId),
        if (!account.isSavedMessages(chat))
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: Text(s.t('local_name')),
            subtitle: Text(localChatName(chat) ?? s.t('local_name_off')),
            onTap: () => renameChatLocally(context, account, chat),
          ),
      ],
    );
  }
}

/// This chat's notification tone, or "Default (global tone)".
class _ChatToneTile extends ConsumerWidget {
  const _ChatToneTile({required this.chatId});

  final int chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    final own = settings.chatTones[chatId];
    final inherit = s.t('message_tone_inherit', {'tone': s.t('sound_${settings.messageTone}')});
    return ListTile(
      leading: const Icon(Icons.music_note_rounded),
      title: Text(s.t('message_tone')),
      subtitle: Text(own == null ? inherit : s.t('sound_$own')),
      onTap: () async {
        final tone = await pickMessageTone(context, current: own ?? '', inheritLabel: inherit);
        if (tone != null) ref.read(settingsProvider.notifier).setChatTone(chatId, tone.isEmpty ? null : tone);
      },
    );
  }
}
