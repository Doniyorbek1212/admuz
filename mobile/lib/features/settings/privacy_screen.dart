import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/app_lock.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../contacts/contacts_screen.dart';
import 'advanced_settings.dart';
import 'privacy_extra_screens.dart';
import 'privacy_rules_screen.dart';
import 'settings_screen.dart';

export 'privacy_rules_screen.dart' show PrivacyLevel;

final _autoDeleteProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.MessageAutoDeleteTime>(const td.GetDefaultMessageAutoDeleteTime());
  return result.time;
});

final _accountTtlProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.AccountTtl>(const td.GetAccountTtl());
  return result.days;
});

final _passwordProvider = FutureProvider.autoDispose<td.PasswordState>((ref) => ref.watch(accountProvider).passwordState());

final _blockedCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.MessageSenders>(
        const td.GetBlockedMessageSenders(blockList: td.BlockListMain(), offset: 0, limit: 1),
      );
  return result.totalCount;
});

final _sessionCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.Sessions>(const td.GetActiveSessions());
  return result.sessions.length;
});

final _archiveSettingsProvider = FutureProvider.autoDispose<td.ArchiveChatListSettings>(
  (ref) => ref.watch(accountProvider).send<td.ArchiveChatListSettings>(const td.GetArchiveChatListSettings()),
);

/// Radio dialog over [options] (value → label); returns the picked value.
Future<T?> pickOption<T>(BuildContext context, String title, Map<T, String> options, T? current) => showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<T>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final e in options.entries) RadioListTile<T>(value: e.key, title: Text(e.value))],
            ),
          ),
        ],
      ),
    );

/// Settings → Privacy and security, laid out like Telegram/aka: security rows with their state,
/// every privacy setting with its level and exception counts, account deletion, bots and contacts.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  /// Opens [screen]; [refresh] reloads what it may have changed once it closes.
  void _push(BuildContext context, WidgetRef ref, Widget screen, [List<FutureProvider<Object?>> refresh = const []]) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)).then((_) {
      for (final provider in refresh) {
        ref.invalidate(provider);
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.read(accountProvider);
    final primary = Theme.of(context).colorScheme.primary;
    Widget value(String? text) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(text ?? '…', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: primary, fontSize: 15.5)),
        );
    final password = ref.watch(_passwordProvider).value;
    final autoDelete = ref.watch(_autoDeleteProvider).value;
    final ttl = ref.watch(_accountTtlProvider).value;
    final archive = ref.watch(_archiveSettingsProvider).value;
    String onOff(bool on) => s.t(on ? 'state_on' : 'state_off');
    final topChatsOff = switch (account.options['disable_top_chats']) {
      td.OptionValueBoolean(:final value) => value,
      _ => false,
    };
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('privacy_security'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('security'), children: [
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(s.t('two_step')),
              trailing: value(password == null ? null : onOff(password.hasPassword)),
              onTap: () => _push(context, ref, const TwoStepScreen(), [_passwordProvider]),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(s.t('auto_delete_messages')),
              trailing: value(autoDelete == null ? null : (autoDelete == 0 ? s.t('state_off') : autoDeleteLabel(autoDelete, s))),
              onTap: () => _push(context, ref, const AutoDeleteScreen(), [_autoDeleteProvider]),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: Text(s.t('passcode_lock')),
              trailing: value(onOff(ref.watch(appLockProvider).enabled)),
              onTap: () => _push(context, ref, const PasscodeSettingsScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline_rounded),
              title: Text(s.t('login_email')),
              trailing: value(password == null ? null : (password.loginEmailAddressPattern.isEmpty ? s.t('state_off') : password.loginEmailAddressPattern)),
              onTap: password == null ? null : () => changeLoginEmail(context, ref, password.loginEmailAddressPattern).then((_) => ref.invalidate(_passwordProvider)),
            ),
            ListTile(
              leading: const Icon(Icons.front_hand_outlined),
              title: Text(s.t('blocked_users')),
              trailing: value(ref.watch(_blockedCountProvider).value?.toString()),
              onTap: () => _push(context, ref, const BlockedUsersScreen(), [_blockedCountProvider]),
            ),
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(s.t('devices')),
              trailing: value(ref.watch(_sessionCountProvider).value?.toString()),
              onTap: () => _push(context, ref, const SessionsScreen(), [_sessionCountProvider]),
            ),
          ]),
          GroupHint(s.t('devices_hint')),
          SettingsGroup(title: s.t('privacy'), children: [
            for (final key in const ['phone', 'status', 'photo', 'forwards', 'calls', 'voice']) _PrivacyRow(settingKey: key),
            ListTile(
              title: Row(children: [Text(s.t('privacy_messages')), const SizedBox(width: 6), const _PremiumStar()]),
              trailing: value(ref.watch(newChatPrivacyProvider).value == null
                  ? null
                  : (ref.watch(newChatPrivacyProvider).value!.allowNewChatsFromUnknownUsers
                      ? s.t('privacy_level_everybody')
                      : s.t('privacy_level_contacts_premium'))),
              onTap: () => _push(context, ref, const NewChatPrivacyScreen()),
            ),
            for (final key in const ['birthdate']) _PrivacyRow(settingKey: key),
            ListTile(
              title: Text(s.t('privacy_gifts')),
              trailing: value(s.t('privacy_level_everybody')),
              onTap: () => _push(context, ref, const GiftPrivacyScreen()),
            ),
            for (final key in const ['bio', 'audio', 'invites']) _PrivacyRow(settingKey: key),
          ]),
          GroupHint(s.t('privacy_hint_invites')),
          SettingsGroup(title: s.t('new_chats'), children: [
            SwitchListTile(
              title: Text(s.t('archive_unknown')),
              value: archive?.archiveAndMuteNewChatsFromUnknownUsers ?? false,
              onChanged: archive == null
                  ? null
                  : (on) async {
                      await guard(
                        context,
                        () => account.send<td.Ok>(td.SetArchiveChatListSettings(
                          settings: td.ArchiveChatListSettings(
                            archiveAndMuteNewChatsFromUnknownUsers: on,
                            keepUnmutedChatsArchived: archive.keepUnmutedChatsArchived,
                            keepChatsFromFoldersArchived: archive.keepChatsFromFoldersArchived,
                          ),
                        )),
                      );
                      ref.invalidate(_archiveSettingsProvider);
                    },
            ),
          ]),
          GroupHint(s.t('archive_unknown_hint')),
          SettingsGroup(title: s.t('delete_my_account'), children: [
            ListTile(
              title: Text(s.t('account_ttl_if_away')),
              trailing: value(ttl == null ? null : ttlLabel(ttl, s)),
              onTap: () async {
                final options = {for (final months in const [1, 3, 6, 12, 18, 24]) (months * 30.5).round(): ttlLabel((months * 30.5).round(), s)};
                final chosen = await pickOption(context, s.t('account_ttl_if_away'), options, ttl);
                if (chosen == null || !context.mounted) return;
                await guard(context, () => account.send<td.Ok>(td.SetAccountTtl(ttl: td.AccountTtl(days: chosen))));
                ref.invalidate(_accountTtlProvider);
              },
            ),
            ListTile(
              title: Text(s.t('delete_account_now'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => _deleteAccountNow(context, account),
            ),
          ]),
          GroupHint(s.t('account_ttl_hint')),
          SettingsGroup(title: s.t('bots_websites'), children: [
            ListTile(
              title: Text(s.t('clear_payment_info')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('clear_payment_info'), message: s.t('clear_payment_info_confirm'), destructive: true);
                if (!ok || !context.mounted) return;
                await guard(context, () async {
                  await account.send<td.Ok>(const td.DeleteSavedOrderInfo());
                  await account.send<td.Ok>(const td.DeleteSavedCredentials());
                });
                if (context.mounted) showToast(context, s.t('done'));
              },
            ),
            ListTile(title: Text(s.t('connected_websites')), onTap: () => _push(context, ref, const ConnectedWebsitesScreen())),
          ]),
          GroupHint(s.t('connected_websites_hint')),
          SettingsGroup(title: s.t('contacts'), children: [
            ListTile(title: Text(s.t('close_friends')), onTap: () => _push(context, ref, const CloseFriendsScreen())),
            ListTile(
              title: Text(s.t('delete_synced_contacts')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('delete_synced_contacts'), message: s.t('delete_synced_contacts_confirm'), destructive: true);
                if (!ok || !context.mounted) return;
                await guard(context, () => account.send<td.Ok>(const td.ClearImportedContacts()));
                if (context.mounted) showToast(context, s.t('done'));
              },
            ),
            StatefulBuilder(
              builder: (context, setState) => SwitchListTile(
                title: Text(s.t('suggest_frequent')),
                value: !topChatsOff,
                onChanged: (on) async {
                  await guard(context, () => account.send<td.Ok>(td.SetOption(name: 'disable_top_chats', value: td.OptionValueBoolean(value: !on))));
                  setState(() {});
                },
              ),
            ),
          ]),
          GroupHint(s.t('suggest_frequent_hint')),
        ],
      ),
    );
  }
}

class _PremiumStar extends StatelessWidget {
  const _PremiumStar();

  @override
  Widget build(BuildContext context) => const Icon(Icons.star_rounded, size: 20, color: Color(0xFF9B6CE0));
}

class _PrivacyRow extends ConsumerWidget {
  const _PrivacyRow({required this.settingKey});

  final String settingKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final rules = ref.watch(privacyRulesProvider(settingKey)).value;
    return ListTile(
      title: Row(children: [
        Flexible(child: Text(s.t('privacy_$settingKey'), maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (settingKey == 'voice') ...[const SizedBox(width: 6), const _PremiumStar()],
      ]),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 170),
        child: Text(
          rules?.label(s) ?? '…',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15.5),
        ),
      ),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => PrivacyRulesScreen(settingKey: settingKey)))
          .then((_) => ref.invalidate(privacyRulesProvider(settingKey))),
    );
  }
}

String ttlLabel(int days, Strings s) => s.t('ttl_months_short', {'n': '${(days / 30.5).round()}'});

String autoDeleteLabel(int seconds, Strings s) {
  final days = seconds ~/ 86400;
  if (days >= 365) return s.t('period_years', {'n': '${days ~/ 365}'});
  if (days >= 30) return s.t('period_months', {'n': '${days ~/ 30}'});
  if (days >= 7 && days % 7 == 0) return s.t('period_weeks', {'n': '${days ~/ 7}'});
  return s.t('period_days', {'n': '$days'});
}

/// Change the login e-mail: new address, then the code Telegram mails to it.
Future<void> changeLoginEmail(BuildContext context, WidgetRef ref, String pattern) async {
  final s = context.s;
  final account = ref.read(accountProvider);
  if (pattern.isNotEmpty) {
    final change = await confirm(context, title: pattern, message: s.t('login_email_hint'), confirmLabel: s.t('login_email_change'));
    if (!change || !context.mounted) return;
  }
  final email = await promptText(context, title: s.t('login_email'), label: s.t('email_address'), keyboard: TextInputType.emailAddress);
  if (email == null || !email.contains('@') || !context.mounted) return;
  final sent = await guard(context, () => account.send<td.EmailAddressAuthenticationCodeInfo>(td.SetLoginEmailAddress(newLoginEmailAddress: email)));
  if (sent == null || !context.mounted) return;
  final code = await promptText(context, title: s.t('email_code'), label: s.t('email_code_hint', {'email': sent.emailAddressPattern}), keyboard: TextInputType.number);
  if (code == null || code.isEmpty || !context.mounted) return;
  final ok = await guard(context, () => account.send<td.Ok>(td.CheckLoginEmailAddressCode(code: td.EmailAddressAuthenticationCode(code: code))));
  if (ok != null && context.mounted) showToast(context, s.t('done'));
}

/// Contacts who see stories shared with "Close friends"; ticked contacts are saved on Done.
class CloseFriendsScreen extends ConsumerStatefulWidget {
  const CloseFriendsScreen({super.key});

  @override
  ConsumerState<CloseFriendsScreen> createState() => _CloseFriendsScreenState();
}

class _CloseFriendsScreenState extends ConsumerState<CloseFriendsScreen> {
  List<int>? _contacts;
  final Set<int> _chosen = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final result = await guard(context, () async {
      final contacts = await account.send<td.Users>(const td.GetContacts());
      final friends = await account.send<td.Users>(const td.GetCloseFriends());
      return (contacts.userIds, friends.userIds);
    });
    if (result == null || !mounted) return;
    setState(() {
      _contacts = result.$1;
      _chosen.addAll(result.$2);
    });
  }

  Future<void> _save() async {
    final ok = await guard(context, () async {
      await ref.read(accountProvider).send<td.Ok>(td.SetCloseFriends(userIds: _chosen.toList()));
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final contacts = _contacts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('close_friends')), actions: [TextButton(onPressed: contacts == null ? null : _save, child: Text(s.t('done')))]),
      body: contacts == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                GroupHint(s.t('close_friends_hint')),
                for (final id in contacts)
                  CheckboxListTile(
                    secondary: UserAvatar(userId: id, size: 40, showOnline: false),
                    title: Text(account.userName(id)),
                    value: _chosen.contains(id),
                    onChanged: (on) => setState(() => on == true ? _chosen.add(id) : _chosen.remove(id)),
                  ),
              ],
            ),
    );
  }
}

/// Permanently deletes the Telegram account after two confirmations (and the 2-step password, if set).
Future<void> _deleteAccountNow(BuildContext context, TelegramAccount account) async {
  final s = context.s;
  if (!await confirm(context, title: s.t('delete_account_now'), message: s.t('delete_account_warning'), confirmLabel: s.t('continue'), destructive: true)) return;
  if (!context.mounted) return;
  final state = await guard(context, account.passwordState);
  if (state == null || !context.mounted) return;
  var password = '';
  if (state.hasPassword) {
    final entered = await promptText(context, title: s.t('delete_account_now'), label: s.t('password'), keyboard: TextInputType.visiblePassword);
    if (entered == null || entered.isEmpty || !context.mounted) return;
    password = entered;
  }
  if (!await confirm(context, title: s.t('delete_account_final'), confirmLabel: s.t('delete'), destructive: true)) return;
  if (!context.mounted) return;
  // On success TDLib closes the session itself; the auth flow then shows the login screen.
  await guard(context, () => account.send<td.Ok>(td.DeleteAccount(reason: 'Deleted from UZARO', password: password)));
}

/// One-field text dialog; null when cancelled.
Future<String?> promptText(BuildContext context, {required String title, required String label, TextInputType? keyboard, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, keyboardType: keyboard, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(context.t('ok'))),
      ],
    ),
  ).whenComplete(controller.dispose);
}

final _blockedProvider = FutureProvider.autoDispose<List<td.MessageSender>>((ref) async {
  final account = ref.watch(accountProvider);
  final result = await account.send<td.MessageSenders>(
    const td.GetBlockedMessageSenders(blockList: td.BlockListMain(), offset: 0, limit: 100),
  );
  return result.senders;
});

class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final blocked = ref.watch(_blockedProvider);
    final account = ref.watch(accountProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('blocked_users'))),
      body: blocked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (senders) => ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            SettingsGroup(children: [
              ListTile(
                leading: Icon(Icons.person_add_disabled_outlined, color: Theme.of(context).colorScheme.primary),
                title: Text(s.t('block_user'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                onTap: () async {
                  final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
                  if (user == null || !context.mounted) return;
                  await guard(
                    context,
                    () => account.send<td.Ok>(td.SetMessageSenderBlockList(senderId: td.MessageSenderUser(userId: user.id), blockList: const td.BlockListMain())),
                  );
                  ref.invalidate(_blockedProvider);
                },
              ),
            ]),
            GroupHint(s.t('blocked_hint')),
            if (senders.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s.t('no_blocked'), style: TextStyle(color: Theme.of(context).hintColor))))
            else
              SettingsGroup(title: s.t('blocked_count', {'n': '${senders.length}'}), children: [
                for (final sender in senders)
                  ListTile(
                    leading: sender is td.MessageSenderUser
                        ? UserAvatar(userId: sender.userId, size: 44)
                        : ChatAvatar(chatId: (sender as td.MessageSenderChat).chatId, size: 44),
                    title: Text(account.senderName(sender)),
                    subtitle: switch (sender) {
                      td.MessageSenderUser(:final userId) when account.users[userId] != null =>
                        Text(account.users[userId]!.phoneNumber.isEmpty ? formatUserStatus(account.users[userId]!, s) : '+${account.users[userId]!.phoneNumber}'),
                      _ => null,
                    },
                    trailing: TextButton(
                      onPressed: () async {
                        await guard(context, () => account.send<td.Ok>(td.SetMessageSenderBlockList(senderId: sender, blockList: null)));
                        ref.invalidate(_blockedProvider);
                      },
                      child: Text(s.t('unblock')),
                    ),
                  ),
              ]),
          ],
        ),
      ),
    );
  }
}
