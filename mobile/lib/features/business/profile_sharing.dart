import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';

/// Whether the user agreed to share their Telegram name, username and phone with the Sado server
/// (null: not asked yet). Without consent the server account stays anonymous.
final profileSharingProvider = NotifierProvider<ProfileSharingNotifier, bool?>(ProfileSharingNotifier.new);

class ProfileSharingNotifier extends Notifier<bool?> {
  static const _key = 'sado.profileSharing';

  @override
  bool? build() => ref.watch(sharedPreferencesProvider).getBool(_key);

  Future<void> set(bool share) async {
    await ref.read(sharedPreferencesProvider).setBool(_key, share);
    state = share;
    final api = ref.read(sadoApiProvider);
    if (!api.configured) return;
    try {
      if (share) {
        final me = ref.read(meProvider);
        if (me != null) await api.saveProfile(profileOf(me));
      } else {
        await api.deleteProfile();
      }
    } on ApiException catch (error) {
      debugPrint('profile sharing sync failed: $error');
    }
  }
}

Profile profileOf(td.User me) => Profile(
      firstName: me.firstName,
      lastName: me.lastName,
      username: me.usernames?.activeUsernames.firstOrNull ?? '',
      phone: me.phoneNumber,
    );

/// Sends the current profile when sharing is on; called when the signed-in user changes.
Future<void> syncSharedProfile(WidgetRef ref, td.User me) async {
  final api = ref.read(sadoApiProvider);
  if (ref.read(profileSharingProvider) != true || !api.configured) return;
  try {
    await api.saveProfile(profileOf(me));
  } on ApiException catch (error) {
    debugPrint('profile sync failed: $error');
  }
}

/// Asks once whether to share the profile with the Sado server.
Future<void> askProfileSharingOnce(BuildContext context, WidgetRef ref) async {
  if (ref.read(profileSharingProvider) != null || !ref.read(sadoApiProvider).configured) return;
  final s = context.s;
  final share = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.verified_user_rounded),
      title: Text(s.t('consent_title')),
      content: Text(s.t('consent_text')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('consent_no'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('consent_yes'))),
      ],
    ),
  );
  if (share != null) await ref.read(profileSharingProvider.notifier).set(share);
}
