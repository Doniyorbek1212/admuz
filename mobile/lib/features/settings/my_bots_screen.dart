import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../home/home_screen.dart' show openChat;
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'privacy_screen.dart' show promptText;
import 'telegram_services_screens.dart' show openUsername;

/// Bots this account owns (made with @BotFather), newest Telegram order.
final _ownedBotsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  final bots = await ref.watch(accountProvider).send<td.Users>(const td.GetOwnedBots());
  return bots.userIds;
});

/// Settings → My bots: the account's bots, and a way to make a new one in @BotFather.
class MyBotsScreen extends ConsumerWidget {
  const MyBotsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final bots = ref.watch(_ownedBotsProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('my_bots'))),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(_ownedBotsProvider.future),
        child: ListView(children: [
          SettingsGroup(children: [
            ListTile(
              leading: const TileIcon(Icons.add_rounded, Color(0xFF2E9BF0)),
              title: Text(s.t('bot_create')),
              subtitle: Text(s.t('bot_create_hint')),
              // Bots are made in @BotFather, as in the official apps; /newbot starts its questions.
              onTap: () => _askBotFather(context, ref, '/newbot'),
            ),
          ]),
          switch (bots) {
            AsyncData(:final value) when value.isEmpty => Padding(
                padding: const EdgeInsets.all(24),
                child: Text(s.t('my_bots_empty'), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
              ),
            AsyncData(:final value) => SettingsGroup(title: s.t('my_bots'), children: [
                for (final id in value)
                  ListTile(
                    leading: UserAvatar(userId: id, size: 42, showOnline: false),
                    title: Text(account.users[id]?.firstName ?? ''),
                    subtitle: Text(_mainUsername(account.users[id]).isEmpty ? '' : '@${_mainUsername(account.users[id])}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BotEditScreen(botUserId: id)));
                      ref.invalidate(_ownedBotsProvider);
                    },
                  ),
              ]),
            AsyncError(:final error) => Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Text(errorText(context, error), textAlign: TextAlign.center),
                  TextButton(onPressed: () => ref.invalidate(_ownedBotsProvider), child: Text(s.t('retry'))),
                ]),
              ),
            _ => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          },
        ]),
      ),
    );
  }
}

/// Sends [command] to @BotFather and opens its chat, where it continues with buttons.
Future<void> _askBotFather(BuildContext context, WidgetRef ref, String command) async {
  final account = ref.read(accountProvider);
  final chat = await guard(context, () => account.send<td.Chat>(const td.SearchPublicChat(username: 'BotFather')));
  if (chat == null || !context.mounted) return;
  await guard(context, () => account.sendText(chat.id, command));
  if (context.mounted) openChat(context, chat.id);
}

String _mainUsername(td.User? user) {
  final names = user?.usernames;
  if (names == null) return '';
  return names.editableUsername.isNotEmpty ? names.editableUsername : names.activeUsernames.firstOrNull ?? '';
}

/// What the owner can change on one bot: photo, name, "about" line, description, extra usernames and its token.
class BotEditScreen extends ConsumerStatefulWidget {
  const BotEditScreen({super.key, required this.botUserId});

  final int botUserId;

  @override
  ConsumerState<BotEditScreen> createState() => _BotEditScreenState();
}

class _BotEditScreenState extends ConsumerState<BotEditScreen> {
  String? _about;
  String? _description;
  td.AffiliateProgramInfo? _affiliate;

  int get _id => widget.botUserId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final loaded = await guard(context, () async => (
          await account.send<td.Text>(td.GetBotInfoShortDescription(botUserId: _id, languageCode: '')),
          await account.send<td.Text>(td.GetBotInfoDescription(botUserId: _id, languageCode: '')),
          await account.send<td.UserFullInfo>(td.GetUserFullInfo(userId: _id)),
        ));
    if (loaded == null || !mounted) return;
    setState(() {
      _about = loaded.$1.text;
      _description = loaded.$2.text;
      _affiliate = loaded.$3.botInfo?.affiliateProgram;
    });
  }

  /// Stars affiliate program: other bots and channels earn a share of what users they bring pay this bot.
  Future<void> _affiliateProgram() async {
    final s = context.s;
    final current = _affiliate?.parameters;
    final percent = await promptText(context,
        title: s.t('bot_affiliate'), label: s.t('bot_affiliate_percent'), keyboard: TextInputType.number,
        initial: current == null ? '' : '${current.commissionPerMille / 10}');
    if (percent == null || !mounted) return;
    final perMille = ((double.tryParse(percent.replaceAll(',', '.')) ?? 0) * 10).round();
    td.AffiliateProgramParameters? parameters;
    if (perMille > 0) {
      final months = await promptText(context,
          title: s.t('bot_affiliate'), label: s.t('bot_affiliate_months'), keyboard: TextInputType.number, initial: '${current?.monthCount ?? 0}');
      final monthCount = int.tryParse(months ?? '');
      if (monthCount == null || !mounted) return;
      parameters = td.AffiliateProgramParameters(commissionPerMille: perMille, monthCount: monthCount);
    } else if (current == null || !await confirm(context, title: s.t('bot_affiliate'), message: s.t('bot_affiliate_stop_ask'), destructive: true)) {
      return;
    }
    if (!mounted) return;
    final account = ref.read(accountProvider);
    final done = await guard(context, () async {
      final chat = await account.send<td.Chat>(td.CreatePrivateChat(userId: _id, force: false));
      await account.send<td.Ok>(td.SetChatAffiliateProgram(chatId: chat.id, parameters: parameters));
      return true;
    });
    if (done == true && mounted) await _load();
  }

  Future<void> _edit({required String title, required String initial, required int maxLength, bool multiline = false,
      required td.TdFunction Function(String value) request}) async {
    final value = await promptText(context, title: title, label: title, initial: initial, maxLength: maxLength,
        keyboard: multiline ? TextInputType.multiline : null);
    if (value == null || value == initial || !mounted) return;
    final done = await guard(context, () async {
      await ref.read(accountProvider).send<td.Ok>(request(value));
      return true;
    });
    if (done == true && mounted) {
      showToast(context, context.t('bot_saved'));
      await _load();
    }
  }

  Future<void> _photo({required bool remove}) async {
    td.InputChatPhoto? photo;
    if (!remove) {
      final path = await pickGalleryImage();
      if (path == null || !mounted) return;
      photo = td.InputChatPhotoStatic(photo: td.InputFileLocal(path: path));
    }
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetBotProfilePhoto(botUserId: _id, photo: photo)));
  }

  /// TDLib gives tokens only to manager bots, so the owner asks @BotFather, as in the official apps:
  /// /token shows it, /revoke makes a new one and stops the old one at once.
  Future<void> _token({required bool revoke}) async {
    final s = context.s;
    if (revoke) {
      final ok = await confirm(context, title: s.t('bot_token_revoke'), message: s.t('bot_token_revoke_hint'), destructive: true);
      if (!ok || !mounted) return;
    }
    await _askBotFather(context, ref, revoke ? '/revoke' : '/token');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final bot = account.users[_id];
    final name = bot?.firstName ?? '';
    final usernames = bot?.usernames;
    final hasPhoto = bot?.profilePhoto != null;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(name)),
      body: ListView(children: [
        const SizedBox(height: 16),
        Center(child: UserAvatar(userId: _id, size: 96, showOnline: false)),
        const SizedBox(height: 8),
        Text(name, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        if (_mainUsername(bot).isNotEmpty)
          Text('@${_mainUsername(bot)}', textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor)),
        const SizedBox(height: 8),
        SettingsGroup(children: [
          ListTile(leading: const Icon(Icons.add_a_photo_rounded), title: Text(s.t('bot_set_photo')), onTap: () => _photo(remove: false)),
          if (hasPhoto)
            ListTile(leading: const Icon(Icons.no_photography_outlined), title: Text(s.t('delete_photo')), onTap: () => _photo(remove: true)),
          ListTile(
            leading: const Icon(Icons.badge_rounded),
            title: Text(s.t('bot_name')),
            subtitle: Text(name),
            onTap: () => _edit(
                title: s.t('bot_name'), initial: name, maxLength: 64, request: (v) => td.SetBotName(botUserId: _id, languageCode: '', name: v)),
          ),
          ListTile(
            leading: const Icon(Icons.short_text_rounded),
            title: Text(s.t('bot_about')),
            subtitle: Text((_about ?? '').isEmpty ? s.t('bot_not_set') : _about!, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: _about == null
                ? null
                : () => _edit(
                    title: s.t('bot_about'),
                    initial: _about!,
                    maxLength: 120,
                    multiline: true,
                    request: (v) => td.SetBotInfoShortDescription(botUserId: _id, languageCode: '', shortDescription: v)),
          ),
          ListTile(
            leading: const Icon(Icons.notes_rounded),
            title: Text(s.t('bot_description')),
            subtitle: Text((_description ?? '').isEmpty ? s.t('bot_not_set') : _description!, maxLines: 3, overflow: TextOverflow.ellipsis),
            onTap: _description == null
                ? null
                : () => _edit(
                    title: s.t('bot_description'),
                    initial: _description!,
                    maxLength: 512,
                    multiline: true,
                    request: (v) => td.SetBotInfoDescription(botUserId: _id, languageCode: '', description: v)),
          ),
        ]),
        // Bought (collectible) usernames can be switched on and off; the main one is set in @BotFather.
        if (usernames != null && (usernames.activeUsernames.length + usernames.disabledUsernames.length) > 1)
          SettingsGroup(title: s.t('usernames'), children: [
            for (final (username, active) in [
              for (final u in usernames.activeUsernames) (u, true),
              for (final u in usernames.disabledUsernames) (u, false),
            ])
              SwitchListTile(
                title: Text('@$username'),
                value: active,
                onChanged: username == usernames.editableUsername
                    ? null
                    : (on) => guard(context, () => account.send<td.Ok>(td.ToggleBotUsernameIsActive(botUserId: _id, username: username, isActive: on))),
              ),
          ]),
        SettingsGroup(children: [
          ListTile(
            leading: const Icon(Icons.handshake_rounded),
            title: Text(s.t('bot_affiliate')),
            subtitle: Text(switch (_affiliate?.parameters) {
              null => s.t('bot_affiliate_off'),
              final p => '${p.commissionPerMille / 10}% · ${p.monthCount == 0 ? s.t('bot_affiliate_forever') : s.t('bot_affiliate_n_months', {'n': '${p.monthCount}'})}',
            }),
            onTap: _affiliateProgram,
          ),
        ]),
        SettingsGroup(title: s.t('bot_token'), children: [
          ListTile(leading: const Icon(Icons.key_rounded), title: Text(s.t('bot_token_show')), onTap: () => _token(revoke: false)),
          ListTile(
            leading: Icon(Icons.autorenew_rounded, color: theme.colorScheme.error),
            title: Text(s.t('bot_token_revoke'), style: TextStyle(color: theme.colorScheme.error)),
            onTap: () => _token(revoke: true),
          ),
        ]),
        SettingsGroup(children: [
          ListTile(
            leading: const Icon(Icons.chat_rounded),
            title: Text(s.t('bot_open_chat')),
            onTap: () async {
              final chat = await guard(context, () => account.send<td.Chat>(td.CreatePrivateChat(userId: _id, force: false)));
              if (chat != null && context.mounted) openChat(context, chat.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_rounded),
            title: Text(s.t('bot_more_in_father')),
            subtitle: Text(s.t('bot_more_in_father_hint')),
            onTap: () => openUsername(context, ref, 'BotFather'),
          ),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }
}
