import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import '../hub/ad_banner_card.dart';
import 'admin_lists.dart';

/// Whether this device holds an admin key (shows the admin entry in the drawer).
final hasAdminKeyProvider = FutureProvider<bool>((ref) async => await ref.watch(sadoApiProvider).adminKey() != null);

/// Opens the admin panel, asking for the admin key first when none is saved.
Future<void> openAdminPanel(BuildContext context, WidgetRef ref) async {
  final hasKey = await ref.read(sadoApiProvider).adminKey() != null;
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => hasKey ? const AdminPanelScreen() : const AdminLoginScreen()));
}

class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _key = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    setState(() => _busy = true);
    final name = await apiGuard(context, () => ref.read(sadoApiProvider).adminLogin(key));
    if (!mounted) return;
    setState(() => _busy = false);
    if (name == null) return;
    ref.invalidate(hasAdminKeyProvider);
    showToast(context, context.t('admin_welcome', {'name': name}));
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const AdminPanelScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('admin_login'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 20),
          const Center(child: TileIcon(Icons.admin_panel_settings_rounded, Color(0xFF5A6B7F))),
          const SizedBox(height: 24),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: s.t('admin_key'), helperText: s.t('admin_key_hint'), prefixIcon: const Icon(Icons.key_rounded), border: const OutlineInputBorder()),
            onSubmitted: (_) => _login(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _login,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _busy ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Text(s.t('admin_login_btn')),
          ),
        ],
      ),
    );
  }
}

/// Review queue: ads waiting for payment/content approval and shops waiting for approval.
class AdminPanelScreen extends ConsumerWidget {
  const AdminPanelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final onBar = Theme.of(context).appBarTheme.foregroundColor ?? Colors.white;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: groupedBackground(context),
        appBar: AppBar(
          title: Text(s.t('admin_title')),
          actions: [
            IconButton(
              tooltip: s.t('admin_logout'),
              icon: const Icon(Icons.logout_rounded),
              onPressed: () async {
                await ref.read(sadoApiProvider).adminLogout();
                ref.invalidate(hasAdminKeyProvider);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
          bottom: TabBar(
            indicatorColor: onBar,
            labelColor: onBar,
            unselectedLabelColor: onBar.withValues(alpha: 0.65),
            dividerColor: Colors.transparent,
            tabs: [Tab(text: s.t('admin_ads')), Tab(text: s.t('admin_shops')), Tab(text: s.t('admin_users'))],
          ),
        ),
        body: const TabBarView(children: [_AdsQueue(), AdminShopsQueue(), AdminUsersList()]),
      ),
    );
  }
}

/// Pending / live filter shared by both queues.
class _QueueFilter extends StatelessWidget {
  const _QueueFilter({required this.live, required this.onChanged});

  final bool live;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, icon: const Icon(Icons.hourglass_top_rounded), label: Text(context.t('admin_pending'))),
            ButtonSegment(value: true, icon: const Icon(Icons.play_circle_outline_rounded), label: Text(context.t('admin_active'))),
          ],
          selected: {live},
          onSelectionChanged: (value) => onChanged(value.first),
        ),
      );
}

class _AdsQueue extends ConsumerStatefulWidget {
  const _AdsQueue();

  @override
  ConsumerState<_AdsQueue> createState() => _AdsQueueState();
}

class _AdsQueueState extends ConsumerState<_AdsQueue> with AutomaticKeepAliveClientMixin {
  bool _live = false;
  late Future<List<Ad>> _ads = _load();

  @override
  bool get wantKeepAlive => true;

  Future<List<Ad>> _load() => ref.read(sadoApiProvider).adminAds(status: _live ? 'approved' : 'pending_review');

  void _reload() => setState(() => _ads = _load());

  Future<void> _decide(Ad ad, {required bool approve}) async {
    final api = ref.read(sadoApiProvider);
    final reason = approve ? null : await askRejectReason(context);
    if (!approve && reason == null) return;
    if (!mounted) return;
    final done = await apiGuard(context, () async {
      approve ? await api.adminApproveAd(ad.id) : await api.adminRejectAd(ad.id, reason!);
      return true;
    });
    if (done == true && mounted) {
      showToast(context, context.t(approve ? 'admin_approved' : 'admin_rejected'));
      _reload();
    }
  }

  Future<void> _showReceipt(Ad ad) => showReceipt(context, () => ref.read(sadoApiProvider).adminReceipt(ad.id));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = context.s;
    return Column(
      children: [
        _QueueFilter(live: _live, onChanged: (live) => setState(() {
              _live = live;
              _ads = _load();
            })),
        Expanded(
          child: FutureBuilder<List<Ad>>(
            future: _ads,
            builder: (context, snapshot) {
              final error = snapshot.error;
              if (error != null) return EmptyState(icon: Icons.cloud_off_rounded, title: error is ApiException ? apiErrorText(context, error) : s.t('err_GENERIC'));
              final ads = snapshot.data;
              if (ads == null) return const Center(child: CircularProgressIndicator());
              if (ads.isEmpty) return EmptyState(icon: Icons.inbox_rounded, title: s.t('admin_no_pending'));
              return RefreshIndicator(
                onRefresh: () async {
                  _reload();
                  await _ads;
                },
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: ads.length,
                  itemBuilder: (context, i) => _adCard(context, ads[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _adCard(BuildContext context, Ad ad) {
    final s = context.s;
    final theme = Theme.of(context);
    return SettingsGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: AspectRatio(aspectRatio: 2.2, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: AdBannerCard(ad: ad, playVideo: false))),
      ),
      ListTile(
        title: Text(s.t('ad_regions_list', {'list': ad.regions.join(', ')})),
        subtitle: Text('${s.t('ad_days', {'n': '${ad.days}'})}${ad.linkUrl.isEmpty ? '' : '\n${ad.linkUrl}'}\n${ad.mediaUrl}', maxLines: 4, overflow: TextOverflow.ellipsis),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(s.t('admin_amount'), style: TextStyle(color: theme.hintColor, fontSize: 12)),
            Text(formatUzs(context, ad.priceUzs), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            if (ad.hasReceipt)
              TextButton.icon(onPressed: () => _showReceipt(ad), icon: const Icon(Icons.receipt_long_rounded), label: Text(s.t('admin_receipt'))),
            const Spacer(),
            OutlinedButton(
              onPressed: () => _decide(ad, approve: false),
              style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
              child: Text(s.t('admin_reject')),
            ),
            if (!_live) ...[
              const SizedBox(width: 8),
              FilledButton(onPressed: () => _decide(ad, approve: true), child: Text(s.t('admin_approve'))),
            ],
          ],
        ),
      ),
    ]);
  }
}
