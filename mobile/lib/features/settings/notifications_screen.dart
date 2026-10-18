import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

const _scopes = <String, td.NotificationSettingsScope>{
  'notif_private': td.NotificationSettingsScopePrivateChats(),
  'notif_groups': td.NotificationSettingsScopeGroupChats(),
  'notif_channels': td.NotificationSettingsScopeChannelChats(),
};

final _scopeProvider = FutureProvider.autoDispose.family<td.ScopeNotificationSettings, String>((ref, key) {
  return ref.watch(accountProvider).send<td.ScopeNotificationSettings>(td.GetScopeNotificationSettings(scope: _scopes[key]!));
});

/// Settings → Notifications: this device's behaviour plus Telegram's per-chat-type defaults (synced to all devices).
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('notifications'))),
      body: ListView(
        children: [
          SectionHeader(s.t('notif_device')),
          SwitchListTile(title: Text(s.t('notif_show')), value: settings.notificationsEnabled, onChanged: notifier.setNotifications),
          SwitchListTile(
            title: Text(s.t('notif_preview')),
            value: settings.messagePreview,
            onChanged: settings.notificationsEnabled ? notifier.setMessagePreview : null,
          ),
          const Divider(),
          SectionHeader(s.t('notif_telegram')),
          for (final key in _scopes.keys) _ScopeTiles(scopeKey: key),
          const Divider(),
          ListTile(
            leading: Icon(Icons.restart_alt_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('notif_reset'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              final ok = await confirm(context, title: s.t('notif_reset'), message: s.t('notif_reset_confirm'), destructive: true);
              if (!ok || !context.mounted) return;
              await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ResetAllNotificationSettings()));
              for (final key in _scopes.keys) {
                ref.invalidate(_scopeProvider(key));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _ScopeTiles extends ConsumerWidget {
  const _ScopeTiles({required this.scopeKey});

  final String scopeKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(_scopeProvider(scopeKey)).value;

    Future<void> update({int? muteFor, bool? showPreview}) async {
      if (current == null) return;
      await guard(
        context,
        () => ref.read(accountProvider).send<td.Ok>(td.SetScopeNotificationSettings(
              scope: _scopes[scopeKey]!,
              notificationSettings: td.ScopeNotificationSettings(
                muteFor: muteFor ?? current.muteFor,
                soundId: current.soundId,
                showPreview: showPreview ?? current.showPreview,
                useDefaultMuteStories: current.useDefaultMuteStories,
                muteStories: current.muteStories,
                storySoundId: current.storySoundId,
                showStoryPoster: current.showStoryPoster,
                disablePinnedMessageNotifications: current.disablePinnedMessageNotifications,
                disableMentionNotifications: current.disableMentionNotifications,
              ),
            )),
      );
      ref.invalidate(_scopeProvider(scopeKey));
    }

    final enabled = current != null && current.muteFor == 0;
    return Column(
      children: [
        SwitchListTile(
          title: Text(s.t(scopeKey)),
          value: enabled,
          onChanged: current == null ? null : (on) => update(muteFor: on ? 0 : muteForever),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 32, right: 16),
          title: Text(s.t('notif_scope_preview')),
          value: current?.showPreview ?? true,
          onChanged: enabled ? (on) => update(showPreview: on) : null,
        ),
      ],
    );
  }
}
