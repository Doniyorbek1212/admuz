import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'sado_api.dart';

/// Collects the ids asked for in the same frame (everyone on a chat list screen) into as few requests as possible.
/// An id the server does not know resolves to null. A failed request fails its ids, so the provider asking
/// retries (Riverpod does that on its own) instead of keeping "none" for the whole session after one bad start.
class IdBatcher<T> {
  IdBatcher(this._fetch, {this.perRequest = 100});

  final Future<Map<int, T>> Function(List<int> ids) _fetch;
  final int perRequest;
  final Map<int, Completer<T?>> _pending = {};
  Timer? _flush;

  Future<T?> load(int id) {
    final completer = _pending.putIfAbsent(id, Completer.new);
    _flush ??= Timer(Duration.zero, _send);
    return completer.future;
  }

  Future<void> _send() async {
    _flush = null;
    final batch = Map.of(_pending);
    _pending.clear();
    final ids = batch.keys.toList();
    for (var i = 0; i < ids.length; i += perRequest) {
      final chunk = ids.sublist(i, math.min(i + perRequest, ids.length));
      try {
        final found = await _fetch(chunk);
        for (final id in chunk) {
          batch[id]!.complete(found[id]);
        }
      } on ApiException catch (error) {
        debugPrint('batched lookup failed: $error');
        for (final id in chunk) {
          batch[id]!.completeError(error);
        }
      }
    }
  }
}
