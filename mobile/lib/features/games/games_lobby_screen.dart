import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart' show apiErrorText, apiGuard, formatUzs;
import '../contacts/contacts_screen.dart';
import '../gifts/gift_widgets.dart' show ensureGiftsLinked;
import '../hub/games_screen.dart';
import '../settings/privacy_screen.dart' show promptText;
import '../webapp/web_app_screen.dart' show hasWebView;
import 'game_screen.dart';
import 'games_live.dart';
import 'games_models.dart';
import 'tournament_screen.dart';

/// Opens [game] once when it is a new live game of this player; true when a screen was pushed.
Future<Object?> openLiveGame(BuildContext context, GamesLive live, LiveGame game) async {
  if (!live.open.add(game.id)) return null;
  return Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => GameScreen(game: game)));
}

/// Online chess and checkers: quick play by time control, friend challenges, arena tournaments, leaderboards
/// and the player's game history. Playing needs the Telegram account proven to the UZARO server (one rating
/// per person).
class GamesLobbyScreen extends ConsumerStatefulWidget {
  const GamesLobbyScreen({super.key});

  @override
  ConsumerState<GamesLobbyScreen> createState() => _GamesLobbyScreenState();
}

class _GamesLobbyScreenState extends ConsumerState<GamesLobbyScreen> {
  late final GamesLive _live = ref.read(gamesLiveProvider);
  late final SadoApi _api = ref.read(sadoApiProvider);
  StreamSubscription<Map<String, dynamic>>? _events;
  String _kind = 'chess';
  bool? _linked;
  GamesProfile? _profile;
  List<LiveGame> _active = const [];
  TimeControl? _seeking;
  DateTime? _seekSince;
  Timer? _seekTicker;

  int get _me => ref.read(accountProvider).myId;

  @override
  void initState() {
    super.initState();
    _live.hold();
    _events = _live.events.listen(_onEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    if (_seeking != null) _live.send({'t': 'cancel'});
    _seekTicker?.cancel();
    unawaited(_events?.cancel());
    _live.release();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _linked = null);
    final linked = await ensureGiftsLinked(context, ref);
    if (!mounted) return;
    setState(() => _linked = linked);
    if (linked) await _load();
  }

  Future<void> _load() async {
    try {
      var profile = GamesProfile.fromJson(await _api.gamesMe());
      if (profile.name.isEmpty) {
        final account = ref.read(accountProvider);
        await _api.setGameName(_defaultName(account.userName(account.myId)));
        profile = GamesProfile.fromJson(await _api.gamesMe());
      }
      final active = [for (final g in (await _api.gamesActive())['items'] as List) LiveGame.fromJson((g as Map).cast<String, dynamic>())];
      if (mounted) {
        setState(() {
          _profile = profile;
          _active = active;
        });
      }
    } on ApiException catch (error) {
      if (mounted) showToast(context, apiErrorText(context, error));
    }
  }

  static String _defaultName(String telegramName) {
    final clean = telegramName.trim();
    if (clean.length < 2) return "O'yinchi";
    return clean.length > 32 ? clean.substring(0, 32) : clean;
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
    final s = context.s;
    switch (m['t']) {
      case 'game':
        final game = _live.games[(m['game'] as Map)['id']];
        if (game == null || !game.active || game.sideOf(_me) == null || game.moves.isNotEmpty) return;
        if (!_isCurrent && _live.open.isNotEmpty) return; // a game screen is already in front
        if (game.tournamentId != null) return; // the tournament screen opens its own games
        _stopSeeking(send: false);
        unawaited(_play(game));
      case 'ready':
        final seek = _seeking;
        if (seek != null) _seek(seek);
        setState(() {});
      case 'disconnected':
        setState(() {});
      case 'challenge':
        if (_isCurrent) unawaited(_incoming(m));
      case 'challenge_sent':
        showToast(context, s.t(m['online'] == true ? 'g_challenge_sent' : 'g_challenge_sent_offline'));
      case 'declined':
        showToast(context, s.t('g_challenge_declined'));
      case 'error':
        final ref = m['ref'];
        if (ref == 'seek' || ref == 'challenge' || ref == 'accept') {
          _stopSeeking(send: false);
          showToast(context, apiErrorText(context, ApiException('${m['code']}')));
        }
    }
  }

  Future<void> _play(LiveGame game) async {
    final result = await openLiveGame(context, _live, game);
    if (!mounted) return;
    unawaited(_load());
    if (result == 'again') {
      final tc = _profile?.timeControls.where((t) => t.initial == game.initial && t.increment == game.increment).firstOrNull;
      if (tc != null) {
        setState(() => _kind = game.kind);
        _seek(tc);
      }
    }
  }

  void _seek(TimeControl tc) {
    final sent = _live.send({'t': 'seek', 'kind': _kind, 'initial': tc.initial, 'increment': tc.increment, 'rated': true, 'name': _profile?.name ?? ''});
    if (!sent) {
      showToast(context, context.s.t('g_offline'));
      return;
    }
    setState(() {
      _seeking = tc;
      _seekSince ??= DateTime.now();
    });
    _seekTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopSeeking({bool send = true}) {
    if (send) _live.send({'t': 'cancel'});
    _seekTicker?.cancel();
    _seekTicker = null;
    if (mounted) {
      setState(() {
        _seeking = null;
        _seekSince = null;
      });
    }
  }

  Future<void> _challenge() async {
    final s = context.s;
    final tc = await _pickTimeControl(context, _profile?.timeControls ?? const []);
    if (tc == null || !mounted) return;
    final user = await Navigator.of(context).push<td.User>(MaterialPageRoute(builder: (_) => const ContactsScreen(pickUser: true)));
    if (user == null || !mounted) return;
    final sent = _live.send({'t': 'challenge', 'telegram_user_id': user.id, 'kind': _kind, 'initial': tc.initial,
        'increment': tc.increment, 'rated': false, 'name': _profile?.name ?? ''});
    if (!sent) showToast(context, s.t('g_offline'));
  }

  Future<void> _incoming(Map<String, dynamic> m) async {
    final s = context.s;
    final kind = m['kind'] == 'chess' ? s.t('g_chess') : s.t('g_checkers');
    final tc = '${(m['initial'] as int) ~/ 60}+${m['increment']}';
    final ok = await confirm(context,
        title: s.t('g_challenge_from', {'name': '${m['from']}'}), message: '$kind · $tc', confirmLabel: s.t('g_accept'));
    if (!mounted) return;
    _live.send({'t': ok ? 'accept' : 'decline', 'id': m['id'], 'name': _profile?.name ?? ''});
  }

  Future<void> _rename() async {
    final s = context.s;
    // promptText keeps the controller alive through the close animation (disposing it here crashed the dialog).
    final name = await promptText(context, title: s.t('g_name'), label: s.t('g_name_hint'), initial: _profile?.name ?? '', maxLength: 32);
    if (name == null || name.length < 2 || !mounted) return;
    await apiGuard(context, () => _api.setGameName(name));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.t('g_title')),
          bottom: _linked == true
              ? TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
                  Tab(text: s.t('g_tab_play')),
                  Tab(text: s.t('g_tab_tournaments')),
                  Tab(text: s.t('g_tab_rating')),
                  Tab(text: s.t('g_tab_history')),
                ])
              : null,
        ),
        body: switch (_linked) {
          null => const Center(child: CircularProgressIndicator()),
          false => EmptyState(
              icon: Icons.sports_esports_outlined,
              title: s.t('g_link_needed'),
              subtitle: s.t('g_link_needed_hint'),
              action: Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
                FilledButton(onPressed: _start, child: Text(s.t('retry'))),
                if (hasWebView) OutlinedButton(onPressed: _offline, child: Text(s.t('g_offline_games'))),
              ]),
            ),
          true => Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'chess', label: Text(s.t('g_chess')), icon: const Text('♞︎', style: TextStyle(fontSize: 18))),
                    ButtonSegment(value: 'checkers', label: Text(s.t('g_checkers')), icon: const Icon(Icons.circle, size: 16)),
                  ],
                  selected: {_kind},
                  onSelectionChanged: _seeking != null ? null : (v) => setState(() => _kind = v.first),
                ),
              ),
              Expanded(
                child: TabBarView(children: [
                  _playTab(context),
                  TournamentsTab(kind: _kind, live: _live),
                  LeaderboardTab(kind: _kind),
                  HistoryTab(kind: _kind, onOpen: (g) => openLiveGame(context, _live, g)),
                ]),
              ),
            ]),
        },
      ),
    );
  }

  void _offline() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GamesScreen()));

  Widget _playTab(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final profile = _profile;
    if (profile == null) return const Center(child: CircularProgressIndicator());
    final seeking = _seeking;
    final active = _active.where((g) => g.kind == _kind).toList();
    final controls = profile.timeControls;
    final usual = controls.where((t) => t.speed == 'blitz').firstOrNull ?? controls.firstOrNull;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
      if (!_live.connected.value)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(s.t('g_connecting'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      if (profile.banned)
        Card(color: theme.colorScheme.errorContainer, child: ListTile(leading: const Icon(Icons.block), title: Text(s.t('api_PLAYER_BANNED')))),
      _ProfileCard(
        name: profile.name,
        telegramUserId: _me,
        ratings: [for (final speed in _speeds) (speed, profile.rating(_kind, speed))],
        onRename: _rename,
      ),
      for (final g in active)
        Card(
          color: theme.colorScheme.secondaryContainer,
          child: ListTile(
            leading: const Icon(Icons.play_circle_fill_rounded, color: Colors.green, size: 36),
            title: Text(s.t('g_resume'), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${g.white.name} — ${g.black.name} · ${g.timeControl}'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _play(g),
          ),
        ),
      const SizedBox(height: 12),
      if (seeking != null)
        _SeekingCard(
          control: seeking,
          seconds: DateTime.now().difference(_seekSince ?? DateTime.now()).inSeconds,
          onCancel: _stopSeeking,
        )
      else ...[
        if (usual != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            onPressed: profile.banned ? null : () => _seek(usual),
            icon: const Icon(Icons.play_arrow_rounded, size: 30),
            label: Text(s.t('g_play_now', {'time': _timeLabel(context, usual)})),
          ),
        const SizedBox(height: 4),
        Text(s.t('g_play_now_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 18),
        Text(s.t('g_pick_time'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        Text(s.t('g_pick_time_hint'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 10),
        for (final speed in _speeds)
          if (controls.any((t) => t.speed == speed))
            _SpeedRow(
              speed: speed,
              controls: [for (final t in controls) if (t.speed == speed) t],
              onPick: profile.banned ? null : _seek,
            ),
      ],
      const SizedBox(height: 8),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: _BigTile(
            icon: Icons.person_add_alt_1_rounded,
            color: const Color(0xFF3D8BFF),
            title: s.t('g_play_friend'),
            subtitle: s.t('g_play_friend_hint'),
            onTap: _challenge,
          ),
        ),
        if (hasWebView) ...[
          const SizedBox(width: 10),
          Expanded(
            child: _BigTile(
              icon: Icons.smart_toy_outlined,
              color: const Color(0xFF8E5CF7),
              title: s.t('g_vs_computer'),
              subtitle: s.t('g_offline_games_hint'),
              onTap: _offline,
            ),
          ),
        ],
      ]),
    ]);
  }
}

const _speeds = ['bullet', 'blitz', 'rapid'];

IconData _speedIcon(String speed) => switch (speed) {
      'bullet' => Icons.bolt_rounded,
      'blitz' => Icons.local_fire_department_rounded,
      _ => Icons.timer_rounded,
    };

/// "5 min" or "3 min + 2 s", the way people say it, instead of "3+2".
String _timeLabel(BuildContext context, TimeControl tc) {
  final minutes = context.s.t('g_minutes', {'n': '${tc.initial ~/ 60}'});
  return tc.increment > 0 ? '$minutes ${context.s.t('g_plus_seconds', {'n': '${tc.increment}'})}' : minutes;
}

/// One speed (bullet, blitz, rapid): its name, what it means, and its time controls as buttons.
class _SpeedRow extends StatelessWidget {
  const _SpeedRow({required this.speed, required this.controls, required this.onPick});

  final String speed;
  final List<TimeControl> controls;
  final void Function(TimeControl)? onPick;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final pick = onPick;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_speedIcon(speed), size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(s.t('g_speed_$speed'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Expanded(
            child: Text('· ${s.t('g_speed_${speed}_hint')}', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          for (final tc in controls)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Material(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: pick == null ? null : () => pick(tc),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(children: [
                        Text(s.t('g_minutes', {'n': '${tc.initial ~/ 60}'}), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                        Text(
                          tc.increment > 0 ? s.t('g_plus_seconds', {'n': '${tc.increment}'}) : s.t('g_no_bonus'),
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

/// The player: avatar, game name (tap the pencil to change it) and the three ratings of the chosen game.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.name, required this.telegramUserId, required this.ratings, required this.onRename});

  final String name;
  final int telegramUserId;
  final List<(String, GameRatingInfo?)> ratings;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Column(children: [
          Row(children: [
            GameAvatar(name: name, telegramUserId: telegramUserId, size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                Text(s.t('g_rating_about'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12.5)),
              ]),
            ),
            IconButton(tooltip: s.t('g_name'), icon: const Icon(Icons.edit_outlined), onPressed: onRename),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (final (speed, info) in ratings)
              Expanded(
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(_speedIcon(speed), size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 3),
                    Text('${info?.rating ?? 1500}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  ]),
                  Text(
                    (info?.provisional ?? true) ? '${s.t('g_speed_$speed')} · ${s.t('g_rating_new')}' : s.t('g_speed_$speed'),
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                  ),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Looking for an opponent: what is being looked for, for how long, and a way out.
class _SeekingCard extends StatelessWidget {
  const _SeekingCard({required this.control, required this.seconds, required this.onCancel});

  final TimeControl control;
  final int seconds;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
        child: Column(children: [
          const SizedBox.square(dimension: 44, child: CircularProgressIndicator(strokeWidth: 4)),
          const SizedBox(height: 14),
          Text(s.t('g_seeking'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${_timeLabel(context, control)} · ${s.t('g_speed_${control.speed}')}'),
          Text(
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: 4),
          Text(s.t('g_seeking_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onCancel, child: Text(s.t('cancel'))),
        ]),
      ),
    );
  }
}

class _BigTile extends StatelessWidget {
  const _BigTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 20, backgroundColor: color.withValues(alpha: 0.15), child: Icon(icon, color: color)),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}

Future<TimeControl?> _pickTimeControl(BuildContext context, List<TimeControl> controls) => showModalBottomSheet<TimeControl>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final tc in controls)
              ActionChip(label: Text('${_timeLabel(context, tc)} · ${context.s.t('g_speed_${tc.speed}')}'), onPressed: () => Navigator.of(context).pop(tc)),
          ]),
        ),
      ),
    );

// ---- tournaments ----

class TournamentsTab extends ConsumerStatefulWidget {
  const TournamentsTab({super.key, required this.kind, required this.live});

  final String kind;
  final GamesLive live;

  @override
  ConsumerState<TournamentsTab> createState() => _TournamentsTabState();
}

class _TournamentsTabState extends ConsumerState<TournamentsTab> {
  List<TournamentInfo>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final body = await ref.read(sadoApiProvider).tournaments();
      final items = [for (final t in body['items'] as List) TournamentInfo.fromJson((t as Map).cast<String, dynamic>())];
      if (mounted) setState(() => _items = items);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _items ??= const []);
        showToast(context, apiErrorText(context, error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final items = _items?.where((t) => t.kind == widget.kind).toList();
    if (items == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(children: [
              SizedBox(height: 360, child: EmptyState(icon: Icons.emoji_events_outlined, title: s.t('g_no_tournaments'), subtitle: s.t('g_no_tournaments_hint'))),
            ])
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (context, i) => TournamentCard(
                t: items[i],
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TournamentScreen(id: items[i].id)));
                  unawaited(_load());
                },
              ),
            ),
    );
  }
}

class TournamentCard extends StatelessWidget {
  const TournamentCard({super.key, required this.t, required this.onTap});

  final TournamentInfo t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final status = s.t('g_t_${t.status}');
    final color = switch (t.status) { 'running' => Colors.green, 'scheduled' => theme.colorScheme.primary, _ => theme.colorScheme.outline };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.emoji_events_rounded, color: Color(0xFFE8B422)),
              const SizedBox(width: 8),
              Expanded(child: Text(t.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                child: Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _Fact(Icons.timer_outlined, t.timeControl),
              _Fact(Icons.event_rounded, formatWhen(context, t.startsAt)),
              _Fact(Icons.people_alt_outlined, '${t.players}'),
              if (t.prizeUzs > 0) _Fact(Icons.payments_outlined, formatUzs(context, t.prizeUzs)),
              if (t.joined) _Fact(Icons.check_circle_rounded, s.t('g_t_joined')),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(color: color)),
    ]);
  }
}

String formatWhen(BuildContext context, DateTime at) {
  final local = MaterialLocalizations.of(context);
  final time = local.formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: true);
  final now = DateTime.now();
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  return sameDay ? time : '${local.formatShortMonthDay(at)}, $time';
}

// ---- leaderboard ----

class LeaderboardTab extends ConsumerStatefulWidget {
  const LeaderboardTab({super.key, required this.kind});

  final String kind;

  @override
  ConsumerState<LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<LeaderboardTab> {
  String _speed = 'blitz';
  List<Map<String, dynamic>>? _items;
  Map<String, dynamic>? _me;
  String _loaded = '';

  Future<void> _load() async {
    final key = '${widget.kind}/$_speed';
    _loaded = key;
    try {
      final body = await ref.read(sadoApiProvider).gamesLeaderboard(widget.kind, _speed);
      if (!mounted || _loaded != key) return;
      setState(() {
        _items = [for (final r in body['items'] as List) (r as Map).cast<String, dynamic>()];
        _me = (body['me'] as Map?)?.cast<String, dynamic>();
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _items ??= const []);
        showToast(context, apiErrorText(context, error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    if (_loaded != '${widget.kind}/$_speed') {
      _items = null;
      unawaited(_load());
    }
    final items = _items;
    final me = _me;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(spacing: 8, children: [
          for (final speed in const ['bullet', 'blitz', 'rapid'])
            ChoiceChip(label: Text(s.t('g_speed_$speed')), selected: _speed == speed, onSelected: (_) => setState(() => _speed = speed)),
        ]),
      ),
      Expanded(
        child: items == null
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? EmptyState(icon: Icons.leaderboard_outlined, title: s.t('g_board_empty'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final r = items[i];
                        final rank = r['rank'] as int;
                        return ListTile(
                          selected: r['me'] == true,
                          leading: SizedBox(
                            width: 76,
                            child: Row(children: [
                              SizedBox(
                                width: 30,
                                child: Text(rank <= 3 ? ['🥇', '🥈', '🥉'][rank - 1] : '$rank',
                                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                              ),
                              const SizedBox(width: 6),
                              GameAvatar(name: '${r['name']}', telegramUserId: r['telegram_user_id'] as int?, size: 38),
                            ]),
                          ),
                          title: Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(s.t('g_wld', {'w': '${r['wins']}', 'l': '${r['losses']}', 'd': '${r['draws']}'})),
                          trailing: Text('${r['rating']}${r['provisional'] == true ? '?' : ''}',
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        );
                      },
                    ),
                  ),
      ),
      if (me != null && me['rank'] != null)
        Material(
          color: theme.colorScheme.primaryContainer,
          child: SafeArea(
            top: false,
            child: ListTile(
              leading: const Icon(Icons.person_pin_rounded),
              title: Text(s.t('g_my_rank', {'n': '${me['rank']}'})),
              trailing: Text('${me['rating']}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
    ]);
  }
}

// ---- history ----

class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key, required this.kind, required this.onOpen});

  final String kind;
  final Future<Object?> Function(LiveGame game) onOpen;

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> {
  List<LiveGame>? _items;
  bool _more = false;
  String _loaded = '';

  Future<void> _load({bool more = false}) async {
    final kind = widget.kind;
    _loaded = kind;
    try {
      final body = await ref.read(sadoApiProvider).gamesHistory(kind: kind, offset: more ? (_items?.length ?? 0) : 0);
      final page = [for (final g in body['items'] as List) LiveGame.fromJson((g as Map).cast<String, dynamic>())];
      if (!mounted || _loaded != kind) return;
      setState(() {
        _items = [if (more) ...?_items, ...page];
        _more = body['has_more'] == true;
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _items ??= const []);
        showToast(context, apiErrorText(context, error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    if (_loaded != widget.kind) {
      _items = null;
      unawaited(_load());
    }
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return EmptyState(icon: Icons.history_rounded, title: s.t('g_history_empty'));
    final me = ref.read(accountProvider).myId;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length + (_more ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == items.length) {
            unawaited(_load(more: true));
            return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
          }
          final g = items[i];
          final side = g.sideOf(me) ?? 'white';
          final opponent = side == 'white' ? g.black : g.white;
          final mine = side == 'white' ? g.white : g.black;
          final result = !g.active && g.winner.isNotEmpty ? (g.winner == 'draw' ? 'd' : g.winner == side ? 'w' : 'l') : '';
          final color = switch (result) { 'w' => Colors.green, 'l' => Colors.red, _ => Colors.grey };
          return ListTile(
            leading: GameAvatar(name: opponent.name, telegramUserId: opponent.telegramUserId),
            title: Text('${opponent.name} (${opponent.rating})', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([
              g.timeControl,
              if (g.reason.isNotEmpty) s.t('g_reason_${g.reason}'),
              if (g.createdAt != null) formatWhen(context, g.createdAt!),
            ].join(' · ')),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(g.active ? s.t('g_live') : s.t('g_result_$result'), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
              if (g.rated && mine.delta != 0)
                Text(mine.delta > 0 ? '+${mine.delta}' : '${mine.delta}', style: TextStyle(color: mine.delta > 0 ? Colors.green : Colors.red)),
            ]),
            onTap: () async {
              await widget.onOpen(g);
              if (mounted) unawaited(_load());
            },
          );
        },
      ),
    );
  }
}
