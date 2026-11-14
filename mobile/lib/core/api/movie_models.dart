import 'market_models.dart';

/// A film or series from the hub's "Movies" section (server: /v1/movies). Videos are posts in a public Telegram channel.
class MovieTitle {
  const MovieTitle({
    required this.id,
    required this.isSeries,
    required this.title,
    required this.description,
    required this.year,
    required this.categories,
    required this.country,
    required this.language,
    required this.posterUrl,
    required this.videos,
  });

  factory MovieTitle.fromJson(Map<String, dynamic> j) => MovieTitle(
        id: j['id'] as String,
        isSeries: j['kind'] == 'series',
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        year: j['year'] as int?,
        categories: [for (final c in j['categories'] as List? ?? const []) c as String],
        country: j['country'] as String? ?? '',
        language: j['language'] as String? ?? '',
        posterUrl: switch (j['poster_url']) { final String url => resolveMediaUrl(url), _ => null },
        videos: [for (final v in j['videos'] as List? ?? const []) MovieVideo.fromJson(v as Map<String, dynamic>)],
      );

  /// Same shape as the server's, so a saved copy reads back through [MovieTitle.fromJson] (offline downloads).
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': isSeries ? 'series' : 'film',
        'title': title,
        'description': description,
        'year': year,
        'categories': categories,
        'country': country,
        'language': language,
        'poster_url': posterUrl,
        'videos': [for (final v in videos) v.toJson()],
      };

  final String id;
  final bool isSeries;
  final String title;
  final String description;
  final int? year;
  final List<String> categories;
  final String country;
  final String language;
  final String? posterUrl;

  /// Filled only by the detail endpoint, in season/episode order.
  final List<MovieVideo> videos;
}

class MovieVideo {
  const MovieVideo({
    required this.id,
    required this.season,
    required this.episode,
    required this.name,
    required this.durationSeconds,
    required this.height,
    required this.sizeBytes,
    required this.channel,
    required this.messageId,
  });

  factory MovieVideo.fromJson(Map<String, dynamic> j) => MovieVideo(
        id: j['id'] as String,
        season: j['season'] as int? ?? 0,
        episode: j['episode'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        durationSeconds: j['duration_seconds'] as int? ?? 0,
        height: j['height'] as int? ?? 0,
        sizeBytes: j['size_bytes'] as int? ?? 0,
        channel: j['channel'] as String? ?? '',
        messageId: j['message_id'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'season': season,
        'episode': episode,
        'name': name,
        'duration_seconds': durationSeconds,
        'height': height,
        'size_bytes': sizeBytes,
        'channel': channel,
        'message_id': messageId,
      };

  final String id;
  final int season;
  final int episode;
  final String name;
  final int durationSeconds;
  final int height;
  final int sizeBytes;
  final String channel;
  final int messageId;

  /// Public post link the app resolves through TDLib.
  String get link => 'https://t.me/$channel/$messageId';
}

class MoviePage {
  const MoviePage(this.items, this.total);

  factory MoviePage.fromJson(Map<String, dynamic> j) =>
      MoviePage([for (final t in j['items'] as List) MovieTitle.fromJson(t as Map<String, dynamic>)], j['total'] as int? ?? 0);

  final List<MovieTitle> items;
  final int total;
}
