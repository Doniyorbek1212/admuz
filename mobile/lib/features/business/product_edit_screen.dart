import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'business_widgets.dart';

const _maxMedia = 10;

/// One gallery slot: an uploaded item, or a local file still uploading.
class _Slot {
  _Slot.uploaded(MediaItem this.item) : isVideo = item.isVideo;
  _Slot.uploading({required this.isVideo});

  MediaItem? item;
  final bool isVideo;
  double progress = 0;
}

/// Adds a product to a shop, or edits/deletes one: photo/video gallery, prices with discount, category, stock.
class ProductEditScreen extends ConsumerStatefulWidget {
  const ProductEditScreen({super.key, required this.shopId, this.product});

  final String shopId;
  final Product? product;

  @override
  ConsumerState<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends ConsumerState<ProductEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.product?.title ?? '');
  late final _description = TextEditingController(text: widget.product?.description ?? '');
  late final _price = TextEditingController(text: widget.product == null ? '' : '${widget.product!.priceUzs}');
  late final _oldPrice = TextEditingController(text: widget.product?.oldPriceUzs?.toString() ?? '');
  late final _sku = TextEditingController(text: widget.product?.sku ?? '');
  final _stock = TextEditingController(text: '0');
  late String _category = widget.product?.category ?? '';
  late bool _active = widget.product?.active ?? true;
  late final List<_Slot> _media = [for (final m in widget.product?.media ?? const <MediaItem>[]) _Slot.uploaded(m)];
  bool _saving = false;

  bool get _uploading => _media.any((m) => m.item == null);

  @override
  void dispose() {
    for (final c in [_title, _description, _price, _oldPrice, _sku, _stock]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _upload(String path, {required bool isVideo}) async {
    final slot = _Slot.uploading(isVideo: isVideo);
    setState(() => _media.add(slot));
    final api = ref.read(sadoApiProvider);
    final item = await apiGuard(context, () => api.uploadMedia(path, onProgress: (p) {
          if (mounted) setState(() => slot.progress = p);
        }));
    if (!mounted) return;
    setState(() => item == null ? _media.remove(slot) : slot.item = item);
  }

  Future<void> _addPhotos() async {
    final left = _maxMedia - _media.length;
    if (left <= 0) return;
    final files = await ImagePicker().pickMultiImage(imageQuality: 85, maxWidth: 1600, limit: left > 1 ? left : null);
    for (final file in files.take(left)) {
      if (!mounted) return;
      await _upload(file.path, isVideo: false);
    }
  }

  Future<void> _addVideo() async {
    if (_media.length >= _maxMedia) return;
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
    if (file != null && mounted) await _upload(file.path, isVideo: true);
  }

  void _slotMenu(_Slot slot) {
    final s = context.s;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!slot.isVideo)
              ListTile(
                leading: const Icon(Icons.star_rounded),
                title: Text(s.t('media_cover')),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _media
                    ..remove(slot)
                    ..insert(0, slot));
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                setState(() => _media.remove(slot));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _uploading) return;
    setState(() => _saving = true);
    final oldPrice = int.tryParse(_oldPrice.text.trim());
    final draft = ProductDraft(
      title: _title.text.trim(),
      description: _description.text.trim(),
      category: _category,
      sku: _sku.text.trim(),
      priceUzs: int.parse(_price.text.trim()),
      oldPriceUzs: oldPrice == null || oldPrice == 0 ? null : oldPrice,
      media: [for (final slot in _media) slot.item!],
      active: _active,
      initialStock: int.tryParse(_stock.text.trim()) ?? 0,
    );
    final api = ref.read(sadoApiProvider);
    final existing = widget.product;
    final saved = await apiGuard(context, () => existing == null ? api.addProduct(widget.shopId, draft) : api.updateProduct(existing.id, draft));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved != null) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final s = context.s;
    final product = widget.product;
    if (product == null) return;
    if (!await confirm(context, title: s.t('product_delete'), message: s.t('product_delete_confirm'), destructive: true)) return;
    if (!mounted) return;
    final done = await apiGuard(context, () async {
      await ref.read(sadoApiProvider).deleteProduct(product.id);
      return true;
    });
    if (done == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)];
    InputDecoration field(String label, {IconData? icon, String? helper}) =>
        InputDecoration(labelText: label, helperText: helper, prefixIcon: icon == null ? null : Icon(icon), border: const OutlineInputBorder());
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(s.t(widget.product == null ? 'product_new' : 'product_edit')),
        actions: [if (widget.product != null) IconButton(tooltip: s.t('product_delete'), icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete)],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            SettingsGroup(title: s.t('product_media'), children: [_gallery(context)]),
            SettingsGroup(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(controller: _title, maxLength: 120, decoration: field(s.t('product_title'), icon: Icons.sell_rounded), validator: (v) => validateRequired(context, v)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      isExpanded: true,
                      decoration: field(s.t('product_category'), icon: Icons.category_rounded),
                      items: [
                        DropdownMenuItem(value: '', child: Text(s.t('cat_none'))),
                        for (final c in productCategories) DropdownMenuItem(value: c, child: Text(s.t('cat_$c'))),
                      ],
                      onChanged: (v) => setState(() => _category = v ?? ''),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _price,
                            keyboardType: TextInputType.number,
                            inputFormatters: digits,
                            decoration: field(s.t('product_price')),
                            validator: (v) => validateRequired(context, v),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(controller: _oldPrice, keyboardType: TextInputType.number, inputFormatters: digits, decoration: field(s.t('product_old_price'))),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (widget.product == null)
                      TextFormField(controller: _stock, keyboardType: TextInputType.number, inputFormatters: digits, decoration: field(s.t('stock_initial'), icon: Icons.warehouse_rounded))
                    else
                      InputDecorator(
                        decoration: field(s.t('warehouse'), icon: Icons.warehouse_rounded, helper: s.t('warehouse_history')),
                        child: Text(s.t('in_stock', {'n': '${widget.product!.stock}'})),
                      ),
                    const SizedBox(height: 16),
                    TextFormField(controller: _sku, maxLength: 40, decoration: field(s.t('product_sku'), icon: Icons.qr_code_2_rounded)),
                    const SizedBox(height: 6),
                    TextFormField(controller: _description, maxLength: 2000, minLines: 4, maxLines: 10, decoration: field(s.t('product_description'))),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(s.t('product_active')), value: _active, onChanged: (v) => setState(() => _active = v)),
                  ],
                ),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton(
                onPressed: _saving || _uploading ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: _saving
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(s.t(_uploading ? 'uploading' : 'done')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gallery(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final canAdd = _media.length < _maxMedia;
    Widget addButton(IconData icon, String label, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: canAdd ? onTap : null,
          child: Container(
            width: 92,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5), width: 1.5),
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 12.5)),
              ],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 112,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                addButton(Icons.add_photo_alternate_rounded, s.t('product_add_photo'), _addPhotos),
                const SizedBox(width: 8),
                addButton(Icons.video_call_rounded, s.t('product_add_video'), _addVideo),
                for (var i = 0; i < _media.length; i++) ...[
                  const SizedBox(width: 8),
                  _slotTile(context, _media[i], cover: i == 0 && !_media[i].isVideo),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('${s.t('product_media_hint')}  ${_media.length}/$_maxMedia', style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
        ],
      ),
    );
  }

  Widget _slotTile(BuildContext context, _Slot slot, {required bool cover}) {
    final s = context.s;
    final item = slot.item;
    return GestureDetector(
      onTap: item == null ? null : () => _slotMenu(slot),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 92,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (item == null)
                ColoredBox(color: Theme.of(context).hintColor.withValues(alpha: 0.15))
              else
                AdMediaPreview(url: item.url, isVideo: item.isVideo),
              if (item == null) Center(child: SizedBox.square(dimension: 36, child: CircularProgressIndicator(value: slot.progress > 0 ? slot.progress : null))),
              if (cover)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(s.t('media_cover'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
