import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/settings_group.dart';

/// Slider stops: off, battery thresholds, always on (Telegram/aka power saving).
const _levels = [0, 5, 10, 15, 20, 25, 100];

/// Settings → Power saving: battery threshold plus which animations are allowed.
class PowerSavingScreen extends ConsumerWidget {
  const PowerSavingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final active = ref.watch(powerSavingProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    final index = _levels.indexOf(settings.powerSaveLevel).clamp(0, _levels.length - 1);
    final level = settings.powerSaveLevel;
    final description = level <= 0
        ? s.t('power_hint_off')
        : level >= 100
            ? s.t('power_hint_on')
            : s.t('power_hint_level', {'n': '$level'});
    Widget toggle(IconData icon, String key, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
          secondary: Icon(icon),
          title: Text(s.t(key)),
          value: value,
          // While power saving is on everything is off; the switches keep the user's choice for later.
          onChanged: active ? null : onChanged,
        );
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('power_saving'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Text(s.t('power_mode'), style: TextStyle(color: primary, fontWeight: FontWeight.w600, fontSize: 14.5)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(5)),
                    child: Text(
                      s.t(active ? 'power_badge_on' : 'power_badge_off').toUpperCase(),
                      style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.t('power_off'), style: TextStyle(color: level <= 0 ? primary : hint)),
                  if (level > 0 && level < 100)
                    Row(children: [
                      Text('$level% ', style: TextStyle(color: primary)),
                      Icon(Icons.battery_2_bar_rounded, size: 18, color: primary),
                      Text(' ${s.t('power_below')}', style: TextStyle(color: primary)),
                    ]),
                  Text(s.t('power_on'), style: TextStyle(color: level >= 100 ? primary : hint)),
                ],
              ),
            ),
            Slider(
              value: index.toDouble(),
              max: (_levels.length - 1).toDouble(),
              divisions: _levels.length - 1,
              onChanged: (v) => notifier.setPowerSaveLevel(_levels[v.round()]),
            ),
          ]),
          GroupHint(description),
          SettingsGroup(title: s.t('power_options'), children: [
            toggle(Icons.emoji_emotions_outlined, 'power_stickers', settings.animatedStickers, notifier.setAnimatedStickers),
            toggle(Icons.videocam_outlined, 'power_videos', settings.autoplayVideos, notifier.setAutoplayVideos),
            toggle(Icons.gif_box_outlined, 'power_gifs', settings.autoplayGifs, notifier.setAutoplayGifs),
          ]),
          SettingsGroup(children: [
            SwitchListTile(
              title: Text(s.t('power_transitions')),
              value: settings.smoothTransitions,
              onChanged: active ? null : notifier.setSmoothTransitions,
            ),
          ]),
          GroupHint(s.t('power_transitions_hint')),
        ],
      ),
    );
  }
}
