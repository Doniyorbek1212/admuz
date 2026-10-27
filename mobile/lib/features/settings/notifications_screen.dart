import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/chat_sounds.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../home/home_screen.dart';
import 'notification_sounds.dart';

const _scopes = <String, td.NotificationSettingsScope>{
  'notif_private': td.NotificationSettingsScopePrivateChats(),
  'notif_groups': td.NotificationSettingsScopeGroupChats(),
  'notif_channels': td.NotificationSettingsScopeChannelChats(),
};

final _scopeProvider = FutureProvider.autoDispose.family<td.ScopeNotificationSettings, String>((ref, key) {
  return ref.watch(accountProvider).send<td.ScopeNotificationSettings>(td.GetScopeNotificationSettings(scope: _scopes[key]!));
});

/// Chats whose notification settings differ from their scope's default.
final _exceptionsProvider = FutureProvider.autoDispose.family<List<int>, String>((ref, key) async {
  final chats = await ref.watch(accountProvider).send<td.Chats>(td.GetChatNotificationSettingsExceptions(scope: _scopes[key], compareSound: false));
  return chats.chatIds;
});

/// Same scope settings with some fields replaced (TDLib wants the whole object back).
td.ScopeNotificationSettings _with(
  td.ScopeNotificationSettings current, {
  int? muteFor,
  bool? showPreview,
  bool? muteStories,
  bool? disablePinned,
}) =>
    td.ScopeNotificationSettings(
      muteFor: muteFor ?? current.muteFor,
      soundId: current.soundId,
      showPreview: showPreview ?? current.showPreview,
      useDefaultMuteStories: muteStories == null ? current.useDefaultMuteStories : false,
      muteStories: muteStories ?? current.muteStories,
      storySoundId: current.storySoundId,
      showStoryPoster: current.showStoryPoster,
      disablePinnedMessageNotifications: disablePinned ?? current.disablePinnedMessageNotifications,
      disableMentionNotifications: current.disableMentionNotifications,
    );

/// Settings → Notifications, laid out like Telegram/aka: this device, chat kinds with exceptions,
/// stories, reactions, events and reset.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  Future<void> _setScope(String key, td.ScopeNotificationSettings next) async {
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetScopeNotificationSettings(scope: _scopes[key]!, notificationSettings: next)));
    ref.invalidate(_scopeProvider(key));
  }

  /// Sound list where each tap previews the sound, like Telegram's tone picker.
  Future<void> _pickSound(String current, void Function(String id) onPicked) async {
    final s = context.s;
    var selected = current;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          content: RadioGroup<String>(
            groupValue: selected,
            onChanged: (id) {
              if (id == null) return;
              setDialogState(() => selected = id);
              ChatSounds.instance.play(id);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final id in ChatSounds.ids) RadioListTile<String>(value: id, title: Text(s.t('sound_$id')))],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(context, selected), child: Text(s.t('ok'))),
          ],
        ),
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final account = ref.watch(accountProvider);
    final s = context.s;
    final privateScope = ref.watch(_scopeProvider('notif_private')).value;
    final reactions = account.reactionNotifications;
    final contactJoinedOff = switch (account.options['disable_contact_registered_notifications']) {
      td.OptionValueBoolean(:final value) => value,
      _ => false,
    };
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('notifications'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('notif_device'), children: [
            SwitchListTile(title: Text(s.t('notif_show')), value: settings.notificationsEnabled, onChanged: notifier.setNotifications),
            SwitchListTile(
              title: Text(s.t('notif_preview')),
              value: settings.messagePreview,
              onChanged: settings.notificationsEnabled ? notifier.setMessagePreview : null,
            ),
          ]),
          SettingsGroup(title: s.t('chat_sounds'), children: [
            SwitchListTile(
              secondary: const Icon(Icons.volume_up_rounded),
              title: Text(s.t('chat_sounds')),
              subtitle: Text(s.t('chat_sounds_hint')),
              value: settings.chatSounds,
              onChanged: notifier.setChatSounds,
            ),
            ListTile(
              enabled: settings.chatSounds,
              leading: const Icon(Icons.north_east_rounded),
              title: Text(s.t('sound_send')),
              subtitle: Text(s.t('sound_${settings.sendSound}')),
              onTap: () => _pickSound(settings.sendSound, notifier.setSendSound),
            ),
            ListTile(
              enabled: settings.chatSounds,
              leading: const Icon(Icons.south_west_rounded),
              title: Text(s.t('sound_receive')),
              subtitle: Text(s.t('sound_${settings.receiveSound}')),
              onTap: () => _pickSound(settings.receiveSound, notifier.setReceiveSound),
            ),
          ]),
          SettingsGroup(title: s.t('notif_telegram'), children: [
            for (final key in _scopes.keys) _ScopeTile(scopeKey: key, onChanged: _setScope),
            ListTile(
              leading: const Icon(Icons.library_music_outlined),
              title: Text(s.t('notification_sounds')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotificationSoundsScreen())),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.motion_photos_on_outlined),
              title: Text(s.t('notif_stories')),
              value: privateScope != null && !privateScope.muteStories,
              onChanged: privateScope == null ? null : (on) => _setScope('notif_private', _with(privateScope, muteStories: !on)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.favorite_border_rounded),
              title: Text(s.t('notif_reactions')),
              value: reactions != null && reactions.messageReactionSource is! td.ReactionNotificationSourceNone,
              onChanged: reactions == null
                  ? null
                  : (on) async {
                      final source = on ? const td.ReactionNotificationSourceContacts() : const td.ReactionNotificationSourceNone();
                      final next = td.ReactionNotificationSettings(
                        messageReactionSource: source,
                        storyReactionSource: source,
                        pollVoteSource: reactions.pollVoteSource,
                        soundId: reactions.soundId,
                        showPreview: reactions.showPreview,
                      );
                      await guard(context, () => account.send<td.Ok>(td.SetReactionNotificationSettings(notificationSettings: next)));
                      if (mounted) setState(() {});
                    },
            ),
          ]),
          SettingsGroup(title: s.t('notif_events'), children: [
            SwitchListTile(
              title: Text(s.t('notif_contact_joined')),
              value: !contactJoinedOff,
              onChanged: (on) async {
                await guard(
                  context,
                  () => account.send<td.Ok>(td.SetOption(name: 'disable_contact_registered_notifications', value: td.OptionValueBoolean(value: !on))),
                );
                if (mounted) setState(() {});
              },
            ),
            SwitchListTile(
              title: Text(s.t('notif_pinned')),
              value: privateScope != null && !privateScope.disablePinnedMessageNotifications,
              onChanged: privateScope == null
                  ? null
                  : (on) async {
                      for (final key in _scopes.keys) {
                        final current = await ref.read(_scopeProvider(key).future);
                        if (!mounted) return;
                        await _setScope(key, _with(current, disablePinned: !on));
                      }
                    },
            ),
          ]),
          if (Platform.isAndroid)
            SettingsGroup(title: s.t('notif_other'), children: [
              SwitchListTile(
                title: Text(s.t('notif_keep_alive')),
                subtitle: Text(s.t('notif_keep_alive_hint')),
                value: settings.keepAlive,
                onChanged: settings.notificationsEnabled ? notifier.setKeepAlive : null,
              ),
            ]),
          SettingsGroup(title: s.t('reset_title'), children: [
            ListTile(
              title: Text(s.t('notif_reset'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: Text(s.t('notif_reset_confirm')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('notif_reset'), message: s.t('notif_reset_confirm'), destructive: true);
                if (!ok || !context.mounted) return;
                await guard(context, () => account.send<td.Ok>(const td.ResetAllNotificationSettings()));
                for (final key in _scopes.keys) {
                  ref
                    ..invalidate(_scopeProvider(key))
                    ..invalidate(_exceptionsProvider(key));
                }
              },
            ),
          ]),
        ],
      ),
    );
  }
}

/// "Private chats — On, 22 exceptions" with a switch; the row opens the scope's details.
class _ScopeTile extends ConsumerWidget {
  const _ScopeTile({required this.scopeKey, required this.onChanged});

  final String scopeKey;
  final Future<void> Function(String key, td.ScopeNotificationSettings next) onChanged;

  static const _icons = {
    'notif_private': Icons.person_outline_rounded,
    'notif_groups': Icons.group_outlined,
    'notif_channels': Icons.campaign_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(_scopeProvider(scopeKey)).value;
    final exceptions = ref.watch(_exceptionsProvider(scopeKey)).value;
    final enabled = current != null && current.muteFor == 0;
    final state = s.t(enabled ? 'state_on' : 'state_off');
    return ListTile(
      leading: Icon(_icons[scopeKey]),
      title: Text(s.t(scopeKey)),
      subtitle: Text(exceptions == null || exceptions.isEmpty ? state : '$state, ${s.t('notif_exceptions_n', {'n': '${exceptions.length}'})}'),
      trailing: Switch(
        value: enabled,
        onChanged: current == null ? null : (on) => onChanged(scopeKey, _with(current, muteFor: on ? 0 : muteForever)),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ScopeScreen(scopeKey: scopeKey, onChanged: onChanged))),
    );
  }
}

/// One chat kind: preview switch and the chats with their own settings.
class _ScopeScreen extends ConsumerWidget {
  const _ScopeScreen({required this.scopeKey, required this.onChanged});

  final String scopeKey;
  final Future<void> Function(String key, td.ScopeNotificationSettings next) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final current = ref.watch(_scopeProvider(scopeKey)).value;
    final exceptions = ref.watch(_exceptionsProvider(scopeKey));
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t(scopeKey))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(children: [
            SwitchListTile(
              title: Text(s.t('notif_show')),
              value: current != null && current.muteFor == 0,
              onChanged: current == null ? null : (on) => onChanged(scopeKey, _with(current, muteFor: on ? 0 : muteForever)),
            ),
            SwitchListTile(
              title: Text(s.t('notif_scope_preview')),
              value: current?.showPreview ?? true,
              onChanged: current == null || current.muteFor != 0 ? null : (on) => onChanged(scopeKey, _with(current, showPreview: on)),
            ),
          ]),
          SettingsGroup(
            title: s.t('notif_exceptions'),
            children: exceptions.when(
              loading: () => const [Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))],
              error: (error, _) => [ListTile(title: Text(errorText(context, error)))],
              data: (ids) => ids.isEmpty
                  ? [ListTile(title: Text(s.t('notif_no_exceptions'), style: TextStyle(color: hint)))]
                  : [
                      for (final id in ids)
                        ListTile(
                          leading: ChatAvatar(chatId: id, size: 42),
                          title: Text(account.chats[id]?.title ?? '$id', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            s.t(account.chats[id] != null && account.isMuted(account.chats[id]!) ? 'state_off' : 'state_on'),
                            style: TextStyle(color: hint),
                          ),
                          onTap: () => openChat(context, id),
                        ),
                    ],
            ),
          ),
        ],
      ),
    );
  }
}
