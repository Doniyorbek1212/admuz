import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_lock.dart';
import '../../core/config.dart';
import '../../core/formatters.dart';
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
import 'privacy_screen.dart';
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
          _securityGroup(context),
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
        _row(
          context,
          Icons.language_rounded,
          const Color(0xFF7C4DFF),
          s.t('language'),
          subtitle: Strings.languageNames[settings.localeCode] ?? settings.localeCode,
          onTap: () async {
            final code = await _pickLanguage(context, settings.localeCode, only: Strings.supported);
            if (code != null) ref.read(settingsProvider.notifier).setLocale(code);
          },
        ),
      ],
    );
  }

  Widget _securityGroup(BuildContext context) {
    final s = context.s;
    return SettingsGroup(
      children: [
        _row(context, Icons.pin_rounded, const Color(0xFF0FA3B1), s.t('passcode_lock'), screen: const PasscodeSettingsScreen()),
        _row(context, Icons.shield_rounded, const Color(0xFF2EAD5B), s.t('two_step'), screen: const TwoStepScreen()),
        _row(context, Icons.vpn_lock_rounded, const Color(0xFF2E9BF0), s.t('proxy'), screen: const ProxyScreen()),
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
        _row(
          context,
          Icons.verified_user_rounded,
          const Color(0xFF2EAD5B),
          s.t('file_guard'),
          subtitle: s.t(settings.fileGuard.enabled ? 'file_guard_enabled' : 'auto_delete_off'),
          screen: const FileGuardScreen(),
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.visibility_off_rounded, Color(0xFF5A6B7F)),
          title: Text(s.t('ghost_mode')),
          subtitle: Text(s.t('ghost_mode_hint')),
          value: settings.ghostMode,
          onChanged: (value) {
            notifier.setGhostMode(value);
            account.setOnline(!value);
          },
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.badge_rounded, Color(0xFF3D8BFF)),
          title: Text(s.t('share_profile')),
          subtitle: Text(s.t('share_profile_hint')),
          value: ref.watch(profileSharingProvider) ?? false,
          onChanged: (value) => ref.read(profileSharingProvider.notifier).set(value),
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.auto_delete_rounded, Color(0xFFE5486A)),
          title: Text(s.t('keep_deleted')),
          subtitle: Text(s.t('keep_deleted_hint')),
          value: settings.keepDeleted,
          onChanged: notifier.setKeepDeleted,
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.history_rounded, Color(0xFFFF8A1F)),
          title: Text(s.t('keep_edits')),
          subtitle: Text(s.t('keep_edits_hint')),
          value: settings.keepEditHistory,
          onChanged: notifier.setKeepEditHistory,
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
            if (emoji != null) notifier.setQuickReaction(emoji);
          },
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.tab_rounded, Color(0xFF7C4DFF)),
          title: Text(s.t('chat_type_tabs')),
          subtitle: Text(s.t('chat_type_tabs_hint')),
          value: settings.chatTypeTabs,
          onChanged: notifier.setChatTypeTabs,
        ),
        SwitchListTile(
          secondary: const TileIcon(Icons.keyboard_return_rounded, Color(0xFF8E8E93)),
          title: Text(s.t('send_by_enter')),
          value: settings.sendByEnter,
          onChanged: notifier.setSendByEnter,
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
        _row(context, Icons.help_rounded, const Color(0xFF2E9BF0), s.t('telegram_faq'), onTap: () => open('https://telegram.org/faq')),
        _row(context, Icons.lightbulb_rounded, const Color(0xFF7C4DFF), s.t('telegram_features'), onTap: () => open('https://telegram.org/tour')),
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
  late final td.User? _me = ref.read(meProvider);
  late final _first = TextEditingController(text: _me?.firstName ?? '');
  late final _last = TextEditingController(text: _me?.lastName ?? '');
  late final _username = TextEditingController(text: _me?.usernames?.editableUsername ?? '');
  final _bio = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = _me;
    if (me != null) {
      ref.read(accountProvider).send<td.UserFullInfo>(td.GetUserFullInfo(userId: me.id)).then((info) {
        if (mounted) _bio.text = info.bio?.text ?? '';
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
        ],
      ),
    );
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
    return Scaffold(
      appBar: AppBar(title: Text(s.t('devices'))),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (data) {
          final current = data.sessions.where((x) => x.isCurrent).toList();
          final others = data.sessions.where((x) => !x.isCurrent).toList();
          return ListView(
            children: [
              SectionHeader(s.t('this_device')),
              for (final session in current) _SessionTile(session: session),
              if (others.isNotEmpty) ...[
                ListTile(
                  leading: Icon(Icons.front_hand_rounded, color: Theme.of(context).colorScheme.error),
                  title: Text(s.t('terminate_others'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () async {
                    final ok = await confirm(context, title: s.t('terminate_others'), message: s.t('terminate_others_confirm'), destructive: true);
                    if (!ok || !context.mounted) return;
                    await guard(context, () => account.send<td.Ok>(const td.TerminateAllOtherSessions()));
                    ref.invalidate(_sessionsProvider);
                  },
                ),
                SectionHeader(s.t('active_sessions')),
                for (final session in others)
                  _SessionTile(
                    session: session,
                    onTerminate: () async {
                      await guard(context, () => account.send<td.Ok>(td.TerminateSession(sessionId: session.id)));
                      ref.invalidate(_sessionsProvider);
                    },
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, this.onTerminate});

  final td.Session session;
  final VoidCallback? onTerminate;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return ListTile(
      leading: CircleAvatar(child: Icon(session.platform.toLowerCase().contains('ios') ? Icons.phone_iphone_rounded : Icons.devices_other_rounded)),
      title: Text('${session.applicationName} ${session.applicationVersion}'),
      subtitle: Text(
        '${session.deviceModel}, ${session.platform} ${session.systemVersion}\n${session.ipAddress} ${session.location} • ${formatChatTime(session.lastActiveDate, s.locale)}',
      ),
      isThreeLine: true,
      trailing: onTerminate == null ? null : IconButton(icon: const Icon(Icons.logout_rounded), tooltip: s.t('terminate'), onPressed: onTerminate),
    );
  }
}

// ------------------------------------------------------------------ appearance

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('appearance'))),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.wallpaper_rounded),
            title: Text(s.t('chat_background')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WallpaperScreen())),
          ),
          SectionHeader(s.t('theme')),
          RadioGroup<ThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (mode) => notifier.setThemeMode(mode ?? ThemeMode.system),
            child: Column(
              children: [
                RadioListTile(value: ThemeMode.system, title: Text(s.t('theme_system'))),
                RadioListTile(value: ThemeMode.light, title: Text(s.t('theme_light'))),
                RadioListTile(value: ThemeMode.dark, title: Text(s.t('theme_dark'))),
              ],
            ),
          ),
          SectionHeader(s.t('accent_color')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < accentPalette.length; i++)
                  GestureDetector(
                    onTap: () => notifier.setAccent(i),
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: accentPalette[i],
                      child: settings.accentIndex == i ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                    ),
                  ),
              ],
            ),
          ),
          SectionHeader(s.t('text_size')),
          Slider(
            value: settings.textScale,
            min: 0.85,
            max: 1.4,
            divisions: 11,
            label: '${(settings.textScale * 100).round()}%',
            onChanged: notifier.setTextScale,
          ),
          SectionHeader(s.t('bubble_radius')),
          Slider(value: settings.bubbleRadius, min: 4, max: 24, divisions: 10, label: '${settings.bubbleRadius.round()}', onChanged: notifier.setBubbleRadius),
        ],
      ),
    );
  }
}
