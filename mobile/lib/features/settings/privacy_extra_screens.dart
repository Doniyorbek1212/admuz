import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'privacy_screen.dart';

final _autoDeleteProvider = FutureProvider.autoDispose<int>((ref) async {
  final result = await ref.watch(accountProvider).send<td.MessageAutoDeleteTime>(const td.GetDefaultMessageAutoDeleteTime());
  return result.time;
});

/// Settings → Privacy → Auto-delete messages: off / day / week / month, or a custom period.
class AutoDeleteScreen extends ConsumerWidget {
  const AutoDeleteScreen({super.key});

  static const _day = 86400;

  Future<void> _set(BuildContext context, WidgetRef ref, int seconds) async {
    await guard(
      context,
      () => ref.read(accountProvider).send<td.Ok>(td.SetDefaultMessageAutoDeleteTime(messageAutoDeleteTime: td.MessageAutoDeleteTime(time: seconds))),
    );
    ref.invalidate(_autoDeleteProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(_autoDeleteProvider).value;
    const presets = [0, _day, 7 * _day, 31 * _day];
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('auto_delete_messages'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Icon(Icons.timer_outlined, size: 80, color: Color(0xFFF5B830))),
          SettingsGroup(title: s.t('auto_delete_timer'), children: [
            RadioGroup<int>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) _set(context, ref, v);
              },
              child: Column(children: [
                for (final seconds in presets)
                  RadioListTile<int>(
                    value: seconds,
                    controlAffinity: ListTileControlAffinity.trailing,
                    title: Text(seconds == 0 ? s.t('state_off') : s.t('auto_delete_after', {'period': autoDeleteLabel(seconds, s)})),
                  ),
                if (current != null && !presets.contains(current))
                  RadioListTile<int>(
                    value: current,
                    controlAffinity: ListTileControlAffinity.trailing,
                    title: Text(s.t('auto_delete_after', {'period': autoDeleteLabel(current, s)})),
                  ),
              ]),
            ),
            ListTile(
              title: Text(s.t('auto_delete_custom')),
              onTap: () async {
                final options = {
                  for (final days in const [2, 3, 4, 5, 6, 14, 21, 60, 90, 180, 365]) days * _day: autoDeleteLabel(days * _day, s),
                };
                final chosen = await pickOption(context, s.t('auto_delete_custom'), options, current);
                if (chosen != null && context.mounted) await _set(context, ref, chosen);
              },
            ),
          ]),
          GroupHint(s.t('auto_delete_hint')),
        ],
      ),
    );
  }
}

final newChatPrivacyProvider = FutureProvider.autoDispose<td.NewChatPrivacySettings>(
  (ref) => ref.watch(accountProvider).send<td.NewChatPrivacySettings>(const td.GetNewChatPrivacySettings()),
);

/// Settings → Privacy → Messages: who may start a chat with me (contacts-and-Premium needs Premium).
class NewChatPrivacyScreen extends ConsumerWidget {
  const NewChatPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final current = ref.watch(newChatPrivacyProvider).value;
    final isPremium = ref.watch(meProvider)?.isPremium ?? false;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('privacy_messages'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('privacy_q_messages'), children: [
            RadioGroup<bool>(
              groupValue: current?.allowNewChatsFromUnknownUsers,
              onChanged: (everybody) async {
                if (everybody == null || current == null) return;
                if (!everybody && !isPremium) {
                  showToast(context, s.t('premium_required'));
                  return;
                }
                await guard(
                  context,
                  () => ref.read(accountProvider).send<td.Ok>(td.SetNewChatPrivacySettings(
                        settings: td.NewChatPrivacySettings(
                          allowNewChatsFromUnknownUsers: everybody,
                          incomingPaidMessageStarCount: current.incomingPaidMessageStarCount,
                        ),
                      )),
                );
                ref.invalidate(newChatPrivacyProvider);
              },
              child: Column(children: [
                RadioListTile<bool>(value: true, controlAffinity: ListTileControlAffinity.trailing, title: Text(s.t('privacy_level_everybody'))),
                RadioListTile<bool>(
                  value: false,
                  controlAffinity: ListTileControlAffinity.trailing,
                  title: Text(s.t('privacy_level_contacts_premium')),
                  secondary: isPremium ? null : Icon(Icons.lock_rounded, size: 18, color: primary),
                ),
              ]),
            ),
          ]),
          GroupHint(s.t('privacy_hint_messages')),
        ],
      ),
    );
  }
}

final _giftSettingsProvider = FutureProvider.autoDispose<td.GiftSettings>((ref) async {
  final account = ref.watch(accountProvider);
  final info = await account.send<td.UserFullInfo>(td.GetUserFullInfo(userId: account.myId));
  return info.giftSettings;
});

/// Settings → Privacy → Gifts: gift button in chats and which gift kinds may be sent to me.
class GiftPrivacyScreen extends ConsumerWidget {
  const GiftPrivacyScreen({super.key});

  Future<void> _save(BuildContext context, WidgetRef ref, td.GiftSettings next) async {
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetGiftSettings(settings: next)));
    ref.invalidate(_giftSettingsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final settings = ref.watch(_giftSettingsProvider);
    final isPremium = ref.watch(meProvider)?.isPremium ?? false;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('privacy_gifts'))),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (current) {
          final types = current.acceptedGiftTypes;
          td.GiftSettings withTypes({bool? unlimited, bool? limited, bool? upgraded, bool? channels, bool? premium}) => td.GiftSettings(
                showGiftButton: current.showGiftButton,
                acceptedGiftTypes: td.AcceptedGiftTypes(
                  unlimitedGifts: unlimited ?? types.unlimitedGifts,
                  limitedGifts: limited ?? types.limitedGifts,
                  upgradedGifts: upgraded ?? types.upgradedGifts,
                  giftsFromChannels: channels ?? types.giftsFromChannels,
                  premiumSubscription: premium ?? types.premiumSubscription,
                ),
              );
          // Only Premium users may refuse gift kinds, as in Telegram.
          ValueChanged<bool>? gate(td.GiftSettings Function(bool) build) =>
              isPremium ? (on) => _save(context, ref, build(on)) : (_) => showToast(context, s.t('premium_required'));
          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              SettingsGroup(children: [
                SwitchListTile(
                  title: Text(s.t('gift_button')),
                  value: current.showGiftButton,
                  onChanged: (on) => _save(context, ref, td.GiftSettings(showGiftButton: on, acceptedGiftTypes: types)),
                ),
              ]),
              GroupHint(s.t('gift_button_hint')),
              SettingsGroup(title: s.t('gift_types'), children: [
                SwitchListTile(title: Text(s.t('gift_limited')), value: types.limitedGifts, onChanged: gate((on) => withTypes(limited: on))),
                SwitchListTile(title: Text(s.t('gift_unlimited')), value: types.unlimitedGifts, onChanged: gate((on) => withTypes(unlimited: on))),
                SwitchListTile(title: Text(s.t('gift_unique')), value: types.upgradedGifts, onChanged: gate((on) => withTypes(upgraded: on))),
                SwitchListTile(title: Text(s.t('gift_channels')), value: types.giftsFromChannels, onChanged: gate((on) => withTypes(channels: on))),
                SwitchListTile(title: Text(s.t('gift_premium')), value: types.premiumSubscription, onChanged: gate((on) => withTypes(premium: on))),
              ]),
              GroupHint(s.t('gift_types_hint')),
            ],
          );
        },
      ),
    );
  }
}

final _websitesProvider = FutureProvider.autoDispose<List<td.ConnectedWebsite>>((ref) async {
  final result = await ref.watch(accountProvider).send<td.ConnectedWebsites>(const td.GetConnectedWebsites());
  return result.websites;
});

/// Settings → Privacy → Logged in with Telegram: connected websites, disconnect one or all.
class ConnectedWebsitesScreen extends ConsumerWidget {
  const ConnectedWebsitesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final sites = ref.watch(_websitesProvider);
    final account = ref.read(accountProvider);
    final error = Theme.of(context).colorScheme.error;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('connected_websites'))),
      body: sites.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errorText(context, e))),
        data: (list) => ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            if (list.isNotEmpty) ...[
              SettingsGroup(children: [
                ListTile(
                  leading: Icon(Icons.front_hand_outlined, color: error),
                  title: Text(s.t('disconnect_all_websites'), style: TextStyle(color: error)),
                  onTap: () async {
                    final ok = await confirm(context, title: s.t('disconnect_all_websites'), destructive: true);
                    if (!ok || !context.mounted) return;
                    await guard(context, () => account.send<td.Ok>(const td.DisconnectAllWebsites()));
                    ref.invalidate(_websitesProvider);
                  },
                ),
              ]),
              GroupHint(s.t('connected_websites_hint')),
            ],
            if (list.isEmpty)
              EmptyState(icon: Icons.language_rounded, title: s.t('no_connected_websites'))
            else
              SettingsGroup(title: s.t('connected_websites_list'), children: [
                for (final site in list)
                  ListTile(
                    leading: UserAvatar(userId: site.botUserId, size: 40),
                    title: Text(site.domainName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${account.userName(site.botUserId)}, ${site.browser}, ${site.platform}\n${site.ipAddress} — ${site.location}'),
                    isThreeLine: true,
                    trailing: Text(formatChatTime(site.lastActiveDate, s.locale), style: TextStyle(color: hint, fontSize: 12.5)),
                    onTap: () async {
                      final ok = await confirm(context, title: site.domainName, message: s.t('disconnect_website_confirm'), confirmLabel: s.t('disconnect'), destructive: true);
                      if (!ok || !context.mounted) return;
                      await guard(context, () => account.send<td.Ok>(td.DisconnectWebsite(websiteId: site.id)));
                      ref.invalidate(_websitesProvider);
                    },
                  ),
              ]),
          ],
        ),
      ),
    );
  }
}
