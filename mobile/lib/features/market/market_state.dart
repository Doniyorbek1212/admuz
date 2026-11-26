import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../state/settings.dart';

/// Most units of one product in the cart (the server's cap per order line).
const maxCartQuantity = 99;

/// Product ids the user hearted, kept on this device.
final favoritesProvider = NotifierProvider<FavoritesNotifier, Set<String>>(FavoritesNotifier.new);

class FavoritesNotifier extends Notifier<Set<String>> {
  static const _key = 'market.favorites';

  @override
  Set<String> build() => {...?ref.watch(sharedPreferencesProvider).getStringList(_key)};

  void toggle(String productId) {
    state = state.contains(productId) ? {...state}.difference({productId}) : {...state, productId};
    unawaited(ref.read(sharedPreferencesProvider).setStringList(_key, state.toList()));
  }
}

/// One product in the cart: the product as last seen and how many. [available] is false once the server no longer
/// sells it (it stays listed so the user sees why it went).
@immutable
class CartLine {
  const CartLine(this.product, this.quantity, {this.available = true});

  final Product product;
  final int quantity;
  final bool available;

  int get totalUzs => product.priceUzs * quantity;

  bool get canOrder => available && product.stock >= quantity;
}

/// The cart, newest first, kept on this device across launches. Prices and stock are refreshed from the server
/// when the cart opens and checked again by the server when the order is placed.
final cartProvider = NotifierProvider<CartNotifier, List<CartLine>>(CartNotifier.new);

class CartNotifier extends Notifier<List<CartLine>> {
  static const _key = 'market.cart';

  @override
  List<CartLine> build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final line in jsonDecode(raw) as List)
          CartLine(Product.fromJson((line as Map<String, dynamic>)['product'] as Map<String, dynamic>), line['quantity'] as int),
      ];
    } on FormatException catch (error) {
      debugPrint('cart unreadable, starting empty: $error');
      return const [];
    } on TypeError catch (error) {
      debugPrint('cart unreadable, starting empty: $error');
      return const [];
    }
  }

  int quantityOf(String productId) => state.where((l) => l.product.id == productId).firstOrNull?.quantity ?? 0;

  /// One more of [product]; false when the stock (or the per-line cap) is already in the cart.
  bool add(Product product) {
    final have = quantityOf(product.id);
    if (have >= product.stock || have >= maxCartQuantity) return false;
    if (have == 0) {
      _save([CartLine(product, 1), ...state]);
    } else {
      setQuantity(product.id, have + 1);
    }
    return true;
  }

  /// 0 takes the product out of the cart.
  void setQuantity(String productId, int quantity) => _save([
        for (final line in state)
          if (line.product.id != productId)
            line
          else if (quantity > 0)
            CartLine(line.product, quantity.clamp(1, maxCartQuantity), available: line.available),
      ]);

  void removeAll(Iterable<String> productIds) {
    final gone = productIds.toSet();
    _save([for (final line in state) if (!gone.contains(line.product.id)) line]);
  }

  /// Takes the server's current price and stock; products it no longer sells are marked unavailable.
  void refresh(List<Product> fresh) {
    final byId = {for (final p in fresh) p.id: p};
    _save([
      for (final line in state)
        switch (byId[line.product.id]) {
          final Product product => CartLine(product, line.quantity),
          null => CartLine(line.product, line.quantity, available: false),
        },
    ]);
  }

  void _save(List<CartLine> lines) {
    state = List.unmodifiable(lines);
    final json = jsonEncode([for (final l in lines) {'product': l.product.toJson(), 'quantity': l.quantity}]);
    unawaited(ref.read(sharedPreferencesProvider).setString(_key, json));
  }
}

/// Units in the cart, for the badge.
final cartCountProvider = Provider<int>((ref) => ref.watch(cartProvider).fold(0, (n, l) => n + l.quantity));
