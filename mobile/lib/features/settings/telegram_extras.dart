import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'misc_extras.dart' show copyInternalLink, countryName;
import 'privacy_screen.dart' show pickOption, promptText;

// ------------------------------------------------------------------ in-app browser

/// Telegram's link-opening settings: in-app browser or external, plus per-site exceptions.
class WebBrowserSettingsScreen extends ConsumerStatefulWidget {
  const WebBrowserSettingsScreen({super.key});

  @override
  ConsumerState<WebBrowserSettingsScreen> createState() => _WebBrowserSettingsScreenState();
}

class _WebBrowserSettingsScreenState extends ConsumerState<WebBrowserSettingsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);

  @override
  void initState() {
    super.initState();
    _account.webBrowserRevision.addListener(_changed);
  }

  @override
  void dispose() {
    _account.webBrowserRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _addException({required bool external}) async {
    final s = context.s;
    final url = await promptText(context, title: s.t(external ? 'browser_always_external' : 'browser_always_in_app'), label: 'https://…', keyboard: TextInputType.url);
    if (url == null || url.trim().isEmpty || !mounted) return;
    final link = url.contains('://') ? url.trim() : 'https://${url.trim()}';
    await guard(context, () => _account.send<td.Ok>(td.AddWebBrowserSettingsException(openExternalBrowser: external, url: link)));
  }

  Widget _exceptionTile(td.WebDomainException e) => ListTile(
        leading: const Icon(Icons.public_rounded),
        title: Text(e.title.isNotEmpty ? e.title : e.domain, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(e.domain),
        trailing: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => guard(context, () => _account.send<td.Ok>(td.RemoveWebBrowserSettingsException(url: e.url))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = _account.webBrowserSettings;
    final external = settings?.openExternalBrowser ?? false;
    final hasExceptions = (settings?.externalExceptions.isNotEmpty ?? false) || (settings?.inAppExceptions.isNotEmpty ?? false);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('browser_settings'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        SettingsGroup(children: [
          SwitchListTile(
            title: Text(s.t('browser_open_external')),
            subtitle: Text(s.t('browser_open_external_hint')),
            value: external,
            onChanged: (on) => guard(
              context,
              () => _account.send<td.Ok>(td.ChangeWebBrowserSettings(openExternalBrowser: on, displayCloseButton: settings?.displayCloseButton ?? true)),
            ),
          ),
          if (Platform.isAndroid && !external)
            SwitchListTile(
              title: Text(s.t('browser_close_button')),
              value: settings?.displayCloseButton ?? true,
              onChanged: (on) => guard(context, () => _account.send<td.Ok>(td.ChangeWebBrowserSettings(openExternalBrowser: false, displayCloseButton: on))),
            ),
        ]),
        SettingsGroup(title: s.t(external ? 'browser_always_in_app' : 'browser_always_external'), children: [
          for (final e in (external ? settings?.inAppExceptions : settings?.externalExceptions) ?? const <td.WebDomainException>[]) _exceptionTile(e),
          ListTile(leading: const Icon(Icons.add_rounded), title: Text(s.t('browser_add_site')), onTap: () => _addException(external: !external)),
        ]),
        if (hasExceptions)
          SettingsGroup(children: [
            ListTile(
              leading: Icon(Icons.delete_sweep_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('browser_clear_exceptions'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => guard(context, () => _account.send<td.Ok>(const td.RemoveAllWebBrowserSettingsExceptions())),
            ),
          ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ save to gallery

/// Video size caps Telegram offers for autosave.
const _videoSizeOptions = [10, 50, 100, 500, 1000, 4000];

/// Settings → Data → Save to gallery: per chat type and per chat exceptions, synced with Telegram.
class AutosaveScreen extends ConsumerStatefulWidget {
  const AutosaveScreen({super.key});

  @override
  ConsumerState<AutosaveScreen> createState() => _AutosaveScreenState();
}

class _AutosaveScreenState extends ConsumerState<AutosaveScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.AutosaveSettings? _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await guard(context, () => _account.send<td.AutosaveSettings>(const td.GetAutosaveSettings()));
    if (settings == null || !mounted) return;
    _account.autosaveSettings = settings;
    setState(() => _settings = settings);
  }

  Future<void> _set(td.AutosaveSettingsScope scope, td.ScopeAutosaveSettings? value) async {
    if (value != null && (value.autosavePhotos || value.autosaveVideos) && !await Gal.hasAccess(toAlbum: true)) {
      if (!await Gal.requestAccess(toAlbum: true)) {
        if (mounted) showToast(context, context.t('gallery_permission'));
        return;
      }
    }
    if (!mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.SetAutosaveSettings(scope: scope, settings: value)));
    await _load();
  }

  Future<void> _edit(td.AutosaveSettingsScope scope, td.ScopeAutosaveSettings current, String title) async {
    final s = context.s;
    var photos = current.autosavePhotos;
    var videos = current.autosaveVideos;
    var maxMb = (current.maxVideoFileSize / (1024 * 1024)).round().clamp(1, 4000);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
            SwitchListTile(title: Text(s.t('photos')), value: photos, onChanged: (v) => setSheet(() => photos = v)),
            SwitchListTile(title: Text(s.t('videos')), value: videos, onChanged: (v) => setSheet(() => videos = v)),
            if (videos)
              ListTile(
                title: Text(s.t('autosave_video_limit')),
                trailing: Text(formatFileSize(maxMb * 1024 * 1024)),
                onTap: () async {
                  final picked = await pickOption<int>(context, s.t('autosave_video_limit'), {for (final mb in _videoSizeOptions) mb: formatFileSize(mb * 1024 * 1024)}, maxMb);
                  if (picked != null) setSheet(() => maxMb = picked);
                },
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('save'))),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _set(scope, td.ScopeAutosaveSettings(autosavePhotos: photos, autosaveVideos: videos, maxVideoFileSize: maxMb * 1024 * 1024));
  }

  String _summary(td.ScopeAutosaveSettings value, Strings s) => [
        if (value.autosavePhotos) s.t('photos'),
        if (value.autosaveVideos) '${s.t('videos')} ≤ ${formatFileSize(value.maxVideoFileSize)}',
      ].join(', ').ifEmpty(s.t('off'));

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final settings = _settings;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('autosave'))),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              SettingsGroup(children: [
                for (final (key, scope, value) in [
                  ('private_chats', const td.AutosaveSettingsScopePrivateChats() as td.AutosaveSettingsScope, settings.privateChatSettings),
                  ('groups', const td.AutosaveSettingsScopeGroupChats(), settings.groupSettings),
                  ('channels', const td.AutosaveSettingsScopeChannelChats(), settings.channelSettings),
                ])
                  ListTile(
                    title: Text(s.t(key)),
                    subtitle: Text(_summary(value, s)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _edit(scope, value, s.t(key)),
                  ),
              ]),
              GroupHint(s.t('autosave_hint')),
              if (settings.exceptions.isNotEmpty)
                SettingsGroup(title: s.t('exceptions'), children: [
                  for (final e in settings.exceptions)
                    ListTile(
                      leading: ChatAvatar(chatId: e.chatId, size: 38, showOnline: false),
                      title: Text(_account.chats[e.chatId] == null ? '${e.chatId}' : chatTitle(_account.chats[e.chatId]!, _account, s)),
                      subtitle: Text(_summary(e.settings, s)),
                      onTap: () => _edit(td.AutosaveSettingsScopeChat(chatId: e.chatId), e.settings, s.t('exceptions')),
                      trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => _set(td.AutosaveSettingsScopeChat(chatId: e.chatId), null)),
                    ),
                  ListTile(
                    leading: Icon(Icons.delete_sweep_rounded, color: Theme.of(context).colorScheme.error),
                    title: Text(s.t('exceptions_clear'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: () async {
                      await guard(context, () => _account.send<td.Ok>(const td.ClearAutosaveSettingsExceptions()));
                      await _load();
                    },
                  ),
                ]),
            ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ------------------------------------------------------------------ Telegram language packs

/// Opens a t.me/setlanguage/… link: shows the pack and installs it as the Telegram language.
Future<void> installLanguagePack(BuildContext context, TelegramAccount account, String languagePackId) async {
  final info = await guard(context, () => account.send<td.LanguagePackInfo>(td.GetLanguagePackInfo(languagePackId: languagePackId)));
  if (info == null || !context.mounted) return;
  final s = context.s;
  final ok = await confirm(
    context,
    title: info.nativeName.isNotEmpty ? info.nativeName : info.name,
    message: s.t('lang_pack_install_hint', {'done': '${info.translatedStringCount}', 'total': '${info.totalStringCount}'}),
    confirmLabel: s.t('lang_pack_install'),
  );
  if (!ok || !context.mounted) return;
  final done = await guard(context, () async {
    if (!info.isOfficial) await account.send<td.Ok>(td.AddCustomServerLanguagePack(languagePackId: info.id));
    await _useLanguagePack(account, info.id);
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t('done'));
}

/// Makes [id] the language of texts Telegram's servers send (service notices, errors, bot commands).
Future<void> _useLanguagePack(TelegramAccount account, String id) async {
  await account.send<td.Ok>(td.SetOption(name: 'language_pack_id', value: td.OptionValueString(value: id)));
  await account.send<td.Ok>(td.SynchronizeLanguagePack(languagePackId: id));
}

/// All languages Telegram is translated into; picking one switches the server-side texts.
class TelegramLanguagesScreen extends ConsumerStatefulWidget {
  const TelegramLanguagesScreen({super.key});

  @override
  ConsumerState<TelegramLanguagesScreen> createState() => _TelegramLanguagesScreenState();
}

class _TelegramLanguagesScreenState extends ConsumerState<TelegramLanguagesScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  List<td.LanguagePackInfo>? _packs;
  String? _suggested;
  String _flag = '';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    _suggest();
  }

  Future<void> _load() async {
    final info = await guard(context, () => _account.send<td.LocalizationTargetInfo>(const td.GetLocalizationTargetInfo(onlyLocal: false)));
    // The cached option may predate a change made from a t.me/setlanguage link; read the live value.
    try {
      _account.options['language_pack_id'] = await _account.send<td.OptionValue>(const td.GetOption(name: 'language_pack_id'));
    } on TdException catch (error) {
      debugPrint('language_pack_id unknown: $error');
    }
    if (mounted) setState(() => _packs = info?.languagePacks ?? const []);
  }

  /// The language people of the user's country (from the phone number) usually pick.
  Future<void> _suggest() async {
    final phone = _account.me?.phoneNumber ?? '';
    if (phone.isEmpty) return;
    try {
      final number = await _account.send<td.PhoneNumberInfo>(td.GetPhoneNumberInfo(phoneNumberPrefix: phone));
      final country = number.country?.countryCode;
      if (country == null) return;
      final language = await _account.send<td.Text>(td.GetPreferredCountryLanguage(countryCode: country));
      final flag = await _account.send<td.Text>(td.GetCountryFlagEmoji(countryCode: country));
      final name = await countryName(_account, country);
      if (mounted && language.text.isNotEmpty) {
        setState(() {
          _suggested = language.text;
          _flag = '${flag.text} $name';
        });
      }
    } on TdException catch (error) {
      debugPrint('preferred language unknown: $error');
    }
  }

  String get _current => switch (_account.options['language_pack_id']) {
        td.OptionValueString(:final value) => value,
        _ => '',
      };

  Future<void> _menu(td.LanguagePackInfo pack) async {
    final s = context.s;
    final custom = pack.id.startsWith('X');
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.list_alt_rounded), title: Text(s.t('lang_pack_strings')), onTap: () => Navigator.pop(context, 'strings')),
          if (!custom)
            ListTile(leading: const Icon(Icons.emoji_emotions_outlined), title: Text(s.t('emoji_suggest_keywords')), onTap: () => Navigator.pop(context, 'emoji')),
          if (!custom) ListTile(leading: const Icon(Icons.link_rounded), title: Text(s.t('copy_link')), onTap: () => Navigator.pop(context, 'link')),
          if (custom) ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('rename')), onTap: () => Navigator.pop(context, 'rename')),
          if (pack.isInstalled && !pack.isOfficial && pack.id != _current)
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'strings':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LanguagePackStringsScreen(pack: pack)));
      case 'link':
        await copyInternalLink(context, _account, td.InternalLinkTypeLanguagePack(languagePackId: pack.id));
      case 'emoji':
        // Telegram's page for suggesting emoji search keywords in this language.
        final url = await guard(context, () => _account.send<td.HttpUrl>(td.GetEmojiSuggestionsUrl(languageCode: pack.baseLanguagePackId.isNotEmpty ? pack.baseLanguagePackId : pack.id)));
        if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
      case 'rename':
        final name = await promptText(context, title: s.t('rename'), label: s.t('title'), initial: pack.name);
        if (name == null || name.trim().isEmpty || !mounted) return;
        await guard(context, () => _account.send<td.Ok>(td.EditCustomLanguagePackInfo(info: pack.copyWith(name: name.trim(), nativeName: name.trim()))));
      case 'delete':
        await guard(context, () => _account.send<td.Ok>(td.DeleteLanguagePack(languagePackId: pack.id)));
    }
    await _load();
  }

  /// A local pack for translating Telegram's texts yourself; strings are added in its string list.
  Future<void> _createCustom() async {
    final s = context.s;
    final name = await promptText(context, title: s.t('lang_pack_custom'), label: s.t('title'));
    if (name == null || name.trim().isEmpty || !mounted) return;
    final id = 'X${DateTime.now().millisecondsSinceEpoch}';
    await guard(
      context,
      () => _account.send<td.Ok>(td.SetCustomLanguagePack(
        info: td.LanguagePackInfo(
          id: id,
          baseLanguagePackId: '',
          name: name.trim(),
          nativeName: name.trim(),
          pluralCode: 'en',
          isOfficial: false,
          isRtl: false,
          isBeta: false,
          isInstalled: true,
          totalStringCount: 0,
          translatedStringCount: 0,
          localStringCount: 0,
          translationUrl: '',
        ),
        strings: const [],
      )),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final packs = _packs;
    final q = _query.toLowerCase();
    final shown = packs?.where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.nativeName.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('telegram_languages'))),
      floatingActionButton: FloatingActionButton(tooltip: s.t('lang_pack_custom'), onPressed: _createCustom, child: const Icon(Icons.add_rounded)),
      body: shown == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(s.t('telegram_languages_hint'), style: TextStyle(color: Theme.of(context).hintColor))),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: s.t('search'), isDense: true),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              for (final pack in shown)
                ListTile(
                  title: Row(children: [
                    Flexible(child: Text(pack.nativeName.isNotEmpty ? pack.nativeName : pack.name)),
                    if (pack.id == _suggested) ...[const SizedBox(width: 6), Chip(label: Text('$_flag ${s.t('suggested')}'.trim()), visualDensity: VisualDensity.compact)],
                  ]),
                  subtitle: Text([
                    pack.name,
                    if (!pack.isOfficial && pack.totalStringCount > 0) '${(100 * pack.translatedStringCount / pack.totalStringCount).round()}%',
                    if (pack.isBeta) 'beta',
                  ].join(' · ')),
                  trailing: pack.id == _current ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                  onTap: () async {
                    await guard(context, () => _useLanguagePack(_account, pack.id));
                    if (mounted) setState(() {});
                  },
                  onLongPress: () => _menu(pack),
                ),
            ]),
    );
  }
}

/// Every string of a language pack, searchable; strings of a custom pack can be edited.
class LanguagePackStringsScreen extends ConsumerStatefulWidget {
  const LanguagePackStringsScreen({super.key, required this.pack});

  final td.LanguagePackInfo pack;

  @override
  ConsumerState<LanguagePackStringsScreen> createState() => _LanguagePackStringsScreenState();
}

class _LanguagePackStringsScreenState extends ConsumerState<LanguagePackStringsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  List<td.LanguagePackString>? _strings;
  String _query = '';

  bool get _custom => widget.pack.id.startsWith('X');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(context, () => _account.send<td.LanguagePackStrings>(td.GetLanguagePackStrings(languagePackId: widget.pack.id, keys: const [])));
    if (mounted) setState(() => _strings = result?.strings ?? const []);
  }

  static String _text(td.LanguagePackStringValue? value) => switch (value) {
        td.LanguagePackStringValueOrdinary(:final value) => value,
        td.LanguagePackStringValuePluralized(:final oneValue, :final otherValue) => '$oneValue / $otherValue',
        _ => '',
      };

  Future<void> _edit(String key, String current) async {
    final s = context.s;
    final value = await promptText(context, title: key, label: s.t('translation'), initial: current);
    if (value == null || !mounted) return;
    final ok = await guard(context, () async {
      await _account.send<td.Ok>(td.SetCustomLanguagePackString(
        languagePackId: widget.pack.id,
        newString: td.LanguagePackString(key: key, value: td.LanguagePackStringValueOrdinary(value: value)),
      ));
      return true;
    });
    if (ok != true || !mounted) return;
    // Read back from the local pack database, the same place the strings are served from.
    final json = TdClient.executeStatic(td.GetLanguagePackString(
      languagePackDatabasePath: '${_account.databaseDirectory}${Platform.pathSeparator}langpack.db',
      localizationTarget: 'android',
      languagePackId: widget.pack.id,
      key: key,
    ));
    final saved = json == null ? null : td.LanguagePackStringValue.fromJson(json);
    setState(() {
      final strings = [...?_strings];
      final index = strings.indexWhere((e) => e.key == key);
      final updated = td.LanguagePackString(key: key, value: saved ?? td.LanguagePackStringValueOrdinary(value: value));
      index < 0 ? strings.insert(0, updated) : strings[index] = updated;
      _strings = strings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final strings = _strings;
    final q = _query.toLowerCase();
    final shown = strings?.where((e) => q.isEmpty || e.key.toLowerCase().contains(q) || _text(e.value).toLowerCase().contains(q)).take(500).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.pack.nativeName.isNotEmpty ? widget.pack.nativeName : widget.pack.name)),
      floatingActionButton: _custom
          ? FloatingActionButton(
              onPressed: () async {
                final key = await promptText(context, title: s.t('lang_pack_add_string'), label: 'key');
                if (key != null && key.trim().isNotEmpty && context.mounted) await _edit(key.trim(), '');
              },
              child: const Icon(Icons.add_rounded),
            )
          : null,
      body: shown == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: s.t('search'), isDense: true),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text(s.t('nothing_found')))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, index) {
                          final e = shown[index];
                          return ListTile(
                            dense: true,
                            title: Text(_text(e.value), maxLines: 3, overflow: TextOverflow.ellipsis),
                            subtitle: Text(e.key, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                            onTap: _custom ? () => _edit(e.key, _text(e.value)) : null,
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
