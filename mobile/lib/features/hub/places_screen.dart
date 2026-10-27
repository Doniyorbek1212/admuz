import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/place_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../chat/link_router.dart';
import 'hub_catalog.dart';

/// Look of a place category: the same label, glyph and color as its hub tile.
HubItem placeCategoryItem(String category) =>
    hubLocalItems.firstWhere((i) => i.placeCategory == category, orElse: () => hubLocalItems.first);

/// District picked in the directory, remembered per region; null means the whole region.
final placesDistrictProvider = NotifierProvider<PlacesDistrictNotifier, String?>(PlacesDistrictNotifier.new);

class PlacesDistrictNotifier extends Notifier<String?> {
  String _key(String region) => 'hubDistrict.$region';

  @override
  String? build() {
    final region = ref.watch(hubRegionProvider);
    return ref.watch(sharedPreferencesProvider).getString(_key(region));
  }

  void select(String? district) {
    final prefs = ref.read(sharedPreferencesProvider);
    final key = _key(ref.read(hubRegionProvider));
    district == null ? prefs.remove(key) : prefs.setString(key, district);
    state = district;
  }
}

final _regionsProvider = FutureProvider<List<PlaceRegion>>((ref) => ref.watch(sadoApiProvider).placeRegions());

/// The hub's "Region" directory: district, nearest-first, search, category chips with counts, place cards.
class PlacesScreen extends ConsumerStatefulWidget {
  const PlacesScreen({super.key, this.initialCategory});

  final String? initialCategory;

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  late String? _category = widget.initialCategory;
  String _query = '';
  Timer? _debounce;
  Position? _here;
  bool _locating = false;
  final _scroll = ScrollController();

  final List<Place> _items = [];
  int? _nextOffset = 0;
  bool _loading = false;
  ApiException? _error;
  Map<String, int> _counts = const {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
    });
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String get _region => ref.read(hubRegionProvider);
  String? get _district => ref.read(placesDistrictProvider);

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _items.clear();
      _nextOffset = 0;
      _error = null;
    });
    final api = ref.read(sadoApiProvider);
    unawaited(api.placeCounts(_region, district: _district).then((c) {
      if (mounted && generation == _generation) setState(() => _counts = c);
    }).catchError((Object _) {}));
    await _loadMore(generation: generation);
  }

  Future<void> _loadMore({int? generation}) async {
    final gen = generation ?? _generation;
    final offset = _nextOffset;
    if (offset == null || (_loading && generation == null)) return;
    _loading = true;
    try {
      final page = await ref.read(sadoApiProvider).places(
            _region,
            district: _district,
            category: _category,
            query: _query,
            lat: _here?.latitude,
            lon: _here?.longitude,
            offset: offset,
          );
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _nextOffset = page.nextOffset;
      });
    } on ApiException catch (error) {
      if (mounted && gen == _generation) setState(() => _error = error);
    } finally {
      if (gen == _generation) _loading = false;
    }
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _query = value.trim();
      _reload();
    });
  }

  /// "Nearest" toggles distance order around the user's current position.
  Future<void> _toggleNearest() async {
    if (_here != null) {
      setState(() => _here = null);
      return _reload();
    }
    final s = context.s;
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) showToast(context, s.t('location_permission'));
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
      );
      if (!mounted) return;
      setState(() => _here = position);
      await _reload();
    } on Exception catch (error) {
      debugPrint('location failed: $error');
      if (mounted) showToast(context, s.t('hub_region_failed'));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickArea() async {
    final s = context.s;
    final regions = await ref.read(_regionsProvider.future).catchError((Object _) => const <PlaceRegion>[]);
    if (!mounted) return;
    var region = _region;
    final picked = await showModalBottomSheet<(String, String?)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final districts = regions.where((r) => r.name == region).firstOrNull?.districts ?? const <String>[];
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: region,
                    decoration: InputDecoration(labelText: s.t('places_region')),
                    items: [for (final r in uzRegions) DropdownMenuItem(value: r, child: Text(r))],
                    onChanged: (value) => setSheet(() => region = value ?? region),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.public_rounded),
                  title: Text(s.t('places_whole_region')),
                  onTap: () => Navigator.pop(context, (region, null)),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final d in districts)
                      ListTile(
                        leading: const Icon(Icons.location_city_rounded),
                        title: Text(d),
                        trailing: region == _region && d == _district ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary) : null,
                        onTap: () => Navigator.pop(context, (region, d)),
                      ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.$1 != _region) ref.read(hubRegionProvider.notifier).select(picked.$1);
    ref.read(placesDistrictProvider.notifier).select(picked.$2);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final region = ref.watch(hubRegionProvider);
    final district = ref.watch(placesDistrictProvider);
    final total = _counts.values.fold(0, (a, b) => a + b);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('hub_region'))),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(children: [
                Expanded(
                  child: _Pill(
                    filled: true,
                    icon: Icons.near_me_rounded,
                    label: district == null ? region : '$district, $region',
                    trailing: Icons.expand_more_rounded,
                    onTap: _pickArea,
                  ),
                ),
                const SizedBox(width: 8),
                _Pill(
                  filled: _here != null,
                  icon: Icons.navigation_rounded,
                  label: s.t('places_nearest'),
                  busy: _locating,
                  onTap: _locating ? null : _toggleNearest,
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: TextField(
                textInputAction: TextInputAction.search,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: s.t('places_search_hint'),
                  filled: true,
                  fillColor: groupCardColor(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _CategoryChip(
                    label: s.t('places_all'),
                    count: total,
                    selected: _category == null,
                    onTap: () {
                      setState(() => _category = null);
                      _reload();
                    },
                  ),
                  for (final item in hubLocalItems.where((i) => i.placeCategory != null))
                    _CategoryChip(
                      icon: item.icon,
                      color: item.color,
                      label: s.t(item.labelKey),
                      count: _counts[item.placeCategory],
                      selected: _category == item.placeCategory,
                      onTap: () {
                        setState(() => _category = item.placeCategory);
                        _reload();
                      },
                    ),
                ],
              ),
            ),
          ),
          if (_error != null && _items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(icon: Icons.cloud_off_rounded, title: apiErrorText(context, _error!), subtitle: ''),
            )
          else if (_items.isEmpty && _nextOffset == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(icon: Icons.travel_explore_rounded, title: s.t('places_empty'), subtitle: s.t('places_empty_hint')),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              sliver: SliverList.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) => PlaceCard(place: _items[index]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: _nextOffset != null
                      ? CircularProgressIndicator(color: primary)
                      : Text(s.t('places_source'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.filled, required this.icon, required this.label, this.trailing, this.onTap, this.busy = false});

  final bool filled;
  final IconData icon;
  final String label;
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final fg = filled ? primary : Theme.of(context).colorScheme.onSurface;
    return Material(
      color: filled ? primary.withValues(alpha: 0.12) : groupCardColor(context),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            busy ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: primary)) : Icon(icon, size: 19, color: primary),
            const SizedBox(width: 8),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 15))),
            if (trailing != null) ...[const SizedBox(width: 4), Icon(trailing, size: 20, color: fg)],
          ]),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.selected, required this.onTap, this.icon, this.color, this.count});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? color;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? primary : groupCardColor(context),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 17, color: selected ? Colors.white : color), const SizedBox(width: 6)],
              Text(label, style: TextStyle(color: selected ? Colors.white : null, fontWeight: FontWeight.w600)),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Text('$count', style: TextStyle(color: selected ? Colors.white70 : Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Category glyph on its tinted rounded square.
class PlaceIcon extends StatelessWidget {
  const PlaceIcon({super.key, required this.category, this.size = 64});

  final String category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final item = placeCategoryItem(category);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: item.color.withValues(alpha: dark ? 0.18 : 0.13), borderRadius: BorderRadius.circular(size * 0.28)),
      child: Icon(item.icon, color: item.color, size: size * 0.5),
    );
  }
}

Future<void> callPlace(String phone) => launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^\d+]'), '')));

class PlaceCard extends StatelessWidget {
  const PlaceCard({super.key, required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final meta = [
      s.t(placeCategoryItem(place.category).labelKey),
      if (place.subcategory.isNotEmpty && place.subcategory != s.t(placeCategoryItem(place.category).labelKey)) place.subcategory,
      ?place.district,
    ].join(' · ');
    return Material(
      color: groupCardColor(context),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaceDetailScreen(place: place))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            PlaceIcon(category: place.category, size: 60),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                  if (place.verified) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, size: 17, color: theme.colorScheme.primary)),
                ]),
                const SizedBox(height: 3),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint, fontSize: 13.5)),
                if (place.address.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(children: [
                    Icon(Icons.place_outlined, size: 15, color: hint),
                    const SizedBox(width: 3),
                    Expanded(child: Text(place.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: hint, fontSize: 13.5))),
                  ]),
                ],
                if (place.is24h || place.distanceM != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    if (place.is24h) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFF2EBD59).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                        child: const Text('● 24/7', style: TextStyle(color: Color(0xFF1E9E47), fontWeight: FontWeight.w700, fontSize: 12.5)),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (place.distanceM != null) ...[
                      Icon(Icons.near_me_outlined, size: 14, color: hint),
                      const SizedBox(width: 3),
                      Text(formatDistance(place.distanceM!), style: TextStyle(color: hint, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ]),
                ],
              ]),
            ),
            if (place.phones.isNotEmpty) ...[
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: s.t('call'),
                style: IconButton.styleFrom(backgroundColor: const Color(0xFF2EBD59), foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
                onPressed: () => callPlace(place.phones.first),
                icon: const Icon(Icons.call_rounded),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// One place: what it is, how to reach it, and where the data comes from.
class PlaceDetailScreen extends StatelessWidget {
  const PlaceDetailScreen({super.key, required this.place});

  final Place place;

  String get _shareText => [
        place.name,
        if (place.address.isNotEmpty) place.address,
        ...place.phones,
        if (place.hasLocation) 'https://maps.google.com/?q=${place.latitude},${place.longitude}',
      ].join('\n');

  Future<void> _openMap() {
    final query = place.hasLocation ? '${place.latitude},${place.longitude}' : '${place.name} ${place.address} ${place.region}';
    return launchUrl(Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': query}), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final item = placeCategoryItem(place.category);
    final actions = <(IconData, Color, String, VoidCallback)>[
      if (place.phones.isNotEmpty) (Icons.call_rounded, const Color(0xFF2EBD59), s.t('call'), () => callPlace(place.phones.first)),
      (Icons.map_rounded, const Color(0xFF3D8BFF), s.t('places_map'), _openMap),
      if (place.telegram.isNotEmpty) (Icons.send_rounded, const Color(0xFF2AABEE), 'Telegram', () => openLink(context, 'https://t.me/${place.telegram}')),
      (Icons.share_rounded, const Color(0xFF8B6CFF), s.t('share'), () => SharePlus.instance.share(ShareParams(text: _shareText))),
    ];
    Widget info(IconData icon, String label, String value, {VoidCallback? onTap}) => ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: item.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: item.color, size: 21),
          ),
          title: Text(label, style: TextStyle(color: theme.hintColor, fontSize: 13)),
          subtitle: Text(value, style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.w500)),
          trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        );
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(s.t(item.labelKey)),
        actions: [IconButton(tooltip: s.t('share'), icon: const Icon(Icons.share_outlined), onPressed: () => SharePlus.instance.share(ShareParams(text: _shareText)))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(0, 12, 0, 24), children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 150,
            decoration: BoxDecoration(color: item.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(24)),
            child: Center(child: Icon(item.icon, color: item.color, size: 72)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (place.subcategory.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: item.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(item.icon, size: 15, color: item.color),
                  const SizedBox(width: 5),
                  Text(place.subcategory, style: TextStyle(color: item.color, fontWeight: FontWeight.w700)),
                ]),
              ),
            const SizedBox(height: 10),
            Text(place.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.15)),
            if (place.is24h) ...[
              const SizedBox(height: 8),
              const Text('● 24/7', style: TextStyle(color: Color(0xFF1E9E47), fontWeight: FontWeight.w700)),
            ],
          ]),
        ),
        SettingsGroup(children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              for (final (icon, color, label, onTap) in actions)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(16)),
                          child: Icon(icon, color: color),
                        ),
                        const SizedBox(height: 6),
                        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
        SettingsGroup(children: [
          info(Icons.place_rounded, s.t('places_address'), [
            if (place.address.isNotEmpty) place.address,
            [?place.district, place.region].join(', '),
          ].join('\n'), onTap: _openMap),
          if (place.landmark.isNotEmpty) info(Icons.flag_rounded, s.t('places_landmark'), place.landmark),
          if (place.workingHours.isNotEmpty) info(Icons.schedule_rounded, s.t('places_hours'), place.is24h ? '24/7' : place.workingHours),
          for (final phone in place.phones) info(Icons.call_rounded, s.t('phone'), phone, onTap: () => callPlace(phone)),
          if (place.website.isNotEmpty) info(Icons.language_rounded, s.t('places_website'), place.website, onTap: () => openLink(context, place.website)),
          if (place.instagram.isNotEmpty)
            info(Icons.camera_alt_rounded, 'Instagram', '@${place.instagram}', onTap: () => openLink(context, 'https://instagram.com/${place.instagram}')),
        ]),
        if (place.description.isNotEmpty)
          SettingsGroup(title: s.t('places_about'), children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 12), child: Text(place.description, style: const TextStyle(fontSize: 15.5, height: 1.4))),
          ]),
        if (place.fromOsm) GroupHint(s.t('places_osm_credit')),
        GroupHint(s.t('places_report_hint')),
      ]),
    );
  }
}
