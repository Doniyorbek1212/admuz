import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/strings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

/// "Log in with Telegram" on a website or app (t.me/oauth link): shows who asks, from where, and what
/// they want; the user picks the code shown on the site when asked, then allows or declines.
Future<void> handleOauthLink(BuildContext context, TelegramAccount account, String url) async {
  final info = await guard(context, () => account.send<td.OauthLinkInfo>(td.GetOauthLinkInfo(url: url, inAppOrigin: '')));
  if (info == null || !context.mounted) return;
  final s = context.s;
  var matchCode = '';
  if (info.matchCodeFirst && info.matchCodes.isNotEmpty) {
    final picked = await _pickMatchCode(context, info.matchCodes);
    if (!context.mounted) return;
    if (picked == null) {
      await guard(context, () => account.send<td.Ok>(td.DeclineOauthRequest(url: url)));
      return;
    }
    // A wrong code ends the request on Telegram's side.
    final ok = await guard(context, () async {
      await account.send<td.Ok>(td.CheckOauthRequestMatchCode(url: url, matchCode: picked));
      return true;
    });
    if (ok != true || !context.mounted) return;
    matchCode = picked;
  }
  var allowWrite = info.requestWriteAccess;
  var allowPhone = false;
  final app = info.verifiedAppName.isNotEmpty ? info.verifiedAppName : s.t('oauth_unverified');
  final accept = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(s.t('oauth_title', {'site': info.domain}), style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(app, textAlign: TextAlign.center, style: TextStyle(color: info.verifiedAppName.isEmpty ? Theme.of(context).colorScheme.error : null)),
            const SizedBox(height: 12),
            for (final (icon, value) in [
              (Icons.devices_rounded, [info.browser, info.platform].where((v) => v.isNotEmpty).join(' · ')),
              (Icons.place_outlined, [info.location, info.ipAddress].where((v) => v.isNotEmpty).join(' · ')),
            ])
              if (value.isNotEmpty) ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(icon), title: Text(value)),
            Text(s.t('oauth_warning'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
            if (info.requestWriteAccess && info.botUserId != 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: allowWrite,
                title: Text(s.t('oauth_write_access', {'bot': account.userName(info.botUserId)})),
                onChanged: (v) => setSheet(() => allowWrite = v ?? false),
              ),
            if (info.requestPhoneNumberAccess)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: allowPhone,
                title: Text(s.t('oauth_phone_access')),
                onChanged: (v) => setSheet(() => allowPhone = v ?? false),
              ),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('oauth_allow'))),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('decline'))),
          ]),
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (accept != true) {
    await guard(context, () => account.send<td.Ok>(td.DeclineOauthRequest(url: url)));
    return;
  }
  if (!info.matchCodeFirst && info.matchCodes.isNotEmpty) {
    final picked = await _pickMatchCode(context, info.matchCodes);
    if (picked == null || !context.mounted) return;
    matchCode = picked;
  }
  final result = await guard(
    context,
    () => account.send<td.HttpUrl>(td.AcceptOauthRequest(url: url, matchCode: matchCode, allowWriteAccess: allowWrite, allowPhoneNumberAccess: allowPhone)),
  );
  if (result == null || !context.mounted) return;
  if (result.url.isEmpty) {
    showToast(context, s.t('oauth_done', {'site': info.domain}));
  } else {
    await launchUrl(Uri.parse(result.url), mode: LaunchMode.externalApplication);
  }
}

/// The site shows one code; picking the same one here proves the request comes from that screen.
Future<String?> _pickMatchCode(BuildContext context, List<String> codes) {
  final s = context.s;
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s.t('oauth_match_code'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
            for (final code in codes)
              OutlinedButton(onPressed: () => Navigator.pop(context, code), child: Text(code, style: const TextStyle(fontSize: 22, letterSpacing: 2))),
          ]),
        ]),
      ),
    ),
  );
}
