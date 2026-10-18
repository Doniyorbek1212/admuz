import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/settings_group.dart';
import '../hub/hub_catalog.dart';
import 'business_widgets.dart';

/// Creates a shop or edits one; saving sends it to admin review (a paid slot first asks for payment).
class ShopEditScreen extends ConsumerStatefulWidget {
  const ShopEditScreen({super.key, this.shop});

  final Shop? shop;

  @override
  ConsumerState<ShopEditScreen> createState() => _ShopEditScreenState();
}

class _ShopEditScreenState extends ConsumerState<ShopEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.shop?.name ?? '');
  late final _description = TextEditingController(text: widget.shop?.description ?? '');
  late final _phone = TextEditingController(text: widget.shop?.phone ?? '');
  late final _telegram = TextEditingController(text: widget.shop?.telegram ?? '');
  late String _logo = widget.shop?.logoUrl ?? '';
  late String _region = widget.shop?.region ?? ref.read(hubRegionProvider);
  bool _saving = false;
  double? _logoProgress;

  @override
  void dispose() {
    for (final c in [_name, _description, _phone, _telegram]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLogo() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90, maxWidth: 800);
    if (file == null || !mounted) return;
    setState(() => _logoProgress = 0);
    final media = await apiGuard(context, () => ref.read(sadoApiProvider).uploadMedia(file.path, onProgress: (p) => setState(() => _logoProgress = p)));
    if (!mounted) return;
    setState(() {
      _logoProgress = null;
      if (media != null) _logo = media.url;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final draft = ShopDraft(
      name: _name.text.trim(),
      description: _description.text.trim(),
      region: _region,
      phone: _phone.text.trim(),
      telegram: _telegram.text.trim().replaceFirst('@', ''),
      logoUrl: _logo,
    );
    final api = ref.read(sadoApiProvider);
    final existing = widget.shop;
    final saved = await apiGuard(context, () => existing == null ? api.createShop(draft) : api.updateShop(existing.id, draft));
    if (!mounted) return;
    setState(() => _saving = false);
    // The caller opens a new shop's dashboard (where a paid slot shows the payment step).
    if (saved != null) Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    InputDecoration field(String label, {IconData? icon, String? hint}) =>
        InputDecoration(labelText: label, hintText: hint, prefixIcon: icon == null ? null : Icon(icon), border: const OutlineInputBorder());
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t(widget.shop == null ? 'biz_open_shop' : 'biz_edit_shop'))),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Center(
              child: GestureDetector(
                onTap: _logoProgress == null ? _pickLogo : null,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(borderRadius: BorderRadius.circular(28), child: SizedBox.square(dimension: 104, child: NetImage(_logo, icon: Icons.storefront_rounded))),
                    if (_logoProgress != null) SizedBox.square(dimension: 48, child: CircularProgressIndicator(value: _logoProgress)),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(radius: 17, backgroundColor: Theme.of(context).colorScheme.primary, child: const Icon(Icons.photo_camera_rounded, size: 18, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
            Center(child: TextButton(onPressed: _logoProgress == null ? _pickLogo : null, child: Text(s.t('shop_logo_pick')))),
            const SizedBox(height: 8),
            TextFormField(controller: _name, maxLength: 80, decoration: field(s.t('shop_name'), icon: Icons.storefront_rounded), validator: (v) => validateRequired(context, v)),
            const SizedBox(height: 8),
            TextFormField(controller: _description, maxLength: 1000, minLines: 3, maxLines: 6, decoration: field(s.t('shop_description'))),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _region,
              decoration: field(s.t('shop_region'), icon: Icons.location_on_rounded),
              items: [for (final r in uzRegions) DropdownMenuItem(value: r, child: Text(r))],
              onChanged: (value) => setState(() => _region = value ?? _region),
            ),
            const SizedBox(height: 16),
            TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: field(s.t('shop_phone'), icon: Icons.phone_rounded, hint: '+998 90 123 45 67')),
            const SizedBox(height: 16),
            TextFormField(controller: _telegram, decoration: field(s.t('shop_telegram'), icon: Icons.send_rounded, hint: 'my_shop')),
            const SizedBox(height: 16),
            Text(s.t('shop_review_note'), style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving || _logoProgress != null ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Text(s.t('shop_save')),
            ),
          ],
        ),
      ),
    );
  }
}
