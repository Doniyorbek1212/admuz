import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'business_widgets.dart';

const _kindColors = {
  StockKind.stockIn: Color(0xFF13B88A),
  StockKind.sale: Color(0xFF3D8BFF),
  StockKind.stockReturn: Color(0xFFF5A623),
  StockKind.adjust: Color(0xFF8E8E93),
};

const _kindIcons = {
  StockKind.stockIn: Icons.south_west_rounded,
  StockKind.sale: Icons.shopping_cart_checkout_rounded,
  StockKind.stockReturn: Icons.assignment_return_rounded,
  StockKind.adjust: Icons.tune_rounded,
};

String _kindLabel(BuildContext context, StockKind kind) => context.t(switch (kind) {
      StockKind.stockIn => 'stock_in',
      StockKind.sale => 'stock_sale',
      StockKind.stockReturn => 'stock_return',
      StockKind.adjust => 'stock_adjust',
    });

/// Warehouse ledger of a shop: receipts, sales, returns and adjustments, newest first.
class WarehouseScreen extends ConsumerStatefulWidget {
  const WarehouseScreen({super.key, required this.shop});

  final Shop shop;

  @override
  ConsumerState<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends ConsumerState<WarehouseScreen> {
  final List<StockMovement> _items = [];
  bool _loading = true;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore({bool reset = false}) async {
    setState(() => _loading = true);
    final page = await apiGuard(
      context,
      () => ref.read(sadoApiProvider).stockHistory(widget.shop.id, beforeId: reset || _items.isEmpty ? null : _items.last.id),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page == null) return;
      if (reset) _items.clear();
      _items.addAll(page);
      _hasMore = page.length >= 100;
    });
  }

  Future<void> _addMovement() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MovementSheet(products: widget.shop.products),
    );
    if (added == true && mounted) _loadMore(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text('${s.t('warehouse')} · ${widget.shop.name}')),
      floatingActionButton: widget.shop.products.isEmpty
          ? null
          : FloatingActionButton.extended(onPressed: _addMovement, icon: const Icon(Icons.add_rounded), label: Text(s.t('stock_add'))),
      body: _items.isEmpty && _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? EmptyState(icon: Icons.warehouse_outlined, title: s.t('stock_empty'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _items.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(child: _loading ? const CircularProgressIndicator() : IconButton.filledTonal(onPressed: _loadMore, icon: const Icon(Icons.expand_more_rounded))),
                      );
                    }
                    return _MovementTile(movement: _items[i]);
                  },
                ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement});

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _kindColors[movement.kind]!;
    final date = movement.createdAt;
    final signed = movement.quantity > 0 ? '+${movement.quantity}' : '${movement.quantity}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: groupCardColor(context),
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.15), child: Icon(_kindIcons[movement.kind], color: color)),
          title: Text(movement.productTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              _kindLabel(context, movement.kind),
              if (date != null) DateFormat('dd.MM.yyyy HH:mm').format(date),
              if (movement.note.isNotEmpty) movement.note,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(signed, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: movement.quantity > 0 ? const Color(0xFF13B88A) : theme.colorScheme.error)),
              if (movement.unitPriceUzs > 0) Text(formatUzs(context, movement.unitPriceUzs), style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MovementSheet extends ConsumerStatefulWidget {
  const _MovementSheet({required this.products});

  final List<Product> products;

  @override
  ConsumerState<_MovementSheet> createState() => _MovementSheetState();
}

class _MovementSheetState extends ConsumerState<_MovementSheet> {
  late Product _product = widget.products.first;
  StockKind _kind = StockKind.stockIn;
  int _direction = 1;
  final _quantity = TextEditingController(text: '1');
  late final _price = TextEditingController(text: '${widget.products.first.priceUzs}');
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_quantity, _price, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final quantity = int.tryParse(_quantity.text.trim()) ?? 0;
    if (quantity <= 0) return;
    setState(() => _saving = true);
    final trade = _kind == StockKind.sale || _kind == StockKind.stockReturn;
    final updated = await apiGuard(
      context,
      () => ref.read(sadoApiProvider).moveStock(
            _product.id,
            kind: _kind,
            quantity: quantity,
            direction: _direction,
            unitPriceUzs: trade ? int.tryParse(_price.text.trim()) ?? 0 : 0,
            note: _note.text.trim(),
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (updated != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.t('stock_add'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            DropdownButtonFormField<Product>(
              initialValue: _product,
              isExpanded: true,
              decoration: InputDecoration(labelText: s.t('stock_product'), border: const OutlineInputBorder()),
              items: [
                for (final p in widget.products)
                  DropdownMenuItem(value: p, child: Text('${p.title} · ${s.t('units', {'n': '${p.stock}'})}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (p) => setState(() {
                _product = p ?? _product;
                _price.text = '${_product.priceUzs}';
              }),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in StockKind.values)
                  ChoiceChip(
                    avatar: Icon(_kindIcons[kind], size: 18),
                    label: Text(_kindLabel(context, kind)),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() => _kind = kind),
                  ),
              ],
            ),
            if (_kind == StockKind.adjust) ...[
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 1, label: Text(s.t('stock_direction_plus'))),
                  ButtonSegment(value: -1, label: Text(s.t('stock_direction_minus'))),
                ],
                selected: {_direction},
                onSelectionChanged: (v) => setState(() => _direction = v.first),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _quantity,
              keyboardType: TextInputType.number,
              inputFormatters: digits,
              decoration: InputDecoration(labelText: s.t('stock_quantity'), border: const OutlineInputBorder()),
            ),
            if (_kind == StockKind.sale || _kind == StockKind.stockReturn) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _price,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                decoration: InputDecoration(labelText: s.t('stock_unit_price'), border: const OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _note, maxLength: 200, decoration: InputDecoration(labelText: s.t('stock_note'), border: const OutlineInputBorder())),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Text(s.t('done')),
            ),
          ],
        ),
      ),
    );
  }
}
