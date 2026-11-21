import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../business/business_widgets.dart' show apiErrorText, apiGuard;
import '../games/games_lobby_screen.dart' show formatWhen;
import '../gifts/gift_widgets.dart' show ensureGiftsLinked;
import '../settings/privacy_screen.dart' show promptText;
import 'ai_markdown.dart';

const _brand = [Color(0xFF8B6CFF), Color(0xFF3FA9F5)];

class _Msg {
  _Msg(this.role, this.text);
  final String role; // user | model
  String text;
}

class _ChatRow {
  const _ChatRow(this.id, this.title, this.updatedAt);
  factory _ChatRow.fromJson(Map<String, dynamic> j) =>
      _ChatRow(j['id'] as String, j['title'] as String? ?? '', DateTime.tryParse(j['updated_at'] as String? ?? '')?.toLocal());
  final String id;
  final String title;
  final DateTime? updatedAt;
}

/// UZARO AI: a chat assistant with saved conversations (drawer), answers streamed as they are written.
class UzaroAiScreen extends ConsumerStatefulWidget {
  const UzaroAiScreen({super.key});

  @override
  ConsumerState<UzaroAiScreen> createState() => _UzaroAiScreenState();
}

class _UzaroAiScreenState extends ConsumerState<UzaroAiScreen> {
  late final SadoApi _api = ref.read(sadoApiProvider);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _scaffold = GlobalKey<ScaffoldState>();
  bool? _ready; // null: checking; false: not linked or not available
  String _blocked = '';
  List<_ChatRow> _chats = const [];
  String? _chatId;
  List<_Msg> _messages = [];
  StreamSubscription<Map<String, dynamic>>? _answer;
  CancelToken? _cancel;
  _Msg? _reply; // the answer being written
  bool _loadingChat = false;
  int _used = 0;
  int _limit = 0;

  bool get _busy => _answer != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _cancel?.cancel();
    unawaited(_answer?.cancel());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final s = context.s;
    setState(() => _ready = null);
    if (!await ensureGiftsLinked(context, ref) || !mounted) {
      if (mounted) _block(s.t('ai_link_needed'));
      return;
    }
    try {
      final status = await _api.aiStatus();
      if (!mounted) return;
      if (status['available'] != true) {
        _block(s.t('ai_unavailable'));
        return;
      }
      setState(() {
        _ready = true;
        _used = status['used_today'] as int? ?? 0;
        _limit = status['daily_limit'] as int? ?? 0;
      });
      await _loadChats();
    } on ApiException catch (error) {
      if (mounted) _block(apiErrorText(context, error));
    }
  }

  void _block(String why) => setState(() {
        _ready = false;
        _blocked = why;
      });

  Future<void> _loadChats() async {
    try {
      final body = await _api.aiChats();
      if (mounted) setState(() => _chats = [for (final c in body['items'] as List) _ChatRow.fromJson((c as Map).cast<String, dynamic>())]);
    } on ApiException catch (error) {
      if (mounted) showToast(context, apiErrorText(context, error));
    }
  }

  Future<void> _open(String id) async {
    _scaffold.currentState?.closeDrawer();
    _stop();
    setState(() {
      _chatId = id;
      _messages = [];
      _loadingChat = true;
    });
    try {
      final body = await _api.aiChat(id);
      if (!mounted || _chatId != id) return;
      setState(() {
        _messages = [for (final m in body['messages'] as List) _Msg('${(m as Map)['role']}', '${m['text']}')];
        _loadingChat = false;
      });
      _toBottom(jump: true);
    } on ApiException catch (error) {
      if (!mounted || _chatId != id) return;
      setState(() => _loadingChat = false);
      showToast(context, apiErrorText(context, error));
    } on TypeError {
      if (!mounted || _chatId != id) return;
      setState(() => _loadingChat = false);
      showToast(context, context.s.t('err_GENERIC'));
    }
  }

  void _newChat() {
    _scaffold.currentState?.closeDrawer();
    _stop();
    setState(() {
      _loadingChat = false;
      _chatId = null;
      _messages = [];
    });
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      jump ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  void _send([String? preset]) {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy || _loadingChat) return; // a chat still loading would overwrite this message
    _input.clear();
    final reply = _Msg('model', '');
    final cancel = CancelToken();
    setState(() {
      _messages = [..._messages, _Msg('user', text), reply];
      _reply = reply;
      _cancel = cancel;
    });
    _toBottom();
    _answer = _api.aiAsk(text, chatId: _chatId, cancel: cancel).listen(
      (event) {
        if (!mounted) return;
        switch (event['t']) {
          case 'chat':
            final chat = _ChatRow.fromJson((event['chat'] as Map).cast<String, dynamic>());
            setState(() {
              _chatId = chat.id;
              _chats = [chat, ..._chats.where((c) => c.id != chat.id)];
              _used++;
            });
          case 'delta':
            setState(() => reply.text += '${event['text']}');
            _toBottom();
          case 'error':
            if (reply.text.isEmpty) setState(() => _messages = [..._messages]..remove(reply));
            showToast(context, apiErrorText(context, ApiException('${event['code']}')));
        }
      },
      onError: (Object error) {
        if (!mounted || _reply != reply) return;
        _finish();
        showToast(context, error is ApiException ? apiErrorText(context, error) : context.s.t('err_GENERIC'));
      },
      onDone: () {
        if (mounted && _reply == reply) _finish();
      },
      cancelOnError: true,
    );
    setState(() {});
  }

  /// Ends the current answer in the UI; an answer that never got text leaves no empty bubble behind.
  void _finish() {
    final reply = _reply;
    setState(() {
      if (reply != null && reply.text.isEmpty) _messages = [..._messages]..remove(reply);
      _answer = null;
      _reply = null;
      _cancel = null;
    });
  }

  /// Stops at once: the request is aborted and the UI is free immediately, without waiting for the
  /// stream to notice (a silent model would otherwise keep the stop button up until the next chunk).
  void _stop() {
    final answer = _answer;
    if (answer == null) return;
    _cancel?.cancel();
    unawaited(answer.cancel());
    if (mounted) _finish();
  }

  Future<void> _chatMenu(_ChatRow chat) async {
    final s = context.s;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: Text(s.t('ai_rename')), onTap: () => Navigator.pop(context, 'rename')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      if (!await confirm(context, title: s.t('ai_delete_confirm'), confirmLabel: s.t('delete'), destructive: true) || !mounted) return;
      final ok = await apiGuard(context, () async {
        await _api.deleteAiChat(chat.id);
        return true;
      });
      if (ok == true && mounted) {
        setState(() => _chats = _chats.where((c) => c.id != chat.id).toList());
        if (_chatId == chat.id) _newChat();
      }
      return;
    }
    final title = await promptText(context, title: s.t('ai_rename'), label: s.t('ai_rename'), initial: chat.title, maxLength: 80);
    if (title == null || title.isEmpty || !mounted) return;
    await apiGuard(context, () => _api.renameAiChat(chat.id, title));
    await _loadChats();
  }

  Future<void> _clearAll() async {
    final s = context.s;
    if (!await confirm(context, title: s.t('ai_clear_confirm'), confirmLabel: s.t('delete'), destructive: true) || !mounted) return;
    final ok = await apiGuard(context, () async {
      await _api.deleteAllAiChats();
      return true;
    });
    if (ok == true && mounted) {
      setState(() => _chats = const []);
      _newChat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      key: _scaffold,
      drawer: _ready == true ? _drawer(context) : null,
      appBar: AppBar(
        centerTitle: true,
        title: const _BrandTitle(),
        actions: [
          if (_ready == true) IconButton(tooltip: s.t('ai_new_chat'), icon: const Icon(Icons.edit_square), onPressed: _newChat),
        ],
      ),
      body: switch (_ready) {
        null => const Center(child: CircularProgressIndicator()),
        false => EmptyState(
            icon: Icons.auto_awesome_rounded,
            title: _blocked,
            action: FilledButton(onPressed: _start, child: Text(s.t('retry'))),
          ),
        true => SafeArea(
            top: false,
            child: Column(children: [
              Expanded(child: _loadingChat ? const Center(child: CircularProgressIndicator()) : _messages.isEmpty ? _welcome(context) : _list(context)),
              _composer(context),
            ]),
          ),
      },
    );
  }

  Widget _drawer(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _newChat,
              icon: const Icon(Icons.add_rounded),
              label: Text(s.t('ai_new_chat')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Text(s.t('ai_history'), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const Spacer(),
              if (_chats.isNotEmpty) TextButton(onPressed: _clearAll, child: Text(s.t('ai_clear_all'))),
            ]),
          ),
          Expanded(
            child: _chats.isEmpty
                ? Center(child: Text(s.t('ai_history_empty'), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)))
                : ListView.builder(
                    itemCount: _chats.length,
                    itemBuilder: (context, i) {
                      final chat = _chats[i];
                      return ListTile(
                        selected: chat.id == _chatId,
                        leading: const Icon(Icons.chat_bubble_outline_rounded),
                        title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: chat.updatedAt == null ? null : Text(formatWhen(context, chat.updatedAt!)),
                        onTap: () => _open(chat.id),
                        onLongPress: () => _chatMenu(chat),
                        trailing: IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => _chatMenu(chat)),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final ideas = [s.t('ai_idea_1'), s.t('ai_idea_2'), s.t('ai_idea_3'), s.t('ai_idea_4')];
    return ListView(padding: const EdgeInsets.fromLTRB(20, 48, 20, 20), children: [
      const Center(child: _Orb(size: 72)),
      const SizedBox(height: 20),
      Text(s.t('ai_welcome'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(s.t('ai_welcome_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 28),
      for (final idea in ideas)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () => _send(idea),
            child: Text(idea, style: theme.textTheme.bodyLarge),
          ),
        ),
    ]);
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.s;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final m = _messages[i];
        if (m.role == 'user') {
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(left: 48, bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(18)),
              child: SelectableText(m.text, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
            ),
          );
        }
        final streaming = _busy && i == _messages.length - 1;
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2), child: _Orb(size: 28)),
            const SizedBox(width: 10),
            Expanded(
              child: m.text.isEmpty
                  ? const Padding(padding: EdgeInsets.only(top: 6), child: _Typing())
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SelectionArea(child: AiMarkdown(m.text, onCopyCode: (_) => showToast(context, s.t('copied')))),
                      if (!streaming)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: s.t('copy'),
                          icon: Icon(Icons.copy_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: m.text));
                            showToast(context, s.t('copied'));
                          },
                        ),
                    ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.only(left: 18, right: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 6,
                maxLength: 8000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(hintText: s.t('ai_ask_hint'), border: InputBorder.none, counterText: ''),
                onSubmitted: (_) => _send(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _busy
                  ? IconButton.filled(tooltip: s.t('ai_stop'), onPressed: _stop, icon: const Icon(Icons.stop_rounded))
                  : ListenableBuilder(
                      listenable: _input,
                      builder: (context, _) => IconButton.filled(
                        tooltip: s.t('send'),
                        onPressed: _input.text.trim().isEmpty ? null : _send,
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                    ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${s.t('ai_disclaimer')}${_limit > 0 ? ' · ${s.t('ai_left_today', {'n': '${(_limit - _used).clamp(0, _limit)}'})}' : ''}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const _Orb(size: 24),
        const SizedBox(width: 8),
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(colors: _brand).createShader(r),
          child: const Text('UZARO AI', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.3)),
        ),
      ]);
}

class _Orb extends StatelessWidget {
  const _Orb({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: _brand, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: Icon(Icons.auto_awesome_rounded, color: Colors.white, size: size * 0.55),
      );
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsets.only(right: 5),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.3 + 0.7 * ((((_c.value * 3) - i) % 3) < 1 ? 1 : 0)),
            ),
          ),
      ]),
    );
  }
}
