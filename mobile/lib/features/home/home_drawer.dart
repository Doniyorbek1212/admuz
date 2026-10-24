import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_lock.dart';
import '../../core/config.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../admin/admin_panel_screen.dart';
import '../business/business_screen.dart';
import '../chat/marked_messages_screen.dart';
import '../calls/calls_screen.dart';
import '../contacts/contacts_screen.dart';
import '../settings/downloads_screen.dart';
import '../settings/settings_screen.dart';
import '../stories/stories.dart';
import 'ghost_mode_button.dart';
import 'home_screen.dart';

/// Side menu of the chat list: account card, quick destinations and Sado switches.
class HomeDrawer extends ConsumerStatefulWidget {
  const HomeDrawer({super.key});

  @override
  ConsumerState<HomeDrawer> createState() => _HomeDrawerState();
}

/// Hidden chats sit behind the passcode when one is set; true when the user may open them.
Future<bool> unlockHiddenChats(BuildContext context, WidgetRef ref) async {
  if (!ref.read(appLockProvider).enabled) return true;
  final s = context.s;
  final pin = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_enter')));
  if (pin == null || !context.mounted) return false;
  if (await ref.read(appLockProvider.notifier).verify(pin)) return true;
  if (context.mounted) showToast(context, s.t('passcode_wrong'));
  return false;
}

class _HomeDrawerState extends ConsumerState<HomeDrawer> {
  bool _showAccounts = false;

  void _push(Widget screen) {
    Navigator.of(context)
      ..pop()
      ..push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  void _openPanel(Widget screen) {
    // The drawer is closing; open from a context that outlives it.
    final navigator = Navigator.of(context)..pop();
    unawaited(openPanel(navigator.overlay!.context, screen));
  }

  Future<void> _openSaved() async {
    final account = ref.read(accountProvider);
    Navigator.pop(context);
    final chat = await guard(context, account.savedMessages);
    if (chat != null && mounted) openChat(context, chat.id);
  }

  Future<void> _openHidden() async {
    if (await unlockHiddenChats(context, ref) && mounted) _push(const HiddenChatsScreen());
  }

  void _addStory() {
    // The drawer is closing; run the flow on the navigator's (home) context.
    final home = Navigator.of(context).context;
    Navigator.pop(context);
    postStoryFlow(home, ref);
  }

  ListTile _row(IconData icon, Color color, String title, VoidCallback onTap) => ListTile(
        leading: TileIcon(icon, color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final s = context.s;
    final theme = Theme.of(context);
    return Drawer(
      backgroundColor: groupedBackground(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(24))),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _DrawerHeader(expanded: _showAccounts, onToggleAccounts: () => setState(() => _showAccounts = !_showAccounts)),
          if (_showAccounts) _accounts(context),
          const SizedBox(height: 6),
          SettingsGroup(children: [
            _row(Icons.group_add_rounded, const Color(0xFF2E9BF0), s.t('new_group'), () => _push(const ContactsScreen(createGroup: true))),
            _row(Icons.campaign_rounded, const Color(0xFFFF9F1A), s.t('new_channel'), () => _push(const NewChannelScreen())),
            _row(Icons.person_rounded, const Color(0xFF2EAD5B), s.t('contacts'), () => _push(const ContactsScreen())),
            _row(Icons.call_rounded, const Color(0xFF2EAD5B), s.t('calls'), () => _push(const CallsScreen())),
            _row(Icons.bookmark_rounded, const Color(0xFF3D8BFF), s.t('saved_messages'), _openSaved),
            _row(Icons.star_rounded, const Color(0xFFF5A623), s.t('marked_messages'), () => _push(const MarkedMessagesScreen())),
            _row(Icons.archive_rounded, const Color(0xFF8E8E93), s.t('archive'), () => _push(const ArchiveScreen())),
          ]),
          SettingsGroup(title: s.t('drawer_tools'), children: [
            SwitchListTile(
              secondary: _GhostTileIcon(active: settings.ghostMode),
              title: Text(s.t('ghost_mode'), style: const TextStyle(fontWeight: FontWeight.w500)),
              subtitle: Text(s.t('ghost_mode_short'), maxLines: 2),
              value: settings.ghostMode,
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setGhostMode(value);
                ref.read(accountProvider).setOnline(!value);
              },
            ),
            SwitchListTile(
              secondary: const TileIcon(Icons.dark_mode_rounded, Color(0xFF5A6B7F)),
              title: Text(s.t('night_mode'), style: const TextStyle(fontWeight: FontWeight.w500)),
              value: theme.brightness == Brightness.dark,
              onChanged: (dark) => ref.read(settingsProvider.notifier).setThemeMode(dark ? ThemeMode.dark : ThemeMode.light),
            ),
            if (settings.hiddenChatIds.isNotEmpty) _row(Icons.visibility_off_rounded, const Color(0xFF7C4DFF), s.t('hidden_chats'), _openHidden),
            _row(Icons.add_a_photo_rounded, const Color(0xFFFF5C8A), s.t('add_story'), _addStory),
            _row(Icons.download_rounded, const Color(0xFF13B88A), s.t('downloads'), () => _openPanel(const DownloadsScreen())),
          ]),
          SettingsGroup(children: [
            _row(Icons.work_rounded, const Color(0xFFFF7A59), s.t('hub_business'), () => _push(const BusinessScreen())),
            if (ref.watch(hasAdminKeyProvider).value ?? false)
              _row(Icons.admin_panel_settings_rounded, const Color(0xFF5A6B7F), s.t('admin_title'), () => _push(const AdminPanelScreen())),
            _row(Icons.settings_rounded, const Color(0xFF8E8E93), s.t('settings'), () => _openPanel(const SettingsScreen())),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
            child: Text(
              s.t('drawer_footer', {'version': AppConfig.appVersion}),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: theme.hintColor, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accounts(BuildContext context) {
    final slots = ref.watch(accountSlotsProvider);
    final s = context.s;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SettingsGroup(children: [
        for (final slot in slots.slots)
          ListTile(
            leading: CircleAvatar(child: Text(initialsOf(slots.labels[slot] ?? '$slot'))),
            title: Text(slots.labels[slot]?.isNotEmpty == true ? slots.labels[slot]! : '${s.t('account')} $slot'),
            trailing: slot == slots.active ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary) : null,
            onTap: () {
              Navigator.pop(context);
              ref.read(accountSlotsProvider.notifier).switchTo(slot);
            },
          ),
        if (slots.slots.length < AccountSlotsNotifier.maxAccounts)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
              child: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
            ),
            title: Text(s.t('add_account'), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w500)),
            onTap: () {
              Navigator.pop(context);
              ref.read(accountSlotsProvider.notifier).addAccount();
            },
          ),
      ]),
    );
  }
}

/// Gradient account card with avatar, theme toggle, name, phone and the account switcher.
class _DrawerHeader extends ConsumerWidget {
  const _DrawerHeader({required this.expanded, required this.onToggleAccounts});

  final bool expanded;
  final VoidCallback onToggleAccounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    final username = me?.usernames?.activeUsernames.firstOrNull;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(accent, Colors.white, 0.08)!, Color.lerp(accent, Colors.black, 0.38)!],
        ),
      ),
      padding: EdgeInsets.fromLTRB(18, MediaQuery.paddingOf(context).top + 16, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (me != null)
                Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  child: UserAvatar(userId: me.id, size: 64, showOnline: false),
                ),
              const Spacer(),
              Material(
                color: Colors.white.withValues(alpha: 0.18),
                shape: const CircleBorder(),
                child: IconButton(
                  icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: Colors.white),
                  tooltip: context.t('night_mode'),
                  onPressed: () => ref.read(settingsProvider.notifier).setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggleAccounts,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          me == null ? '' : '${me.firstName} ${me.lastName}'.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          me == null ? '' : ['+${me.phoneNumber}', if (username != null) '@$username'].join('  •  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more_rounded, color: Colors.white),
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

/// [TileIcon]-shaped badge with the ghost glyph; amber while ghost mode is on.
class _GhostTileIcon extends StatelessWidget {
  const _GhostTileIcon({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFFFFB020) : const Color(0xFF5A6B7F);
    return Container(
      width: 32,
      height: 32,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.12)!, color],
        ),
      ),
      child: CustomPaint(painter: GhostPainter(color: Colors.white, filled: active)),
    );
  }
}
