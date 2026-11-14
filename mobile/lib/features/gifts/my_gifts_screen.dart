import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import 'gift_widgets.dart';

/// Profile ⋮ → My gifts: every gift the user received, with who sees each one and its sender.
class MyGiftsScreen extends StatelessWidget {
  const MyGiftsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: groupedBackground(context),
        appBar: AppBar(title: Text(context.t('gifts_mine'))),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: const [ReceivedGifts()]),
      );
}

/// The gifts this user received: hide all, hide one, or hide who sent it from people opening the profile.
/// Asks to link the account first when it is not linked yet.
class ReceivedGifts extends ConsumerStatefulWidget {
  const ReceivedGifts({super.key});

  @override
  ConsumerState<ReceivedGifts> createState() => _ReceivedGiftsState();
}

class _ReceivedGiftsState extends ConsumerState<ReceivedGifts> {
  /// Received gifts and the "hide all" switch once this account is linked; null = not linked yet.
  late Future<(List<SentGift>, bool)?> _received = _load();

  Future<(List<SentGift>, bool)?> _load() async {
    final api = ref.read(sadoApiProvider);
    if (await api.telegramId() != ref.read(accountProvider).myId) return null;
    return api.receivedGifts();
  }

  void _reload() => setState(() => _received = _load());

  Future<void> _link() async {
    if (await ensureGiftsLinked(context, ref) && mounted) _reload();
  }

  Future<void> _changeVisibility(Future<void> Function() change) async {
    final done = await apiGuard(context, () async {
      await change();
      return true;
    });
    if (done == true && mounted) {
      ref.invalidate(userGiftsProvider(ref.read(accountProvider).myId));
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final api = ref.read(sadoApiProvider);
    return FutureBuilder<(List<SentGift>, bool)?>(
      future: _received,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        }
        final data = snapshot.data;
        if (snapshot.hasError || data == null) {
          return SettingsGroup(title: s.t('gifts_received'), children: [
            ListTile(
              leading: const Icon(Icons.verified_user_rounded),
              title: Text(s.t('gifts_link_to_see')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _link,
            ),
          ]);
        }
        final (received, hideAll) = data;
        return SettingsGroup(title: s.t('gifts_received'), children: [
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_rounded),
            title: Text(s.t('gifts_hide_all')),
            subtitle: Text(s.t('gifts_hide_all_hint')),
            value: hideAll,
            onChanged: (hide) => _changeVisibility(() => api.setAllGiftsHidden(hide)),
          ),
          if (received.isEmpty) ListTile(title: Text(s.t('gifts_received_empty'))),
          for (final gift in received)
            ListTile(
              leading: GiftImage(gift.gift, size: 44),
              title: Text(gift.gift.titleFor(s.locale), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: _status(context, gift, hideAll),
              onTap: () => showGiftDetails(context, gift),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                // Who sent it: hidden from profile visitors (an anonymous sender is hidden already).
                if (!gift.anonymous)
                  IconButton(
                    tooltip: s.t(gift.senderHidden ? 'gifts_sender_show' : 'gifts_sender_hide'),
                    icon: Icon(gift.senderHidden ? Icons.person_off_rounded : Icons.person_rounded),
                    onPressed: () => _changeVisibility(() => api.setGiftSenderHidden(gift.id, !gift.senderHidden)),
                  ),
                // While everything is hidden, single gifts have nothing to switch.
                IconButton(
                  tooltip: s.t(gift.hidden ? 'gifts_show' : 'gifts_hide'),
                  icon: Icon(gift.hidden || hideAll ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                  onPressed: hideAll ? null : () => _changeVisibility(() => api.setGiftHidden(gift.id, !gift.hidden)),
                ),
              ]),
            ),
        ]);
      },
    );
  }

  /// The gift's note, then what profile visitors do not see of it.
  Widget? _status(BuildContext context, SentGift gift, bool hideAll) {
    final s = context.s;
    final lines = [
      if (gift.text.isNotEmpty) gift.text,
      if (gift.hidden || hideAll) s.t('gifts_hidden_state'),
      if (gift.senderHidden && !gift.anonymous) s.t('gifts_sender_hidden_state'),
    ];
    return lines.isEmpty ? null : Text(lines.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}
