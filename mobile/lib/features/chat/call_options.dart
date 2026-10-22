import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/strings.dart';
import '../../widgets/common.dart';

/// Call sheet for a person (chat header and profile). Voice/video calls over Telegram are not built
/// yet (they need the tgcalls media stack), so they say so; a visible phone number can still be
/// dialled over the SIM.
Future<void> showCallOptions(BuildContext context, td.User user) async {
  final s = context.s;
  final phone = user.phoneNumber;
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.call_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(s.t('call_voice')),
            subtitle: Text(s.t('calls_soon')),
            onTap: () => Navigator.pop(context, 'soon'),
          ),
          ListTile(
            leading: Icon(Icons.videocam_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(s.t('call_video')),
            subtitle: Text(s.t('calls_soon')),
            onTap: () => Navigator.pop(context, 'soon'),
          ),
          if (phone.isNotEmpty)
            ListTile(
              leading: Icon(Icons.sim_card_rounded, color: Theme.of(context).hintColor),
              title: Text(s.t('call_phone')),
              subtitle: Text('+$phone'),
              onTap: () => Navigator.pop(context, 'phone'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'soon') return showToast(context, s.t('calls_soon'));
  final launched = await launchUrl(Uri(scheme: 'tel', path: '+$phone'));
  if (!launched && context.mounted) showToast(context, s.t('call_phone_failed'));
}
