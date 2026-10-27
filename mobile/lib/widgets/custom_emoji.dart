import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/tdlib/td_client.dart';
import '../features/chat/composer_panels.dart';
import '../state/providers.dart';
import '../state/telegram.dart';

/// Collects custom emoji ids asked for in the same frame into one GetCustomEmojiStickers call.
class _EmojiLoader {
  _EmojiLoader(this.account);

  final TelegramAccount account;
  final Map<int, Completer<td.Sticker?>> _pending = {};
  Timer? _flush;

  Future<td.Sticker?> load(int id) {
    final completer = _pending.putIfAbsent(id, Completer.new);
    _flush ??= Timer(Duration.zero, _send);
    return completer.future;
  }

  Future<void> _send() async {
    _flush = null;
    final batch = Map.of(_pending);
    _pending.clear();
    try {
      final result = await account.send<td.Stickers>(td.GetCustomEmojiStickers(customEmojiIds: batch.keys.take(200).toList()));
      final byId = {
        for (final sticker in result.stickers)
          if (sticker.fullType case td.StickerFullTypeCustomEmoji(:final customEmojiId)) customEmojiId: sticker,
      };
      batch.forEach((id, completer) => completer.complete(byId[id]));
    } on TdException {
      for (final completer in batch.values) {
        completer.complete(null);
      }
    }
  }
}

final _loaderProvider = Provider((ref) => _EmojiLoader(ref.watch(accountProvider)));

// shortcut: never evicted; fine for the few hundred emoji a session sees, add autoDispose if memory grows.
final customEmojiProvider = FutureProvider.family<td.Sticker?, int>((ref, id) => ref.watch(_loaderProvider).load(id));

/// A custom emoji drawn from its sticker; [fallback] (the plain emoji) shows while loading or on failure.
class CustomEmojiView extends ConsumerWidget {
  const CustomEmojiView({super.key, required this.id, this.size = 20, this.fallback = ''});

  final int id;
  final double size;
  final String fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sticker = ref.watch(customEmojiProvider(id)).value;
    return SizedBox.square(
      dimension: size,
      child: sticker == null
          ? FittedBox(child: Text(fallback.isEmpty ? '⭐' : fallback))
          : StickerThumb(sticker: sticker),
    );
  }
}

/// Premium emoji status shown after a user's name; nothing when there is none.
class EmojiStatusBadge extends StatelessWidget {
  const EmojiStatusBadge({super.key, required this.status, this.size = 18});

  final td.EmojiStatus? status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id = switch (status?.type) {
      td.EmojiStatusTypeCustomEmoji(:final customEmojiId) => customEmojiId,
      td.EmojiStatusTypeUpgradedGift(:final modelCustomEmojiId) => modelCustomEmojiId,
      _ => 0,
    };
    if (id == 0) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(left: 4), child: CustomEmojiView(id: id, size: size));
  }
}
