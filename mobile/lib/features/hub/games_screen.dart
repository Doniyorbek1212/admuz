import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/config.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// Hub games (chess, checkers, sudoku, sliding puzzle): HTML pages on our own site under /games/,
/// opened in the app's language and theme. The page stays inside /games/; nothing else loads here.
class GamesScreen extends ConsumerStatefulWidget {
  const GamesScreen({super.key});

  @override
  ConsumerState<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends ConsumerState<GamesScreen> {
  late final WebViewController _controller = WebViewController();
  late final Uri _home;
  bool _started = false;
  bool _loading = true;
  bool _failed = false;

  bool _isGamesPage(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == _home.scheme && uri.host == _home.host && uri.path.startsWith('/games/');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final dark = Theme.of(context).brightness == Brightness.dark;
    _home = Uri.parse('${AppConfig.apiUrl}/games/index.html').replace(queryParameters: {
      'lang': ref.read(settingsProvider).localeCode,
      'theme': dark ? 'dark' : 'light',
    });
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Theme.of(context).colorScheme.surface)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) {
            if (mounted) setState(() => _failed = true);
          }
        },
        onNavigationRequest: (request) =>
            _isGamesPage(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
      ));
    unawaited(_controller.loadRequest(_home));
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    unawaited(_controller.loadRequest(_home));
  }

  /// System back steps back inside the games (game → list) before leaving the screen.
  Future<void> _back() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        appBar: AppBar(title: Text(s.t('hub_games'))),
        body: _failed
            ? EmptyState(
                icon: Icons.wifi_off_rounded,
                title: s.t('games_offline'),
                action: FilledButton(onPressed: _retry, child: Text(s.t('retry'))),
              )
            : Stack(children: [
                WebViewWidget(controller: _controller),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ]),
      ),
    );
  }
}
