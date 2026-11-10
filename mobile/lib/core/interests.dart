import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';
import 'api/sado_api.dart';

/// Interest topics of personalised hub ads (server: app.services.interests.TOPICS), with their label keys.
/// Hub categories reuse their tile labels.
const adTopicLabelKeys = {
  'taxi': 'hub_taxi',
  'pharmacy': 'hub_pharmacy',
  'hotel': 'hub_hotel',
  'doctor': 'hub_doctors',
  'car_service': 'hub_workshops',
  'bank': 'hub_banks',
  'travel': 'hub_travel',
  'food': 'hub_food',
  'shops': 'hub_shops',
  'movies': 'hub_movies',
  'music': 'hub_music',
  'games': 'hub_games',
  'gifts': 'hub_gifts',
  'tech': 'topic_tech',
  'fashion': 'topic_fashion',
  'beauty': 'topic_beauty',
  'education': 'topic_education',
  'real_estate': 'topic_real_estate',
  'sport': 'topic_sport',
  'kids': 'topic_kids',
};

const maxAdTopics = 3;

/// Whether what the user opens in the hub may tailor the ads they see. Off wipes what the server learnt.
final personalizedAdsProvider = NotifierProvider<PersonalizedAdsNotifier, bool>(PersonalizedAdsNotifier.new);

class PersonalizedAdsNotifier extends Notifier<bool> {
  static const _key = 'ads.personalized';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? true;

  Future<void> set(bool enabled) async {
    await ref.read(sharedPreferencesProvider).setBool(_key, enabled);
    state = enabled;
    if (!enabled && ref.read(sadoApiProvider).configured) await ref.read(sadoApiProvider).clearInterests();
  }
}

/// Fire-and-forget interest signal: the user opened ("open"), looked at ("view") or searched ("search") [topic].
void trackInterest(WidgetRef ref, String? topic, {String kind = 'open'}) {
  if (topic == null || !adTopicLabelKeys.containsKey(topic) || !ref.read(personalizedAdsProvider)) return;
  unawaited(ref.read(sadoApiProvider).sendInterest(topic, kind));
}
