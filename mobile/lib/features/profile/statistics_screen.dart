import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

/// Channel or group statistics: headline numbers, graphs and top members / recent posts.
class ChatStatisticsScreen extends ConsumerStatefulWidget {
  const ChatStatisticsScreen({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<ChatStatisticsScreen> createState() => _ChatStatisticsScreenState();
}

class _ChatStatisticsScreenState extends ConsumerState<ChatStatisticsScreen> {
  td.ChatStatistics? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final stats = await account.send<td.ChatStatistics>(td.GetChatStatistics(chatId: widget.chatId, isDark: isDark));
      if (mounted) setState(() => _stats = stats);
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('statistics'))),
      body: switch (stats) {
        null when _error != null => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))),
        null => const Center(child: CircularProgressIndicator()),
        td.ChatStatisticsChannel() => ListView(children: _channel(stats, account, s)),
        td.ChatStatisticsSupergroup() => ListView(children: _supergroup(stats, account, s)),
        _ => Center(child: Text(s.t('nothing_here'))),
      },
    );
  }

  Widget _period(td.DateRange period, Strings s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text('${formatChatTime(period.startDate, s.locale)} – ${formatChatTime(period.endDate, s.locale)}', style: TextStyle(color: Theme.of(context).hintColor)),
      );

  List<Widget> _channel(td.ChatStatisticsChannel st, TelegramAccount account, Strings s) => [
        _period(st.period, s),
        _ValueGrid(values: [
          (s.t('stat_followers'), st.memberCount),
          (s.t('stat_views_per_post'), st.meanMessageViewCount),
          (s.t('stat_shares_per_post'), st.meanMessageShareCount),
          (s.t('stat_reactions_per_post'), st.meanMessageReactionCount),
          (s.t('stat_views_per_story'), st.meanStoryViewCount),
          (s.t('stat_reactions_per_story'), st.meanStoryReactionCount),
        ]),
        ListTile(dense: true, title: Text(s.t('stat_notifications_on')), trailing: Text('${st.enabledNotificationsPercentage.toStringAsFixed(1)}%')),
        for (final (key, graph) in [
          ('stat_growth', st.memberCountGraph),
          ('stat_followers_graph', st.joinGraph),
          ('stat_notifications', st.muteGraph),
          ('stat_views_by_hour', st.viewCountByHourGraph),
          ('stat_views_by_source', st.viewCountBySourceGraph),
          ('stat_new_followers_by_source', st.joinBySourceGraph),
          ('stat_languages', st.languageGraph),
          ('stat_interactions', st.messageInteractionGraph),
          ('stat_reactions', st.messageReactionGraph),
          ('stat_story_interactions', st.storyInteractionGraph),
        ])
          StatGraphCard(chatId: widget.chatId, title: s.t(key), graph: graph),
        if (st.recentInteractions.isNotEmpty) SectionHeader(s.t('stat_recent_posts')),
        for (final item in st.recentInteractions)
          if (item.objectType case td.ChatStatisticsObjectTypeMessage(:final messageId))
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text('👁 ${item.viewCount}   ↪ ${item.forwardCount}   ❤ ${item.reactionCount}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MessageStatisticsScreen(chatId: widget.chatId, messageId: messageId))),
            ),
      ];

  List<Widget> _supergroup(td.ChatStatisticsSupergroup st, TelegramAccount account, Strings s) => [
        _period(st.period, s),
        _ValueGrid(values: [
          (s.t('stat_members'), st.memberCount),
          (s.t('stat_messages'), st.messageCount),
          (s.t('stat_viewing_members'), st.viewerCount),
          (s.t('stat_posting_members'), st.senderCount),
        ]),
        for (final (key, graph) in [
          ('stat_growth', st.memberCountGraph),
          ('stat_members_graph', st.joinGraph),
          ('stat_new_members_by_source', st.joinBySourceGraph),
          ('stat_languages', st.languageGraph),
          ('stat_messages', st.messageContentGraph),
          ('stat_actions', st.actionGraph),
          ('stat_by_hour', st.dayGraph),
          ('stat_by_weekday', st.weekGraph),
        ])
          StatGraphCard(chatId: widget.chatId, title: s.t(key), graph: graph),
        if (st.topSenders.isNotEmpty) SectionHeader(s.t('stat_top_members')),
        for (final m in st.topSenders)
          _userTile(account, m.userId, s.count('messages', m.sentMessageCount)),
        if (st.topAdministrators.isNotEmpty) SectionHeader(s.t('stat_top_admins')),
        for (final m in st.topAdministrators)
          _userTile(account, m.userId, s.t('stat_admin_actions', {'d': '${m.deletedMessageCount}', 'b': '${m.bannedUserCount}', 'r': '${m.restrictedUserCount}'})),
        if (st.topInviters.isNotEmpty) SectionHeader(s.t('stat_top_inviters')),
        for (final m in st.topInviters)
          _userTile(account, m.userId, s.t('stat_invited', {'n': '${m.addedMemberCount}'})),
      ];

  Widget _userTile(TelegramAccount account, int userId, String subtitle) => ListTile(
        leading: UserAvatar(userId: userId, size: 40),
        title: Text(account.userName(userId)),
        subtitle: Text(subtitle),
        onTap: () async {
          final chat = await guard(context, () => account.openPrivateChat(userId));
          if (chat != null && mounted) openChat(context, chat.id);
        },
      );
}

/// Interaction and reaction graphs of one channel post.
class MessageStatisticsScreen extends ConsumerWidget {
  const MessageStatisticsScreen({super.key, required this.chatId, required this.messageId});

  final int chatId;
  final int messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('stat_post'))),
      body: FutureBuilder(
        future: Future.wait([
          account.send<td.MessageStatistics>(td.GetMessageStatistics(chatId: chatId, messageId: messageId, isDark: isDark)),
          account.send<td.PublicForwards>(td.GetMessagePublicForwards(chatId: chatId, messageId: messageId, offset: '', limit: 1)),
        ]),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text(s.t('nothing_here')));
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final stats = data[0] as td.MessageStatistics;
          final forwards = data[1] as td.PublicForwards;
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: Text(s.t('message_go_to')),
                onTap: () => openChat(context, chatId, messageId: messageId),
              ),
              ListTile(leading: const Icon(Icons.public_rounded), title: Text(s.t('stat_public_shares')), trailing: Text('${forwards.totalCount}')),
              StatGraphCard(chatId: chatId, title: s.t('stat_interactions'), graph: stats.messageInteractionGraph),
              StatGraphCard(chatId: chatId, title: s.t('stat_reactions'), graph: stats.messageReactionGraph),
            ],
          );
        },
      ),
    );
  }
}

class _ValueGrid extends StatelessWidget {
  const _ValueGrid({required this.values});

  final List<(String, td.StatisticalValue)> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (label, v) in values)
            SizedBox(
              width: (MediaQuery.sizeOf(context).width - 36) / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: _compact(v.value), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    if (v.growthRatePercentage != 0 || v.value != v.previousValue)
                      TextSpan(
                        text: '  ${v.value >= v.previousValue ? '+' : ''}${_compact(v.value - v.previousValue)} (${v.growthRatePercentage.toStringAsFixed(1)}%)',
                        style: TextStyle(fontSize: 12, color: v.value >= v.previousValue ? Colors.green : theme.colorScheme.error),
                      ),
                  ])),
                  Text(label, style: TextStyle(color: theme.hintColor, fontSize: 13)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _compact(double v) {
  final a = v.abs();
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(1)}K';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// One statistics graph; async graphs are fetched by token, errors and empty graphs are hidden.
class StatGraphCard extends ConsumerStatefulWidget {
  const StatGraphCard({super.key, required this.chatId, required this.title, required this.graph});

  final int chatId;
  final String title;
  final td.StatisticalGraph graph;

  @override
  ConsumerState<StatGraphCard> createState() => _StatGraphCardState();
}

class _StatGraphCardState extends ConsumerState<StatGraphCard> {
  ChartData? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve(widget.graph);
  }

  Future<void> _resolve(td.StatisticalGraph graph) async {
    switch (graph) {
      case td.StatisticalGraphData(:final jsonData):
        final data = ChartData.parse(jsonData);
        setState(() => data == null ? _failed = true : _data = data);
      case td.StatisticalGraphAsync(:final token):
        try {
          final loaded = await ref.read(accountProvider).send<td.StatisticalGraph>(td.GetStatisticalGraph(chatId: widget.chatId, token: token, x: 0));
          if (mounted && loaded is! td.StatisticalGraphAsync) await _resolve(loaded);
        } on TdException {
          if (mounted) setState(() => _failed = true);
        }
      default:
        setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_failed || (data != null && data.series.isEmpty)) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (data == null)
              const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
            else if (data.isPie)
              for (final series in data.series)
                Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: series.color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(series.name)),
                  Text(_compact(series.values.fold(0.0, (a, b) => a + b))),
                ])
            else ...[
              SizedBox(height: 160, child: CustomPaint(size: Size.infinite, painter: _LinePainter(data, Theme.of(context).dividerColor))),
              const SizedBox(height: 8),
              Wrap(spacing: 12, children: [
                for (final series in data.series)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: series.color, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text(series.name, style: const TextStyle(fontSize: 12)),
                  ]),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class ChartSeries {
  const ChartSeries(this.name, this.color, this.values);

  final String name;
  final Color color;
  final List<double> values;
}

/// Telegram's statistics chart JSON: columns of x + y series with names, colors and types.
class ChartData {
  const ChartData(this.series, {required this.isPie});

  final List<ChartSeries> series;
  final bool isPie;

  static ChartData? parse(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final types = (map['types'] as Map?)?.cast<String, dynamic>() ?? const {};
      final names = (map['names'] as Map?)?.cast<String, dynamic>() ?? const {};
      final colors = (map['colors'] as Map?)?.cast<String, dynamic>() ?? const {};
      final series = <ChartSeries>[];
      for (final column in (map['columns'] as List? ?? const [])) {
        final list = column as List;
        if (list.isEmpty) continue;
        final id = list.first as String;
        if (types[id] == 'x') continue;
        series.add(ChartSeries('${names[id] ?? id}', _color('${colors[id] ?? ''}'), [for (final v in list.skip(1)) (v as num).toDouble()]));
      }
      return ChartData(series, isPie: map['pie'] == true || types.values.contains('pie'));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  // Colors come as "#RRGGBB" or "NAME#RRGGBB".
  static Color _color(String raw) {
    final hex = raw.contains('#') ? raw.substring(raw.lastIndexOf('#') + 1) : '';
    final value = int.tryParse(hex, radix: 16);
    return value == null || hex.length != 6 ? Colors.blue : Color(0xFF000000 | value);
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.data, this.gridColor);

  final ChartData data;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = data.series.expand((s) => s.values).fold<double>(0, max);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (maxValue <= 0) return;
    for (final series in data.series) {
      if (series.values.length < 2) continue;
      final path = Path();
      for (var i = 0; i < series.values.length; i++) {
        final point = Offset(size.width * i / (series.values.length - 1), size.height * (1 - series.values[i] / maxValue));
        i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = series.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.data != data;
}
