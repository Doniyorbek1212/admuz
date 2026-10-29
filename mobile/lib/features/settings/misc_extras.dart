import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../chat/payments.dart' show formatInvoiceAmount;

// ------------------------------------------------------------------ terms of service

/// Telegram's updated terms of service (updateTermsOfService): shown once, accepted with a tap.
Future<void> showTermsOfService(BuildContext context, TelegramAccount account, td.UpdateTermsOfService update) async {
  final s = context.s;
  final terms = update.termsOfService;
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: !terms.showPopup,
    builder: (context) => AlertDialog(
      title: Text(s.t('terms_title')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(terms.text.text),
          if (terms.minUserAge > 0) ...[const SizedBox(height: 8), Text(s.t('terms_min_age', {'n': '${terms.minUserAge}'}), style: const TextStyle(fontWeight: FontWeight.w600))],
        ]),
      ),
      actions: [
        if (!terms.showPopup) TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('later'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('accept'))),
      ],
    ),
  );
  if (accepted == true && context.mounted) {
    await guard(context, () => account.send<td.Ok>(td.AcceptTermsOfService(termsOfServiceId: update.termsOfServiceId)));
    account.pendingTerms.value = null;
  }
}

// ------------------------------------------------------------------ suggested actions

/// Label key and icon for the suggestions Telegram sends (updateSuggestedActions); null = not shown here.
(String, IconData)? suggestedActionLook(td.SuggestedAction action) => switch (action) {
      td.SuggestedActionSetBirthdate() => ('suggest_birthdate', Icons.cake_outlined),
      td.SuggestedActionSetProfilePhoto() => ('suggest_profile_photo', Icons.add_a_photo_outlined),
      td.SuggestedActionCheckPhoneNumber() => ('suggest_check_phone', Icons.phone_iphone_rounded),
      td.SuggestedActionCheckPassword() => ('suggest_check_password', Icons.password_rounded),
      td.SuggestedActionSetPassword() => ('suggest_set_password', Icons.lock_outline_rounded),
      td.SuggestedActionSetLoginEmailAddress() => ('suggest_login_email', Icons.mail_outline_rounded),
      td.SuggestedActionEnableArchiveAndMuteNewChats() => ('suggest_archive_new', Icons.archive_outlined),
      td.SuggestedActionUpgradePremium() || td.SuggestedActionSubscribeToAnnualPremium() || td.SuggestedActionRestorePremium() || td.SuggestedActionExtendPremium() =>
        ('suggest_premium', Icons.workspace_premium_outlined),
      _ => null,
    };

/// Banner above the chat list with Telegram's first suggestion for the account; dismissing hides it for good.
class SuggestedActionBanner extends ConsumerWidget {
  const SuggestedActionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder<List<td.SuggestedAction>>(
      valueListenable: account.suggestedActions,
      builder: (context, actions, _) {
        final action = actions.where((a) => suggestedActionLook(a) != null).firstOrNull;
        if (action == null) return const SizedBox.shrink();
        final (key, icon) = suggestedActionLook(action)!;
        return Material(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
          child: ListTile(
            dense: true,
            leading: Icon(icon),
            title: Text(context.t(key)),
            trailing: IconButton(
              tooltip: context.t('hide'),
              icon: const Icon(Icons.close_rounded),
              onPressed: () async {
                await account.send<td.Ok>(td.HideSuggestedAction(action: action)).catchError((Object _) => const td.Ok());
                account.suggestedActions.value = [...account.suggestedActions.value]..remove(action);
              },
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ links

/// Bot login links (inline "Log in" buttons and t.me login URLs): asks before logging in and opens the result.
/// Returns false when the link is a plain one that the caller should open itself.
Future<bool> openExternalLoginLink(BuildContext context, TelegramAccount account, String link) async {
  td.LoginUrlInfo? info;
  try {
    info = await account.send<td.LoginUrlInfo>(td.GetExternalLinkInfo(link: link));
  } on TdException {
    return false;
  }
  if (!context.mounted) return true;
  switch (info) {
    case td.LoginUrlInfoOpen(:final url, :final skipConfirmation):
      if (url == link) return false;
      if (!skipConfirmation && !await confirm(context, title: context.t('open_link'), message: url)) return true;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    case td.LoginUrlInfoRequestConfirmation(:final domain, :final botUserId, :final requestWriteAccess):
      final s = context.s;
      var allowWrite = false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialog) => AlertDialog(
            title: Text(s.t('oauth_title', {'site': domain})),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(s.t('oauth_warning')),
              if (requestWriteAccess)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: allowWrite,
                  title: Text(s.t('oauth_write_access', {'bot': account.userName(botUserId)})),
                  onChanged: (v) => setDialog(() => allowWrite = v ?? false),
                ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('oauth_allow'))),
            ],
          ),
        ),
      );
      if (ok != true || !context.mounted) return true;
      final url = await guard(context, () => account.send<td.HttpUrl>(td.GetExternalLink(link: link, allowWriteAccess: allowWrite)));
      if (url != null) await launchUrl(Uri.parse(url.url), mode: LaunchMode.externalApplication);
  }
  return true;
}

/// A shareable t.me (or tg://) link to something in Telegram, built by TDLib.
Future<void> copyInternalLink(BuildContext context, TelegramAccount account, td.InternalLinkType type) async {
  final link = await guard(context, () => account.send<td.HttpUrl>(td.GetInternalLink(type: type, isHttp: true)));
  if (link == null || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: link.url));
  if (context.mounted) showToast(context, context.t('link_copied'));
}

// ------------------------------------------------------------------ collectibles (Fragment)

/// When and for how much a username or number was bought on Fragment.
Future<void> showCollectibleInfo(BuildContext context, TelegramAccount account, td.CollectibleItemType type, String label) async {
  final info = await guard(context, () => account.send<td.CollectibleItemInfo>(td.GetCollectibleItemInfo(type: type)));
  if (info == null || !context.mounted) return;
  final s = context.s;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(label),
      content: Text(s.t('collectible_bought', {
        'date': formatChatTime(info.purchaseDate, s.locale),
        'price': formatInvoiceAmount(info.amount, info.currency),
        'crypto': '${info.cryptocurrencyAmount / 1e9} ${info.cryptocurrency}',
      })),
      actions: [
        TextButton(onPressed: () => launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication), child: const Text('Fragment')),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok'))),
      ],
    ),
  );
}

// ------------------------------------------------------------------ small data lookups

final currentWeatherProvider = FutureProvider.autoDispose.family<td.CurrentWeather?, (double, double)>((ref, point) async {
  try {
    return await ref.watch(accountProvider).send<td.CurrentWeather>(
          td.GetCurrentWeather(location: td.Location(latitude: point.$1, longitude: point.$2, horizontalAccuracy: 0)),
        );
  } on TdException {
    return null;
  }
});

final _ratesProvider = FutureProvider.autoDispose<Map<String, double>>((ref) async {
  try {
    final rates = await ref.watch(accountProvider).send<td.CurrencyExchangeRates>(const td.GetCurrencyExchangeRates());
    return {for (final r in rates.rates) r.currency: r.rate};
  } on TdException {
    return const {};
  }
});

/// "≈ $12.40" next to a price in another currency (Telegram's own USD rates); empty when unknown.
class UsdHint extends ConsumerWidget {
  const UsdHint({super.key, required this.amount, required this.currency});

  final int amount;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rate = ref.watch(_ratesProvider).value?[currency];
    if (currency == 'USD' || rate == null || rate <= 0) return const SizedBox.shrink();
    return Text('≈ \$${(amount / 100 / rate).toStringAsFixed(2)}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13));
  }
}

/// Native name of a country from Telegram's list (e.g. "O'zbekiston"), or the code itself.
Future<String> countryName(TelegramAccount account, String code) async {
  try {
    final info = await account.send<td.CountryInfo>(td.GetCountry(countryCode: code));
    return info.name.isNotEmpty ? info.name : code;
  } on TdException {
    return code;
  }
}

/// A value from Telegram's application config (feature limits, bot usernames…), or null.
Future<Object?> appConfigValue(TelegramAccount account, String key) async {
  try {
    final config = await account.send<td.JsonValue>(const td.GetApplicationConfig());
    if (config case td.JsonValueObject(:final members)) {
      for (final m in members) {
        if (m.key == key) {
          return switch (m.value) {
            td.JsonValueString(:final value) => value,
            td.JsonValueNumber(:final value) => value,
            td.JsonValueBoolean(:final value) => value,
            _ => null,
          };
        }
      }
    }
  } on TdException catch (error) {
    debugPrint('app config unavailable: $error');
  }
  return null;
}

/// Thumbs up/down under a voice message transcript; Telegram uses it to improve recognition.
class SpeechRatingRow extends ConsumerStatefulWidget {
  const SpeechRatingRow({super.key, required this.message});

  final td.Message message;

  @override
  ConsumerState<SpeechRatingRow> createState() => _SpeechRatingRowState();
}

class _SpeechRatingRowState extends ConsumerState<SpeechRatingRow> {
  bool _rated = false;

  Future<void> _rate(bool good) async {
    setState(() => _rated = true);
    await ref
        .read(accountProvider)
        .send<td.Ok>(td.RateSpeechRecognition(chatId: widget.message.chatId, messageId: widget.message.id, isGood: good))
        .catchError((Object _) => const td.Ok());
  }

  @override
  Widget build(BuildContext context) {
    if (_rated) return Text(context.t('speech_rated'), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.thumb_up_alt_outlined), onPressed: () => _rate(true)),
      IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.thumb_down_alt_outlined), onPressed: () => _rate(false)),
    ]);
  }
}

/// Invisible watcher in the chat list: opens new terms of service as soon as Telegram sends them.
class TermsOfServiceWatcher extends ConsumerStatefulWidget {
  const TermsOfServiceWatcher({super.key});

  @override
  ConsumerState<TermsOfServiceWatcher> createState() => _TermsOfServiceWatcherState();
}

class _TermsOfServiceWatcherState extends ConsumerState<TermsOfServiceWatcher> {
  late final TelegramAccount _account = ref.read(accountProvider);
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _account.pendingTerms.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _account.pendingTerms.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    final terms = _account.pendingTerms.value;
    if (terms == null || _showing || !mounted) return;
    _showing = true;
    await showTermsOfService(context, _account, terms);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
