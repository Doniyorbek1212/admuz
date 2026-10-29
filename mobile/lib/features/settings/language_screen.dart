import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'privacy_screen.dart' show pickOption;
import 'telegram_extras.dart';

/// App languages with their native and English names, as Telegram lists them.
const _appLanguages = {'uz': ("O'zbek", 'Uzbek'), 'ru': ('Русский', 'Russian'), 'en': ('English', 'English')};

const translationLanguages = {
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

/// Settings → Language: message translation options, then the app language.
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final isPremium = ref.watch(meProvider)?.isPremium ?? false;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('language'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('translate_messages'), children: [
            SwitchListTile(title: Text(s.t('show_translate_button')), value: settings.showTranslateButton, onChanged: notifier.setShowTranslateButton),
            SwitchListTile(
              title: Text(s.t('translate_entire_chats')),
              secondary: isPremium ? null : const Icon(Icons.lock_rounded, size: 18),
              value: false,
              onChanged: (_) => showToast(context, s.t('premium_required')),
            ),
            ListTile(
              title: Text(s.t('translate_to')),
              trailing: Text(
                translationLanguages[settings.translateTo] ?? settings.translateTo,
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15),
              ),
              onTap: () async {
                final code = await pickOption(context, s.t('translate_to'), translationLanguages, settings.translateTo);
                if (code != null) notifier.setTranslateTo(code);
              },
            ),
          ]),
          GroupHint(s.t('translate_hint')),
          SettingsGroup(title: s.t('language'), children: [
            RadioGroup<String>(
              groupValue: settings.localeCode,
              onChanged: (code) {
                if (code != null) notifier.setLocale(code);
              },
              child: Column(children: [
                for (final MapEntry(key: code, value: (native, english)) in _appLanguages.entries)
                  if (Strings.supported.contains(code))
                    RadioListTile<String>(value: code, title: Text(native), subtitle: Text(english)),
              ]),
            ),
          ]),
          SettingsGroup(children: [
            ListTile(
              title: Text(s.t('telegram_languages')),
              subtitle: Text(s.t('telegram_languages_short')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TelegramLanguagesScreen())),
            ),
          ]),
        ],
      ),
    );
  }
}
