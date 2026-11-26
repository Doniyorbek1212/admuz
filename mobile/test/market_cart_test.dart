import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/market_models.dart';
import 'package:sado/features/market/market_state.dart';
import 'package:sado/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Product _product(String id, {int stock = 3, int price = 1000}) =>
    Product.fromJson({'id': id, 'shop_id': 'shop', 'title': 'P $id', 'price_uzs': price, 'stock': stock});

Future<ProviderContainer> _container() async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('add stops at the stock and the count follows', () async {
    final c = await _container();
    final cart = c.read(cartProvider.notifier);
    final p = _product('a', stock: 2);

    expect(cart.add(p), isTrue);
    expect(cart.add(p), isTrue);
    expect(cart.add(p), isFalse);
    expect(cart.add(_product('zero', stock: 0)), isFalse);

    expect(c.read(cartCountProvider), 2);
    expect(c.read(cartProvider).single.totalUzs, 2000);
  });

  test('the cart survives a restart, and quantity 0 removes the line', () async {
    final first = await _container();
    first.read(cartProvider.notifier)
      ..add(_product('a'))
      ..add(_product('b'))
      ..setQuantity('a', 3);

    final second = await _container();
    expect({for (final l in second.read(cartProvider)) l.product.id: l.quantity}, {'a': 3, 'b': 1});

    second.read(cartProvider.notifier).setQuantity('a', 0);
    expect([for (final l in second.read(cartProvider)) l.product.id], ['b']);
  });

  test('refresh takes new prices and marks products the server dropped', () async {
    final c = await _container();
    final cart = c.read(cartProvider.notifier)
      ..add(_product('kept'))
      ..add(_product('gone'));

    cart.refresh([_product('kept', price: 5000, stock: 1)]);

    final lines = {for (final l in c.read(cartProvider)) l.product.id: l};
    expect(lines['kept']!.product.priceUzs, 5000);
    expect(lines['kept']!.canOrder, isTrue);
    expect(lines['gone']!.available, isFalse);
    expect(lines['gone']!.canOrder, isFalse);
  });

  test('favourites toggle and persist', () async {
    final c = await _container();
    c.read(favoritesProvider.notifier)
      ..toggle('x')
      ..toggle('y')
      ..toggle('x');

    final again = await _container();
    expect(again.read(favoritesProvider), {'y'});
  });
}
