import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../l10n/strings.dart';
import '../state/settings.dart';

/// Local passcode that locks the UZARO UI (like Telegram's "Passcode Lock"). It is not the Telegram
/// password and does not log the account out. The PIN never leaves the device: only a salted
/// PBKDF2 hash is kept in the platform keystore (Android Keystore / iOS Keychain).
class AppLockState {
  const AppLockState({required this.enabled, required this.locked, required this.autoLockMinutes, this.lockedUntil, this.pinLength = newPinLength});

  final bool enabled;
  final bool locked;

  /// Digits of the stored PIN: 6 for new PINs, 4 for ones set before the longer PIN.
  final int pinLength;

  /// 0 = lock every time the app goes to the background.
  final int autoLockMinutes;

  /// Set after too many wrong attempts.
  final DateTime? lockedUntil;

  AppLockState copyWith({bool? enabled, bool? locked, int? autoLockMinutes, DateTime? lockedUntil, bool clearCooldown = false, int? pinLength}) =>
      AppLockState(
        enabled: enabled ?? this.enabled,
        locked: locked ?? this.locked,
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        lockedUntil: clearCooldown ? null : (lockedUntil ?? this.lockedUntil),
        pinLength: pinLength ?? this.pinLength,
      );
}

/// Digits asked for a new PIN.
const newPinLength = 6;

/// PBKDF2-HMAC-SHA256 rounds; slow enough to hurt guessing, run off the UI isolate.
const _pbkdf2Rounds = 150000;

/// Legacy (before PBKDF2) hash: 20 000 rounds of salted SHA-256. Only checked to upgrade old PINs.
String hashPasscode(String pin, String salt) {
  List<int> digest = utf8.encode('$salt:$pin');
  for (var i = 0; i < 20000; i++) {
    digest = sha256.convert(digest).bytes;
  }
  return base64Encode(digest);
}

/// PBKDF2-HMAC-SHA256 of [pin] with [salt] (base64 of the 32-byte key).
String derivePasscodeKey(String pin, String salt, {int rounds = _pbkdf2Rounds}) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode(salt)), rounds, 32));
  return base64Encode(derivator.process(Uint8List.fromList(utf8.encode(pin))));
}

String _deriveInIsolate((String, String) args) => derivePasscodeKey(args.$1, args.$2);

/// Compares without stopping at the first different byte.
bool _sameHash(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Cooldown after [failed] wrong PINs: none for the first [AppLockNotifier.maxAttempts], then 30 s doubling up to about an hour.
Duration? passcodeCooldown(int failed) {
  if (failed < AppLockNotifier.maxAttempts) return null;
  return Duration(seconds: 30 * (1 << (failed - AppLockNotifier.maxAttempts).clamp(0, 7)));
}

class AppLockNotifier extends Notifier<AppLockState> {
  // Default options on purpose: PINs saved by older builds must stay readable.
  static const _storage = FlutterSecureStorage();
  static const _hashKey = 'sado.lock.hash';
  static const _saltKey = 'sado.lock.salt';
  static const _kdfKey = 'sado.lock.kdf';
  static const _failedKey = 'sado.lock.failed';
  static const _untilKey = 'sado.lock.until';
  static const maxAttempts = 5;

  int _failedAttempts = 0;
  bool _countersLoaded = false;
  DateTime? _backgroundedAt;

  @override
  AppLockState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final enabled = prefs.getBool('lock.enabled') ?? false;
    // Wrong-PIN counters live in the keystore so restarting the app does not reset the cooldown.
    if (enabled) Future.microtask(_loadCounters);
    // Start locked so no chat content is visible before the PIN is entered.
    return AppLockState(
      enabled: enabled,
      locked: enabled,
      autoLockMinutes: prefs.getInt('lock.autoMinutes') ?? 1,
      pinLength: prefs.getInt('lock.pinLength') ?? 4,
    );
  }

  Future<void> _loadCounters() async {
    if (_countersLoaded) return;
    _countersLoaded = true;
    _failedAttempts = int.tryParse(await _storage.read(key: _failedKey) ?? '') ?? 0;
    final until = int.tryParse(await _storage.read(key: _untilKey) ?? '');
    if (until != null) {
      final at = DateTime.fromMillisecondsSinceEpoch(until);
      if (at.isAfter(DateTime.now())) state = state.copyWith(lockedUntil: at);
    }
  }

  Future<void> _saveCounters(DateTime? until) async {
    await _storage.write(key: _failedKey, value: '$_failedAttempts');
    if (until == null) {
      await _storage.delete(key: _untilKey);
    } else {
      await _storage.write(key: _untilKey, value: '${until.millisecondsSinceEpoch}');
    }
  }

  Future<void> _store(String pin) async {
    final random = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => random.nextInt(256)));
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(key: _hashKey, value: await compute(_deriveInIsolate, (pin, salt)));
    await _storage.write(key: _kdfKey, value: 'pbkdf2');
    await ref.read(sharedPreferencesProvider).setInt('lock.pinLength', pin.length);
  }

  Future<void> enable(String pin) async {
    await _store(pin);
    _failedAttempts = 0;
    _countersLoaded = true;
    await _saveCounters(null);
    await ref.read(sharedPreferencesProvider).setBool('lock.enabled', true);
    state = state.copyWith(enabled: true, locked: false, pinLength: pin.length, clearCooldown: true);
  }

  Future<void> disable() async {
    for (final key in const [_hashKey, _saltKey, _kdfKey, _failedKey, _untilKey]) {
      await _storage.delete(key: key);
    }
    await ref.read(sharedPreferencesProvider).setBool('lock.enabled', false);
    state = state.copyWith(enabled: false, locked: false, clearCooldown: true);
  }

  Future<void> setAutoLock(int minutes) async {
    await ref.read(sharedPreferencesProvider).setInt('lock.autoMinutes', minutes);
    state = state.copyWith(autoLockMinutes: minutes);
  }

  /// True while wrong PINs must wait; every check (unlock, change, disable, hidden chats) obeys it.
  bool get coolingDown => state.lockedUntil?.isAfter(DateTime.now()) ?? false;

  /// Checks a PIN without unlocking (used before changing or disabling the passcode).
  /// Counts as an attempt: wrong PINs here grow the same cooldown as on the lock screen.
  Future<bool> verify(String pin) async {
    await _loadCounters();
    if (coolingDown) return false;
    final salt = await _storage.read(key: _saltKey);
    final hash = await _storage.read(key: _hashKey);
    if (salt == null || hash == null) return false;
    final legacy = await _storage.read(key: _kdfKey) != 'pbkdf2';
    final ok = _sameHash(legacy ? hashPasscode(pin, salt) : await compute(_deriveInIsolate, (pin, salt)), hash);
    if (ok) {
      // A PIN set before PBKDF2 is re-hashed now that we know it.
      if (legacy) await _store(pin);
      _failedAttempts = 0;
      await _saveCounters(null);
      state = state.copyWith(clearCooldown: true);
      return true;
    }
    _failedAttempts++;
    final wait = passcodeCooldown(_failedAttempts);
    final until = wait == null ? null : DateTime.now().add(wait);
    await _saveCounters(until);
    if (until != null) state = state.copyWith(lockedUntil: until);
    return false;
  }

  /// Returns true when unlocked; applies a growing cooldown after repeated failures.
  Future<bool> unlock(String pin) async {
    if (!await verify(pin)) return false;
    state = state.copyWith(locked: false);
    return true;
  }

  void lockNow() {
    if (state.enabled) state = state.copyWith(locked: true);
  }

  void onBackground() => _backgroundedAt ??= DateTime.now();

  void onForeground() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (!state.enabled || since == null) return;
    if (DateTime.now().difference(since) >= Duration(minutes: state.autoLockMinutes)) {
      state = state.copyWith(locked: true);
    }
  }
}

final appLockProvider = NotifierProvider<AppLockNotifier, AppLockState>(AppLockNotifier.new);

/// Covers the whole app with the lock screen while locked.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lock = ref.read(appLockProvider.notifier);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      lock.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      lock.onForeground();
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    return Stack(
      children: [
        // Offstage keeps navigation state but stops the UI from painting or receiving input.
        Offstage(offstage: locked, child: TickerMode(enabled: !locked, child: widget.child)),
        if (locked) const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();

  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen> {
  String _pin = '';
  bool _error = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(appLockProvider).lockedUntil != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _submit(String pin) async {
    final ok = await ref.read(appLockProvider.notifier).unlock(pin);
    if (!mounted) return;
    if (!ok) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(ref.watch(settingsProvider).localeCode);
    final until = ref.watch(appLockProvider).lockedUntil;
    final wait = until == null ? 0 : until.difference(DateTime.now()).inSeconds;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: PinPad(
          title: wait > 0 ? s.t('passcode_wait', {'seconds': '$wait'}) : s.t(_error ? 'passcode_wrong' : 'passcode_enter'),
          pin: _pin,
          error: _error,
          enabled: wait <= 0,
          length: ref.watch(appLockProvider.select((s) => s.pinLength)),
          onChanged: (pin) {
            setState(() {
              _pin = pin;
              _error = false;
            });
            if (pin.length == ref.read(appLockProvider).pinLength) unawaited(_submit(pin));
          },
        ),
      ),
    );
  }
}

/// Numeric keypad with dot indicators.
class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.title, required this.pin, required this.onChanged, this.error = false, this.enabled = true, this.length = newPinLength});

  final int length;

  final String title;
  final String pin;
  final ValueChanged<String> onChanged;
  final bool error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {IconData? icon, VoidCallback? onTap}) => SizedBox.square(
          dimension: 76,
          child: TextButton(
            style: TextButton.styleFrom(shape: const CircleBorder(), foregroundColor: scheme.onSurface),
            onPressed: enabled ? onTap : null,
            child: icon != null ? Icon(icon, size: 26) : Text(label, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
          ),
        );
    void digit(String d) {
      if (pin.length < length) onChanged(pin + d);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset('assets/logo.png', width: 72, height: 72),
        const SizedBox(height: 20),
        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: error ? scheme.error : null)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < length; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 9),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < pin.length ? (error ? scheme.error : scheme.primary) : Colors.transparent,
                  border: Border.all(color: error ? scheme.error : scheme.primary, width: 1.6),
                ),
              ),
          ],
        ),
        const SizedBox(height: 32),
        for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) key(d, onTap: () => digit(d))]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(dimension: 76),
            key('0', onTap: () => digit('0')),
            key('', icon: Icons.backspace_outlined, onTap: pin.isEmpty ? null : () => onChanged(pin.substring(0, pin.length - 1))),
          ],
        ),
      ],
    );
  }
}

/// Settings page: turn the passcode on/off, change it, pick the auto-lock delay.
class PasscodeSettingsScreen extends ConsumerWidget {
  const PasscodeSettingsScreen({super.key});

  Future<String?> _askNewPin(BuildContext context) async {
    final first = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_new', length: newPinLength)));
    if (first == null || !context.mounted) return null;
    final second = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PinEntryScreen(titleKey: 'passcode_repeat', length: newPinLength)));
    if (second == null || !context.mounted) return null;
    if (first != second) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('passcode_mismatch'))));
      return null;
    }
    return first;
  }

  Future<bool> _checkCurrent(BuildContext context, WidgetRef ref) => checkCurrentPasscode(context, ref);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    final notifier = ref.read(appLockProvider.notifier);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('passcode_lock'))),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(s.t('passcode_lock')),
            subtitle: Text(s.t('passcode_hint')),
            value: lock.enabled,
            onChanged: (value) async {
              if (value) {
                final pin = await _askNewPin(context);
                if (pin != null) await notifier.enable(pin);
              } else if (await _checkCurrent(context, ref)) {
                await notifier.disable();
              }
            },
          ),
          if (lock.enabled) ...[
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: Text(s.t('passcode_change')),
              onTap: () async {
                if (!await _checkCurrent(context, ref) || !context.mounted) return;
                final pin = await _askNewPin(context);
                if (pin != null) await notifier.enable(pin);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(s.t('passcode_auto_lock')),
              trailing: DropdownButton<int>(
                value: lock.autoLockMinutes,
                underline: const SizedBox.shrink(),
                items: [
                  for (final minutes in const [0, 1, 5, 60, 300])
                    DropdownMenuItem(
                      value: minutes,
                      child: Text(minutes == 0 ? s.t('passcode_immediately') : s.t('passcode_after_minutes', {'n': '$minutes'})),
                    ),
                ],
                onChanged: (v) => v == null ? null : notifier.setAutoLock(v),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded),
              title: Text(s.t('passcode_lock_now')),
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                notifier.lockNow();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Asks for the current PIN (change, disable, hidden chats); wrong tries count toward the cooldown.
Future<bool> checkCurrentPasscode(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(appLockProvider.notifier);
  if (notifier.coolingDown) {
    final wait = ref.read(appLockProvider).lockedUntil!.difference(DateTime.now()).inSeconds;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('passcode_wait', {'seconds': '$wait'}))));
    return false;
  }
  final length = ref.read(appLockProvider).pinLength;
  final pin = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => PinEntryScreen(titleKey: 'passcode_enter', length: length)));
  if (pin == null) return false;
  final ok = await notifier.verify(pin);
  if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('passcode_wrong'))));
  return ok;
}

class PinEntryScreen extends StatefulWidget {
  const PinEntryScreen({super.key, required this.titleKey, this.length = newPinLength});

  final String titleKey;
  final int length;

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  String _pin = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: PinPad(
        title: context.t(widget.titleKey),
        pin: _pin,
        length: widget.length,
        onChanged: (pin) {
          setState(() => _pin = pin);
          if (pin.length == widget.length) Navigator.pop(context, pin);
        },
      ),
    );
  }
}
