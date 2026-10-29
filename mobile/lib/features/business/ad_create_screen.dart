import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/settings_group.dart';
import '../hub/ad_banner_card.dart';
import '../hub/hub_catalog.dart';
import 'ad_payment_screen.dart';
import 'business_widgets.dart';

/// Composes a hub banner ad: content, media link, target regions and duration, with a live preview and price.
class AdCreateScreen extends ConsumerStatefulWidget {
  const AdCreateScreen({super.key});

  @override
  ConsumerState<AdCreateScreen> createState() => _AdCreateScreenState();
}

class _AdCreateScreenState extends ConsumerState<AdCreateScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _text = TextEditingController();
  final _media = TextEditingController();
  final _link = TextEditingController();
  late final Future<AdsConfig> _config = ref.read(sadoApiProvider).adsConfig();
  late final Set<String> _regions = {ref.read(hubRegionProvider)};
  bool _isVideo = false;
  int _days = 7;
  bool _saving = false;
  double? _uploadProgress;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _text, _media]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _text, _media, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Uploads a banner picture or short video from the gallery instead of pasting a link.
  Future<void> _pickMedia() async {
    final picker = ImagePicker();
    final file = _isVideo
        ? await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60))
        : await picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1600);
    if (file == null || !mounted) return;
    setState(() => _uploadProgress = 0);
    final media = await apiGuard(context, () => ref.read(sadoApiProvider).uploadMedia(file.path, onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        }));
    if (!mounted) return;
    setState(() {
      _uploadProgress = null;
      if (media != null) {
        _media.text = media.url;
        _isVideo = media.isVideo;
      }
    });
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate() || _regions.isEmpty) return;
    setState(() => _saving = true);
    final draft = AdDraft(
      title: _title.text.trim(),
      text: _text.text.trim(),
      isVideo: _isVideo,
      mediaUrl: _media.text.trim(),
      linkUrl: _link.text.trim(),
      regions: [for (final r in uzRegions) if (_regions.contains(r)) r],
      days: _days,
    );
    final ad = await apiGuard(context, () => ref.read(sadoApiProvider).createAd(draft));
    if (!mounted) return;
    setState(() => _saving = false);
    if (ad != null) Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => AdPaymentScreen(ad: ad)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    InputDecoration field(String label, {IconData? icon, String? helper}) =>
        InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2, prefixIcon: icon == null ? null : Icon(icon), border: const OutlineInputBorder());
    final preview = Ad(
      id: 'preview',
      title: _title.text.trim().isEmpty ? s.t('ad_title') : _title.text.trim(),
      text: _text.text.trim(),
      isVideo: _isVideo,
      mediaUrl: _media.text.trim(),
      linkUrl: '',
    );
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('ad_new'))),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(s.t('ad_preview'), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AspectRatio(aspectRatio: 2.2, child: ClipRRect(borderRadius: BorderRadius.circular(22), child: AdBannerCard(ad: preview, playVideo: false))),
            ),
            SettingsGroup(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(controller: _title, maxLength: 60, decoration: field(s.t('ad_title'), icon: Icons.title_rounded), validator: (v) => validateRequired(context, v)),
                    const SizedBox(height: 6),
                    TextFormField(controller: _text, maxLength: 160, maxLines: 2, decoration: field(s.t('ad_text'), icon: Icons.notes_rounded)),
                    const SizedBox(height: 6),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(value: false, icon: const Icon(Icons.image_rounded), label: Text(s.t('ad_image'))),
                        ButtonSegment(value: true, icon: const Icon(Icons.movie_rounded), label: Text(s.t('ad_video'))),
                      ],
                      selected: {_isVideo},
                      onSelectionChanged: (value) => setState(() => _isVideo = value.first),
                    ),
                    const SizedBox(height: 10),
                    _MediaSpecs(isVideo: _isVideo),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _media,
                      keyboardType: TextInputType.url,
                      decoration: field(s.t('ad_media_url'), icon: Icons.link_rounded, helper: s.t('ad_media_hint')),
                      validator: (v) => validateMediaUrl(context, v),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _uploadProgress == null ? _pickMedia : null,
                      icon: _uploadProgress == null
                          ? Icon(_isVideo ? Icons.video_library_rounded : Icons.photo_library_rounded)
                          : SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, value: _uploadProgress! > 0 ? _uploadProgress : null)),
                      label: Text(s.t(_uploadProgress == null ? (_isVideo ? 'product_add_video' : 'product_add_photo') : 'uploading')),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _link,
                      keyboardType: TextInputType.url,
                      decoration: field(s.t('ad_link'), icon: Icons.open_in_new_rounded),
                      validator: (v) => validateOptionalUrl(context, v),
                    ),
                  ],
                ),
              ),
            ]),
            _regionsCard(context),
            _priceCard(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton.icon(
                onPressed: _saving || _regions.isEmpty || _uploadProgress != null ? null : _submit,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: _saving ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.payments_rounded),
                label: Text(s.t('ad_submit')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _regionsCard(BuildContext context) {
    final s = context.s;
    final all = _regions.length == uzRegions.length;
    return SettingsGroup(title: s.t('ad_regions'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: Text(s.t('ad_all_regions')),
              selected: all,
              onSelected: (on) => setState(() => on ? _regions.addAll(uzRegions) : _regions.clear()),
            ),
            for (final region in uzRegions)
              FilterChip(
                label: Text(region),
                selected: _regions.contains(region),
                onSelected: (on) => setState(() => on ? _regions.add(region) : _regions.remove(region)),
              ),
          ],
        ),
      ),
    ]);
  }

  Widget _priceCard(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return FutureBuilder<AdsConfig>(
      future: _config,
      builder: (context, snapshot) {
        final config = snapshot.data;
        final maxDays = config?.maxDays ?? 30;
        final total = (config?.pricePerRegionDay ?? 0) * _regions.length * _days;
        return SettingsGroup(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(s.t('ad_days', {'n': '$_days'}), style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Slider(value: _days.toDouble(), min: 1, max: maxDays.toDouble(), divisions: maxDays - 1, label: '$_days', onChanged: (v) => setState(() => _days = v.round())),
          ListTile(
            title: Text(s.t('ad_price_total'), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: config == null
                ? null
                : Text(s.t('ad_price_formula', {'regions': '${_regions.length}', 'days': '$_days', 'price': formatUzs(context, config.pricePerRegionDay)})),
            trailing: config == null
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(formatUzs(context, total), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: theme.colorScheme.primary)),
          ),
        ]);
      },
    );
  }
}

/// What the banner slot expects, so uploads are not cropped or rejected (server: 5 MB photos, 30 MB videos).
class _MediaSpecs extends StatelessWidget {
  const _MediaSpecs({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final lines = isVideo
        ? [s.t('ad_spec_size'), s.t('ad_spec_video_format'), s.t('ad_spec_video_limit'), s.t('ad_spec_video_sound')]
        : [s.t('ad_spec_size'), s.t('ad_spec_image_format'), s.t('ad_spec_image_limit')];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.aspect_ratio_rounded, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(s.t(isVideo ? 'ad_spec_video_title' : 'ad_spec_image_title'), style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('• $line', style: TextStyle(fontSize: 13, color: theme.textTheme.bodySmall?.color)),
          ),
        const SizedBox(height: 4),
        Text(s.t('ad_spec_safe_zone'), style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
      ]),
    );
  }
}
