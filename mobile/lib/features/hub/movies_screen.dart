import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/movie_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';
import 'movie_downloads.dart';
import 'movie_player.dart';

/// Hub "Movies": films and series an admin published, by kind and category, with search.
class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  bool? _series; // null: films and series
  String _category = '';
  List<(String, int)> _categories = const [];
  List<MovieTitle> _items = const [];
  int _total = 0;
  bool _loading = false;
  ApiException? _error;
  int _generation = 0; // drops responses of filters the user already changed

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
    });
    final api = ref.read(sadoApiProvider);
    unawaited(api.recordActivity(ref.read(sharedPreferencesProvider), 'movies_open'));
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _items = const [];
      _total = 0;
      _error = null;
    });
    final api = ref.read(sadoApiProvider);
    unawaited(api.movieCategories(series: _series).then((c) {
      if (mounted && generation == _generation) setState(() => _categories = c);
    }, onError: (Object _) {}));
    await _fetch(generation, 0);
  }

  Future<void> _loadMore() async {
    if (_loading || _error != null || _items.length >= _total) return;
    await _fetch(_generation, _items.length);
  }

  Future<void> _fetch(int generation, int offset) async {
    setState(() => _loading = true);
    try {
      final page = await ref.read(sadoApiProvider).movies(series: _series, category: _category, query: _search.text.trim(), offset: offset);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [..._items, ...page.items];
        _total = page.total;
      });
    } on ApiException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('hub_movies')), actions: [
        IconButton(
          icon: const Icon(Icons.download_for_offline_rounded),
          tooltip: s.t('downloads'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MovieDownloadsScreen())),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _search,
                onChanged: _onSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: s.t('movies_search'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: s.t('close'),
                          onPressed: () {
                            _search.clear();
                            _reload();
                          },
                        ),
                  filled: true,
                  fillColor: groupCardColor(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _ChipRow(children: [
              for (final (value, key) in const [(null, 'movies_all'), (false, 'movies_films'), (true, 'movies_series')])
                _Chip(
                  label: s.t(key),
                  selected: _series == value,
                  onTap: () {
                    setState(() {
                      _series = value;
                      _category = '';
                    });
                    _reload();
                  },
                ),
            ]),
          ),
          if (_categories.isNotEmpty)
            SliverToBoxAdapter(
              child: _ChipRow(children: [
                for (final (name, count) in _categories)
                  _Chip(
                    label: '$name · $count',
                    selected: _category == name,
                    outlined: true,
                    onTap: () {
                      setState(() => _category = _category == name ? '' : name);
                      _reload();
                    },
                  ),
              ]),
            ),
          if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? EmptyState(
                          icon: Icons.wifi_off_rounded,
                          title: apiErrorText(context, _error!),
                          action: FilledButton(onPressed: _reload, child: Text(s.t('retry'))),
                        )
                      : EmptyState(
                          icon: Icons.movie_filter_rounded,
                          title: s.t(_search.text.isEmpty && _category.isEmpty ? 'movies_empty' : 'movies_empty_search'),
                        ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, bottom + 16),
              // Width-based columns: 3 on a phone, more on an unfolded or tablet screen.
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.52,
                ),
                itemCount: _items.length,
                itemBuilder: (context, i) => _PosterCard(title: _items[i]),
              ),
            ),
        ]),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 4, 6), children: children),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap, this.outlined = false});

  final String label;
  final bool selected;
  final bool outlined;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? primary : (outlined ? Colors.transparent : groupCardColor(context)),
        shape: StadiumBorder(side: BorderSide(color: selected ? primary : Theme.of(context).dividerColor)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(label,
                  style: TextStyle(fontWeight: FontWeight.w600, color: selected ? Theme.of(context).colorScheme.onPrimary : null)),
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.title});

  final MovieTitle title;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: title.title,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MovieDetailScreen(id: title.id, preview: title))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(fit: StackFit.expand, children: [
                NetImage(title.posterUrl ?? '', icon: Icons.movie_rounded),
                if (title.isSeries)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
                      child: Text(s.t('movies_series'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Text(title.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.2)),
          Text(
            [if (title.year != null) '${title.year}', ...title.categories.take(1)].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.hintColor, fontSize: 12.5),
          ),
        ]),
      ),
    );
  }
}

/// A film's or series' page: poster, facts, description and the play button or the episode list.
class MovieDetailScreen extends ConsumerStatefulWidget {
  const MovieDetailScreen({super.key, required this.id, this.preview});

  final String id;

  /// List entry shown while the full title (with videos) loads.
  final MovieTitle? preview;

  @override
  ConsumerState<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends ConsumerState<MovieDetailScreen> {
  MovieTitle? _title;
  ApiException? _error;
  int? _season;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final title = await ref.read(sadoApiProvider).movie(widget.id);
      if (mounted) setState(() => _title = title);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _play(MovieTitle title, int index) async {
    await openMoviePlayer(context, title, index);
    if (mounted) setState(() {}); // refresh "continue" positions
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final title = _title ?? widget.preview;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(title?.title ?? s.t('hub_movies'))),
      body: title == null
          ? (_error != null
              ? EmptyState(icon: Icons.wifi_off_rounded, title: apiErrorText(context, _error!), action: FilledButton(onPressed: _load, child: Text(s.t('retry'))))
              : const Center(child: CircularProgressIndicator()))
          : LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 680;
              final info = _info(context, title, wide);
              final videos = _videos(context, title);
              final bottom = MediaQuery.paddingOf(context).bottom + 16;
              // Unfolded phones and tablets: poster and facts on the left, episodes on the right.
              if (wide) {
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: constraints.maxWidth * 0.42, child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 8, bottom), children: info)),
                  Expanded(child: ListView(padding: EdgeInsets.fromLTRB(8, 16, 16, bottom), children: videos)),
                ]);
              }
              return ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, bottom), children: [...info, ...videos]);
            }),
    );
  }

  List<Widget> _info(BuildContext context, MovieTitle title, bool wide) {
    final theme = Theme.of(context);
    final facts = [
      if (title.year != null) '${title.year}',
      if (title.country.isNotEmpty) title.country,
      if (title.language.isNotEmpty) title.language,
      if (!title.isSeries && title.videos.isNotEmpty && title.videos.first.durationSeconds > 0) _length(context, title.videos.first.durationSeconds),
    ];
    return [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(width: wide ? 150 : 120, height: wide ? 225 : 180, child: NetImage(title.posterUrl ?? '', icon: Icons.movie_rounded)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            if (facts.isNotEmpty) Text(facts.join(' · '), style: TextStyle(color: theme.hintColor)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in title.categories)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Text(c, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
            ]),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      if (!title.isSeries && title.videos.isNotEmpty) ...[
        _playButton(context, title, 0),
        const SizedBox(height: 8),
        _DownloadButton(title: title, video: title.videos.first),
      ],
      if (title.description.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(title.description, style: const TextStyle(height: 1.45)),
      ],
    ];
  }

  Widget _playButton(BuildContext context, MovieTitle title, int index) {
    final s = context.s;
    final saved = moviePosition(ref.read(sharedPreferencesProvider), title.videos[index].id);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(saved == null ? s.t('movies_watch') : s.t('movies_continue', {'time': formatDuration(saved)}),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        onPressed: () => _play(title, index),
      ),
    );
  }

  List<Widget> _videos(BuildContext context, MovieTitle title) {
    if (!title.isSeries) return const [];
    final s = context.s;
    final seasons = {for (final v in title.videos) v.season}.toList()..sort();
    final season = _season ?? (seasons.isEmpty ? 0 : seasons.first);
    final prefs = ref.read(sharedPreferencesProvider);
    return [
      if (title.videos.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text(s.t('movies_episodes'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (seasons.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 8, children: [
              for (final n in seasons)
                ChoiceChip(label: Text(s.t('movies_season', {'n': '$n'})), selected: n == season, onSelected: (_) => setState(() => _season = n)),
            ]),
          ),
        const SizedBox(height: 8),
        SettingsGroup(children: [
          for (final (i, v) in title.videos.indexed)
            if (v.season == season)
              ListTile(
                leading: CircleAvatar(child: Text('${v.episode}')),
                title: Text(v.name.isNotEmpty ? v.name : s.t('movies_episode', {'n': '${v.episode}'})),
                subtitle: Text([
                  if (v.durationSeconds > 0) _length(context, v.durationSeconds),
                  if (moviePosition(prefs, v.id) case final at?) '▶ ${formatDuration(at)}',
                ].join(' · ')),
                trailing: _DownloadButton(title: title, video: v, compact: true),
                onTap: () => _play(title, i),
              ),
        ]),
      ],
    ];
  }
}

/// Save a video to the phone, show its progress (tap stops it), or delete the saved copy.
class _DownloadButton extends ConsumerWidget {
  const _DownloadButton({required this.title, required this.video, this.compact = false});

  final MovieTitle title;
  final MovieVideo video;

  /// Icon only (episode rows) instead of a full-width button.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final downloads = ref.watch(movieDownloadsProvider);
    final notifier = ref.read(movieDownloadsProvider.notifier);
    final progress = downloads.active[video.id];
    final saved = downloads.saved.containsKey(video.id);

    Future<void> start() async {
      final messenger = ScaffoldMessenger.of(context);
      final failed = s.t('movies_download_failed');
      if (!await notifier.download(title, video)) messenger.showSnackBar(SnackBar(content: Text(failed)));
    }

    final (Widget icon, String label, VoidCallback onTap) = switch ((saved, progress)) {
      (true, _) => (const Icon(Icons.download_done_rounded), s.t('movies_saved'), () => confirmMovieDelete(context, ref, video.id)),
      (_, final p?) => (
          SizedBox.square(
            dimension: 22,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(value: p > 0 ? p : null, strokeWidth: 2.5),
              const Icon(Icons.stop_rounded, size: 14),
            ]),
          ),
          s.t('movies_downloading', {'n': '${(p * 100).floor()}'}),
          () => notifier.cancel(video.id),
        ),
      _ => (
          const Icon(Icons.download_rounded),
          [s.t('download'), if (video.sizeBytes > 0) formatFileSize(video.sizeBytes)].join(' · '),
          () => unawaited(start()),
        ),
    };
    if (compact) return IconButton(icon: icon, tooltip: label, onPressed: onTap);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        icon: icon,
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        onPressed: onTap,
      ),
    );
  }
}

Future<void> confirmMovieDelete(BuildContext context, WidgetRef ref, String videoId) async {
  final s = context.s;
  final notifier = ref.read(movieDownloadsProvider.notifier);
  if (await confirm(context, title: s.t('movies_delete_saved'), confirmLabel: s.t('delete'), destructive: true)) {
    await notifier.delete(videoId);
  }
}

/// Films and episodes saved on the phone; opens without internet.
class MovieDownloadsScreen extends ConsumerWidget {
  const MovieDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final downloads = ref.watch(movieDownloadsProvider);
    final saved = downloads.saved.entries.toList();
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('downloads'))),
      body: saved.isEmpty
          ? EmptyState(icon: Icons.download_for_offline_outlined, title: s.t('movies_downloads_empty'))
          : ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.paddingOf(context).bottom + 16), children: [
              SettingsGroup(children: [
                for (final MapEntry(key: videoId, value: title) in saved)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(width: 40, height: 60, child: NetImage(title.posterUrl ?? '', icon: Icons.movie_rounded)),
                    ),
                    title: Text(title.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      if (title.isSeries) ...[
                        if (title.videos.first.season > 0) s.t('movies_season', {'n': '${title.videos.first.season}'}),
                        if (title.videos.first.episode > 0) s.t('movies_episode', {'n': '${title.videos.first.episode}'}),
                      ],
                      if (title.videos.first.sizeBytes > 0) formatFileSize(title.videos.first.sizeBytes),
                    ].join(' · ')),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: s.t('delete'),
                      onPressed: () => confirmMovieDelete(context, ref, videoId),
                    ),
                    onTap: () => openMoviePlayer(context, title, 0),
                  ),
              ]),
            ]),
    );
  }
}

/// "94 daqiqa" for a film, "0:42" for a clip shorter than a minute.
String _length(BuildContext context, int seconds) =>
    seconds >= 60 ? context.t('movies_minutes', {'n': '${seconds ~/ 60}'}) : formatDuration(Duration(seconds: seconds));
