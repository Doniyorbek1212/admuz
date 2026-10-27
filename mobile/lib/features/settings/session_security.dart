import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/qr_scan_screen.dart';

/// The unconfirmed login's session id; Telegram's update does not carry it, the session list does.
Future<int?> _unconfirmedSessionId(TelegramAccount account) async {
  final sessions = await account.send<td.Sessions>(const td.GetActiveSessions());
  return sessions.sessions.where((s) => s.isUnconfirmed).firstOrNull?.id;
}

/// Confirms ("it's me") or terminates ("not me") the newest unconfirmed login.
Future<void> answerUnconfirmedSession(BuildContext context, TelegramAccount account, {required bool itsMe}) async {
  final done = await guard(context, () async {
    final id = await _unconfirmedSessionId(account);
    if (id != null) {
      await account.send<td.Ok>(itsMe ? td.ConfirmSession(sessionId: id) : td.TerminateSession(sessionId: id));
    }
    return true;
  });
  if (done != true) return;
  account.unconfirmedSession.value = null;
  if (context.mounted) showToast(context, context.t(itsMe ? 'session_confirmed' : 'session_terminated'));
}

/// "New login from …. Is it you?" card above the chat list while a login waits for confirmation.
class UnconfirmedSessionBanner extends ConsumerWidget {
  const UnconfirmedSessionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder(
      valueListenable: account.unconfirmedSession,
      builder: (context, session, _) {
        if (session == null) return const SizedBox.shrink();
        final s = context.s;
        final theme = Theme.of(context);
        final where = [session.deviceModel, session.location].where((x) => x.isNotEmpty).join(', ');
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.t('session_new_login'), style: TextStyle(fontWeight: FontWeight.w700, color: theme.colorScheme.onErrorContainer)),
              const SizedBox(height: 4),
              Text(s.t('session_is_it_you', {'where': where}), style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => answerUnconfirmedSession(context, account, itsMe: false),
                  child: Text(s.t('session_not_me'), style: TextStyle(color: theme.colorScheme.error)),
                ),
                TextButton(onPressed: () => answerUnconfirmedSession(context, account, itsMe: true), child: Text(s.t('session_its_me'))),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

/// Settings → Devices → "Link desktop device": scan the QR shown by Telegram Desktop/Web.
Future<bool> linkDesktopDevice(BuildContext context, TelegramAccount account) async {
  final s = context.s;
  final link = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => QrScanScreen(hint: s.t('qr_login_hint'))));
  if (link == null || !context.mounted) return false;
  if (!link.startsWith('tg://login?token=')) {
    showToast(context, s.t('qr_login_wrong'));
    return false;
  }
  final session = await guard(context, () => account.send<td.Session>(td.ConfirmQrCodeAuthentication(link: link)));
  if (session == null || !context.mounted) return false;
  showToast(context, s.t('qr_login_done', {'device': session.deviceModel}));
  return true;
}

/// QR scanning needs a camera plugin that exists only on phones.
bool get canScanQr => Platform.isAndroid || Platform.isIOS;

/// Per-session switches: may this device take calls and secret chats; terminate it.
Future<void> showSessionSheet(BuildContext context, TelegramAccount account, td.Session session, {required VoidCallback onChanged}) async {
  final s = context.s;
  var calls = session.canAcceptCalls;
  var secret = session.canAcceptSecretChats;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(session.deviceModel, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${session.applicationName} ${session.applicationVersion} · ${session.platform} ${session.systemVersion}\n'
                '${session.location.isNotEmpty ? session.location : session.ipAddress}'),
            isThreeLine: true,
          ),
          if (session.isUnconfirmed)
            ListTile(
              leading: const Icon(Icons.verified_user_rounded),
              title: Text(s.t('session_its_me')),
              onTap: () async {
                await guard(context, () => account.send<td.Ok>(td.ConfirmSession(sessionId: session.id)));
                account.unconfirmedSession.value = null;
                onChanged();
                if (context.mounted) Navigator.pop(context);
              },
            ),
          SwitchListTile(
            title: Text(s.t('session_accept_calls')),
            value: calls,
            onChanged: (on) async {
              final ok = await guard(context, () async {
                await account.send<td.Ok>(td.ToggleSessionCanAcceptCalls(sessionId: session.id, canAcceptCalls: on));
                return true;
              });
              if (ok == true) setState(() => calls = on);
              onChanged();
            },
          ),
          SwitchListTile(
            title: Text(s.t('session_accept_secret')),
            value: secret,
            onChanged: (on) async {
              final ok = await guard(context, () async {
                await account.send<td.Ok>(td.ToggleSessionCanAcceptSecretChats(sessionId: session.id, canAcceptSecretChats: on));
                return true;
              });
              if (ok == true) setState(() => secret = on);
              onChanged();
            },
          ),
          if (!session.isCurrent)
            ListTile(
              leading: Icon(Icons.logout_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('terminate'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                await guard(context, () => account.send<td.Ok>(td.TerminateSession(sessionId: session.id)));
                onChanged();
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ]),
      ),
    ),
  );
}
