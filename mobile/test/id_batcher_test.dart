import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/id_batcher.dart';
import 'package:sado/core/api/sado_api.dart';

void main() {
  test('ids asked together go in one request; unknown ids resolve to null', () async {
    final requests = <List<int>>[];
    final batcher = IdBatcher<String>((ids) async {
      requests.add(ids);
      return {1: 'one'};
    });

    final results = await Future.wait([batcher.load(1), batcher.load(2)]);

    expect(results, ['one', null]);
    expect(requests, [
      [1, 2],
    ]);
  });

  test('a failed request fails its ids so the caller can retry', () async {
    var fail = true;
    final batcher = IdBatcher<String>((ids) async {
      if (fail) throw ApiException('NETWORK');
      return {7: 'seven'};
    });

    await expectLater(batcher.load(7), throwsA(isA<ApiException>()));
    fail = false;
    expect(await batcher.load(7), 'seven');
  });
}
