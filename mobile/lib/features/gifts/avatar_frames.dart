import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/frame_models.dart';
import '../../core/api/id_batcher.dart';
import '../../core/api/sado_api.dart';
import '../../core/store_rules.dart';
import '../../core/theme.dart' show brandGold;
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart';
import 'gift_widgets.dart' show ensureGiftsLinked;
import 'topup_screen.dart';

/// The frame art is drawn on a canvas whose photo hole is this share of its width (frame_renders contract).
const framePhotoShare = 0.76;

/// At or above this avatar size the profile-size frame with the "UZARO" plate is used; below it the small one.
const _plateFromSize = 72.0;

/// The frame shop with what this customer owns and wears; also resolves other people's frame keys to art.
final frameShopProvider = FutureProvider<FrameShop>((ref) => ref.watch(sadoApiProvider).frameShop());

final _frameLoaderProvider = Provider((ref) => IdBatcher<String>(ref.watch(sadoApiProvider).framesOf));

/// When the shop was last refetched for a frame key it did not know.
DateTime? _shopRefetchedAt;

/// The frame a Telegram user wears, or null.
// shortcut: cached for the session like the badge, so someone else's new frame shows after a restart; the user's
// own purchase invalidates theirs right away.
final userFrameProvider = FutureProvider.family<AvatarFrameItem?, int>((ref, userId) async {
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return null;
  final key = await ref.watch(_frameLoaderProvider).load(userId);
  if (key == null) return null;
  final frame = (await ref.watch(frameShopProvider.future)).byKey(key);
  // A frame uploaded after this session loaded the shop: fetch the catalog again (at most once a minute), and
  // this provider reruns with it.
  final now = DateTime.now();
  if (frame == null && (_shopRefetchedAt == null || now.difference(_shopRefetchedAt!) > const Duration(minutes: 1))) {
    _shopRefetchedAt = now;
    ref.invalidate(frameShopProvider);
  }
  return frame;
});

/// Draws [frame] round an avatar of [size] without changing the avatar's layout size: the art overflows by about
/// 16 % each side, the photo itself stays where it was.
class FramedAvatar extends StatelessWidget {
  const FramedAvatar({super.key, required this.frame, required this.size, required this.child});

  final AvatarFrameItem frame;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outer = size / framePhotoShare;
    final inset = (outer - size) / 2;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox.square(
      dimension: size,
      child: Stack(clipBehavior: Clip.none, fit: StackFit.expand, children: [
        child,
        Positioned(
          left: -inset,
          top: -inset,
          width: outer,
          height: outer,
          child: IgnorePointer(
            child: Image.network(
              size >= _plateFromSize ? frame.animationUrl : frame.smallUrl,
              cacheWidth: (outer * dpr).round(),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      ]),
    );
  }
}

/// [child] with the frame [userId] wears, if any. Nothing changes while it loads or when there is none.
class UserFrame extends ConsumerWidget {
  const UserFrame({super.key, required this.userId, required this.size, required this.child});

  final int userId;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frame = ref.watch(userFrameProvider(userId)).value;
    return frame == null ? child : FramedAvatar(frame: frame, size: size, child: child);
  }
}

/// The frame shop: every frame shown on the user's own avatar, bought once, one worn at a time.
class FrameShopScreen extends ConsumerStatefulWidget {
  const FrameShopScreen({super.key});

  @override
  ConsumerState<FrameShopScreen> createState() => _FrameShopScreenState();
}

class _FrameShopScreenState extends ConsumerState<FrameShopScreen> {
  String? _picked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Frames uploaded since the shop was last loaded show up when it opens; the old list stays on screen meanwhile.
    if (ref.read(frameShopProvider).hasValue) {
      Future.microtask(() {
        if (mounted) ref.invalidate(frameShopProvider);
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String? doneKey) async {
    if (!await ensureGiftsLinked(context, ref) || !mounted) return;
    setState(() => _busy = true);
    final ok = await apiGuard(context, () async {
      await action();
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok != true) return;
    ref.invalidate(frameShopProvider);
    ref.invalidate(userFrameProvider(ref.read(accountProvider).myId));
    if (doneKey != null) showToast(context, context.t(doneKey));
  }

  Future<void> _topUp() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TopupScreen()));
    if (mounted) ref.invalidate(frameShopProvider);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final shop = ref.watch(frameShopProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('frames_title')), leading: panelCloseButton(context)),
      body: shop.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.wifi_off_rounded,
          title: error is ApiException ? apiErrorText(context, error) : errorText(context, error),
          action: FilledButton(onPressed: () => ref.invalidate(frameShopProvider), child: Text(s.t('retry'))),
        ),
        data: (shop) => _content(context, shop),
      ),
    );
  }

  Widget _content(BuildContext context, FrameShop shop) {
    final s = context.s;
    final theme = Theme.of(context);
    final me = ref.read(accountProvider).myId;
    final items = shop.items.where((f) => f.onSale || shop.owned.contains(f.key)).toList();
    if (items.isEmpty) return EmptyState(icon: Icons.filter_frames_rounded, title: s.t('frames_empty'));
    final picked = shop.byKey(_picked ?? shop.equipped ?? items.first.key) ?? items.first;
    return Column(children: [
      const SizedBox(height: 28),
      Center(child: FramedAvatar(frame: picked, size: 120, child: UserAvatar(userId: me, size: 120, showOnline: false))),
      const SizedBox(height: 28),
      Text(picked.titleFor(s.locale), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
        child: Text(s.t('frames_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 13)),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 112, mainAxisSpacing: 8, crossAxisSpacing: 8),
          itemCount: items.length,
          itemBuilder: (context, i) => _tile(context, shop, items[i], items[i].key == picked.key),
        ),
      ),
      _actions(context, shop, picked),
    ]);
  }

  Widget _tile(BuildContext context, FrameShop shop, AvatarFrameItem frame, bool selected) {
    final s = context.s;
    final theme = Theme.of(context);
    final owned = shop.owned.contains(frame.key);
    return Semantics(
      button: true,
      selected: selected,
      label: frame.titleFor(s.locale),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _picked = frame.key),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: Border.all(color: selected ? brandGold : Colors.transparent, width: 2),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            FramedAvatar(
              frame: frame,
              size: 50,
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.primary.withValues(alpha: 0.25)),
                child: const SizedBox.square(dimension: 50),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              shop.equipped == frame.key ? s.t('frames_wearing') : owned ? s.t('frames_owned') : formatUzs(context, frame.priceUzs),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: owned ? brandGold : theme.hintColor),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, FrameShop shop, AvatarFrameItem picked) {
    final s = context.s;
    final theme = Theme.of(context);
    final api = ref.read(sadoApiProvider);
    final owned = shop.owned.contains(picked.key);
    final wearing = shop.equipped == picked.key;
    final enough = shop.balanceUzs >= picked.priceUzs;
    final busy = _busy
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    final Widget button;
    if (wearing) {
      button = OutlinedButton(
        onPressed: _busy ? null : () => _run(() => api.wearFrame(null), null),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        child: busy ?? Text(s.t('frames_take_off')),
      );
    } else if (owned) {
      button = FilledButton(
        onPressed: _busy ? null : () => _run(() => api.wearFrame(picked.key), null),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        child: busy ?? Text(s.t('frames_wear')),
      );
    } else if (storeBlocksWalletSpending) {
      // Where the balance could only be bought outside the store it may not buy digital goods.
      button = const SizedBox.shrink();
    } else {
      button = FilledButton.icon(
        onPressed: _busy ? null : (enough ? () => _run(() => api.buyFrame(picked.key), 'frames_bought') : _topUp),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        icon: busy ?? Icon(enough ? Icons.filter_frames_rounded : Icons.account_balance_wallet_rounded),
        label: Text(enough ? s.t('frames_buy', {'price': formatUzs(context, picked.priceUzs)}) : s.t('gifts_topup')),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${s.t('gifts_balance')}: ${formatUzs(context, shop.balanceUzs)}', textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor)),
          const SizedBox(height: 8),
          button,
        ]),
      ),
    );
  }
}
