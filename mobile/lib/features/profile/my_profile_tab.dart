import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/sado_api.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart' show brandGold, brandGradient;
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart' show EmojiStatusBadge;
import '../../widgets/emoji_pattern.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart' show apiGuard;
import '../chat/marked_messages_screen.dart';
import '../gifts/gift_showcase.dart' show giftShowcaseProvider;
import '../gifts/gift_widgets.dart';
import '../gifts/gifts_screen.dart';
import '../gifts/profile_background.dart';
import '../gifts/uzaro_badge.dart' show UzaroBadge;
import '../home/home_screen.dart';
import '../settings/downloads_screen.dart';
import '../settings/settings_screen.dart';
import '../stories/story_archive.dart';
import 'chat_info_screen.dart';
import 'uzaro_username.dart';

/// Bio and birthday of the signed-in user; refreshed after editing the profile.
final _myFullInfoProvider = FutureProvider.autoDispose<td.UserFullInfo?>((ref) async {
  final me = ref.watch(meProvider);
  if (me == null) return null;
  return ref.watch(accountProvider).send<td.UserFullInfo>(td.GetUserFullInfo(userId: me.id));
});

/// How many of the user's stories the profile shows inline; the rest are one tap away.
const _storiesShown = 30;

/// Every story the user has posted, newest first (the owner's archive holds the active ones too).
final _myStoriesProvider = FutureProvider.autoDispose<List<td.Story>>((ref) async {
  final account = ref.watch(accountProvider);
  final stories = await account.send<td.Stories>(td.GetChatArchivedStories(chatId: account.myId, fromStoryId: 0, limit: _storiesShown));
  return stories.stories;
});

/// Whether profile visitors see none of the user's UZARO gifts; null when gifts are off or the account is not linked.
final _giftsHiddenProvider = FutureProvider.autoDispose<bool?>((ref) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured || await api.telegramId() != ref.watch(accountProvider).myId) return null;
  return (await api.receivedGifts()).$2;
});

/// "Profile" tab of the bottom bar: the signed-in user's card, quick actions and personal spaces.
class MyProfileTab extends ConsumerWidget {
  const MyProfileTab({super.key});

  Future<void> _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    // No title bar: the header itself runs up under the status bar.
    return Scaffold(
      backgroundColor: groupedBackground(context),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : _StatusBarShield(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(_myStoriesProvider);
                  ref.invalidate(_myFullInfoProvider);
                  await ref.read(_myStoriesProvider.future).catchError((Object _) => const <td.Story>[]);
                },
                child: ListView(
                  // Clears the shell's floating bottom bar (reported as bottom padding).
                  padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 12),
                  children: [
                    _header(context, ref, me),
                    const SizedBox(height: 12),
                    _actions(context, ref),
                    _infoCard(context, ref, me),
                    _stories(context, ref),
                  ],
                ),
              ),
            ),
    );
  }

  /// Full-bleed header in the colors and pattern UZARO users see on this profile (the brand colors until one is picked).
  Widget _header(BuildContext context, WidgetRef ref, td.User me) {
    final theme = Theme.of(context);
    final style = ref.watch(userGiftsProvider(me.id)).value;
    final colors = style?.background;
    final pattern = style?.pattern;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        gradient: colors == null
            ? brandGradient(theme.colorScheme.primary, vertical: true)
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(colors.first), Color(colors.length > 1 ? colors[1] : colors.first)],
              ),
        border: Border(bottom: BorderSide(color: brandGold.withValues(alpha: 0.8), width: 1.5)),
      ),
      // passthrough: the column takes the full width, so the avatar and name sit in the middle of the screen.
      child: Stack(fit: StackFit.passthrough, children: [
        if (pattern != null) Positioned.fill(child: EmojiPattern(pattern: pattern, spots: headerPatternSpots)),
        Positioned(top: MediaQuery.paddingOf(context).top + 2, right: 4, child: _menu(context, ref, me)),
        Padding(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 18, 16, 14),
          child: Column(children: [
            GiftOrbit(
              telegramId: me.id,
              avatarSize: 104,
              child: GestureDetector(
                // All photos ever set (swipe, delete), not just the current one.
                onTap: me.profilePhoto == null
                    ? null
                    : () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => ProfilePhotosScreen(userId: me.id, chatId: me.id))),
                // The profile photo is the one avatar that keeps the brand's gold ring.
                child: GoldRing(width: 2.2, child: UserAvatar(userId: me.id, size: 104, showOnline: false)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '${me.firstName} ${me.lastName}'.trim(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: Colors.white),
                  ),
                ),
                // Same marks others see after the name: Premium emoji status, then the paid UZARO badge.
                EmojiStatusBadge(status: me.emojiStatus, size: 22),
                UzaroBadge(userId: me.id, size: 22),
              ],
            ),
            const SizedBox(height: 3),
            Text(formatUserStatus(me, context.s), style: const TextStyle(color: Colors.white70, fontSize: 14.5)),
            if (ref.watch(sadoApiProvider).configured)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: FilledButton.tonalIcon(
                  onPressed: () => showProfileBackgroundPicker(context, ref),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.palette_rounded, size: 18),
                  label: Text(context.t('gifts_background')),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _actions(BuildContext context, WidgetRef ref) {
    final s = context.s;
    Widget button(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Material(
              color: groupCardColor(context),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                  child: Column(
                    children: [
                      Icon(icon, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 6),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(
        children: [
          button(Icons.add_a_photo_rounded, s.t('set_photo'), () => changeProfilePhoto(context, ref)),
          button(Icons.edit_rounded, s.t('edit_info'), () async {
            await _push(context, const EditProfileScreen());
            ref.invalidate(_myFullInfoProvider);
          }),
          button(Icons.settings_rounded, s.t('settings'), () => _push(context, const SettingsScreen())),
        ],
      ),
    );
  }

  Widget _infoCard(BuildContext context, WidgetRef ref, td.User me) {
    final s = context.s;
    final info = ref.watch(_myFullInfoProvider).value;
    final bio = info?.bio?.text ?? '';
    final birthdate = info?.birthdate;
    final username = me.usernames?.activeUsernames.firstOrNull;
    final hint = Theme.of(context).hintColor;
    Widget row(IconData icon, String value, String label) => ListTile(
          visualDensity: const VisualDensity(vertical: -2),
          leading: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
          title: Text(value, style: const TextStyle(fontSize: 16, height: 1.25)),
          subtitle: Text(label, style: TextStyle(fontSize: 13, color: hint)),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: value));
            showToast(context, s.t('copied'));
          },
        );
    return SettingsGroup(children: [
      row(Icons.phone_outlined, '+${me.phoneNumber}', s.t('mobile')),
      if (bio.isNotEmpty) row(Icons.info_outline_rounded, bio, s.t('bio')),
      if (username != null) row(Icons.alternate_email_rounded, '@$username', s.t('username')),
      _uzaroNameRow(context, ref, hint),
      if (birthdate != null) row(Icons.cake_outlined, _formatBirthdate(birthdate, s), s.t('birthday')),
    ]);
  }

  /// The UZARO @name, next to the Telegram username; tap to choose or change it.
  Widget _uzaroNameRow(BuildContext context, WidgetRef ref, Color hint) {
    final s = context.s;
    final name = ref.watch(myUzaroNameProvider).value;
    return ListTile(
      visualDensity: const VisualDensity(vertical: -2),
      leading: Icon(Icons.verified_rounded, color: Theme.of(context).colorScheme.primary, size: 22),
      title: Text(name == null ? s.t('uzaro_username_none') : '@$name', style: const TextStyle(fontSize: 16, height: 1.25)),
      subtitle: Text(s.t('uzaro_username'), style: TextStyle(fontSize: 13, color: hint)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _push(context, UzaroUsernameScreen(current: name)),
      onLongPress: name == null
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: '@$name'));
              showToast(context, s.t('copied'));
            },
    );
  }

  /// The user's stories right on the profile; the row above opens archive, pinning and albums.
  Widget _stories(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final myId = ref.read(accountProvider).myId;
    final stories = ref.watch(_myStoriesProvider);
    return SettingsGroup(children: [
      ListTile(
        leading: const TileIcon(Icons.motion_photos_on_rounded, Color(0xFFE5486A)),
        title: Text(s.t('my_stories'), style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(s.t('see_all'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          const Icon(Icons.chevron_right_rounded),
        ]),
        onTap: () async {
          await _push(context, ChatStoriesScreen(chatId: myId, canManage: true));
          ref.invalidate(_myStoriesProvider);
        },
      ),
      switch (stories) {
        AsyncData(:final value) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: StoryGrid(chatId: myId, stories: value, embedded: true),
          ),
        AsyncError() => Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: TextButton(onPressed: () => ref.invalidate(_myStoriesProvider), child: Text(s.t('retry')))),
          ),
        _ => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      },
    ]);
  }

  /// ⋮ in the header's corner: the personal spaces and the UZARO gift switches.
  Widget _menu(BuildContext context, WidgetRef ref, td.User me) {
    final s = context.s;
    final giftsOn = ref.watch(sadoApiProvider).configured;
    final giftsHidden = ref.watch(_giftsHiddenProvider).value;
    PopupMenuItem<VoidCallback> item(IconData icon, Color color, String label, VoidCallback action) => PopupMenuItem(
          value: action,
          child: Row(children: [TileIcon(icon, color), const SizedBox(width: 14), Expanded(child: Text(label))]),
        );
    return PopupMenuButton<VoidCallback>(
      tooltip: s.t('more'),
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        item(Icons.bookmark_rounded, const Color(0xFF2E9BF0), s.t('saved_messages'), () async {
          final chat = await guard(context, ref.read(accountProvider).savedMessages);
          if (chat != null && context.mounted) openChat(context, chat.id);
        }),
        item(Icons.star_rounded, const Color(0xFFF5A623), s.t('marked_messages'), () => _push(context, const MarkedMessagesScreen())),
        item(Icons.archive_rounded, const Color(0xFF8E8E93), s.t('archive'), () => _push(context, const ArchiveScreen())),
        item(Icons.download_rounded, const Color(0xFF2EAD5B), s.t('downloads'), () => _push(context, const DownloadsScreen())),
        if (giftsOn && giftsHidden != null)
          item(
            giftsHidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            const Color(0xFF7E57C2),
            s.t(giftsHidden ? 'gifts_show_all' : 'gifts_hide_all'),
            () => _setGiftsHidden(context, ref, me.id, !giftsHidden),
          ),
        if (giftsOn)
          item(Icons.card_giftcard_rounded, brandGold, s.t('gifts_title'), () async {
            await _push(context, const GiftsScreen());
            ref.invalidate(_giftsHiddenProvider);
          }),
      ],
    );
  }

  Future<void> _setGiftsHidden(BuildContext context, WidgetRef ref, int myId, bool hide) async {
    final done = await apiGuard(context, () async {
      await ref.read(sadoApiProvider).setAllGiftsHidden(hide);
      return true;
    });
    if (done != true) return;
    ref
      ..invalidate(_giftsHiddenProvider)
      ..invalidate(userGiftsProvider(myId))
      ..invalidate(giftShowcaseProvider(myId));
    if (context.mounted) showToast(context, context.t(hide ? 'gifts_hidden_done' : 'gifts_shown_done'));
  }
}

/// Keeps the status bar readable without an AppBar: white icons over the header; once the header has scrolled
/// away, a strip in the page color slides in behind the icons, which switch to the theme's contrast.
class _StatusBarShield extends StatefulWidget {
  const _StatusBarShield({required this.child});

  final Widget child;

  @override
  State<_StatusBarShield> createState() => _StatusBarShieldState();
}

class _StatusBarShieldState extends State<_StatusBarShield> {
  /// Scroll offset at which the header's bottom edge has left the status bar (the header is about this tall).
  static const _headerScrolledAway = 220.0;
  bool _covered = false;

  bool _onScroll(ScrollNotification n) {
    final covered = n.depth == 0 && n.metrics.pixels > _headerScrolledAway;
    if (n.depth == 0 && covered != _covered) setState(() => _covered = covered);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    // Transparent: Android otherwise keeps its dark scrim over the header's top strip.
    final style = (_covered && light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light).copyWith(statusBarColor: Colors.transparent);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: style,
      child: Stack(children: [
        NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: MediaQuery.paddingOf(context).top,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _covered ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: ColoredBox(color: groupedBackground(context)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// "12.12.2000 (25 years old)", or "12.12" when the year is hidden.
String _formatBirthdate(td.Birthdate date, Strings s) {
  String two(int n) => n.toString().padLeft(2, '0');
  final dayMonth = '${two(date.day)}.${two(date.month)}';
  if (date.year == 0) return dayMonth;
  final now = DateTime.now();
  final hadBirthday = now.month > date.month || (now.month == date.month && now.day >= date.day);
  final age = now.year - date.year - (hadBirthday ? 0 : 1);
  return '$dayMonth.${date.year} (${s.t('years_old', {'n': '$age'})})';
}
