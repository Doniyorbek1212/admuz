import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../contacts/contacts_screen.dart';

enum PrivacyLevel { everybody, contacts, nobody }

/// One privacy setting split the way Telegram shows it: a base level plus "always allow / never allow" exceptions.
class PrivacyRules {
  const PrivacyRules({
    required this.level,
    this.allowUsers = const [],
    this.restrictUsers = const [],
    this.allowChats = const [],
    this.restrictChats = const [],
    this.allowPremium = false,
  });

  factory PrivacyRules.parse(td.UserPrivacySettingRules rules) {
    var level = PrivacyLevel.nobody;
    final allowUsers = <int>[], restrictUsers = <int>[], allowChats = <int>[], restrictChats = <int>[];
    var allowPremium = false;
    for (final rule in rules.rules) {
      switch (rule) {
        case td.UserPrivacySettingRuleAllowAll():
          level = PrivacyLevel.everybody;
        case td.UserPrivacySettingRuleAllowContacts():
          level = PrivacyLevel.contacts;
        case td.UserPrivacySettingRuleAllowUsers(:final userIds):
          allowUsers.addAll(userIds);
        case td.UserPrivacySettingRuleRestrictUsers(:final userIds):
          restrictUsers.addAll(userIds);
        case td.UserPrivacySettingRuleAllowChatMembers(:final chatIds):
          allowChats.addAll(chatIds);
        case td.UserPrivacySettingRuleRestrictChatMembers(:final chatIds):
          restrictChats.addAll(chatIds);
        case td.UserPrivacySettingRuleAllowPremiumUsers():
          allowPremium = true;
        default:
          break;
      }
    }
    return PrivacyRules(
      level: level,
      allowUsers: allowUsers,
      restrictUsers: restrictUsers,
      allowChats: allowChats,
      restrictChats: restrictChats,
      allowPremium: allowPremium,
    );
  }

  final PrivacyLevel level;
  final List<int> allowUsers;
  final List<int> restrictUsers;
  final List<int> allowChats;
  final List<int> restrictChats;

  /// "Contacts and Premium users" for group invites.
  final bool allowPremium;

  int get allowCount => allowUsers.length + allowChats.length;
  int get restrictCount => restrictUsers.length + restrictChats.length;

  /// Exceptions first, then the base rule: TDLib applies the first matching rule.
  td.UserPrivacySettingRules build() => td.UserPrivacySettingRules(rules: [
        if (level != PrivacyLevel.everybody && allowUsers.isNotEmpty) td.UserPrivacySettingRuleAllowUsers(userIds: allowUsers),
        if (level != PrivacyLevel.everybody && allowChats.isNotEmpty) td.UserPrivacySettingRuleAllowChatMembers(chatIds: allowChats),
        if (level != PrivacyLevel.nobody && restrictUsers.isNotEmpty) td.UserPrivacySettingRuleRestrictUsers(userIds: restrictUsers),
        if (level != PrivacyLevel.nobody && restrictChats.isNotEmpty) td.UserPrivacySettingRuleRestrictChatMembers(chatIds: restrictChats),
        if (allowPremium && level == PrivacyLevel.contacts) const td.UserPrivacySettingRuleAllowPremiumUsers(),
        switch (level) {
          PrivacyLevel.everybody => const td.UserPrivacySettingRuleAllowAll(),
          PrivacyLevel.contacts => const td.UserPrivacySettingRuleAllowContacts(),
          PrivacyLevel.nobody => const td.UserPrivacySettingRuleRestrictAll(),
        },
      ]);

  PrivacyRules copyWith({PrivacyLevel? level, List<int>? allowUsers, List<int>? restrictUsers, List<int>? allowChats, List<int>? restrictChats}) =>
      PrivacyRules(
        level: level ?? this.level,
        allowUsers: allowUsers ?? this.allowUsers,
        restrictUsers: restrictUsers ?? this.restrictUsers,
        allowChats: allowChats ?? this.allowChats,
        restrictChats: restrictChats ?? this.restrictChats,
        allowPremium: allowPremium,
      );

  /// "Everybody (-2)", "My contacts (-1, +3)", "Contacts and Premium".
  String label(Strings s) {
    final base = allowPremium && level == PrivacyLevel.contacts ? s.t('privacy_level_contacts_premium') : s.t('privacy_level_${level.name}');
    final parts = [
      if (level != PrivacyLevel.nobody && restrictCount > 0) '-$restrictCount',
      if (level != PrivacyLevel.everybody && allowCount > 0) '+$allowCount',
    ];
    return parts.isEmpty ? base : '$base (${parts.join(', ')})';
  }
}

td.UserPrivacySetting privacySetting(String key) => switch (key) {
      'phone' => const td.UserPrivacySettingShowPhoneNumber(),
      'photo' => const td.UserPrivacySettingShowProfilePhoto(),
      'bio' => const td.UserPrivacySettingShowBio(),
      'calls' => const td.UserPrivacySettingAllowCalls(),
      'p2p' => const td.UserPrivacySettingAllowPeerToPeerCalls(),
      'invites' => const td.UserPrivacySettingAllowChatInvites(),
      'forwards' => const td.UserPrivacySettingShowLinkInForwardedMessages(),
      'birthdate' => const td.UserPrivacySettingShowBirthdate(),
      'find_phone' => const td.UserPrivacySettingAllowFindingByPhoneNumber(),
      'voice' => const td.UserPrivacySettingAllowPrivateVoiceAndVideoNoteMessages(),
      'audio' => const td.UserPrivacySettingShowProfileAudio(),
      _ => const td.UserPrivacySettingShowStatus(),
    };

final privacyRulesProvider = FutureProvider.autoDispose.family<PrivacyRules, String>((ref, key) async {
  final rules = await ref.watch(accountProvider).send<td.UserPrivacySettingRules>(td.GetUserPrivacySettingRules(setting: privacySetting(key)));
  return PrivacyRules.parse(rules);
});

final _readDateProvider = FutureProvider.autoDispose<td.ReadDatePrivacySettings>(
  (ref) => ref.watch(accountProvider).send<td.ReadDatePrivacySettings>(const td.GetReadDatePrivacySettings()),
);

/// Which levels a setting offers and whether non-"everybody" needs Premium.
List<PrivacyLevel> _levelsFor(String key) => switch (key) {
      'find_phone' || 'invites' => const [PrivacyLevel.everybody, PrivacyLevel.contacts],
      _ => PrivacyLevel.values,
    };

bool _premiumOnly(String key) => key == 'voice';

/// Settings → Privacy → one setting: who may, the matching hint, and its exceptions.
class PrivacyRulesScreen extends ConsumerWidget {
  const PrivacyRulesScreen({super.key, required this.settingKey});

  final String settingKey;

  Future<void> _save(BuildContext context, WidgetRef ref, PrivacyRules next) async {
    await guard(
      context,
      () => ref.read(accountProvider).send<td.Ok>(td.SetUserPrivacySettingRules(setting: privacySetting(settingKey), rules: next.build())),
    );
    ref.invalidate(privacyRulesProvider(settingKey));
  }

  Future<void> _addUsers(BuildContext context, WidgetRef ref, PrivacyRules rules, {required bool allow}) async {
    final picked = await Navigator.of(context).push<List<int>>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickMany: true)));
    if (picked == null || picked.isEmpty || !context.mounted) return;
    // A user is either always allowed or never allowed, not both.
    final next = allow
        ? rules.copyWith(allowUsers: {...rules.allowUsers, ...picked}.toList(), restrictUsers: rules.restrictUsers.where((id) => !picked.contains(id)).toList())
        : rules.copyWith(restrictUsers: {...rules.restrictUsers, ...picked}.toList(), allowUsers: rules.allowUsers.where((id) => !picked.contains(id)).toList());
    await _save(context, ref, next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final rules = ref.watch(privacyRulesProvider(settingKey));
    final isPremium = ref.watch(meProvider)?.isPremium ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('privacy_$settingKey'))),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (current) {
          final locked = _premiumOnly(settingKey) && !isPremium;
          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              SettingsGroup(title: s.t('privacy_q_$settingKey'), children: [
                RadioGroup<PrivacyLevel>(
                  groupValue: current.level,
                  onChanged: (level) {
                    if (level == null || level == current.level) return;
                    if (locked && level != PrivacyLevel.everybody) {
                      showToast(context, s.t('premium_required'));
                      return;
                    }
                    _save(context, ref, current.copyWith(level: level));
                  },
                  child: Column(children: [
                    for (final level in _levelsFor(settingKey))
                      RadioListTile<PrivacyLevel>(
                        value: level,
                        controlAffinity: ListTileControlAffinity.trailing,
                        title: Text(
                          settingKey == 'invites' && level == PrivacyLevel.contacts && current.allowPremium
                              ? s.t('privacy_level_contacts_premium')
                              : s.t('privacy_level_${level.name}'),
                        ),
                        secondary: locked && level != PrivacyLevel.everybody ? Icon(Icons.lock_rounded, size: 18, color: primary) : null,
                      ),
                  ]),
                ),
              ]),
              GroupHint(s.t('privacy_hint_$settingKey')),
              if (settingKey == 'phone' && current.level != PrivacyLevel.everybody) const _NestedSettingTile(settingKey: 'find_phone'),
              if (settingKey == 'status' && current.level != PrivacyLevel.everybody) const _ReadDateTile(),
              if (settingKey == 'calls') const _NestedSettingTile(settingKey: 'p2p'),
              SettingsGroup(title: s.t('privacy_exceptions'), children: [
                if (current.level != PrivacyLevel.everybody)
                  _ExceptionHeader(
                    label: s.t('privacy_always_allow'),
                    onAdd: () => _addUsers(context, ref, current, allow: true),
                  ),
                if (current.level != PrivacyLevel.everybody)
                  for (final id in current.allowUsers)
                    _ExceptionUser(userId: id, onRemove: () => _save(context, ref, current.copyWith(allowUsers: [...current.allowUsers]..remove(id)))),
                if (current.level != PrivacyLevel.everybody)
                  for (final id in current.allowChats)
                    _ExceptionChat(chatId: id, onRemove: () => _save(context, ref, current.copyWith(allowChats: [...current.allowChats]..remove(id)))),
                if (current.level != PrivacyLevel.nobody)
                  _ExceptionHeader(
                    label: s.t('privacy_never_allow'),
                    onAdd: () => _addUsers(context, ref, current, allow: false),
                  ),
                if (current.level != PrivacyLevel.nobody)
                  for (final id in current.restrictUsers)
                    _ExceptionUser(userId: id, onRemove: () => _save(context, ref, current.copyWith(restrictUsers: [...current.restrictUsers]..remove(id)))),
                if (current.level != PrivacyLevel.nobody)
                  for (final id in current.restrictChats)
                    _ExceptionChat(chatId: id, onRemove: () => _save(context, ref, current.copyWith(restrictChats: [...current.restrictChats]..remove(id)))),
              ]),
              GroupHint(s.t('privacy_exceptions_hint')),
            ],
          );
        },
      ),
    );
  }
}

class _ExceptionHeader extends StatelessWidget {
  const _ExceptionHeader({required this.label, required this.onAdd});

  final String label;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        trailing: Text(context.t('privacy_add_users'), style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15)),
        onTap: onAdd,
      );
}

class _ExceptionUser extends ConsumerWidget {
  const _ExceptionUser({required this.userId, required this.onRemove});

  final int userId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(accountProvider).userName(userId);
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 8),
      leading: UserAvatar(userId: userId, size: 36),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(icon: const Icon(Icons.close_rounded), tooltip: context.t('delete'), onPressed: onRemove),
    );
  }
}

class _ExceptionChat extends ConsumerWidget {
  const _ExceptionChat({required this.chatId, required this.onRemove});

  final int chatId;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(accountProvider).chats[chatId]?.title ?? '$chatId';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 8),
      leading: ChatAvatar(chatId: chatId, size: 36),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(icon: const Icon(Icons.close_rounded), tooltip: context.t('delete'), onPressed: onRemove),
    );
  }
}

/// Second setting shown inside another (phone → who can find me; calls → peer-to-peer).
class _NestedSettingTile extends ConsumerWidget {
  const _NestedSettingTile({required this.settingKey});

  final String settingKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final rules = ref.watch(privacyRulesProvider(settingKey)).value;
    return SettingsGroup(title: s.t('privacy_q_$settingKey'), children: [
      ListTile(
        title: Text(s.t('privacy_$settingKey')),
        trailing: Text(rules?.label(s) ?? '…', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15)),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrivacyRulesScreen(settingKey: settingKey))),
      ),
    ]);
  }
}

/// "Hide read time": offered once last seen is hidden from someone.
class _ReadDateTile extends ConsumerWidget {
  const _ReadDateTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(_readDateProvider).value;
    return Column(children: [
      SettingsGroup(children: [
        SwitchListTile(
          title: Text(s.t('privacy_hide_read_time')),
          value: settings != null && !settings.showReadDate,
          onChanged: settings == null
              ? null
              : (hide) async {
                  await guard(
                    context,
                    () => ref.read(accountProvider).send<td.Ok>(td.SetReadDatePrivacySettings(settings: td.ReadDatePrivacySettings(showReadDate: !hide))),
                  );
                  ref.invalidate(_readDateProvider);
                },
        ),
      ]),
      GroupHint(s.t('privacy_hide_read_time_hint')),
    ]);
  }
}
