import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/calls/call_service.dart';
import '../../core/tdlib/td_client.dart' show TdException;
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Call sheet for a person (chat header and profile): Telegram voice/video call, or the SIM when the number is visible.
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
            onTap: () => Navigator.pop(context, 'voice'),
          ),
          ListTile(
            leading: Icon(Icons.videocam_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(s.t('call_video')),
            onTap: () => Navigator.pop(context, 'video'),
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
  if (choice == 'phone') {
    final launched = await launchUrl(Uri(scheme: 'tel', path: '+$phone'));
    if (!launched && context.mounted) showToast(context, s.t('call_phone_failed'));
    return;
  }
  await startTelegramCall(context, user.id, video: choice == 'video');
}

/// Starts a Telegram call; the call screen opens by itself once TDLib reports it.
/// Telegram decides who may be called: the cached profile can still say "no" minutes after the peer allowed calls,
/// so the call is always tried and a refusal (USER_PRIVACY_RESTRICTED) shows the privacy hint.
Future<void> startTelegramCall(BuildContext context, int userId, {bool video = false}) async {
  final s = context.s;
  final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
  final name = account.users[userId]?.firstName ?? '';
  try {
    await CallService.instance.startCall(userId, video: video);
  } on TdException catch (error) {
    if (!context.mounted) return;
    final message = error.message;
    if (message.contains('PRIVACY')) return showToast(context, s.t('call_privacy_restricted', {'name': name}));
    if (message.contains('VIDEO')) return showToast(context, s.t('call_video_unsupported', {'name': name}));
    showToast(context, errorText(context, error));
  }
}
