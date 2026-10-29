import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'privacy_screen.dart' show promptText;

/// Forgotten cloud password with a recovery email: emailed code → new password (empty removes it).
Future<td.PasswordState?> recoverForgottenPassword(BuildContext context, WidgetRef ref) async {
  final s = context.s;
  final account = ref.read(accountProvider);
  final info = await guard(context, () => account.send<td.EmailAddressAuthenticationCodeInfo>(const td.RequestPasswordRecovery()));
  if (info == null || !context.mounted) return null;
  final code = await promptText(context, title: s.t('email_code_title'), label: s.t('recovery_code_sent', {'email': info.emailAddressPattern}), keyboard: TextInputType.number);
  if (code == null || !context.mounted) return null;
  final valid = await guard(context, () => account.send<td.Ok>(td.CheckPasswordRecoveryCode(recoveryCode: code.trim())));
  if (valid == null || !context.mounted) return null;
  final form = await Navigator.of(context).push<(String, String, String, String)>(
    MaterialPageRoute(builder: (_) => const PasswordForm(askOld: false, askEmail: false)),
  );
  if (form == null || !context.mounted) return null;
  return guard(context, () => account.send<td.PasswordState>(td.RecoverPassword(recoveryCode: code.trim(), newPassword: form.$2, newHint: form.$3)));
}

/// No recovery email: Telegram removes the password after a waiting period (or at once for long-unused passwords).
Future<void> resetForgottenPassword(BuildContext context, WidgetRef ref) async {
  final s = context.s;
  final ok = await confirm(context, title: s.t('two_step_reset'), message: s.t('two_step_reset_confirm'), destructive: true);
  if (!ok || !context.mounted) return;
  final result = await guard(context, () => ref.read(accountProvider).send<td.ResetPasswordResult>(const td.ResetPassword()));
  if (result == null || !context.mounted) return;
  showToast(context, switch (result) {
    td.ResetPasswordResultOk() => s.t('two_step_reset_done'),
    td.ResetPasswordResultPending(:final pendingResetDate) => s.t('two_step_reset_pending', {'date': formatChatTime(pendingResetDate, s.locale)}),
    td.ResetPasswordResultDeclined(:final retryDate) => s.t('two_step_reset_declined', {'date': formatChatTime(retryDate, s.locale)}),
    _ => s.t('done'),
  });
}

Future<td.PasswordState?> cancelPasswordReset(BuildContext context, WidgetRef ref) async {
  final account = ref.read(accountProvider);
  final ok = await guard(context, () => account.send<td.Ok>(const td.CancelPasswordReset()));
  if (ok == null) return null;
  return account.passwordState();
}

/// Shows the full recovery email (TDLib only hands out a pattern without the password).
Future<void> showRecoveryEmail(BuildContext context, WidgetRef ref) async {
  final s = context.s;
  final password = await promptText(context, title: s.t('two_step_current'), label: s.t('password'), obscure: true);
  if (password == null || !context.mounted) return;
  final email = await guard(context, () => ref.read(accountProvider).send<td.RecoveryEmailAddress>(td.GetRecoveryEmailAddress(password: password)));
  if (email == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('recovery_email')),
      content: SelectableText(email.recoveryEmailAddress.isEmpty ? s.t('state_off') : email.recoveryEmailAddress),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
    ),
  );
}

/// Tiles for a recovery email that still waits for its code: enter, resend, or drop it.
List<Widget> pendingRecoveryEmailTiles(BuildContext context, WidgetRef ref, td.EmailAddressAuthenticationCodeInfo pending, void Function(td.PasswordState) onState) {
  final s = context.s;
  final account = ref.read(accountProvider);
  return [
    ListTile(
      leading: const Icon(Icons.mark_email_unread_rounded),
      title: Text(s.t('recovery_email_pending')),
      subtitle: Text(pending.emailAddressPattern),
      onTap: () async {
        final code = await promptText(context, title: s.t('email_code_title'), label: s.t('email_code_sent', {'email': pending.emailAddressPattern}), keyboard: TextInputType.number);
        if (code == null || !context.mounted) return;
        final state = await guard(context, () => account.confirmRecoveryEmail(code.trim()));
        if (state != null) onState(state);
      },
    ),
    ListTile(
      leading: const Icon(Icons.forward_to_inbox_rounded),
      title: Text(s.t('resend_code')),
      onTap: () async {
        final state = await guard(context, () => account.send<td.PasswordState>(const td.ResendRecoveryEmailAddressCode()));
        if (state == null || !context.mounted) return;
        onState(state);
        showToast(context, s.t('code_resent'));
      },
    ),
    ListTile(
      leading: const Icon(Icons.cancel_schedule_send_rounded),
      title: Text(s.t('recovery_email_cancel')),
      onTap: () async {
        final state = await guard(context, () => account.send<td.PasswordState>(const td.CancelRecoveryEmailAddressVerification()));
        if (state != null) onState(state);
      },
    ),
  ];
}

class PasswordForm extends StatefulWidget {
  const PasswordForm({super.key, required this.askOld, required this.askEmail});

  final bool askOld;
  final bool askEmail;

  @override
  State<PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<PasswordForm> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _repeat = TextEditingController();
  final _hint = TextEditingController();
  final _email = TextEditingController();
  String? _error;

  @override
  void dispose() {
    for (final c in [_old, _new, _repeat, _hint, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final s = context.s;
    if (_new.text.length < 4) {
      setState(() => _error = s.t('password_too_short'));
    } else if (_new.text != _repeat.text) {
      setState(() => _error = s.t('passwords_mismatch'));
    } else if (_hint.text.trim() == _new.text) {
      setState(() => _error = s.t('hint_equals_password'));
    } else {
      Navigator.pop(context, (_old.text, _new.text, _hint.text.trim(), _email.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('two_step'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.askOld)
            TextField(controller: _old, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_current'))),
          TextField(controller: _new, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_new'))),
          TextField(controller: _repeat, obscureText: true, decoration: InputDecoration(labelText: s.t('two_step_repeat'))),
          TextField(controller: _hint, decoration: InputDecoration(labelText: s.t('two_step_hint'))),
          if (widget.askEmail)
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: InputDecoration(labelText: s.t('recovery_email'))),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 20),
          FilledButton(onPressed: _submit, child: Text(s.t('save'))),
        ],
      ),
    );
  }
}
