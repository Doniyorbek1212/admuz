import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../home/home_drawer.dart';
import '../home/home_screen.dart';

/// Font families every Android phone ships (fonts.xml), so no font files are bundled.
const _fonts = ['', 'sans-serif-light', 'sans-serif-medium', 'sans-serif-condensed', 'serif', 'monospace', 'casual', 'cursive'];

String _fontLabel(String family, Strings s) => s.t('font_${family.isEmpty ? 'default' : family.replaceAll('-', '_')}');

Future<String?> _pickFont(BuildContext context, String current) => showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.t('font')),
        children: [
          RadioGroup<String>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final family in _fonts)
                  RadioListTile<String>(
                    value: family,
                    title: Text(_fontLabel(family, context.s), style: TextStyle(fontFamily: family.isEmpty ? null : family, fontSize: 17)),
                    subtitle: Text('Salom! Привет! 123', style: TextStyle(fontFamily: family.isEmpty ? null : family)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

/// UZARO's own options (aka Messenger's "aka sozlamalari"): hidden chats, send confirmations,
/// deleted/edited message copies, ghost button, avatar behaviour and a reset.
class UzaroSettingsScreen extends ConsumerWidget {
  const UzaroSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final account = ref.watch(accountProvider);
    Widget toggle(String key, bool value, ValueChanged<bool> onChanged, {String? hint}) => SwitchListTile(
          title: Text(s.t(key)),
          subtitle: hint == null ? null : Text(s.t(hint)),
          value: value,
          onChanged: onChanged,
        );
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('uzaro_settings'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('privacy'), children: [
            ListTile(
              title: Text(s.t('hidden_chats')),
              subtitle: Text(s.t('hidden_chats_count', {'n': '${settings.hiddenChatIds.length}'})),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                if (!await unlockHiddenChats(context, ref) || !context.mounted) return;
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HiddenChatsScreen()));
              },
            ),
            toggle('ghost_mode', settings.ghostMode, (value) {
              notifier.setGhostMode(value);
              account.setOnline(!value);
            }, hint: 'ghost_mode_hint'),
          ]),
          SettingsGroup(title: s.t('confirmations'), children: [
            toggle('confirm_sticker', settings.confirmSticker, notifier.setConfirmSticker),
            toggle('confirm_voice', settings.confirmVoice, notifier.setConfirmVoice),
            toggle('confirm_gif', settings.confirmGif, notifier.setConfirmGif),
          ]),
          GroupHint(s.t('confirmations_hint')),
          SettingsGroup(title: s.t('other_settings'), children: [
            ListTile(
              title: Text(s.t('font')),
              trailing: Text(
                _fontLabel(settings.fontFamily, s),
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15, fontFamily: settings.fontFamily.isEmpty ? null : settings.fontFamily),
              ),
              onTap: () async {
                final family = await _pickFont(context, settings.fontFamily);
                if (family != null) notifier.setFontFamily(family);
              },
            ),
            toggle('show_ghost_button', settings.showGhostButton, notifier.setShowGhostButton),
            toggle('keep_edits', settings.keepEditHistory, notifier.setKeepEditHistory, hint: 'keep_edits_hint'),
            toggle('keep_deleted', settings.keepDeleted, notifier.setKeepDeleted, hint: 'keep_deleted_hint'),
            toggle('avatar_opens_profile', settings.avatarOpensProfile, notifier.setAvatarOpensProfile),
            toggle('chat_type_tabs', settings.chatTypeTabs, notifier.setChatTypeTabs, hint: 'chat_type_tabs_hint'),
            toggle('send_by_enter', settings.sendByEnter, notifier.setSendByEnter),
          ]),
          SettingsGroup(title: s.t('reset_title'), children: [
            ListTile(
              title: Text(s.t('reset_uzaro'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: Text(s.t('reset_uzaro_hint')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('reset_uzaro'), message: s.t('reset_uzaro_hint'), destructive: true);
                if (!ok) return;
                await notifier.resetUzaroSettings();
                await account.setOnline(true);
                if (context.mounted) showToast(context, s.t('reset_done'));
              },
            ),
          ]),
        ],
      ),
    );
  }
}
