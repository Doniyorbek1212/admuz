import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart' show apiErrorText, apiGuard, formatUzs;
import 'game_screen.dart' show GameAvatar;
import 'games_live.dart';
import 'games_lobby_screen.dart' show formatWhen, openLiveGame;
import 'games_models.dart';

/// An arena tournament: prizes, rules, joining, and while it runs automatic pairing for as long as the player
/// stays here (or pauses); standings refresh on their own.
class TournamentScreen extends ConsumerStatefulWidget {
  const TournamentScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<TournamentScreen> createState() => _TournamentScreenState();
}

class _TournamentScreenState extends ConsumerState<TournamentScreen> {
  static const _refreshEvery = Duration(seconds: 8);

  late final GamesLive _live = ref.read(gamesLiveProvider);
  late final SadoApi _api = ref.read(sadoApiProvider);
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _refresh;
  Timer? _clock;
  TournamentInfo? _t;
  bool _ready = false;
  bool _paused = false;

  int get _me => ref.read(accountProvider).myId;

  @override
  void initState() {
    super.initState();
    _live.hold();
    _events = _live.events.listen(_onEvent);
    _load();
    _refresh = Timer.periodic(_refreshEvery, (_) => _load());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    if (_ready) _live.send({'t': 'arena', 'tournament': widget.id, 'ready': false});
    _refresh?.cancel();
    _clock?.cancel();
    unawaited(_events?.cancel());
    _live.release();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = TournamentInfo.fromJson(await _api.tournament(widget.id));
      if (!mounted) return;
      setState(() => _t = t);
      _autoReady();
    } on ApiException catch (error) {
      if (mounted && _t == null) showToast(context, apiErrorText(context, error));
    }
  }

  /// Joined players in a running arena are paired while they stay on this screen, unless they paused.
  void _autoReady() {
    final t = _t;
    if (t == null || !t.joined || !t.running || _ready || _paused) return;
    _setReady(true);
  }

  void _setReady(bool ready) {
    if (!_live.send({'t': 'arena', 'tournament': widget.id, 'ready': ready})) return;
    setState(() {
      _ready = ready;
      _paused = !ready;
    });
  }

  // Cached here: looking the route up from socket callbacks (outside build) left stale inherited dependents.
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  bool get _isCurrent => _route?.isCurrent ?? false;

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    switch (m['t']) {
      case 'ready':
        if (_ready) _live.send({'t': 'arena', 'tournament': widget.id, 'ready': true});
        if (!_ready) _autoReady();
      case 'arena':
        if (m['tournament'] != widget.id) return;
        setState(() {
          _ready = m['ready'] == true;
          // "Not ready" only ever answers a pause (here or from a later game screen): stay paused.
          if (!_ready) _paused = true;
        });
      case 'game':
        final game = _live.games[(m['game'] as Map)['id']];
        if (game == null || game.tournamentId != widget.id || !game.active || game.sideOf(_me) == null) return;
        // A game screen on top opens the next arena game itself; otherwise (even under a dialog) open it here,
        // or the clock would run out unseen.
        if (!_isCurrent && _live.open.isNotEmpty) return;
        unawaited(_play(game));
      case 'error':
        if (m['ref'] == 'arena') showToast(context, apiErrorText(context, ApiException('${m['code']}')));
    }
  }

  Future<void> _play(LiveGame game) async {
    final result = await openLiveGame(context, _live, game);
    if (!mounted) return;
    if (result == 'pause') {
      setState(() {
        _ready = false;
        _paused = true;
      });
    }
    unawaited(_load());
  }

  Future<void> _join() async {
    final done = await apiGuard(context, () async {
      await _api.joinTournament(widget.id);
      return true;
    });
    if (done != true || !mounted) return;
    _paused = false;
    await _load();
  }

  Future<void> _leave() async {
    final s = context.s;
    if (!await confirm(context, title: s.t('g_t_leave_confirm'), confirmLabel: s.t('g_t_leave'), destructive: true)) return;
    if (!mounted) return;
    if (_ready) _setReady(false);
    await apiGuard(context, () => _api.leaveTournament(widget.id));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t?.title ?? s.t('g_tab_tournaments'))),
      body: t == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
                _header(context, t),
                if (t.prizeUzs > 0) _prizes(context, t),
                _action(context, t),
                const SizedBox(height: 8),
                Text(s.t('g_t_standings'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (t.standings.isEmpty)
                  Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s.t('g_t_nobody'))))
                else
                  for (final row in t.standings) _StandingTile(row: row, over: t.over),
                const SizedBox(height: 12),
                _rules(context, t),
              ]),
            ),
    );
  }

  Widget _header(BuildContext context, TournamentInfo t) {
    final s = context.s;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final countdown = t.status == 'scheduled'
        ? s.t('g_t_starts_in', {'t': _span(t.startsAt.difference(now))})
        : t.running
            ? s.t('g_t_ends_in', {'t': _span(t.endsAt.difference(now))})
            : s.t('g_t_${t.status}');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emoji_events_rounded, color: Color(0xFFE8B422), size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.t(t.kind == 'chess' ? 'g_chess' : 'g_checkers')} · ${t.timeControl} · ${s.t('g_t_arena')}',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                Text(countdown, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${formatWhen(context, t.startsAt)} — ${formatWhen(context, t.endsAt)} · ${s.t('g_t_players', {'n': '${t.players}'})}'),
          if (t.description.isNotEmpty) ...[const SizedBox(height: 8), Text(t.description)],
        ]),
      ),
    );
  }

  static String _span(Duration d) {
    if (d.isNegative) return '0:00';
    final h = d.inHours, m = d.inMinutes % 60, sec = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
    if (d.inDays > 0) return '${d.inDays}d ${h % 24}:$mm';
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  Widget _prizes(BuildContext context, TournamentInfo t) {
    final s = context.s;
    final theme = Theme.of(context);
    return Card(
      color: const Color(0xFFE8B422).withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.t('g_t_prize_pool'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          Text(formatUzs(context, t.prizeUzs), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (var i = 0; i < t.prizes.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(width: 30, child: Text(i < 3 ? ['🥇', '🥈', '🥉'][i] : '${i + 1}.', style: const TextStyle(fontSize: 18))),
                Expanded(child: Text(s.t('g_t_place', {'n': '${i + 1}'}))),
                Text(formatUzs(context, t.prizes[i]), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          const SizedBox(height: 6),
          Text(s.t('g_t_prize_note', {'n': '${t.minGames}'}), style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _action(BuildContext context, TournamentInfo t) {
    final s = context.s;
    final theme = Theme.of(context);
    if (t.over) return const SizedBox.shrink();
    if (!t.joined) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _join,
        icon: const Icon(Icons.how_to_reg_rounded),
        label: Text(s.t('g_t_join')),
      );
    }
    if (!t.running) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle_rounded, color: Colors.green),
          title: Text(s.t('g_t_joined')),
          subtitle: Text(s.t('g_t_joined_hint')),
          trailing: TextButton(onPressed: _leave, child: Text(s.t('g_t_leave'))),
        ),
      );
    }
    return Card(
      color: _ready ? theme.colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          if (_ready) const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)) else const Icon(Icons.pause_circle_rounded, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text(s.t(_ready ? 'g_t_waiting' : 'g_t_paused'), style: theme.textTheme.titleSmall)),
          if (_ready)
            OutlinedButton(onPressed: () => _setReady(false), child: Text(s.t('g_arena_pause')))
          else
            FilledButton(onPressed: () => _setReady(true), child: Text(s.t('g_t_ready'))),
        ]),
      ),
    );
  }

  Widget _rules(BuildContext context, TournamentInfo t) {
    final s = context.s;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.rule_rounded),
        title: Text(s.t('g_t_rules')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [Text(s.t('g_t_rules_text', {'n': '${t.minGames}'}))],
      ),
    );
  }
}

class _StandingTile extends StatelessWidget {
  const _StandingTile({required this.row, required this.over});

  final Standing row;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final place = row.place;
    return ListTile(
      dense: true,
      selected: row.me,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: SizedBox(
        width: 74,
        child: Row(children: [
          SizedBox(
            width: 28,
            child: Text(over && place != null && place <= 3 ? ['🥇', '🥈', '🥉'][place - 1] : '${row.rank}',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          GameAvatar(name: row.name, telegramUserId: row.telegramUserId, size: 36),
        ]),
      ),
      title: Row(children: [
        Flexible(child: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (row.fire) const Padding(padding: EdgeInsets.only(left: 4), child: Text('🔥')),
      ]),
      subtitle: Text('${row.rating} · ${s.t('g_t_games', {'n': '${row.games}'})}'
          '${over && row.prizeUzs > 0 ? ' · ${formatUzs(context, row.prizeUzs)}' : ''}'),
      trailing: Text('${row.score}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
    );
  }
}
