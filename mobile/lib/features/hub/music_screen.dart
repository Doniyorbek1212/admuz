import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/playback.dart';
import '../../widgets/common.dart';
import '../../widgets/playback_bar.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

/// Hub "Music": songs admins uploaded to the UZARO server, in sections (Uzbek new/old, world, for the car).
/// Tapping a song plays the whole visible list in order in the shared player (background + notification).
class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  String _category = musicCategories.first;
  List<MusicTrack> _items = const [];
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
    await _fetch(generation, 0);
  }

  Future<void> _loadMore() async {
    if (_loading || _error != null || _items.length >= _total) return;
    await _fetch(_generation, _items.length);
  }

  Future<void> _fetch(int generation, int offset) async {
    setState(() => _loading = true);
    try {
      final page = await ref.read(sadoApiProvider).music(category: _category, query: _search.text.trim(), offset: offset);
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

  void _play(int index) {
    final queue = [
      for (final t in _items)
        if (Uri.tryParse(t.audioUrl) case final url?) HubTrack(id: t.id, title: t.title, artist: t.artist, url: url),
    ];
    unawaited(Playback.instance.playTracks(queue, queue.indexWhere((t) => t.id == _items[index].id)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('hub_music'))),
      body: Column(children: [
        const PlaybackBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: CustomScrollView(controller: _scroll, slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) {
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 400), _reload);
                    },
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: s.t('music_search'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: groupCardColor(context),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 48,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 4, 6), children: [
                    for (final c in musicCategories)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: c == 'car' ? const Icon(Icons.directions_car_rounded, size: 18) : null,
                          label: Text(s.t('music_$c')),
                          selected: _category == c,
                          onSelected: (_) {
                            setState(() => _category = c);
                            _reload();
                          },
                        ),
                      ),
                  ]),
                ),
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
                          : EmptyState(icon: Icons.library_music_rounded, title: s.t(_search.text.isEmpty ? 'music_empty' : 'movies_empty_search')),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(12, 4, 12, MediaQuery.paddingOf(context).bottom + 16),
                  sliver: SliverList.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final t = _items[i];
                      return ValueListenableBuilder<NowPlaying?>(
                        valueListenable: Playback.instance.nowPlaying,
                        builder: (context, now, _) {
                          final current = now?.track?.id == t.id;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: theme.colorScheme.primary.withValues(alpha: current ? 1 : 0.12),
                              child: Icon(current ? Icons.equalizer_rounded : Icons.music_note_rounded,
                                  color: current ? theme.colorScheme.onPrimary : theme.colorScheme.primary),
                            ),
                            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: current ? FontWeight.w700 : null)),
                            subtitle: t.artist.isEmpty ? null : Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: t.durationSeconds > 0 ? Text(formatDuration(Duration(seconds: t.durationSeconds)), style: TextStyle(color: theme.hintColor)) : null,
                            onTap: () => _play(i),
                          );
                        },
                      );
                    },
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
