import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/sado_api.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../chat/marked_messages_screen.dart';
import '../gifts/gift_widgets.dart';
import '../gifts/profile_background.dart';
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

/// "Profile" tab of the bottom bar: the signed-in user's card, quick actions and personal spaces.
class MyProfileTab extends ConsumerWidget {
  const MyProfileTab({super.key});

  Future<void> _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: BrandTabBar(title: context.t('tab_profile')),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              // Clears the shell's floating bottom bar (reported as bottom padding).
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 12),
              children: [
                _header(context, ref, me),
                _actions(context, ref),
                _infoCard(context, ref, me),
                _spaces(context, ref),
              ],
            ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, td.User me) {
    final theme = Theme.of(context);
    final online = isOnline(me);
    // The background UZARO users see on this profile, shown here as a card.
    final background = ref.watch(userGiftsProvider(me.id)).value?.background;
    final onHeader = background == null ? null : Colors.white;
    return Container(
      margin: background == null ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: background == null
          ? null
          : BoxDecoration(borderRadius: BorderRadius.circular(28), gradient: profileGradient(background, groupedBackground(context))),
      padding: EdgeInsets.fromLTRB(16, background == null ? 12 : 20, 16, background == null ? 8 : 10),
      child: Column(
        children: [
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
          Text(
            '${me.firstName} ${me.lastName}'.trim(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: onHeader),
          ),
          const SizedBox(height: 3),
          Text(
            formatUserStatus(me, context.s),
            style: TextStyle(
              color: background != null ? Colors.white70 : (online ? theme.colorScheme.primary : theme.hintColor),
              fontSize: 14.5,
            ),
          ),
          if (ref.watch(sadoApiProvider).configured)
            TextButton.icon(
              onPressed: () => showProfileBackgroundPicker(context, ref),
              style: TextButton.styleFrom(foregroundColor: onHeader),
              icon: const Icon(Icons.palette_rounded, size: 18),
              label: Text(context.t('gifts_background')),
            ),
        ],
      ),
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

  Widget _spaces(BuildContext context, WidgetRef ref) {
    final s = context.s;
    return SettingsGroup(children: [
      ListTile(
        leading: const TileIcon(Icons.bookmark_rounded, Color(0xFF2E9BF0)),
        title: Text(s.t('saved_messages')),
        onTap: () async {
          final chat = await guard(context, ref.read(accountProvider).savedMessages);
          if (chat != null && context.mounted) openChat(context, chat.id);
        },
      ),
      ListTile(
        leading: const TileIcon(Icons.motion_photos_on_rounded, Color(0xFFE5486A)),
        title: Text(s.t('my_stories')),
        onTap: () => _push(context, ChatStoriesScreen(chatId: ref.read(accountProvider).myId, canManage: true)),
      ),
      ListTile(
        leading: const TileIcon(Icons.star_rounded, Color(0xFFF5A623)),
        title: Text(s.t('marked_messages')),
        onTap: () => _push(context, const MarkedMessagesScreen()),
      ),
      ListTile(
        leading: const TileIcon(Icons.archive_rounded, Color(0xFF8E8E93)),
        title: Text(s.t('archive')),
        onTap: () => _push(context, const ArchiveScreen()),
      ),
      ListTile(
        leading: const TileIcon(Icons.download_rounded, Color(0xFF2EAD5B)),
        title: Text(s.t('downloads')),
        onTap: () => _push(context, const DownloadsScreen()),
      ),
    ]);
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
