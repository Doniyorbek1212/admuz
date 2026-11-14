import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

/// Every pack the server sells, in so'm order; [products] holds the ones the store already sells (by product id).
typedef _Packs = ({String account, Map<String, int> amounts, Map<String, ProductDetails> products});

/// Play and App Store builds: the balance packs, paid through the store's own billing. The server credits a pack only
/// after it has checked the purchase (with Google, or Apple's signature); Play purchases are consumed by the server,
/// App Store ones finished here. A purchase left over from a crash comes back from the store and is sent again.
class StoreTopup extends ConsumerStatefulWidget {
  const StoreTopup({super.key, required this.onCredited});

  final VoidCallback onCredited;

  @override
  ConsumerState<StoreTopup> createState() => _StoreTopupState();
}

class _StoreTopupState extends ConsumerState<StoreTopup> {
  final _store = InAppPurchase.instance;
  late final StreamSubscription<List<PurchaseDetails>> _purchases;
  late Future<_Packs> _packs = _load();

  /// The product being bought, while the store's sheet or the server check is open.
  String? _buying;

  @override
  void initState() {
    super.initState();
    _purchases = _store.purchaseStream.listen(_onPurchases, onError: (Object _) => _finish());
  }

  @override
  void dispose() {
    unawaited(_purchases.cancel());
    super.dispose();
  }

  Future<_Packs> _load() async {
    final info = await ref.read(sadoApiProvider).storePacks();
    final amounts = Map.fromEntries(info.amounts.entries.toList()..sort((a, b) => a.value.compareTo(b.value)));
    final serverTakes = Platform.isIOS ? info.appStore : info.googlePlay;
    // Until the store and the server are both set up, the packs still show, marked "soon".
    if (!serverTakes || !await _store.isAvailable()) return (account: info.account, amounts: amounts, products: <String, ProductDetails>{});
    final found = await _store.queryProductDetails(amounts.keys.toSet());
    // Play: paid but never credited (the app died mid-way) comes back as "restored" and is sent again.
    // StoreKit hands unfinished transactions to the purchase stream by itself.
    if (Platform.isAndroid) unawaited(_store.restorePurchases(applicationUserName: info.account));
    return (account: info.account, amounts: amounts, products: {for (final p in found.productDetails) p.id: p});
  }

  void _finish() {
    if (mounted) setState(() => _buying = null);
  }

  Future<void> _buy(_Packs packs, ProductDetails product) async {
    setState(() => _buying = product.id);
    try {
      // The account tag is a UUID: Play's obfuscatedAccountId and StoreKit's appAccountToken.
      final param = PurchaseParam(productDetails: product, applicationUserName: packs.account);
      // Play: the server consumes the purchase once it has credited it.
      if (!await _store.buyConsumable(purchaseParam: param, autoConsume: false)) _finish();
    } on PlatformException catch (error) {
      _finish();
      if (mounted) showToast(context, error.message ?? context.t('topup_play_failed'));
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          if (mounted) showToast(context, context.t('topup_play_pending'));
        case PurchaseStatus.canceled:
          _finish();
          await _complete(purchase);
        case PurchaseStatus.error:
          _finish();
          await _complete(purchase);
          if (mounted) showToast(context, purchase.error?.message ?? context.t('topup_play_failed'));
        case PurchaseStatus.purchased || PurchaseStatus.restored:
          await _credit(purchase);
      }
    }
  }

  /// StoreKit keeps re-sending a transaction until it is finished; Play purchases are consumed by the server instead.
  Future<void> _complete(PurchaseDetails purchase) async {
    if (Platform.isIOS && purchase.pendingCompletePurchase) await _store.completePurchase(purchase);
  }

  Future<void> _credit(PurchaseDetails purchase) async {
    if (!mounted) return;
    final api = ref.read(sadoApiProvider);
    final proof = purchase.verificationData.serverVerificationData;
    final result = await apiGuard(
      context,
      () => Platform.isIOS ? api.creditAppStore(proof) : api.creditGooglePlay(purchase.productID, proof),
    );
    _finish();
    // Unfinished on a failed check: the store hands it back and it is sent again next time.
    if (result == null) return;
    final pending = result.state == 'pending';
    if (pending) {
      if (mounted) showToast(context, context.t('topup_play_pending'));
      return;
    }
    await _complete(purchase);
    if (mounted && result.state == 'credited') {
      showToast(context, context.t('topup_play_done', {'amount': formatUzs(context, result.amountUzs)}));
      widget.onCredited();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return FutureBuilder<_Packs>(
      future: _packs,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Text(s.t('topup_play_unavailable'), textAlign: TextAlign.center),
              TextButton(onPressed: () => setState(() => _packs = _load()), child: Text(s.t('retry'))),
            ]),
          );
        }
        final packs = snapshot.data;
        if (packs == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        final store = Platform.isIOS ? 'App Store' : 'Google Play';
        return SettingsGroup(title: s.t('gifts_topup'), children: [
          for (final MapEntry(key: id, value: amount) in packs.amounts.entries)
            ListTile(
              leading: Icon(Icons.account_balance_wallet_rounded, color: theme.colorScheme.primary),
              title: Text(formatUzs(context, amount), style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: switch (packs.products[id]) {
                _ when _buying == id => const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.4)),
                final product? => FilledButton(onPressed: _buying == null ? () => _buy(packs, product) : null, child: Text(product.price)),
                null => FilledButton(onPressed: null, child: Text(s.t('topup_play_soon'))),
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              s.t(packs.products.isEmpty ? 'topup_play_soon_hint' : 'topup_play_hint', {'store': store}),
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor, fontSize: 12.5),
            ),
          ),
        ]);
      },
    );
  }
}
