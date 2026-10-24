import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../admin/admin_panel_screen.dart';
import '../business/profile_sharing.dart';
import '../chat/media_viewers.dart';
import 'advanced_settings.dart';
import 'file_guard_screen.dart';
import 'folders_screen.dart';
import 'notifications_screen.dart';
import '../search/search_screen.dart';
import 'power_saving_screen.dart';
import 'premium_extras.dart';
import 'privacy_screen.dart';
import 'language_screen.dart';
import 'storage_usage_screen.dart';
import 'telegram_services_screens.dart';
import 'uzaro_settings_screen.dart';
import 'uzaro_tools.dart';
import 'wallpaper.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _push(BuildContext context, Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(leading: panelCloseButton(context), title: Text(context.t('settings'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          const _ProfileHeader(),
          _mainGroup(context, ref),
          _telegramGroup(context),
          _sadoGroup(context, ref),
          _helpGroup(context, ref),
          // Long-press on the version opens the (key-protected) admin panel.
          GestureDetector(
            onLongPress: () => openAdminPanel(context, ref),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${AppConfig.appName} ${AppConfig.appVersion} • TDLib ${switch (account.options['version']) {
                  td.OptionValueString(:final value) => value,
                  _ => '',
                }}',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, Color color, String title, {String? subtitle, Widget? screen, VoidCallback? onTap}) => ListTile(
    leading: TileIcon(icon, color),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    onTap: onTap ?? (screen == null ? null : () => _push(context, screen)),
  );

  Widget _mainGroup(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    return SettingsGroup(
      children: [
        _row(context, Icons.account_circle_rounded, const Color(0xFF2E9BF0), s.t('account'), subtitle: s.t('account_sub'), screen: const EditProfileScreen()),
        _row(context, Icons.chat_rounded, const Color(0xFFFF9F1A), s.t('chat_settings'), subtitle: s.t('chat_settings_sub'), screen: const AppearanceScreen()),
        _row(context, Icons.key_rounded, const Color(0xFF2EAD5B), s.t('privacy_security'), subtitle: s.t('privacy_sub'), screen: const PrivacyScreen()),
        _row(
          context,
          Icons.volume_up_rounded,
          const Color(0xFFE5486A),
          s.t('notifications'),
          subtitle: s.t('notifications_sub'),
          screen: const NotificationsScreen(),
        ),
        _row(context, Icons.pie_chart_rounded, const Color(0xFF4A6CF7), s.t('data_storage'), subtitle: s.t('data_storage_sub'), screen: const StorageScreen()),
        _row(context, Icons.folder_rounded, const Color(0xFF2E9BF0), s.t('chat_folders'), subtitle: s.t('chat_folders_sub'), screen: const FoldersScreen()),
        _row(context, Icons.laptop_rounded, const Color(0xFF0FA3B1), s.t('devices'), subtitle: s.t('devices_sub'), screen: const SessionsScreen()),
        _row(context, Icons.battery_saver_rounded, const Color(0xFFFF8A1F), s.t('power_saving'), subtitle: s.t('power_saving_sub'), screen: const PowerSavingScreen()),
        _row(
          context,
          Icons.language_rounded,
          const Color(0xFF7C4DFF),
          s.t('language'),
          subtitle: Strings.languageNames[settings.localeCode] ?? settings.localeCode,
          screen: const LanguageScreen(),
        ),
      ],
    );
  }

  /// Premium, Stars, Business and gifts, as in Telegram/aka.
  Widget _telegramGroup(BuildContext context) {
    final s = context.s;
    return SettingsGroup(
      children: [
        _row(context, Icons.star_rounded, const Color(0xFF8A72EA), 'Telegram Premium', screen: const PremiumInfoScreen()),
        _row(context, Icons.stars_rounded, const Color(0xFFF5A623), s.t('telegram_stars'), screen: const StarsScreen()),
        _row(context, Icons.storefront_rounded, const Color(0xFFE5486A), s.t('telegram_business'), screen: const BusinessInfoScreen()),
        _row(context, Icons.card_giftcard_rounded, const Color(0xFFFF8A1F), s.t('send_gift'), onTap: () => sendGiftFlow(context)),
        _row(context, Icons.redeem_rounded, const Color(0xFFE5486A), s.t('my_gifts'), screen: const MyGiftsScreen()),
      ],
    );
  }

  Widget _sadoGroup(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final account = ref.watch(accountProvider);
    return SettingsGroup(
      title: s.t('sado_features'),
      children: [
        // Same set and order as aka Messenger's own section.
        _row(context, Icons.settings_rounded, const Color(0xFF2E9BF0), s.t('uzaro_settings'), screen: const UzaroSettingsScreen()),
        _row(context, Icons.wifi_tethering_rounded, const Color(0xFF2EAD5B), s.t('online_contacts'), screen: const OnlineContactsScreen()),
        _row(context, Icons.cleaning_services_rounded, const Color(0xFF4A6CF7), s.t('cache_cleaner'), screen: const StorageUsageScreen()),
        _row(context, Icons.manage_accounts_rounded, const Color(0xFF2E9BF0), s.t('contact_changes'), screen: const ContactChangesScreen()),
        _row(context, Icons.badge_rounded, const Color(0xFFFF8A1F), s.t('id_finder'), screen: const IdFinderScreen()),
        _row(context, Icons.phone_in_talk_rounded, const Color(0xFFB04DDB), s.t('phone_finder'), screen: const SearchScreen()),
        _row(
          context,
          Icons.verified_user_rounded,
          const Color(0xFF2EAD5B),
          s.t('file_guard'),
          subtitle: s.t(settings.fileGuard.enabled ? 'file_guard_enabled' : 'auto_delete_off'),
          screen: const FileGuardScreen(),
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.badge_rounded, Color(0xFF3D8BFF)),
          title: Text(s.t('share_profile')),
          subtitle: Text(s.t('share_profile_hint')),
          value: ref.watch(profileSharingProvider) ?? false,
          onChanged: (value) => ref.read(profileSharingProvider.notifier).set(value),
        ),
        ValueListenableBuilder(
          valueListenable: account.archive.revision,
          builder: (context, _, _) {
            final archive = account.archive;
            if (archive.deletedCount == 0 && archive.editedCount == 0) return const SizedBox.shrink();
            return ListTile(
              leading: const TileIcon(Icons.delete_sweep_rounded, Color(0xFF8E8E93)),
              title: Text(s.t('archive_clear')),
              subtitle: Text(s.t('archive_count', {'n': '${archive.deletedCount}', 'count': '${archive.editedCount}'})),
              onTap: () async {
                final ok = await confirm(context, title: s.t('archive_clear'), message: s.t('archive_clear_confirm'), destructive: true);
                if (ok) archive.clear();
              },
            );
          },
        ),
        _row(
          context,
          Icons.translate_rounded,
          const Color(0xFF2E9BF0),
          s.t('translate_to'),
          subtitle: Strings.languageNames[settings.translateTo] ?? settings.translateTo,
          onTap: () async {
            final code = await _pickLanguage(context, settings.translateTo);
            if (code != null) notifier.setTranslateTo(code);
          },
        ),
        ListTile(
          leading: const TileIcon(Icons.favorite_rounded, Color(0xFFE5486A)),
          title: Text(s.t('quick_reaction')),
          trailing: Text(settings.quickReaction, style: const TextStyle(fontSize: 24)),
          onTap: () async {
            final emoji = await _pickQuickReaction(context);
            if (emoji == null || !context.mounted) return;
            notifier.setQuickReaction(emoji);
            // Keeps the double-tap reaction the same in official Telegram apps.
            await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetDefaultReactionType(reactionType: td.ReactionTypeEmoji(emoji: emoji))));
          },
        ),
      ],
    );
  }

  Widget _helpGroup(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final error = Theme.of(context).colorScheme.error;
    void open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return SettingsGroup(
      title: s.t('help'),
      children: [
        _row(context, Icons.chat_bubble_rounded, const Color(0xFFF5A623), s.t('ask_question'), onTap: () => askQuestion(context, ref)),
        _row(context, Icons.help_rounded, const Color(0xFF2E9BF0), s.t('telegram_faq'), onTap: () => open('https://telegram.org/faq')),
        // Telegram's own app opens the @TelegramTips channel here.
        _row(context, Icons.lightbulb_rounded, const Color(0xFF7C4DFF), s.t('telegram_features'), onTap: () => openUsername(context, ref, 'TelegramTips')),
        _row(context, Icons.policy_rounded, const Color(0xFF2EAD5B), s.t('privacy_policy'), onTap: () => open('https://telegram.org/privacy')),
        ListTile(
          leading: TileIcon(Icons.logout_rounded, error),
          title: Text(s.t('log_out'), style: TextStyle(color: error)),
          onTap: () async {
            final ok = await confirm(context, title: s.t('log_out'), message: s.t('log_out_confirm'), destructive: true);
            if (!ok || !context.mounted) return;
            // Root navigator: also closes the desktop settings panel.
            Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
            await guard(context, ref.read(accountProvider).logOut);
          },
        ),
      ],
    );
  }
}

Future<String?> _pickQuickReaction(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(context.t('quick_reaction')),
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final e in const ['👍', '❤', '🔥', '😁', '🙏', '👏', '🎉', '🤩', '😢', '👌', '💯', '🤝'])
            InkWell(
              onTap: () => Navigator.pop(context, e),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(e, style: const TextStyle(fontSize: 28)),
              ),
            ),
        ],
      ),
    ],
  ),
);

/// Picks an image from the gallery and makes it the profile photo.
Future<void> changeProfilePhoto(BuildContext context, WidgetRef ref) async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
  if (file == null || !context.mounted) return;
  await guard(
    context,
    () => ref
        .read(accountProvider)
        .send<td.ChatPhoto>(
          td.SetProfilePhoto(
            photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: file.path)),
            isPublic: false,
          ),
        ),
  );
}

/// Big centered avatar with a camera badge, name and "+phone • @username".
class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    if (me == null) return const SizedBox(height: 8);
    final theme = Theme.of(context);
    final username = me.usernames?.activeUsernames.firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
      child: Column(
        children: [
          Stack(
            children: [
              GestureDetector(
                onTap: me.profilePhoto == null ? null : () => openPhotoViewer(context, me.profilePhoto!.big, me.profilePhoto!.minithumbnail),
                child: UserAvatar(userId: me.id, size: 100, showOnline: false),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Material(
                  color: theme.colorScheme.primary,
                  shape: CircleBorder(side: BorderSide(color: groupedBackground(context), width: 3)),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => changeProfilePhoto(context, ref),
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: Icon(Icons.photo_camera_rounded, size: 18, color: theme.colorScheme.onPrimary, semanticLabel: context.t('set_photo')),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${me.firstName} ${me.lastName}'.trim(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            ['+${me.phoneNumber}', if (username != null) '@$username'].join('  •  '),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.hintColor, fontSize: 14.5),
          ),
        ],
      ),
    );
  }
}

const _translationLanguages = {
  'uz': "O'zbekcha",
  'ru': 'Русский',
  'en': 'English',
  'tr': 'Türkçe',
  'kk': 'Қазақша',
  'ky': 'Кыргызча',
  'tg': 'Тоҷикӣ',
  'ar': 'العربية',
  'de': 'Deutsch',
  'fr': 'Français',
  'es': 'Español',
  'zh': '中文',
  'ko': '한국어',
  'ja': '日本語',
};

Future<String?> _pickLanguage(BuildContext context, String current, {List<String>? only}) {
  final entries = _translationLanguages.entries.where((e) => only == null || only.contains(e.key));
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      children: [
        RadioGroup<String>(
          groupValue: current,
          onChanged: (value) => Navigator.pop(context, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final e in entries) RadioListTile<String>(value: e.key, title: Text(e.value))],
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------ profile

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  /// New number, then the code Telegram sends to it; on success updateUser brings the new number.
  Future<void> _changePhoneNumber(BuildContext context) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final number = await promptText(context, title: s.t('phone_change'), label: s.t('phone_new'), keyboard: TextInputType.phone);
    final digits = number?.replaceAll(RegExp(r'[^0-9+]'), '') ?? '';
    if (digits.length < 7 || !context.mounted) return;
    final sent = await guard(
      context,
      () => account.send<td.AuthenticationCodeInfo>(td.SendPhoneNumberCode(phoneNumber: digits, settings: null, type: const td.PhoneNumberCodeTypeChange())),
    );
    if (sent == null || !context.mounted) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!context.mounted) return;
      final code = await promptText(context, title: s.t('phone_change'), label: s.t('code_sent_sms', {'phone': digits}), keyboard: TextInputType.number);
      if (code == null || !context.mounted) return;
      if (code.isEmpty) {
        // An empty entry asks for the code again, when Telegram offers another way to send it.
        if (sent.nextType != null) await guard(context, () => account.send<td.AuthenticationCodeInfo>(const td.ResendPhoneNumberCode(reason: null)));
        continue;
      }
      final ok = await guard(context, () async {
        await account.send<td.Ok>(td.CheckPhoneNumberCode(code: code));
        return true;
      });
      if (ok == true) {
        if (context.mounted) showToast(context, s.t('phone_changed'));
        return;
      }
    }
  }

  late final td.User? _me = ref.read(meProvider);
  late final _first = TextEditingController(text: _me?.firstName ?? '');
  late final _last = TextEditingController(text: _me?.lastName ?? '');
  late final _username = TextEditingController(text: _me?.usernames?.editableUsername ?? '');
  final _bio = TextEditingController();
  td.Birthdate? _birthdate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = _me;
    if (me != null) {
      ref.read(accountProvider).send<td.UserFullInfo>(td.GetUserFullInfo(userId: me.id)).then((info) {
        if (!mounted) return;
        _bio.text = info.bio?.text ?? '';
        setState(() => _birthdate = info.birthdate);
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _username.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _changePhoto() => changeProfilePhoto(context, ref);

  Future<void> _save() async {
    final me = _me;
    if (me == null || _first.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final account = ref.read(accountProvider);
    final ok = await guard(context, () async {
      if (_first.text.trim() != me.firstName || _last.text.trim() != me.lastName) {
        await account.send<td.Ok>(td.SetName(firstName: _first.text.trim(), lastName: _last.text.trim()));
      }
      final username = _username.text.trim();
      if (username != (me.usernames?.editableUsername ?? '')) {
        await account.send<td.Ok>(td.SetUsername(username: username));
      }
      await account.send<td.Ok>(td.SetBio(bio: _bio.text.trim()));
      return true;
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok == true) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final me = ref.watch(meProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('edit_profile')),
        actions: [IconButton(icon: const Icon(Icons.check_rounded), onPressed: _saving ? null : _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (me != null)
            Center(
              child: GestureDetector(
                onTap: _changePhoto,
                child: Stack(
                  children: [
                    UserAvatar(userId: me.id, size: 100, showOnline: false),
                    const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 17, child: Icon(Icons.camera_alt_rounded, size: 18))),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _first,
            decoration: InputDecoration(labelText: s.t('first_name')),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _last,
            decoration: InputDecoration(labelText: s.t('last_name')),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _bio,
            maxLength: 70,
            decoration: InputDecoration(labelText: s.t('bio'), helperText: s.t('bio_hint')),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _username,
            decoration: InputDecoration(labelText: s.t('username'), prefixText: '@', helperText: s.t('username_hint')),
          ),
          const SizedBox(height: 10),
          if (me != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_rounded),
              title: Text('+${me.phoneNumber}'),
              subtitle: Text(s.t('phone_change_hint')),
              onTap: () => _changePhoneNumber(context),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cake_rounded),
            title: Text(s.t('birthday')),
            subtitle: Text(switch (_birthdate) {
              final b? => [b.day.toString().padLeft(2, '0'), b.month.toString().padLeft(2, '0'), if (b.year > 0) '${b.year}'].join('.'),
              null => s.t('birthday_add'),
            }),
            trailing: _birthdate == null
                ? null
                : IconButton(icon: const Icon(Icons.close_rounded), tooltip: s.t('delete'), onPressed: () => _setBirthdate(null)),
            onTap: () async {
              final now = DateTime.now();
              final b = _birthdate;
              final picked = await showDatePicker(
                context: context,
                firstDate: DateTime(now.year - 110),
                lastDate: now,
                initialDate: b == null ? DateTime(now.year - 20) : DateTime(b.year > 0 ? b.year : now.year - 20, b.month, b.day),
              );
              if (picked != null) await _setBirthdate(td.Birthdate(day: picked.day, month: picked.month, year: picked.year));
            },
          ),
        ],
      ),
    );
  }

  /// Saved right away, like Telegram; null removes the date.
  Future<void> _setBirthdate(td.Birthdate? value) async {
    final ok = await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetBirthdate(birthdate: value)));
    if (ok != null && mounted) setState(() => _birthdate = value);
  }
}

// ------------------------------------------------------------------ sessions

final _sessionsProvider = FutureProvider.autoDispose<td.Sessions>((ref) {
  return ref.watch(accountProvider).send<td.Sessions>(const td.GetActiveSessions());
});

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(_sessionsProvider);
    final account = ref.watch(accountProvider);
    final s = context.s;
    final error = Theme.of(context).colorScheme.error;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('devices'))),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (data) {
          final current = data.sessions.where((x) => x.isCurrent).toList();
          final others = data.sessions.where((x) => !x.isCurrent).toList();
          final ttlOptions = {for (final days in const [7, 30, 90, 183, 365]) days: _ttlLabel(days, s)};
          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              SettingsGroup(title: s.t('this_device'), children: [
                for (final session in current) _SessionTile(session: session),
                if (others.isNotEmpty)
                  ListTile(
                    leading: Icon(Icons.front_hand_rounded, color: error),
                    title: Text(s.t('terminate_others'), style: TextStyle(color: error)),
                    onTap: () async {
                      final ok = await confirm(context, title: s.t('terminate_others'), message: s.t('terminate_others_confirm'), destructive: true);
                      if (!ok || !context.mounted) return;
                      await guard(context, () => account.send<td.Ok>(const td.TerminateAllOtherSessions()));
                      ref.invalidate(_sessionsProvider);
                    },
                  ),
              ]),
              if (others.isNotEmpty) ...[
                GroupHint(s.t('terminate_others_hint')),
                SettingsGroup(title: s.t('active_sessions'), children: [
                  for (final session in others)
                    _SessionTile(
                      session: session,
                      onTerminate: () async {
                        await guard(context, () => account.send<td.Ok>(td.TerminateSession(sessionId: session.id)));
                        ref.invalidate(_sessionsProvider);
                      },
                    ),
                ]),
              ],
              SettingsGroup(title: s.t('session_ttl'), children: [
                ListTile(
                  title: Text(s.t('session_ttl_period')),
                  trailing: Text(
                    _ttlLabel(data.inactiveSessionTtlDays, s),
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15),
                  ),
                  onTap: () async {
                    final days = await showDialog<int>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: Text(s.t('session_ttl')),
                        children: [
                          RadioGroup<int>(
                            groupValue: data.inactiveSessionTtlDays,
                            onChanged: (value) => Navigator.pop(context, value),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [for (final e in ttlOptions.entries) RadioListTile<int>(value: e.key, title: Text(e.value))],
                            ),
                          ),
                        ],
                      ),
                    );
                    if (days == null || !context.mounted) return;
                    await guard(context, () => account.send<td.Ok>(td.SetInactiveSessionTtl(inactiveSessionTtlDays: days)));
                    ref.invalidate(_sessionsProvider);
                  },
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

String _ttlLabel(int days, Strings s) => days < 30 ? s.t('ttl_weeks', {'n': '${(days / 7).round()}'}) : s.t('ttl_months_short', {'n': '${(days / 30.5).round()}'});

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, this.onTerminate});

  final td.Session session;
  final VoidCallback? onTerminate;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final hint = Theme.of(context).hintColor;
    // Coloured platform badges like Telegram/aka: green Android, blue desktop, grey Apple, orange web.
    final platform = '${session.platform} ${session.applicationName}'.toLowerCase();
    final (IconData icon, Color color) = switch (platform) {
      _ when platform.contains('android') => (Icons.android_rounded, const Color(0xFF4CAF50)),
      _ when platform.contains('ios') || platform.contains('mac') || platform.contains('iphone') => (Icons.apple_rounded, const Color(0xFF8E8E93)),
      _ when platform.contains('web') || platform.contains('browser') => (Icons.language_rounded, const Color(0xFFFF8A1F)),
      _ when platform.contains('windows') || platform.contains('linux') || platform.contains('desktop') => (Icons.computer_rounded, const Color(0xFF2E9BF0)),
      _ => (Icons.devices_other_rounded, const Color(0xFF7C4DFF)),
    };
    final lastActive = session.isCurrent ? s.t('online') : formatChatTime(session.lastActiveDate, s.locale);
    return ListTile(
      leading: CircleAvatar(radius: 24, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 26)),
      title: Text(session.deviceModel, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text.rich(
        TextSpan(children: [
          TextSpan(text: '${session.applicationName} ${session.applicationVersion}\n'),
          TextSpan(text: '${session.location.isNotEmpty ? session.location : session.ipAddress} • $lastActive', style: TextStyle(color: hint)),
        ]),
      ),
      isThreeLine: true,
      trailing: onTerminate == null ? null : IconButton(icon: const Icon(Icons.logout_rounded), tooltip: s.t('terminate'), onPressed: onTerminate),
    );
  }
}

// ------------------------------------------------------------------ appearance

/// Two sample bubbles on the chat background, live with the text size and corner settings.
class _ChatPreview extends StatelessWidget {
  const _ChatPreview({required this.textScale, required this.radius});

  final double textScale;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.chatColors;
    final s = context.s;
    Widget bubble(String text, {required bool outgoing}) => Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 260),
            decoration: BoxDecoration(
              color: outgoing ? colors.outgoingBubble : colors.incomingBubble,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Text(text, style: TextStyle(fontSize: 15.5 * textScale, color: outgoing ? colors.outgoingText : colors.incomingText)),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: colors.chatBackground, borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        bubble(s.t('preview_incoming'), outgoing: false),
        bubble(s.t('preview_outgoing'), outgoing: true),
      ]),
    );
  }
}

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('chat_settings'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('text_size'), children: [
            Row(children: [
              const SizedBox(width: 16),
              Text('A', style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
              Expanded(
                child: Slider(value: settings.textScale, min: 0.85, max: 1.4, divisions: 11, onChanged: notifier.setTextScale),
              ),
              Text('${(settings.textScale * 16).round()}', style: TextStyle(color: primary, fontSize: 15)),
              const SizedBox(width: 16),
            ]),
            _ChatPreview(textScale: settings.textScale, radius: settings.bubbleRadius),
          ]),
          SettingsGroup(title: s.t('color_theme'), children: [
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                children: [
                  for (var i = 0; i < accentPalette.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: GestureDetector(
                        onTap: () => notifier.setAccent(i),
                        child: CircleAvatar(
                          radius: 22,
                          backgroundColor: accentPalette[i],
                          child: settings.accentIndex == i ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.wallpaper_rounded),
              title: Text(s.t('chat_background')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WallpaperScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_rounded),
              title: Text(s.t('night_mode')),
              trailing: Text(
                s.t(switch (settings.themeMode) {
                  ThemeMode.system => 'theme_system',
                  ThemeMode.light => 'theme_light',
                  ThemeMode.dark => 'theme_dark',
                }),
                style: TextStyle(color: primary, fontSize: 15),
              ),
              onTap: () async {
                final mode = await pickOption(
                  context,
                  s.t('night_mode'),
                  {ThemeMode.system: s.t('theme_system'), ThemeMode.light: s.t('theme_light'), ThemeMode.dark: s.t('theme_dark')},
                  settings.themeMode,
                );
                if (mode != null) notifier.setThemeMode(mode);
              },
            ),
          ]),
          SettingsGroup(title: s.t('bubble_radius'), children: [
            Slider(value: settings.bubbleRadius, min: 4, max: 24, divisions: 10, label: '${settings.bubbleRadius.round()}', onChanged: notifier.setBubbleRadius),
          ]),
          SettingsGroup(title: s.t('other_settings'), children: [
            SwitchListTile(title: Text(s.t('send_by_enter')), value: settings.sendByEnter, onChanged: notifier.setSendByEnter),
            SwitchListTile(title: Text(s.t('autoplay_gifs')), value: settings.autoplayGifs, onChanged: notifier.setAutoplayGifs),
            SwitchListTile(title: Text(s.t('chat_type_tabs')), subtitle: Text(s.t('chat_type_tabs_hint')), value: settings.chatTypeTabs, onChanged: notifier.setChatTypeTabs),
          ]),
        ],
      ),
    );
  }
}
