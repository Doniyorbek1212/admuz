import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart' show apiErrorText;
import 'board_logic.dart';
import 'game_board.dart';
import 'games_live.dart';
import 'games_models.dart';

/// One online game: live board and clocks while it runs, a replay once it is over.
/// Pops with 'again' when the player asks for a new game with the same settings.
class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key, required this.game});

  final LiveGame game;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  late final GamesLive _live = ref.read(gamesLiveProvider);
  late final int _me = ref.read(accountProvider).myId;
  late LiveGame _game = widget.game;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _ticker;
  Timer? _pendingTimeout;
  String? _pending;
  int? _ply; // null: the live position; otherwise the replay step
  bool? _flip;
  bool _dialogOpen = false;
  List<List<String>>? _replay;

  String? get _side => _game.sideOf(_me);
  bool get _flipped => _flip ?? _side == 'black';

  @override
  void initState() {
    super.initState();
    _live.hold();
    _live.open.add(_game.id);
    _live.watch(_game.id);
    _events = _live.events.listen(_onEvent);
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _game.active) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pendingTimeout?.cancel();
    unawaited(_events?.cancel());
    _live.unwatch(_game.id);
    _live.open.remove(_game.id);
    _live.release();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    switch (m['t']) {
      case 'game':
        final game = _live.games[(m['game'] as Map)['id']];
        if (game == null) return;
        if (game.id != _game.id) {
          _nextArenaGame(game);
          return;
        }
        final wasActive = _game.active;
        final theirMove = game.moves.length > _game.moves.length && _pending == null;
        setState(() {
          _game = game;
          _pending = null;
          _replay = null;
          if (_ply != null && game.active) _ply = null;
        });
        if (theirMove) HapticFeedback.lightImpact();
        if (wasActive && !game.active) unawaited(_showResult());
      case 'error':
        if (_pending == null && m['ref'] != 'draw' && m['ref'] != 'resign') return;
        setState(() => _pending = null);
        showToast(context, apiErrorText(context, ApiException('${m['code']}')));
      case 'disconnected' || 'ready':
        setState(() {});
    }
  }

  /// Arena: the next pairing arrives while this finished game is on screen; it takes this screen's place.
  void _nextArenaGame(LiveGame game) {
    final tournament = _game.tournamentId;
    if (_game.active || !game.active || tournament == null || game.tournamentId != tournament) return;
    if (game.sideOf(_me) == null || !_live.open.add(game.id)) return;
    final navigator = Navigator.of(context);
    if (_dialogOpen) navigator.pop();
    unawaited(navigator.pushReplacement(MaterialPageRoute<Object>(builder: (_) => GameScreen(game: game))));
  }

  // ---- actions ----

  void _move(String move) {
    if (!_live.send({'t': 'move', 'game': _game.id, 'move': move})) {
      showToast(context, context.s.t('g_offline'));
      return;
    }
    setState(() => _pending = move);
    // No answer at all (the connection died quietly): give the board back instead of freezing the turn.
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(const Duration(seconds: 8), () {
      if (!mounted || _pending != move) return;
      setState(() => _pending = null);
      showToast(context, context.s.t('g_offline'));
    });
  }

  Future<void> _resign() async {
    final s = context.s;
    final early = _game.moves.length < 2;
    final ok = await confirm(context, title: s.t(early ? 'g_abort_confirm' : 'g_resign_confirm'),
        confirmLabel: s.t(early ? 'g_abort' : 'g_resign'), destructive: true);
    if (ok && mounted && !_live.send({'t': 'resign', 'game': _game.id})) showToast(context, s.t('g_offline'));
  }

  void _draw({bool decline = false}) {
    if (!_live.send({'t': decline ? 'decline_draw' : 'draw', 'game': _game.id})) {
      showToast(context, context.s.t('g_offline'));
    } else if (!decline && _game.drawOffer.isEmpty) {
      showToast(context, context.s.t('g_draw_sent'));
    }
  }

  Future<void> _showResult() async {
    final s = context.s;
    final side = _side;
    final g = _game;
    final title = g.status == 'aborted'
        ? s.t('g_aborted')
        : g.winner == 'draw'
            ? s.t('g_draw')
            : side == null
                ? s.t(g.winner == 'white' ? 'g_white_won' : 'g_black_won')
                : s.t(g.winner == side ? 'g_win' : 'g_loss');
    final delta = side == null ? 0 : (side == 'white' ? g.white.delta : g.black.delta);
    _dialogOpen = true;
    final again = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          g.winner == side ? Icons.emoji_events_rounded : g.winner == 'draw' ? Icons.handshake_rounded : Icons.flag_rounded,
          size: 40,
          color: g.winner == side ? const Color(0xFFE8B422) : null,
        ),
        title: Text(title, textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s.t('g_reason_${g.reason}'), textAlign: TextAlign.center),
          if (g.rated && g.status != 'aborted' && side != null) ...[
            const SizedBox(height: 12),
            Text(
              s.t('g_rating_change', {'d': delta >= 0 ? '+$delta' : '$delta'}),
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: delta >= 0 ? Colors.green : Colors.red),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop('view'), child: Text(s.t('g_view_board'))),
          if (g.tournamentId == null)
            FilledButton(onPressed: () => Navigator.of(context).pop('again'), child: Text(s.t('g_new_game')))
          else
            FilledButton.tonal(onPressed: () => Navigator.of(context).pop('pause'), child: Text(s.t('g_arena_pause'))),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted) return;
    if (again == 'again') Navigator.of(context).pop('again');
    if (again == 'pause') {
      _live.send({'t': 'arena', 'tournament': g.tournamentId, 'ready': false});
      Navigator.of(context).pop('pause');
    }
  }

  // ---- view ----

  List<String> _cellsLive() {
    var cells = _game.chess ? chessFromFen(_game.position) : checkersFromServer(_game.position);
    if (_pending != null) cells = _game.chess ? playChess(cells, _pending!) : playCheckers(cells, _pending!);
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final g = _game;
    final side = _side;
    final moves = [...g.moves, ?_pending];
    final ply = _ply;
    final cells = ply == null ? _cellsLive() : (_replay ??= replay(g.kind, g.moves))[ply];
    final shown = ply ?? moves.length;
    final last = shown > 0 ? moveSquares(g.kind, moves[shown - 1]) : const <int>[];
    final myTurn = g.active && side == g.turn && _pending == null && ply == null;
    final top = _flipped ? 'white' : 'black';
    final bottom = _flipped ? 'black' : 'white';
    int? check;
    if (g.chess && g.check && ply == null && _pending == null) {
      final king = g.turn == 'white' ? 'K' : 'k';
      check = cells.indexOf(king);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('${s.t(g.chess ? 'g_chess' : 'g_checkers')} · ${g.timeControl}'),
        actions: [
          IconButton(tooltip: s.t('g_flip'), icon: const Icon(Icons.screen_rotation_alt_rounded), onPressed: () => setState(() => _flip = !_flipped)),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final boardSize = box.maxWidth.clamp(0.0, box.maxHeight - 250).toDouble();
          return Column(children: [
            if (g.active && !_live.connected.value) _Banner(icon: Icons.wifi_off_rounded, text: s.t('g_offline')),
            _PlayerBar(game: g, side: top, active: g.active && g.turn == top),
            Center(
              child: SizedBox(
                width: boardSize,
                child: GameBoard(
                  kind: g.kind,
                  cells: cells,
                  flipped: _flipped,
                  lastMove: last,
                  checkSquare: check != null && check >= 0 ? check : null,
                  legal: myTurn ? g.legal : const [],
                  onMove: _move,
                ),
              ),
            ),
            _PlayerBar(game: g, side: bottom, active: g.active && g.turn == bottom),
            if (g.active && g.firstMoveMs != null)
              _Banner(
                icon: Icons.timer_outlined,
                text: s.t(side == g.turn ? 'g_first_move_you' : 'g_first_move', {
                  's': '${((g.firstMoveMs! - DateTime.now().difference(g.receivedAt).inMilliseconds) / 1000).ceil().clamp(0, 99)}'
                }),
              ),
            if (g.active && side != null && g.drawOffer.isNotEmpty && g.drawOffer != side)
              _Banner(icon: Icons.handshake_outlined, text: s.t('g_draw_from'), actions: [
                TextButton(onPressed: () => _draw(decline: true), child: Text(s.t('g_decline'))),
                FilledButton(onPressed: _draw, child: Text(s.t('g_accept'))),
              ]),
            Expanded(child: _MoveList(notation: g.notation.length == g.moves.length ? g.notation : g.moves, current: shown, chess: g.chess,
                onTap: (i) => setState(() => _ply = i == g.moves.length ? null : i))),
            _actions(context, g, side, shown),
          ]);
        }),
      ),
    );
  }

  Widget _actions(BuildContext context, LiveGame g, String? side, int shown) {
    final s = context.s;
    final total = g.moves.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(children: [
        if (g.active && side != null) ...[
          _ActionButton(icon: Icons.flag_outlined, label: s.t(total < 2 ? 'g_abort' : 'g_resign'), onTap: _resign),
          _ActionButton(
            icon: Icons.handshake_outlined,
            label: s.t(g.drawOffer == side ? 'g_draw_offered' : 'g_draw_offer'),
            onTap: total < 2 || g.drawOffer == side ? null : _draw,
          ),
        ] else if (g.tournamentId == null && side != null)
          _ActionButton(icon: Icons.replay_rounded, label: s.t('g_new_game'), onTap: () => Navigator.of(context).pop('again')),
        const Spacer(),
        IconButton(
          tooltip: s.t('g_prev'),
          icon: const Icon(Icons.chevron_left_rounded, size: 32),
          onPressed: shown == 0 ? null : () => setState(() => _ply = shown - 1),
        ),
        IconButton(
          tooltip: s.t('g_next'),
          icon: const Icon(Icons.chevron_right_rounded, size: 32),
          onPressed: _ply == null ? null : () => setState(() => _ply = shown + 1 >= total ? null : shown + 1),
        ),
      ]),
    );
  }
}

class _PlayerBar extends ConsumerWidget {
  const _PlayerBar({required this.game, required this.side, required this.active});

  final LiveGame game;
  final String side;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final person = side == 'white' ? game.white : game.black;
    final ms = game.clockMs(side);
    final low = game.active && ms < 20000;
    final finished = game.status == 'finished' && game.rated;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        GameAvatar(name: person.name, telegramUserId: person.telegramUserId, size: 36),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: person.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: '  ${person.rating}', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              if (finished && person.delta != 0)
                TextSpan(
                  text: person.delta > 0 ? ' +${person.delta}' : ' ${person.delta}',
                  style: TextStyle(color: person.delta > 0 ? Colors.green : Colors.red, fontWeight: FontWeight.w600),
                ),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? (low ? Colors.red.shade600 : theme.colorScheme.primary) : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            formatClock(ms),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: active ? Colors.white : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ]),
    );
  }
}

String formatClock(int ms) {
  final total = (ms / 1000).ceil();
  if (ms < 10000 && ms > 0) {
    final tenths = ms ~/ 100; // floored, so 9.95 s shows 0:09.9, never 0:010.0
    return '0:0${tenths ~/ 10}.${tenths % 10}';
  }
  final m = total ~/ 60, sec = total % 60;
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// The player's Telegram photo when the app knows them, else initials.
class GameAvatar extends ConsumerWidget {
  const GameAvatar({super.key, required this.name, required this.telegramUserId, this.size = 40});

  final String name;
  final int? telegramUserId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = telegramUserId;
    if (id != null && ref.watch(userProvider(id)) != null) return UserAvatar(userId: id, size: size, showOnline: false);
    return Avatar(name: name, seed: id ?? name.hashCode, size: size);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.actions = const []});

  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: theme.colorScheme.onSecondaryContainer))),
        ...actions,
      ]),
    );
  }
}

class _MoveList extends StatefulWidget {
  const _MoveList({required this.notation, required this.current, required this.chess, required this.onTap});

  final List<String> notation;
  final int current;
  final bool chess;
  final ValueChanged<int> onTap;

  @override
  State<_MoveList> createState() => _MoveListState();
}

class _MoveListState extends State<_MoveList> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_MoveList old) {
    super.didUpdateWidget(old);
    if (old.notation.length != widget.notation.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(spacing: 2, runSpacing: 2, children: [
        for (var i = 0; i < widget.notation.length; i++) ...[
          if (i.isEven)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 6),
              child: Text('${i ~/ 2 + 1}.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => widget.onTap(i + 1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              decoration: BoxDecoration(
                color: widget.current == i + 1 ? theme.colorScheme.primaryContainer : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(widget.notation[i], style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(label));
}
