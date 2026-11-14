import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/gift_models.dart';
import '../../core/api/id_batcher.dart';
import '../../core/api/sado_api.dart';
import '../../core/theme.dart' show brandGold;
import '../../state/telegram.dart';

/// Who gets a chat's UZARO gifts: the person (Telegram user id), or a group/channel itself (its TDLib chat id);
/// null for bots and Saved Messages.
int? giftRecipientOf(TelegramAccount account, td.Chat chat) {
  if (account.isSavedMessages(chat)) return null;
  final user = account.privateUser(chat);
  if (user != null) return account.isBot(user) ? null : user.id;
  return chat.type is td.ChatTypeSecret ? null : chat.id;
}

final _showcaseLoaderProvider = Provider((ref) => IdBatcher<GiftShowcase>(ref.watch(sadoApiProvider).topGifts));

/// How long a chat row keeps showing gifts before asking again (new, hidden or withdrawn gifts).
const _showcaseTtl = Duration(minutes: 5);

/// Dearest gifts of a user (Telegram id) or a group/channel (TDLib chat id); null when they show none.
/// Sending a gift invalidates its recipient at once; everything else refreshes every [_showcaseTtl].
final giftShowcaseProvider = FutureProvider.family<GiftShowcase?, int>((ref, recipientId) async {
  if (!ref.watch(sadoApiProvider).configured) return null;
  final refresh = Timer(_showcaseTtl, ref.invalidateSelf);
  ref.onDispose(refresh.cancel);
  return ref.watch(_showcaseLoaderProvider).load(recipientId);
});

/// Behind a chat row: the recipient's dearest gifts drift around the whole row, each on its own loop, always fully
/// inside the row's frame. Nothing (and no ticker) for recipients without gifts.
class GiftDrift extends ConsumerWidget {
  const GiftDrift({super.key, required this.recipientId, this.size = 24});

  final int recipientId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gifts = ref.watch(giftShowcaseProvider(recipientId)).value?.gifts ?? const <SentGift>[];
    if (gifts.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(child: ExcludeSemantics(child: RepaintBoundary(child: _DriftingGifts(gifts: gifts, size: size))));
  }
}

class _DriftingGifts extends StatefulWidget {
  const _DriftingGifts({required this.gifts, required this.size});

  final List<SentGift> gifts;
  final double size;

  @override
  State<_DriftingGifts> createState() => _DriftingGiftsState();
}

class _DriftingGiftsState extends State<_DriftingGifts> with SingleTickerProviderStateMixin {
  static const _lap = Duration(seconds: 16);
  late final AnimationController _loop = AnimationController(vsync: this, duration: _lap);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Remove animations" in the phone settings keeps the gifts where they are.
    if (MediaQuery.disableAnimationsOf(context)) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// A figure-eight per gift, spread evenly along the loop; Alignment keeps the whole picture inside the row.
  static Alignment _place(double t, int index, int count) {
    final phase = 2 * math.pi * (t + index / count);
    return Alignment(0.92 * math.sin(phase), 0.8 * math.sin(2 * phase + index));
  }

  /// The gifts come dearest first: the dearest is drawn biggest and clearest.
  static const _scale = [1.45, 1.15, 0.95];

  @override
  Widget build(BuildContext context) {
    final gifts = widget.gifts;
    return AnimatedBuilder(
      animation: _loop,
      // Painted cheapest first so the dearest gift passes over the others.
      builder: (context, _) => Stack(children: [
        for (final (i, sent) in gifts.indexed.toList().reversed)
          Align(
            alignment: _place(_loop.value, i, gifts.length),
            child: Opacity(
              opacity: i == 0 ? 0.9 : 0.72,
              child: GiftStill(key: ValueKey(sent.id), url: sent.gift.animationUrl, size: widget.size * _scale[math.min(i, _scale.length - 1)]),
            ),
          ),
      ]),
    );
  }
}

/// The first frame of an animated gift, decoded at its small display size; decoding stops after that frame.
class GiftStill extends StatefulWidget {
  const GiftStill({super.key, required this.url, required this.size});

  final String url;
  final double size;

  @override
  State<GiftStill> createState() => _GiftStillState();
}

class _GiftStillState extends State<GiftStill> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_image == null && _stream == null) _resolve();
  }

  void _resolve() {
    final pixels = (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
    final provider = ResizeImage(NetworkImage(widget.url), width: pixels, height: pixels, policy: ResizeImagePolicy.fit);
    final listener = ImageStreamListener(
      (info, _) {
        final first = info.image.clone();
        info.dispose();
        _stop();
        if (!mounted) return first.dispose();
        setState(() => _image = first);
      },
      onError: (error, _) {
        debugPrint('gift picture failed: $error');
        _stop();
        if (mounted) setState(() => _failed = true);
      },
    );
    _listener = listener;
    _stream = provider.resolve(createLocalImageConfiguration(context))..addListener(listener);
  }

  /// Without listeners the animated image stops decoding further frames.
  void _stop() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) return RawImage(image: image, width: widget.size, height: widget.size, fit: BoxFit.contain);
    return SizedBox.square(
      dimension: widget.size,
      child: _failed ? Icon(Icons.card_giftcard_rounded, size: widget.size * 0.8, color: brandGold) : null,
    );
  }
}
