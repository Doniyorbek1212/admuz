/// Online chess and checkers as the UZARO server sends them (/v1/games, and the live socket's "game" events).
library;

class GamePerson {
  const GamePerson({required this.id, required this.name, required this.rating, required this.delta, this.telegramUserId});

  factory GamePerson.fromJson(Map<String, dynamic> j) => GamePerson(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '?',
        rating: j['rating'] as int? ?? 1500,
        delta: j['delta'] as int? ?? 0,
        telegramUserId: j['telegram_user_id'] as int?,
      );

  final String id;
  final String name;
  final int rating;
  final int delta;
  final int? telegramUserId;
}

class LiveGame {
  LiveGame({
    required this.id,
    required this.kind,
    required this.speed,
    required this.initial,
    required this.increment,
    required this.rated,
    required this.white,
    required this.black,
    required this.moves,
    required this.position,
    required this.turn,
    required this.legal,
    required this.notation,
    required this.check,
    required this.whiteMs,
    required this.blackMs,
    required this.clockRunning,
    required this.firstMoveMs,
    required this.status,
    required this.winner,
    required this.reason,
    required this.drawOffer,
    required this.receivedAt,
    this.tournamentId,
    this.createdAt,
  });

  factory LiveGame.fromJson(Map<String, dynamic> j) {
    final clocks = (j['clocks'] as Map?) ?? const {};
    return LiveGame(
      id: j['id'] as String,
      kind: j['kind'] as String? ?? 'chess',
      speed: j['speed'] as String? ?? 'blitz',
      initial: j['initial'] as int? ?? 0,
      increment: j['increment'] as int? ?? 0,
      rated: j['rated'] as bool? ?? true,
      white: GamePerson.fromJson((j['white'] as Map).cast<String, dynamic>()),
      black: GamePerson.fromJson((j['black'] as Map).cast<String, dynamic>()),
      moves: [for (final m in j['moves'] as List? ?? const []) '$m'],
      position: j['position'] as String? ?? '',
      turn: j['turn'] as String? ?? 'white',
      legal: [for (final m in j['legal'] as List? ?? const []) '$m'],
      notation: [for (final m in j['notation'] as List? ?? const []) '$m'],
      check: j['check'] as bool? ?? false,
      whiteMs: clocks['white'] as int? ?? 0,
      blackMs: clocks['black'] as int? ?? 0,
      clockRunning: j['clock_running'] as bool? ?? false,
      firstMoveMs: j['first_move_ms'] as int?,
      status: j['status'] as String? ?? 'active',
      winner: j['winner'] as String? ?? '',
      reason: j['reason'] as String? ?? '',
      drawOffer: j['draw_offer'] as String? ?? '',
      tournamentId: j['tournament_id'] as String?,
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
      receivedAt: DateTime.now(),
    );
  }

  final String id;
  final String kind; // chess | checkers
  final String speed; // bullet | blitz | rapid
  final int initial;
  final int increment;
  final bool rated;
  final GamePerson white;
  final GamePerson black;
  final List<String> moves;
  final String position;
  final String turn;
  final List<String> legal;
  final List<String> notation;
  final bool check;
  final int whiteMs;
  final int blackMs;
  final bool clockRunning;
  final int? firstMoveMs;
  final String status; // active | finished | aborted
  final String winner; // white | black | draw
  final String reason;
  final String drawOffer;
  final String? tournamentId;
  final DateTime? createdAt;
  final DateTime receivedAt;

  bool get active => status == 'active';
  bool get chess => kind == 'chess';

  /// 'white', 'black', or null when the Telegram user [telegramId] only watches.
  String? sideOf(int telegramId) =>
      white.telegramUserId == telegramId ? 'white' : black.telegramUserId == telegramId ? 'black' : null;

  /// The clock of [side] now, counting down locally since the server's snapshot.
  int clockMs(String side) {
    final base = side == 'white' ? whiteMs : blackMs;
    if (!active || !clockRunning || side != turn) return base;
    final left = base - DateTime.now().difference(receivedAt).inMilliseconds;
    return left < 0 ? 0 : left;
  }

  String get timeControl => '${initial ~/ 60}+$increment';
}

class GameRatingInfo {
  const GameRatingInfo(this.kind, this.speed, this.rating, this.provisional, this.games, this.wins, this.losses, this.draws, this.best, {this.rank});

  factory GameRatingInfo.fromJson(Map<String, dynamic> j) => GameRatingInfo(
        j['kind'] as String? ?? '',
        j['speed'] as String? ?? '',
        j['rating'] as int? ?? 1500,
        j['provisional'] as bool? ?? true,
        j['games'] as int? ?? 0,
        j['wins'] as int? ?? 0,
        j['losses'] as int? ?? 0,
        j['draws'] as int? ?? 0,
        j['best'] as int? ?? 1500,
        rank: j['rank'] as int?,
      );

  final String kind;
  final String speed;
  final int rating;
  final bool provisional;
  final int games;
  final int wins;
  final int losses;
  final int draws;
  final int best;
  final int? rank;

  String get label => '$rating${provisional ? '?' : ''}';
}

class TimeControl {
  const TimeControl(this.initial, this.increment, this.speed);

  factory TimeControl.fromJson(Map<String, dynamic> j) => TimeControl(j['initial'] as int, j['increment'] as int, j['speed'] as String);

  final int initial;
  final int increment;
  final String speed;

  String get label => '${initial ~/ 60}+$increment';
}

class GamesProfile {
  const GamesProfile(this.name, this.banned, this.ratings, this.timeControls);

  factory GamesProfile.fromJson(Map<String, dynamic> j) => GamesProfile(
        j['name'] as String? ?? '',
        j['banned'] as bool? ?? false,
        [for (final r in j['ratings'] as List? ?? const []) GameRatingInfo.fromJson((r as Map).cast<String, dynamic>())],
        [for (final t in j['time_controls'] as List? ?? const []) TimeControl.fromJson((t as Map).cast<String, dynamic>())],
      );

  final String name;
  final bool banned;
  final List<GameRatingInfo> ratings;
  final List<TimeControl> timeControls;

  GameRatingInfo? rating(String kind, String speed) => ratings.where((r) => r.kind == kind && r.speed == speed).firstOrNull;
}

class TournamentInfo {
  const TournamentInfo({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.initial,
    required this.increment,
    required this.startsAt,
    required this.endsAt,
    required this.status,
    required this.prizeUzs,
    required this.prizes,
    required this.minGames,
    required this.players,
    required this.joined,
    this.standings = const [],
  });

  factory TournamentInfo.fromJson(Map<String, dynamic> j) => TournamentInfo(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'chess',
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        initial: j['initial'] as int? ?? 0,
        increment: j['increment'] as int? ?? 0,
        startsAt: DateTime.parse(j['starts_at'] as String).toLocal(),
        endsAt: DateTime.parse(j['ends_at'] as String).toLocal(),
        status: j['status'] as String? ?? 'scheduled',
        prizeUzs: j['prize_uzs'] as int? ?? 0,
        prizes: [for (final p in j['prizes'] as List? ?? const []) p as int],
        minGames: j['min_games'] as int? ?? 1,
        players: j['players'] as int? ?? 0,
        joined: j['joined'] as bool? ?? false,
        standings: [for (final s in j['standings'] as List? ?? const []) Standing.fromJson((s as Map).cast<String, dynamic>())],
      );

  final String id;
  final String kind;
  final String title;
  final String description;
  final int initial;
  final int increment;
  final DateTime startsAt;
  final DateTime endsAt;
  final String status; // scheduled | running | finished | paid
  final int prizeUzs;
  final List<int> prizes;
  final int minGames;
  final int players;
  final bool joined;
  final List<Standing> standings;

  String get timeControl => '${initial ~/ 60}+$increment';
  bool get running => status == 'running';
  bool get over => status == 'finished' || status == 'paid';
}

class Standing {
  const Standing(this.rank, this.name, this.telegramUserId, this.score, this.games, this.wins, this.fire, this.rating, this.place, this.prizeUzs, this.me);

  factory Standing.fromJson(Map<String, dynamic> j) => Standing(
        j['rank'] as int? ?? 0,
        j['name'] as String? ?? '?',
        j['telegram_user_id'] as int?,
        j['score'] as int? ?? 0,
        j['games'] as int? ?? 0,
        j['wins'] as int? ?? 0,
        j['fire'] as bool? ?? false,
        j['rating'] as int? ?? 1500,
        j['place'] as int?,
        j['prize_uzs'] as int? ?? 0,
        j['me'] as bool? ?? false,
      );

  final int rank;
  final String name;
  final int? telegramUserId;
  final int score;
  final int games;
  final int wins;
  final bool fire;
  final int rating;
  final int? place;
  final int prizeUzs;
  final bool me;
}
