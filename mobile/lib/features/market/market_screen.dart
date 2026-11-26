import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../business/shops_screen.dart';
import '../hub/hub_catalog.dart';
import 'market_state.dart';
import 'market_widgets.dart';
import 'orders_screen.dart';

const _sorts = ['new', 'cheap', 'expensive', 'discount'];

/// The market's front page: search, categories, the region's shops and one endless feed of products from all of them.
class MarketScreen extends ConsumerStatefulWidget {
  const MarketScreen({super.key});

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  static const _debounce = Duration(milliseconds: 400);

  /// Items per server page (server/app/routers/market.py FEED_PAGE).
  static const _page = 30;

  final _scroll = ScrollController();
  Timer? _timer;
  String _query = '';
  String _category = '';
  String _sort = 'new';
  final _products = <Product>[];
  bool _loading = false;
  bool _end = false;
  ApiException? _error;

  /// Bumped on every new search, so a slow answer to an old one is dropped.
  int _generation = 0;
  late Future<List<Shop>> _shops = _loadShops();

  String get _region => ref.read(hubRegionProvider);

  Future<List<Shop>> _loadShops() => ref.read(sadoApiProvider).shops(_region);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) unawaited(_more());
    });
    unawaited(_more());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restart() async {
    setState(() {
      _generation++;
      _products.clear();
      _end = false;
      _loading = false;
      _error = null;
    });
    await _more();
  }

  Future<void> _more() async {
    if (_loading || _end) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(sadoApiProvider)
          .marketFeed(region: _region, query: _query, category: _category, sort: _sort, offset: _products.length);
      if (!mounted || generation != _generation) return;
      setState(() {
        _products.addAll(page);
        _end = page.length < _page;
      });
    } on ApiException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _search(String query) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (query.trim() == _query) return;
      _query = query.trim();
      unawaited(_restart());
    });
  }

  void _setCategory(String category) {
    _category = _category == category ? '' : category;
    unawaited(_restart());
  }

  Future<void> _pickRegion() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final region in uzRegions)
            ListTile(
              title: Text(region),
              trailing: region == _region ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, region),
            ),
        ]),
      ),
    );
    if (picked == null || picked == _region || !mounted) return;
    ref.read(hubRegionProvider.notifier).select(picked);
    setState(() => _shops = _loadShops());
    await _restart();
  }

  Future<void> _refresh() async {
    setState(() => _shops = _loadShops());
    await _restart();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final browsing = _query.isEmpty && _category.isEmpty;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(s.t('shops_title')),
        actions: [
          IconButton(
            tooltip: s.t('fav_title'),
            icon: const Icon(Icons.favorite_border_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FavoritesScreen())),
          ),
          IconButton(
            tooltip: s.t('orders_title'),
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MyOrdersScreen())),
          ),
          const CartButton(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverToBoxAdapter(child: _searchBar(context)),
          SliverToBoxAdapter(child: _categories(context)),
          if (browsing) SliverToBoxAdapter(child: _ShopsStrip(shops: _shops, region: ref.watch(hubRegionProvider))),
          SliverToBoxAdapter(child: _sortRow(context)),
          if (_products.isEmpty && !_loading && _error == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  icon: Icons.search_off_rounded,
                  title: s.t(browsing ? 'market_empty_region' : 'market_nothing_found'),
                  subtitle: browsing ? s.t('market_try_region') : null,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              sliver: SliverGrid.builder(
                gridDelegate: marketGrid,
                itemCount: _products.length,
                itemBuilder: (context, i) => MarketProductCard(product: _products[i]),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Center(
                child: _error != null
                    ? Column(children: [
                        Text(apiErrorText(context, _error!), textAlign: TextAlign.center),
                        TextButton(onPressed: _more, child: Text(s.t('retry'))),
                      ])
                    : _loading
                        ? const CircularProgressIndicator()
                        : const SizedBox.shrink(),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final s = context.s;
    final region = ref.watch(hubRegionProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            onChanged: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: s.t('market_search'),
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: groupCardColor(context),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ActionChip(
          avatar: const Icon(Icons.place_outlined, size: 18),
          label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 96), child: Text(region, overflow: TextOverflow.ellipsis)),
          tooltip: s.t('shop_region'),
          onPressed: _pickRegion,
        ),
      ]),
    );
  }

  Widget _categories(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final c in productCategories)
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _setCategory(c),
              child: SizedBox(
                width: 76,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _category == c ? theme.colorScheme.primary : groupCardColor(context),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(categoryIcons[c] ?? Icons.category_rounded,
                        color: _category == c ? theme.colorScheme.onPrimary : theme.colorScheme.primary),
                  ),
                  const SizedBox(height: 5),
                  Text(context.t('cat_$c'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, fontWeight: _category == c ? FontWeight.w800 : FontWeight.w500)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sortRow(BuildContext context) => SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          children: [
            for (final sort in _sorts)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(context.t('sort_$sort')),
                  selected: _sort == sort,
                  onSelected: (_) {
                    if (_sort == sort) return;
                    _sort = sort;
                    unawaited(_restart());
                  },
                ),
              ),
          ],
        ),
      );
}

/// The region's shops as a row of logos; hidden while there are none.
class _ShopsStrip extends StatelessWidget {
  const _ShopsStrip({required this.shops, required this.region});

  final Future<List<Shop>> shops;
  final String region;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Shop>>(
        future: shops,
        builder: (context, snapshot) {
          final list = snapshot.data ?? const [];
          if (list.isEmpty) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 4, 0),
              child: Row(children: [
                Expanded(child: Text(context.t('market_shops'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShopsScreen(region: region))),
                  child: Text(context.t('market_all_shops')),
                ),
              ]),
            ),
            SizedBox(
              height: 104,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final shop = list[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShopScreen(shopId: shop.id, title: shop.name))),
                    child: SizedBox(
                      width: 80,
                      child: Column(children: [
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: SizedBox.square(dimension: 62, child: NetImage(shop.logoUrl, icon: Icons.storefront_rounded)),
                        ),
                        const SizedBox(height: 5),
                        Text(shop.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(context.t('shop_products_n', {'n': '${shop.productCount ?? 0}'}),
                            maxLines: 1, style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
      );
}

/// Hearted products, loaded fresh; un-hearting one takes it off the page.
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  late Future<List<Product>> _products = _load();

  Future<List<Product>> _load() {
    final ids = ref.read(favoritesProvider).toList();
    // shortcut: the feed takes at most 100 ids, so older favourites past that are not shown; page it if users hit it.
    return ids.isEmpty ? Future.value(const []) : ref.read(sadoApiProvider).marketFeed(ids: ids.take(100).toList());
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final liked = ref.watch(favoritesProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('fav_title')), actions: const [CartButton()]),
      body: FutureBuilder<List<Product>>(
        future: _products,
        builder: (context, snapshot) {
          final error = snapshot.error;
          if (error != null) {
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'),
              action: FilledButton(onPressed: () => setState(() => _products = _load()), child: Text(s.t('retry'))),
            );
          }
          final all = snapshot.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          final products = [for (final p in all) if (liked.contains(p.id)) p];
          if (products.isEmpty) {
            return EmptyState(icon: Icons.favorite_border_rounded, title: s.t('fav_empty'), subtitle: s.t('fav_empty_hint'));
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            gridDelegate: marketGrid,
            itemCount: products.length,
            itemBuilder: (context, i) => MarketProductCard(product: products[i]),
          );
        },
      ),
    );
  }
}
