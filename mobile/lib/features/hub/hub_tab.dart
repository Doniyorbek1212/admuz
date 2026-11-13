import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/sado_api.dart';
import '../../core/interests.dart';
import '../../core/store_rules.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/ads_screen.dart';
import '../business/business_screen.dart';
import '../business/shops_screen.dart';
import '../gifts/gifts_screen.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';
import '../webapp/web_app_screen.dart' show hasWebView;
import 'hub_banners.dart';
import 'games_screen.dart';
import 'hub_catalog.dart';
import 'hub_results_screen.dart';
import 'hub_quick_links.dart';
import 'movies_screen.dart';
import 'music_screen.dart';
import 'places_screen.dart';

/// Quick link icons: three links and the add tile across a phone, one-line names, no empty band below.
const _quickIconSize = 60.0;

/// "Hub" tab of the bottom bar: banners, local services, entertainment and tools.
class HubTab extends ConsumerWidget {
  const HubTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final region = ref.watch(hubRegionProvider);
    // iOS store builds cannot sell ads (paid outside the App Store), so the tile is hidden there.
    final toolItems = [
      for (final item in hubToolItems)
        if (item.action != HubAction.ads || !storeBlocksExternalPayments) item,
    ];
    final quickLinks = ref.watch(quickLinksProvider);
    final adminLinks = ref.watch(adminQuickLinksProvider).value ?? const <QuickLink>[];
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: BrandTabBar(title: s.t('tab_hub')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(activeAdsProvider(region));
          ref.invalidate(adminQuickLinksProvider);
        },
        child: ListView(
          // Clears the shell's floating bottom bar (reported as bottom padding), or the last section hides under it.
          padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 12),
          children: [
            const HubBanners(),
            // Quick links: just the icons, no header (the user's choice).
            _HubSection(
              oneRow: true,
              tiles: [
                // Paid admin links first, in their order; the user cannot remove them.
                for (final link in adminLinks)
                  _HubTile(
                    icon: QuickLinkBadge(link: link, size: _quickIconSize),
                    label: link.name,
                    labelLines: 1,
                    onTap: () => openQuickLink(context, link),
                  ),
                for (final link in quickLinks)
                  _HubTile(
                    icon: QuickLinkBadge(link: link, size: _quickIconSize),
                    label: link.name,
                    labelLines: 1,
                    onTap: () => openQuickLink(context, link),
                    onLongPress: () => confirmRemoveQuickLink(context, ref, link),
                  ),
                if (quickLinks.length < maxQuickLinks)
                  _HubTile(
                    icon: _IconTile(icon: Icons.add_rounded, color: Theme.of(context).hintColor, size: _quickIconSize, iconSize: 30, radius: 17),
                    label: s.t('add'),
                    labelLines: 1,
                    onTap: () => addQuickLink(context, ref),
                  ),
              ],
            ),
            _HubSection(
              icon: Icons.auto_awesome_rounded,
              color: const Color(0xFFFF5C8A),
              title: s.t('hub_fun'),
              trailing: _count(context, hubFunItems.length),
              tiles: _itemTiles(context, ref, hubFunItems),
            ),
            _HubSection(icon: Icons.handyman_rounded, color: const Color(0xFF2EC27E), title: s.t('hub_tools'), trailing: _count(context, toolItems.length), tiles: _itemTiles(context, ref, toolItems)),
            _HubSection(
              icon: Icons.location_on_rounded,
              color: const Color(0xFF2EC27E),
              title: s.t('hub_region'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    region,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Theme.of(context).hintColor),
                ],
              ),
              onHeaderTap: () => ref.read(sadoApiProvider).configured ? Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen())) : _pickRegion(context, ref),
              tiles: _itemTiles(context, ref, hubLocalItems),
            ),
          ],
        ),
      ),
    );
  }

  static List<Widget> _itemTiles(BuildContext context, WidgetRef ref, List<HubItem> items) => [
    for (final item in items)
      _HubTile(
        icon: _IconTile(icon: item.icon, color: item.color, size: 58, iconSize: 30, radius: 18),
        label: context.t(item.labelKey),
        onTap: () => openHubItem(context, ref, item),
      ),
  ];

  static Widget _count(BuildContext context, int n) => Text(
    '$n',
    style: TextStyle(color: Theme.of(context).hintColor, fontSize: 16, fontWeight: FontWeight.w600),
  );

  Future<void> _pickRegion(BuildContext context, WidgetRef ref) async {
    final current = ref.read(hubRegionProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.t('hub_region_pick'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(Icons.my_location_rounded, color: Theme.of(context).colorScheme.primary),
                title: Text(context.t('hub_region_auto')),
                subtitle: Text(context.t('hub_region_auto_hint')),
                onTap: () => Navigator.pop(context, _autoRegion),
              ),
              const Divider(height: 1),
              Flexible(
                child: RadioGroup<String>(
                  groupValue: current,
                  onChanged: (value) => Navigator.pop(context, value),
                  child: ListView(
                    shrinkWrap: true,
                    children: [for (final region in uzRegions) RadioListTile<String>(value: region, title: Text(region))],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == _autoRegion && context.mounted) return _detectRegion(context, ref);
    if (picked != null) ref.read(hubRegionProvider.notifier).select(picked);
  }

  /// Sheet result for the "Detect automatically" row.
  static const _autoRegion = '';

  Future<void> _detectRegion(BuildContext context, WidgetRef ref) async {
    final s = context.s;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (context.mounted) showToast(context, s.t('location_permission'));
      return;
    }
    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 15)),
      );
    } on Exception catch (error) {
      // Location services off, timeout or no fix.
      debugPrint('region detection failed: $error');
      if (context.mounted) showToast(context, s.t('hub_region_failed'));
      return;
    }
    final area = await locateArea(ref, position);
    if (!context.mounted) return;
    if (area == null) return showToast(context, s.t('hub_region_outside'));
    showToast(context, s.t('hub_region_detected', {'region': area}));
  }
}

/// Runs a hub tile's action.
Future<void> openHubItem(BuildContext context, WidgetRef ref, HubItem item) async {
  final label = context.t(item.labelKey);
  void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  trackInterest(ref, item.topic);
  switch (item.action) {
    case HubAction.places:
      if (ref.read(sadoApiProvider).configured) {
        push(PlacesScreen(initialCategory: item.placeCategory));
      } else {
        // No UZARO server in this build: fall back to public Telegram channels and a map search.
        final region = ref.read(hubRegionProvider);
        push(HubResultsScreen(title: label, query: '${item.query} $region', mapQuery: '${item.mapQuery} $region'));
      }
    case HubAction.search:
      push(HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.movies:
      // A build without the UZARO server falls back to public Telegram channels.
      push(ref.read(sadoApiProvider).configured ? const MoviesScreen() : HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.music:
      push(ref.read(sadoApiProvider).configured ? const MusicScreen() : HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.games:
      // The games page is a web view: without one (Windows) the public game channels are shown.
      push(ref.read(sadoApiProvider).configured && hasWebView ? const GamesScreen() : HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.gifts:
      push(ref.read(sadoApiProvider).configured ? const GiftsScreen() : HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.themes:
      push(const AppearanceScreen());
    case HubAction.business:
      push(const BusinessScreen());
    case HubAction.ads:
      push(const AdsScreen());
    case HubAction.shops:
      push(ShopsScreen(region: ref.read(hubRegionProvider)));
    case HubAction.support:
      final account = ref.read(accountProvider);
      final chat = await guard(context, () async {
        final support = await account.send<td.User>(const td.GetSupportUser());
        return account.openPrivateChat(support.id);
      });
      if (chat != null && context.mounted) openChat(context, chat.id);
  }
}

class _HubSection extends StatelessWidget {
  const _HubSection({this.icon = Icons.apps_rounded, this.color = Colors.grey, this.title, this.trailing = const SizedBox.shrink(), required this.tiles, this.onHeaderTap, this.oneRow = false});

  final IconData icon;
  final Color color;

  /// Header text; without one the section is just its tiles (the quick links row).
  final String? title;
  final Widget trailing;
  final List<Widget> tiles;
  final VoidCallback? onHeaderTap;

  /// One compact row (the user's links plus the add tile fit on a phone; paid admin links make it swipeable).
  final bool oneRow;

  static const _rowTilesOnScreen = 4.0;
  // Tile padding 2×6 + icon + gap 7 + one label line; nothing left over under the names.
  static const _rowHeight = _quickIconSize + 34;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    // Gold-framed card, matching the banners above and the bottom bar.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      child: GoldFrame(
        child: Material(
          color: groupCardColor(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  InkWell(
                    onTap: onHeaderTap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                      child: Row(
                        children: [
                          _IconTile(icon: icon, color: color, size: 40, iconSize: 22, radius: 12),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                          ),
                          trailing,
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(8, title == null ? 8 : (oneRow ? 0 : 4), 8, oneRow ? 2 : 8),
                  // 4 tiles on a phone, more on an unfolded iPhone Duo or a tablet instead of stretched ones.
                  child: oneRow
                      ? LayoutBuilder(
                          builder: (context, box) => SizedBox(
                            height: _rowHeight,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: EdgeInsets.zero,
                              // Wide screens show every tile at grid width instead of stretched ones.
                              itemExtent: (box.maxWidth / _rowTilesOnScreen).clamp(0, 112),
                              children: tiles,
                            ),
                          ),
                        )
                      : GridView(
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 112, childAspectRatio: 0.82),
                          shrinkWrap: true,
                          // Without this the grid inherits the bottom bar's padding.
                          padding: EdgeInsets.zero,
                          physics: const NeverScrollableScrollPhysics(),
                          children: tiles,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({required this.icon, required this.label, required this.onTap, this.onLongPress, this.labelLines = 2});

  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Quick links keep their names on one line so the row stays short.
  final int labelLines;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          children: [
            icon,
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: labelLines,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Colored glyph on a tinted rounded square, as in the reference design.
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.color, required this.size, required this.iconSize, required this.radius});

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.13),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, color: color, size: iconSize),
    );
  }
}
