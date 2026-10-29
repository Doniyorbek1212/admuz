import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

const _scopes = <String, td.NotificationSettingsScope>{
  'notif_private': td.NotificationSettingsScopePrivateChats(),
  'notif_groups': td.NotificationSettingsScopeGroupChats(),
  'notif_channels': td.NotificationSettingsScopeChannelChats(),
};

/// Telegram notification tones saved to the account: upload, remove, and pick one per chat kind.
/// Telegram stores the choice for every client; it does not change UZARO's own in-chat sounds.
class NotificationSoundsScreen extends ConsumerStatefulWidget {
  const NotificationSoundsScreen({super.key});

  @override
  ConsumerState<NotificationSoundsScreen> createState() => _NotificationSoundsScreenState();
}

class _NotificationSoundsScreenState extends ConsumerState<NotificationSoundsScreen> {
  List<td.NotificationSound>? _sounds;
  final Map<String, td.ScopeNotificationSettings> _settings = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final sounds = await guard(context, () => account.send<td.NotificationSounds>(const td.GetSavedNotificationSounds()));
    for (final entry in _scopes.entries) {
      if (!mounted) return;
      final current = await guard(context, () => account.send<td.ScopeNotificationSettings>(td.GetScopeNotificationSettings(scope: entry.value)));
      if (current != null) _settings[entry.key] = current;
    }
    if (mounted) setState(() => _sounds = sounds?.notificationSounds ?? const []);
  }

  Future<void> _upload() async {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    final path = files.firstOrNull?.path;
    if (path == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.NotificationSound>(td.AddSavedNotificationSound(sound: td.InputFileLocal(path: path))));
    await _load();
  }

  String _name(int soundId, Strings s) {
    if (soundId == 0) return s.t('sound_silent');
    final known = _sounds?.where((x) => x.id == soundId).firstOrNull ?? _extra[soundId];
    if (known == null && soundId > 0 && _sounds != null) unawaited(_fetchOne(soundId));
    return known?.title ?? s.t('sound_default');
  }

  /// Sounds set on another device may be missing from the saved list; ask Telegram for that one.
  final Map<int, td.NotificationSound> _extra = {};

  Future<void> _fetchOne(int soundId) async {
    if (_extra.containsKey(soundId)) return;
    try {
      final sound = await ref.read(accountProvider).send<td.NotificationSound>(td.GetSavedNotificationSound(notificationSoundId: soundId));
      if (mounted) setState(() => _extra[soundId] = sound);
    } on TdException catch (error) {
      debugPrint('notification sound $soundId: $error');
    }
  }

  Future<void> _pick(String key) async {
    final s = context.s;
    final current = _settings[key];
    if (current == null) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(s.t('sound_silent')), onTap: () => Navigator.pop(context, 0)),
          for (final sound in _sounds ?? const <td.NotificationSound>[])
            ListTile(
              title: Text(sound.title),
              trailing: sound.id == current.soundId ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () => Navigator.pop(context, sound.id),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    await guard(
      context,
      () => ref.read(accountProvider).send<td.Ok>(td.SetScopeNotificationSettings(scope: _scopes[key]!, notificationSettings: current.copyWith(soundId: picked))),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final sounds = _sounds;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('notification_sounds'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: _upload, icon: const Icon(Icons.upload_rounded), label: Text(s.t('sound_upload'))),
      body: sounds == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              for (final key in _scopes.keys)
                ListTile(
                  title: Text(s.t(key)),
                  subtitle: Text(_settings[key] == null ? '' : _name(_settings[key]!.soundId, s)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _pick(key),
                ),
              const Divider(),
              SectionHeader(s.t('sound_saved')),
              if (sounds.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s.t('sound_saved_empty'))),
              for (final sound in sounds)
                ListTile(
                  leading: const Icon(Icons.music_note_rounded),
                  title: Text(sound.title),
                  subtitle: Text('${sound.duration} s'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.RemoveSavedNotificationSound(notificationSoundId: sound.id)));
                      await _load();
                    },
                  ),
                ),
              const SizedBox(height: 80),
            ]),
    );
  }
}
