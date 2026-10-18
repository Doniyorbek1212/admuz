import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

enum PrivacyLevel { everybody, contacts, nobody }

PrivacyLevel _levelOf(td.UserPrivacySettingRules rules) {
  for (final rule in rules.rules) {
    if (rule is td.UserPrivacySettingRuleAllowAll) return PrivacyLevel.everybody;
    if (rule is td.UserPrivacySettingRuleAllowContacts) return PrivacyLevel.contacts;
    if (rule is td.UserPrivacySettingRuleRestrictAll) return PrivacyLevel.nobody;
  }
  return PrivacyLevel.nobody;
}

td.UserPrivacySettingRules _rulesFor(PrivacyLevel level) => td.UserPrivacySettingRules(rules: [
      switch (level) {
        PrivacyLevel.everybody => const td.UserPrivacySettingRuleAllowAll(),
        PrivacyLevel.contacts => const td.UserPrivacySettingRuleAllowContacts(),
        PrivacyLevel.nobody => const td.UserPrivacySettingRuleRestrictAll(),
      },
    ]);

final _privacyProvider = FutureProvider.autoDispose.family<PrivacyLevel, String>((ref, key) async {
  final account = ref.watch(accountProvider);
  final rules = await account.send<td.UserPrivacySettingRules>(td.GetUserPrivacySettingRules(setting: _setting(key)));
  return _levelOf(rules);
});

td.UserPrivacySetting _setting(String key) => switch (key) {
      'phone' => const td.UserPrivacySettingShowPhoneNumber(),
      'photo' => const td.UserPrivacySettingShowProfilePhoto(),
      'bio' => const td.UserPrivacySettingShowBio(),
      'calls' => const td.UserPrivacySettingAllowCalls(),
      'invites' => const td.UserPrivacySettingAllowChatInvites(),
      'forwards' => const td.UserPrivacySettingShowLinkInForwardedMessages(),
      'birthdate' => const td.UserPrivacySettingShowBirthdate(),
      'find_phone' => const td.UserPrivacySettingAllowFindingByPhoneNumber(),
      _ => const td.UserPrivacySettingShowStatus(),
    };

final _autoDeleteProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.MessageAutoDeleteTime>(const td.GetDefaultMessageAutoDeleteTime());
  return result.time;
});

final _accountTtlProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.AccountTtl>(const td.GetAccountTtl());
  return result.days;
});

/// Radio dialog over [options] (value → label); returns the picked value.
Future<T?> _pick<T>(BuildContext context, String title, Map<T, String> options, T? current) => showDialog<T>(
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

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.read(accountProvider);
    final autoDelete = ref.watch(_autoDeleteProvider);
    final accountTtl = ref.watch(_accountTtlProvider);
    final autoDeleteOptions = {
      0: s.t('auto_delete_off'),
      86400: s.t('period_day'),
      7 * 86400: s.t('period_week'),
      31 * 86400: s.t('period_month'),
    };
    final ttlOptions = {for (final months in const [1, 3, 6, 12, 18, 24]) (months * 30.5).round(): s.t('ttl_months', {'n': '$months'})};
    return Scaffold(
      appBar: AppBar(title: Text(s.t('privacy'))),
      body: ListView(
        children: [
          SectionHeader(s.t('security')),
          ListTile(
            leading: const Icon(Icons.block_rounded),
            title: Text(s.t('blocked_users')),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BlockedUsersScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(s.t('auto_delete_messages')),
            subtitle: Text(autoDelete.when(data: (v) => autoDeleteOptions[v] ?? '${v ~/ 86400} d', loading: () => '…', error: (_, _) => '—')),
            onTap: () async {
              final chosen = await _pick(context, s.t('auto_delete_messages'), autoDeleteOptions, autoDelete.value);
              if (chosen == null || !context.mounted) return;
              await guard(context, () => account.send<td.Ok>(td.SetDefaultMessageAutoDeleteTime(
                    messageAutoDeleteTime: td.MessageAutoDeleteTime(time: chosen),
                  )));
              ref.invalidate(_autoDeleteProvider);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_remove_outlined),
            title: Text(s.t('account_ttl')),
            subtitle: Text(accountTtl.when(
              // Telegram may store any day count; show the nearest offered option.
              data: (days) => ttlOptions[days] ?? s.t('ttl_months', {'n': '${(days / 30.5).round()}'}),
              loading: () => '…',
              error: (_, _) => '—',
            )),
            onTap: () async {
              final chosen = await _pick(context, s.t('account_ttl'), ttlOptions, accountTtl.value);
              if (chosen == null || !context.mounted) return;
              await guard(context, () => account.send<td.Ok>(td.SetAccountTtl(ttl: td.AccountTtl(days: chosen))));
              ref.invalidate(_accountTtlProvider);
            },
          ),
          const Divider(),
          SectionHeader(s.t('privacy')),
          for (final key in const ['status', 'phone', 'find_phone', 'photo', 'bio', 'birthdate', 'forwards', 'calls', 'invites'])
            _PrivacyTile(settingKey: key),
        ],
      ),
    );
  }
}

class _PrivacyTile extends ConsumerWidget {
  const _PrivacyTile({required this.settingKey});

  final String settingKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final level = ref.watch(_privacyProvider(settingKey));
    return ListTile(
      title: Text(s.t('privacy_$settingKey')),
      subtitle: Text(level.when(
        data: (l) => s.t('privacy_level_${l.name}'),
        loading: () => '…',
        error: (_, _) => '—',
      )),
      onTap: () async {
        final current = level.value ?? PrivacyLevel.everybody;
        // Telegram only allows "everybody" or "contacts" for finding by phone number.
        final levels = settingKey == 'find_phone' ? const [PrivacyLevel.everybody, PrivacyLevel.contacts] : PrivacyLevel.values;
        final chosen = await _pick(
          context,
          s.t('privacy_$settingKey'),
          {for (final l in levels) l: s.t('privacy_level_${l.name}')},
          current,
        );
        if (chosen == null || chosen == current || !context.mounted) return;
        await guard(
          context,
          () => ref.read(accountProvider).send<td.Ok>(td.SetUserPrivacySettingRules(setting: _setting(settingKey), rules: _rulesFor(chosen))),
        );
        ref.invalidate(_privacyProvider(settingKey));
      },
    );
  }
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
      appBar: AppBar(title: Text(s.t('blocked_users'))),
      body: blocked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (senders) => senders.isEmpty
            ? EmptyState(icon: Icons.block_rounded, title: s.t('no_blocked'))
            : ListView(
                children: [
                  for (final sender in senders)
                    ListTile(
                      leading: sender is td.MessageSenderUser
                          ? UserAvatar(userId: sender.userId, size: 44)
                          : ChatAvatar(chatId: (sender as td.MessageSenderChat).chatId, size: 44),
                      title: Text(account.senderName(sender)),
                      trailing: TextButton(
                        onPressed: () async {
                          await guard(context, () => account.send<td.Ok>(td.SetMessageSenderBlockList(senderId: sender, blockList: null)));
                          ref.invalidate(_blockedProvider);
                        },
                        child: Text(s.t('unblock')),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
