import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/movie_models.dart';

void main() {
  test('a saved title reads back unchanged (offline downloads persist it as JSON)', () {
    final title = MovieTitle.fromJson({
      'id': 't1',
      'kind': 'series',
      'title': 'Sarguzasht',
      'description': 'Tavsif',
      'year': 2024,
      'categories': ['Drama'],
      'country': 'UZ',
      'language': 'uz',
      'poster_url': 'https://example.com/p.jpg',
      'videos': [
        {'id': 'v1', 'season': 1, 'episode': 2, 'name': 'Boshlanish', 'duration_seconds': 2400, 'height': 720, 'size_bytes': 900, 'channel': 'kino', 'message_id': 7},
      ],
    });

    final back = MovieTitle.fromJson(jsonDecode(jsonEncode(title.toJson())) as Map<String, dynamic>);

    expect(back.toJson(), title.toJson());
    expect(back.isSeries, isTrue);
    expect(back.videos.single.link, 'https://t.me/kino/7');
  });
}
