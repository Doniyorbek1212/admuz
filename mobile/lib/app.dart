import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import 'core/app_lock.dart';
import 'core/calls/call_service.dart';
import 'core/chat_sounds.dart';
import 'core/file_guard.dart';
import 'core/formatters.dart';
import 'core/live_location.dart';
import 'core/media_saver.dart';
import 'core/notifications.dart';
import 'core/push.dart';
import 'core/tdlib/td_client.dart';
import 'core/theme.dart';
import 'features/auth/auth_screens.dart';
import 'features/calls/call_screen.dart';
import 'features/home/home_screen.dart';
import 'features/home/home_shell.dart';
import 'l10n/strings.dart';
import 'state/actions.dart';
import 'state/providers.dart';
import 'state/settings.dart';
import 'state/telegram.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class SadoApp extends ConsumerWidget {
  const SadoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final smooth = ref.watch(motionProvider.select((m) => m.transitions));
    return MaterialApp(
      title: 'UZARO',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: buildTheme(Brightness.light, settings.accent, fontFamily: settings.fontFamily, smoothTransitions: smooth),
      darkTheme: buildTheme(Brightness.dark, settings.accent, fontFamily: settings.fontFamily, smoothTransitions: smooth),
      themeMode: settings.themeMode,
      locale: Locale(settings.localeCode),
      supportedLocales: [for (final code in Strings.supported) Locale(code)],
      localizationsDelegates: const [
        StringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(settings.textScale.clamp(0.85, 1.2))),
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _closeTopPage(ref)},
          child: AppLockGate(child: child!),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

/// Esc on a hardware keyboard: closes the top page (full-window pages first, then the split-view pane),
/// like Telegram Desktop. Chat screens, dialogs and sheets handle Esc themselves before it gets here.
void _closeTopPage(WidgetRef ref) {
  final root = navigatorKey.currentState;
  if (root != null && root.canPop()) {
    unawaited(root.maybePop());
    return;
  }
  final pane = chatPaneNavigatorKey.currentState;
  if (pane == null) return;
  if (pane.canPop()) {
    unawaited(pane.maybePop());
  } else if (ref.read(openChatProvider) != null) {
    closeChat(pane.overlay!.context);
  }
}

/// Routes between setup, login steps and the main UI according to TDLib's authorization state.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credentials = ref.watch(credentialsProvider);
    if (credentials.isLoading) return const _Splash();
    if (credentials.value == null) return const CredentialsScreen();
    final account = ref.watch(telegramProvider);
    if (account.hasError) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${account.error}'))));
    }
    if (account.value == null) return const _Splash();
    final state = ref.watch(authStateProvider);
    return switch (state) {
      td.AuthorizationStateReady() => _SessionScope(key: ValueKey(account.value!.slot), child: const HomeShell()),
      td.AuthorizationStateWaitPhoneNumber() => const PhoneScreen(),
      td.AuthorizationStateWaitOtherDeviceConfirmation(:final link) => QrLoginScreen(link: link),
      td.AuthorizationStateWaitCode(:final codeInfo) => CodeScreen(key: ValueKey(codeInfo.type.getConstructor()), info: codeInfo),
      final td.AuthorizationStateWaitPassword waiting => PasswordScreen(state: waiting),
      td.AuthorizationStateWaitRegistration(:final termsOfService) => RegistrationScreen(terms: termsOfService),
      td.AuthorizationStateWaitEmailAddress() => const EmailScreen(),
      td.AuthorizationStateWaitEmailCode(:final codeInfo) => EmailScreen(codeInfo: codeInfo),
      td.AuthorizationStateWaitPremiumPurchase() => const UnsupportedAuthScreen(),
      _ => const _Splash(),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logo.png', width: 112, height: 112),
            const SizedBox(height: 20),
            const Text('UZARO', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            const SizedBox(height: 24),
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ],
        ),
      ),
    );
  }
}

/// Wires app-wide side effects for a logged-in account: presence, ghost mode, notifications, account label.
class _SessionScope extends ConsumerStatefulWidget {
  const _SessionScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<_SessionScope> createState() => _SessionScopeState();
}

class _SessionScopeState extends ConsumerState<_SessionScope> with WidgetsBindingObserver {
  late final TelegramAccount _account = ref.read(accountProvider);
  StreamSubscription<td.Update>? _messages;
  late AppLifecycleState _lifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Android can start the engine without any UI (keep-alive service after a reboot or a kill):
    // then the user must not show as online, and every message is a background notification.
    _lifecycle = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.detached;
    _configureArchive(ref.read(settingsProvider));
    unawaited(_account.setOnline(_lifecycle == AppLifecycleState.resumed && !ref.read(settingsProvider).ghostMode));
    MessageNotifier.instance.onOpenChat = (chatId) {
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;
      navigator.popUntil((route) => route.isFirst);
      // Same placement as a tap in the list: the split-view pane on wide windows.
      openChat(navigator.overlay!.context, chatId);
    };
    unawaited(MessageNotifier.instance.initialize());
    _messages = _account.messageEvents.listen(_onMessageEvent);
    unawaited(PushService.instance.register(_account));
    CallService.instance.attach(_account);
    CallService.instance.current.addListener(_onCallChanged);
    final settings = ref.read(settingsProvider);
    if (settings.keepMediaDays > 0 || settings.maxCacheGb > 0) {
      unawaited(_account
          .applyCacheLimits(keepDays: settings.keepMediaDays, maxGb: settings.maxCacheGb)
          .catchError((Object error) => debugPrint('storage cleanup failed: $error')));
    }
  }

  Route<void>? _callRoute;

  /// Opens the call screen over everything when a call starts and closes it when the call is gone.
  void _onCallChanged() {
    final session = CallService.instance.current.value;
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (session != null && _callRoute == null) {
      final route = MaterialPageRoute<void>(builder: (_) => CallScreen(session: session), fullscreenDialog: true);
      _callRoute = route;
      unawaited(navigator.push(route).whenComplete(() {
        if (_callRoute == route) _callRoute = null;
      }));
    } else if (session == null && _callRoute != null) {
      final route = _callRoute!;
      _callRoute = null;
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  void _configureArchive(AppSettings settings) => _account.archive
    ..keepDeleted = settings.keepDeleted
    ..keepEdits = settings.keepEditHistory;

  void _onMessageEvent(td.Update update) {
    if (update is td.UpdateMessageSendSucceeded) {
      LiveLocationService.instance.onMessageIdChanged(update.message.chatId, update.oldMessageId, update.message.id);
      final settings = ref.read(settingsProvider);
      if (settings.chatSounds && _lifecycle == AppLifecycleState.resumed) unawaited(ChatSounds.instance.play(settings.sendSound));
      return;
    }
    if (update is! td.UpdateNewMessage) return;
    final message = update.message;
    final settings = ref.read(settingsProvider);
    if (settings.fileGuard.checkMessage(message, _account.myId) != null) {
      // Blocked files never notify; they are deleted (or hidden) instead.
      unawaited(_quarantine(message, settings.fileGuard));
      return;
    }
    unawaited(autoSaveToGallery(_account, message, settings.saveToGallery).catchError((Object error) => debugPrint('auto-save failed: $error')));
    if (message.isOutgoing || !settings.notificationsEnabled) return;
    final chat = _account.chats[message.chatId];
    if (chat == null || _account.isMuted(chat)) return;
    final inForeground = _lifecycle == AppLifecycleState.resumed;
    if (inForeground && ref.read(openChatProvider) == message.chatId) {
      // The open chat shows the message instead of a notification; Telegram plays its in-chat cue.
      if (settings.chatSounds) unawaited(ChatSounds.instance.play(settings.receiveSound));
      return;
    }
    if (!mounted) return;
    unawaited(MessageNotifier.instance.showMessage(
      account: _account,
      message: message,
      strings: Strings(settings.localeCode),
      // While a passcode is set, notifications never show message text.
      showPreview: settings.messagePreview && !ref.read(appLockProvider).enabled && !settings.hiddenChatIds.contains(message.chatId),
    ));
  }

  /// File guard: stop the download, delete the message where that only affects this user, log it.
  /// In supergroups/channels deleting would remove it for everyone, so the bubble just stays blocked.
  Future<void> _quarantine(td.Message message, FileGuardSettings guard) async {
    final attachment = attachmentOf(message.content)!;
    var deleted = false;
    try {
      await _account.send<td.Ok>(td.CancelDownloadFile(fileId: attachment.file.id, onlyIfPending: false));
      if (attachment.file.local.downloadedSize > 0) await _account.send<td.Ok>(td.DeleteFile(fileId: attachment.file.id));
      if (guard.autoDelete) {
        final props = await _account.send<td.MessageProperties>(td.GetMessageProperties(chatId: message.chatId, messageId: message.id));
        if (props.canBeDeletedOnlyForSelf) {
          // Through the account so the archive does not keep the blocked file as "deleted".
          await _account.deleteMessages(message.chatId, [message.id], revoke: false);
          deleted = true;
        }
      }
    } on TdException catch (error) {
      debugPrint('file guard: $error');
    }
    if (!mounted) return;
    final chat = _account.chats[message.chatId];
    ref.read(blockedFilesProvider.notifier).add(BlockedFileEntry(
          fileName: attachment.name,
          chatTitle: chat == null ? '' : chatTitle(chat, _account, Strings(ref.read(settingsProvider).localeCode)),
          date: message.date,
          deleted: deleted,
        ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    final ghost = ref.read(settingsProvider).ghostMode;
    // Telegram expects clients to report offline when not visible.
    unawaited(_account.setOnline(state == AppLifecycleState.resumed && !ghost));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messages?.cancel();
    CallService.instance.current.removeListener(_onCallChanged);
    CallService.instance.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider, (_, settings) => _configureArchive(settings));
    ref.listen(meProvider, (_, me) {
      if (me != null) {
        ref.read(accountSlotsProvider.notifier).setLabel(_account.slot, '${me.firstName} ${me.lastName}'.trim());
      }
    });
    ref.listen(openChatProvider, (_, chatId) {
      if (chatId != null) unawaited(MessageNotifier.instance.cancelChat(chatId));
    });
    return widget.child;
  }
}
