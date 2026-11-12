import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/store_rules.dart';
import '../../core/api/sado_api.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart';
import '../gifts/gift_widgets.dart';
import '../gifts/topup_screen.dart';

/// Shape the server accepts for a UZARO @name (2–32 chars; it lowercases and checks reserved words itself).
/// Names under 5 characters are sold for the UZARO balance (USERNAME_PAID on claim).
final uzaroNamePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{1,31}$');

/// Contact links are refreshed this long; Telegram username links never expire.
const _usernameLinkTtl = Duration(days: 30);

/// My UZARO @name, or null. Loading it also refreshes the contact link others use to open me.
final myUzaroNameProvider = FutureProvider.autoDispose<String?>((ref) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return null;
  try {
    final name = await api.myUzaroUsername();
    if (name != null) unawaited(refreshUzaroContact(api, ref.read(accountProvider)));
    return name;
  } on ApiException {
    return null;
  }
});

/// The UZARO @name of a Telegram user, for their profile; null when none or the server is unreachable.
final uzaroNameOfProvider = FutureProvider.autoDispose.family<String?, int>((ref, telegramId) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return null;
  try {
    return await api.uzaroUsernameOf(telegramId);
  } on ApiException {
    return null;
  }
});

/// Uploads this account's current t.me link path (`contact/TOKEN` or the Telegram username).
Future<void> refreshUzaroContact(SadoApi api, TelegramAccount account) async {
  try {
    final link = await account.send<td.UserLink>(const td.GetUserLink());
    final path = Uri.tryParse(link.url)?.path.replaceFirst('/', '') ?? '';
    if (path.isEmpty) return;
    final ttl = link.expiresIn > 0 ? link.expiresIn : _usernameLinkTtl.inSeconds;
    await api.setUzaroContact(path, ttl);
  } on ApiException catch (error) {
    debugPrint('uzaro contact refresh failed: $error');
  } on TdException catch (error) {
    debugPrint('uzaro contact link unavailable: $error');
  }
}

/// The private chat a UZARO @name leads to. TDLib can open a user only once it knows them, so an unknown person
/// is looked up through the contact path their own app published. Null when that is not possible.
Future<int?> chatForUzaroName(TelegramAccount account, UzaroName name) async {
  Future<int> open(int userId) async => (await account.send<td.Chat>(td.CreatePrivateChat(userId: userId, force: false))).id;
  try {
    return await open(name.telegramUserId);
  } on TdException {
    // Not known to this device yet.
  }
  final contact = name.contactToken;
  if (contact == null) return null;
  try {
    if (contact.startsWith('contact/')) {
      final user = await account.send<td.User>(td.SearchUserByToken(token: contact.substring('contact/'.length)));
      // The token must lead to the account the name belongs to, never somewhere else.
      return user.id == name.telegramUserId ? await open(user.id) : null;
    }
    final chat = await account.send<td.Chat>(td.SearchPublicChat(username: contact));
    return account.privateUser(chat)?.id == name.telegramUserId ? chat.id : null;
  } on TdException {
    return null;
  }
}

/// Choose, change or remove the UZARO @name. Claiming first proves this Telegram account to the server.
class UzaroUsernameScreen extends ConsumerStatefulWidget {
  const UzaroUsernameScreen({super.key, this.current});

  final String? current;

  @override
  ConsumerState<UzaroUsernameScreen> createState() => _UzaroUsernameScreenState();
}

class _UzaroUsernameScreenState extends ConsumerState<UzaroUsernameScreen> {
  late final _controller = TextEditingController(text: widget.current ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim().replaceFirst('@', '');
    if (!uzaroNamePattern.hasMatch(name)) return;
    setState(() => _busy = true);
    final api = ref.read(sadoApiProvider);
    final s = context.s;
    try {
      if (!await ensureGiftsLinked(context, ref) || !mounted) return;
      try {
        await api.claimUzaroUsername(name);
      } on ApiException catch (error) {
        if (error.code != 'USERNAME_PAID') rethrow;
        if (!await _buy(api, name)) return;
      }
      await refreshUzaroContact(api, ref.read(accountProvider));
      ref.invalidate(myUzaroNameProvider);
      if (!mounted) return;
      showToast(context, s.t('uzaro_username_saved'));
      Navigator.pop(context);
    } on ApiException catch (error) {
      if (mounted) showToast(context, apiErrorText(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Short names cost money: show the admin's price, then buy for the balance. False when not bought.
  Future<bool> _buy(SadoApi api, String name) async {
    final s = context.s;
    final (status, price) = await api.uzaroUsernameQuote(name);
    if (!mounted) return false;
    // Store builds may not sell digital goods for a balance topped up outside the store.
    if (status != 'for_sale' || storeBlocksExternalPayments) {
      final key = status == 'taken' ? 'api_USERNAME_TAKEN' : 'api_USERNAME_SALE_CLOSED';
      showToast(context, s.t(key));
      return false;
    }
    final ok = await confirm(
      context,
      title: s.t('uzaro_username_buy_title', {'name': name.toLowerCase()}),
      message: s.t('uzaro_username_buy_body', {'price': formatUzs(context, price)}),
      confirmLabel: s.t('uzaro_username_buy'),
    );
    if (!ok || !mounted) return false;
    try {
      await api.buyUzaroUsername(name);
      return true;
    } on ApiException catch (error) {
      if (error.code != 'INSUFFICIENT_BALANCE' || !mounted) rethrow;
      showToast(context, apiErrorText(context, error));
      await _topUp();
      return false;
    }
  }

  Future<void> _topUp() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TopupScreen()));

  Future<void> _remove() async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('uzaro_username_remove'), destructive: true);
    if (!ok || !mounted) return;
    try {
      await ref.read(sadoApiProvider).releaseUzaroUsername();
      ref.invalidate(myUzaroNameProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (error) {
      if (mounted) showToast(context, apiErrorText(context, error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('uzaro_username'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, value, _) {
              final text = value.text.trim().replaceFirst('@', '');
              final valid = uzaroNamePattern.hasMatch(text);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _controller,
                    autofocus: widget.current == null,
                    maxLength: 32,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      prefixText: '@',
                      labelText: s.t('uzaro_username'),
                      errorText: text.isEmpty || valid ? null : s.t('uzaro_username_rules'),
                    ),
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 8),
                  Text(s.t('uzaro_username_hint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy || !valid || text.toLowerCase() == widget.current ? null : _save,
                    child: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(s.t('save')),
                  ),
                  const SizedBox(height: 16),
                  Text(s.t('uzaro_username_short_hint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _busy ? null : _topUp,
                      icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                      label: Text(s.t('gifts_topup')),
                    ),
                  ),
                ],
              );
            },
          ),
          if (widget.current != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _remove,
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              child: Text(s.t('uzaro_username_remove')),
            ),
          ],
        ],
      ),
    );
  }
}
