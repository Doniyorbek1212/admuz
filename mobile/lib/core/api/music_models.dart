import 'market_models.dart';

/// Hub "Music" sections (server: app.models.MusicCategory); labels are translated as `music_<key>`.
const musicCategories = ['uz_new', 'uz_old', 'world', 'car'];

/// A song an admin uploaded to the UZARO server (/v1/music); streamed from [audioUrl].
class MusicTrack {
  const MusicTrack({required this.id, required this.category, required this.title, required this.artist, required this.audioUrl, required this.durationSeconds});

  factory MusicTrack.fromJson(Map<String, dynamic> j) => MusicTrack(
        id: j['id'] as String,
        category: j['category'] as String? ?? '',
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        audioUrl: resolveMediaUrl(j['audio_url'] as String? ?? ''),
        durationSeconds: j['duration_seconds'] as int? ?? 0,
      );

  final String id;
  final String category;
  final String title;
  final String artist;
  final String audioUrl;
  final int durationSeconds;
}

class MusicPage {
  const MusicPage(this.items, this.total);

  factory MusicPage.fromJson(Map<String, dynamic> j) =>
      MusicPage([for (final t in j['items'] as List) MusicTrack.fromJson(t as Map<String, dynamic>)], j['total'] as int? ?? 0);

  final List<MusicTrack> items;
  final int total;
}
