import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_screen.dart';
import '../business/shops_screen.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';
import 'hub_banners.dart';
import 'hub_catalog.dart';
import 'hub_results_screen.dart';

/// "Hub" tab of the bottom bar: banners, local services, entertainment and tools.
class HubTab extends ConsumerWidget {
  const HubTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final region = ref.watch(hubRegionProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('tab_hub'))),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(activeAdsProvider(region)),
        child: ListView(
          // Clears the shell's floating bottom bar (reported as bottom padding), or the last section hides under it.
          padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 12),
          children: [
            const HubBanners(),
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
              onHeaderTap: () => _pickRegion(context, ref),
              items: hubLocalItems,
            ),
            _HubSection(
              icon: Icons.auto_awesome_rounded,
              color: const Color(0xFFFF5C8A),
              title: s.t('hub_fun'),
              trailing: _count(context, hubFunItems.length),
              items: hubFunItems,
            ),
            _HubSection(
              icon: Icons.handyman_rounded,
              color: const Color(0xFF2EC27E),
              title: s.t('hub_tools'),
              trailing: _count(context, hubToolItems.length),
              items: hubToolItems,
            ),
          ],
        ),
      ),
    );
  }

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
    final region = regionForPosition(position.latitude, position.longitude);
    if (!context.mounted) return;
    if (region == null) return showToast(context, s.t('hub_region_outside'));
    ref.read(hubRegionProvider.notifier).select(region);
    showToast(context, s.t('hub_region_detected', {'region': region}));
  }
}

/// Runs a hub tile's action.
Future<void> openHubItem(BuildContext context, WidgetRef ref, HubItem item) async {
  final label = context.t(item.labelKey);
  void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  switch (item.action) {
    case HubAction.local:
      final region = ref.read(hubRegionProvider);
      push(HubResultsScreen(title: label, query: '${item.query} $region', mapQuery: '${item.mapQuery} $region'));
    case HubAction.search:
      push(HubResultsScreen(title: label, query: item.query ?? label));
    case HubAction.themes:
      push(const AppearanceScreen());
    case HubAction.business:
      push(const BusinessScreen());
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

class _HubSection extends ConsumerWidget {
  const _HubSection({required this.icon, required this.color, required this.title, required this.trailing, required this.items, this.onHeaderTap});

  final IconData icon;
  final Color color;
  final String title;
  final Widget trailing;
  final List<HubItem> items;
  final VoidCallback? onHeaderTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsGroup(
      children: [
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
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            // Without this the grid inherits the bottom bar's padding.
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.82,
            children: [for (final item in items) _HubTile(item: item, onTap: () => openHubItem(context, ref, item))],
          ),
        ),
      ],
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({required this.item, required this.onTap});

  final HubItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          children: [
            _IconTile(icon: item.icon, color: item.color, size: 58, iconSize: 30, radius: 18),
            const SizedBox(height: 7),
            Text(
              context.t(item.labelKey),
              maxLines: 2,
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
