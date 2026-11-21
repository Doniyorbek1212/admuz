import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/interests.dart';
import 'package:sado/features/hub/hub_catalog.dart';

void main() {
  test('ad topics match the server list (app.services.interests.TOPICS)', () {
    expect(adTopicLabelKeys.keys, [
      'taxi', 'pharmacy', 'hotel', 'doctor', 'car_service', 'bank', 'travel', 'food', //
      'shops', 'movies', 'music', 'games', 'gifts',
      'tech', 'fashion', 'beauty', 'education', 'real_estate', 'sport', 'kids',
    ]);
  });

  test('every hub tile with a topic teaches a known topic', () {
    final topics = [for (final item in [...hubLocalItems, ...hubFunItems, ...hubToolItems]) ?item.topic];
    expect(topics, containsAll(['taxi', 'food', 'shops', 'movies', 'music', 'games', 'gifts']));
    expect(topics.where((t) => !adTopicLabelKeys.containsKey(t)), isEmpty);
    expect(hubToolItems.firstWhere((i) => i.action == HubAction.ads).topic, isNull);
  });
}
