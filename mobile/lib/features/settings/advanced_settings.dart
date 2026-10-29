import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/media_saver.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../chat/message_content.dart';
import 'storage_usage_screen.dart';
import 'telegram_extras.dart';
import 'two_step_recovery.dart';

// ------------------------------------------------------------------ proxy

class ProxyScreen extends ConsumerStatefulWidget {
  const ProxyScreen({super.key});

  @override
  ConsumerState<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends ConsumerState<ProxyScreen> {
  List<td.AddedProxy>? _proxies;
  final Map<int, int?> _pings = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final proxies = await account.proxies();
      if (!mounted) return;
      setState(() => _proxies = proxies);
      for (final proxy in proxies) {
        unawaited(account.pingProxy(proxy.proxy).then((ms) {
          if (mounted) setState(() => _pings[proxy.id] = ms);
        }));
      }
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _add() async {
    final proxy = await showDialog<td.Proxy>(context: context, builder: (_) => const _ProxyDialog());
    if (proxy == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).addProxy(proxy));
    await _load();
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final proxy = parseProxyLink(data?.text ?? '');
    if (!mounted) return;
    if (proxy == null) {
      showToast(context, context.t('proxy_link_invalid'));
      return;
    }
    await guard(context, () => ref.read(accountProvider).addProxy(proxy));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final proxies = _proxies;
    final anyEnabled = proxies?.any((p) => p.isEnabled) ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('proxy')),
        actions: [IconButton(tooltip: s.t('proxy_paste'), icon: const Icon(Icons.content_paste_rounded), onPressed: _pasteLink)],
      ),
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add_rounded)),
      body: proxies == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: Text(s.t('proxy_use')),
                  subtitle: Text(s.t('proxy_hint')),
                  value: anyEnabled,
                  onChanged: proxies.isEmpty
                      ? null
                      : (on) async {
                          await guard(context, () => on ? account.enableProxy(proxies.first.id) : account.disableProxy());
                          await _load();
                        },
                ),
                const Divider(),
                if (proxies.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(s.t('proxy_empty'), textAlign: TextAlign.center)),
                for (final proxy in proxies)
                  ListTile(
                    leading: Icon(
                      proxy.isEnabled ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                      color: proxy.isEnabled ? Theme.of(context).colorScheme.primary : null,
                    ),
                    title: Text('${proxy.proxy.server}:${proxy.proxy.port}'),
                    subtitle: Text([
                      switch (proxy.proxy.type) {
                        td.ProxyTypeMtproto() => 'MTProto',
                        td.ProxyTypeSocks5() => 'SOCKS5',
                        td.ProxyTypeHttp() => 'HTTP',
                        _ => '',
                      },
                      if (_pings.containsKey(proxy.id)) _pings[proxy.id] == null ? s.t('proxy_unavailable') : '${_pings[proxy.id]} ms',
                    ].join(' · ')),
                    onTap: () async {
                      await guard(context, () => account.enableProxy(proxy.id));
                      await _load();
                    },
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: s.t('edit'),
                        onPressed: () async {
                          final edited = await showDialog<td.Proxy>(context: context, builder: (_) => _ProxyDialog(initial: proxy.proxy));
                          if (edited == null || !context.mounted) return;
                          await guard(
                            context,
                            () => account.send<td.AddedProxy>(td.EditProxy(proxyId: proxy.id, proxy: edited, enable: proxy.isEnabled, comment: proxy.comment)),
                          );
                          await _load();
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () async {
                          await guard(context, () => account.removeProxy(proxy.id));
                          await _load();
                        },
                      ),
                    ]),
                  ),
              ],
            ),
    );
  }
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({this.initial});

  /// Proxy being edited; null when adding one.
  final td.Proxy? initial;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late String _type = switch (widget.initial?.type) {
    td.ProxyTypeSocks5() => 'socks5',
    td.ProxyTypeHttp() => 'http',
    _ => 'mtproto',
  };
  late final _server = TextEditingController(text: widget.initial?.server ?? '');
  late final _port = TextEditingController(text: widget.initial == null ? '' : '${widget.initial!.port}');
  late final _secret = TextEditingController(text: switch (widget.initial?.type) {
    td.ProxyTypeMtproto(:final secret) => secret,
    _ => '',
  });
  late final _user = TextEditingController(text: switch (widget.initial?.type) {
    td.ProxyTypeSocks5(:final username) || td.ProxyTypeHttp(:final username) => username,
    _ => '',
  });
  late final _password = TextEditingController(text: switch (widget.initial?.type) {
    td.ProxyTypeSocks5(:final password) || td.ProxyTypeHttp(:final password) => password,
    _ => '',
  });

  @override
  void dispose() {
    for (final c in [_server, _port, _secret, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t(widget.initial == null ? 'proxy_add' : 'edit')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'mtproto', label: Text('MTProto')),
                ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                ButtonSegment(value: 'http', label: Text('HTTP')),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            TextField(controller: _server, decoration: InputDecoration(labelText: s.t('proxy_server'))),
            TextField(controller: _port, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.t('proxy_port'))),
            if (_type == 'mtproto')
              TextField(controller: _secret, decoration: InputDecoration(labelText: s.t('proxy_secret')))
            else ...[
              TextField(controller: _user, decoration: InputDecoration(labelText: s.t('proxy_username'))),
              TextField(controller: _password, obscureText: true, decoration: InputDecoration(labelText: s.t('password'))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            final port = int.tryParse(_port.text.trim()) ?? 0;
            final server = _server.text.trim();
            if (server.isEmpty || port <= 0 || port > 65535 || (_type == 'mtproto' && _secret.text.trim().isEmpty)) {
              showToast(context, s.t('proxy_invalid'));
              return;
            }
            final type = switch (_type) {
              'mtproto' => td.ProxyTypeMtproto(secret: _secret.text.trim()) as td.ProxyType,
              'socks5' => td.ProxyTypeSocks5(username: _user.text.trim(), password: _password.text),
              _ => td.ProxyTypeHttp(username: _user.text.trim(), password: _password.text, httpOnly: false),
            };
            Navigator.pop(context, td.Proxy(server: server, port: port, type: type));
          },
          child: Text(s.t(widget.initial == null ? 'add' : 'save')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ data & storage

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  td.StorageStatisticsFast? _stats;
  td.NetworkStatistics? _network;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final stats = await account.storageStats();
      final network = await account.send<td.NetworkStatistics>(const td.GetNetworkStatistics(onlyCurrent: false));
      if (mounted) {
        setState(() {
          _stats = stats;
          _network = network;
        });
      }
    } on TdException catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    await _load();
  }

  /// Telegram's low/medium/high auto-download presets, saved per network type on the server.
  Future<void> _pickAutoDownloadPreset(BuildContext context, td.NetworkType type, String title) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final presets = await guard(context, () => account.send<td.AutoDownloadSettingsPresets>(const td.GetAutoDownloadSettingsPresets()));
    if (presets == null || !context.mounted) return;
    String mb(int bytes) => formatFileSize(bytes);
    final options = <(String, td.AutoDownloadSettings?)>[
      ('auto_download_off', null),
      ('auto_download_low', presets.low),
      ('auto_download_medium', presets.medium),
      ('auto_download_high', presets.high),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
          for (final (i, (key, preset)) in options.indexed)
            ListTile(
              title: Text(s.t(key)),
              subtitle: preset == null
                  ? null
                  : Text(s.t('auto_download_limits', {'photo': mb(preset.maxPhotoFileSize), 'video': mb(preset.maxVideoFileSize), 'file': mb(preset.maxOtherFileSize)})),
              onTap: () => Navigator.pop(context, i),
            ),
        ]),
      ),
    );
    if (picked == null || !context.mounted) return;
    final chosen = options[picked].$2 ?? presets.low.copyWith(isAutoDownloadEnabled: false);
    final done = await guard(context, () async {
      await account.send<td.Ok>(td.SetAutoDownloadSettings(settings: chosen, type: type));
      return true;
    });
    if (done == true && context.mounted) showToast(context, s.t('done'));
  }

  Future<void> _setGallery(String kind, bool on) async {
    // Ask for gallery access when turning it on, while the user is looking.
    if (on && !await ensureGalleryAccess()) {
      if (mounted) showToast(context, context.t('gallery_denied'));
      return;
    }
    ref.read(settingsProvider.notifier).setSaveToGallery(kind, on);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final stats = _stats;
    final network = _network;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final primary = Theme.of(context).colorScheme.primary;
    Widget value(String? text) => Text(text ?? '…', style: TextStyle(color: primary, fontSize: 15.5));
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('data_storage'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(title: s.t('storage_and_network'), children: [
            ListTile(
              leading: const TileIcon(Icons.donut_large_rounded, Color(0xFF3D8AD8)),
              title: Text(s.t('storage_usage')),
              trailing: value(stats == null ? null : formatFileSize(stats.filesSize + stats.databaseSize)),
              onTap: () => _open(const StorageUsageScreen()),
            ),
            ListTile(
              leading: const TileIcon(Icons.bar_chart_rounded, Color(0xFF2EAD5B)),
              title: Text(s.t('network_usage')),
              trailing: value(network == null ? null : formatFileSize(networkTotal(network))),
              onTap: () => _open(const NetworkUsageScreen()),
            ),
          ]),
          SettingsGroup(title: s.t('auto_download'), children: [
            SwitchListTile(
              title: Text(s.t('auto_download_photos')),
              value: settings.autoDownloadPhotos,
              onChanged: notifier.setAutoDownloadPhotos,
            ),
            for (final (type, key) in const <(td.NetworkType, String)>[
              (td.NetworkTypeMobile(), 'network_mobile'),
              (td.NetworkTypeWiFi(), 'network_wifi'),
              (td.NetworkTypeMobileRoaming(), 'network_roaming'),
            ])
              ListTile(
                title: Text(s.t(key)),
                subtitle: Text(s.t('auto_download_preset_hint')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickAutoDownloadPreset(context, type, s.t(key)),
              ),
          ]),
          SettingsGroup(title: s.t('save_to_gallery'), children: [
            for (final kind in const ['private', 'groups', 'channels'])
              SwitchListTile(
                title: Text(s.t('notif_$kind')),
                subtitle: Text(s.t(settings.saveToGallery.contains(kind) ? 'state_on' : 'state_off')),
                value: settings.saveToGallery.contains(kind),
                onChanged: (on) => _setGallery(kind, on),
              ),
          ]),
          GroupHint(s.t('save_to_gallery_hint')),
          SettingsGroup(children: [
            ListTile(
              title: Text(s.t('autosave_telegram')),
              subtitle: Text(s.t('autosave_telegram_hint')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutosaveScreen())),
            ),
            ListTile(
              title: Text(s.t('browser_settings')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WebBrowserSettingsScreen())),
            ),
            ListTile(
              title: Text(s.t('proxy_settings')),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProxyScreen())),
            ),
            ListTile(
              title: Text(s.t('delete_drafts')),
              onTap: () async {
                final ok = await confirm(context, title: s.t('delete_drafts'), message: s.t('delete_drafts_confirm'), destructive: true);
                if (!ok || !context.mounted) return;
                await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ClearAllDraftMessages(excludeSecretChats: false)));
                if (context.mounted) showToast(context, s.t('done'));
              },
            ),
          ]),
        ],
      ),
    );
  }
}

/// Bytes sent plus received over all networks.
int networkTotal(td.NetworkStatistics stats) => stats.entries.fold(0, (sum, entry) => sum + switch (entry) {
      td.NetworkStatisticsEntryFile(:final sentBytes, :final receivedBytes) ||
      td.NetworkStatisticsEntryCall(:final sentBytes, :final receivedBytes) =>
        sentBytes + receivedBytes,
      _ => 0,
    });

/// Traffic per network kind (mobile, Wi-Fi, roaming, other) since the counters were last reset.
class NetworkUsageScreen extends ConsumerStatefulWidget {
  const NetworkUsageScreen({super.key});

  @override
  ConsumerState<NetworkUsageScreen> createState() => _NetworkUsageScreenState();
}

class _NetworkUsageScreenState extends ConsumerState<NetworkUsageScreen> {
  td.NetworkStatistics? _stats;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final stats = await guard(context, () => ref.read(accountProvider).send<td.NetworkStatistics>(const td.GetNetworkStatistics(onlyCurrent: false)));
    if (mounted && stats != null) setState(() => _stats = stats);
  }

  static String _networkKey(td.NetworkType type) => switch (type) {
        td.NetworkTypeMobile() => 'network_mobile',
        td.NetworkTypeWiFi() => 'network_wifi',
        td.NetworkTypeMobileRoaming() => 'network_roaming',
        _ => 'network_other',
      };

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final stats = _stats;
    final primary = Theme.of(context).colorScheme.primary;
    final sent = <String, int>{};
    final received = <String, int>{};
    for (final entry in stats?.entries ?? const <td.NetworkStatisticsEntry>[]) {
      final (type, out, inc) = switch (entry) {
        td.NetworkStatisticsEntryFile(:final networkType, :final sentBytes, :final receivedBytes) => (networkType, sentBytes, receivedBytes),
        td.NetworkStatisticsEntryCall(:final networkType, :final sentBytes, :final receivedBytes) => (networkType, sentBytes, receivedBytes),
        _ => (null, 0, 0),
      };
      if (type == null) continue;
      final key = _networkKey(type);
      sent[key] = (sent[key] ?? 0) + out;
      received[key] = (received[key] ?? 0) + inc;
    }
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('network_usage'))),
      body: stats == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final key in const ['network_mobile', 'network_wifi', 'network_roaming', 'network_other'])
                  if ((sent[key] ?? 0) + (received[key] ?? 0) > 0)
                    SettingsGroup(title: s.t(key), children: [
                      ListTile(
                        leading: const Icon(Icons.arrow_upward_rounded),
                        title: Text(s.t('network_sent')),
                        trailing: Text(formatFileSize(sent[key] ?? 0), style: TextStyle(color: primary)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.arrow_downward_rounded),
                        title: Text(s.t('network_received')),
                        trailing: Text(formatFileSize(received[key] ?? 0), style: TextStyle(color: primary)),
                      ),
                    ]),
                GroupHint(s.t('network_since', {'date': formatChatTime(stats.sinceDate, s.locale)})),
                SettingsGroup(children: [
                  ListTile(
                    title: Text(s.t('network_reset'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: () async {
                      final ok = await confirm(context, title: s.t('network_reset'), destructive: true);
                      if (!ok || !context.mounted) return;
                      await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ResetNetworkStatistics()));
                      await _load();
                    },
                  ),
                ]),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ two-step verification

class TwoStepScreen extends ConsumerStatefulWidget {
  const TwoStepScreen({super.key});

  @override
  ConsumerState<TwoStepScreen> createState() => _TwoStepScreenState();
}

class _TwoStepScreenState extends ConsumerState<TwoStepScreen> {
  td.PasswordState? _state;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final state = await ref.read(accountProvider).passwordState();
      if (mounted) setState(() => _state = state);
    } on TdException catch (error) {
      if (mounted) showToast(context, errorTextFromCode(context, error.message));
    }
  }

  Future<void> _afterChange(td.PasswordState state) async {
    setState(() => _state = state);
    final pending = state.recoveryEmailAddressCodeInfo;
    if (pending == null || !mounted) return;
    final code = await _prompt(context.t('email_code_title'), context.t('email_code_sent', {'email': pending.emailAddressPattern}));
    if (code == null || !mounted) return;
    final confirmed = await guard(context, () => ref.read(accountProvider).confirmRecoveryEmail(code));
    if (confirmed != null && mounted) setState(() => _state = confirmed);
  }

  Future<String?> _prompt(String title, String message, {bool obscure = false}) async {
    final controller = TextEditingController();
    final s = context.s;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty) Text(message),
            TextField(controller: controller, autofocus: true, obscureText: obscure),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(s.t('ok'))),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _setOrChange() async {
    final has = _state?.hasPassword ?? false;
    final result = await Navigator.of(context).push<(String, String, String, String)>(
      MaterialPageRoute(builder: (_) => PasswordForm(askOld: has, askEmail: !(_state?.hasRecoveryEmailAddress ?? false))),
    );
    if (result == null || !mounted) return;
    final state = await guard(
      context,
      () => ref.read(accountProvider).setPassword(oldPassword: result.$1, newPassword: result.$2, hint: result.$3, recoveryEmail: result.$4),
    );
    if (state != null && mounted) await _afterChange(state);
  }

  Future<void> _remove() async {
    final s = context.s;
    final old = await _prompt(s.t('two_step_current'), '', obscure: true);
    if (old == null || !mounted) return;
    final ok = await confirm(context, title: s.t('two_step_disable'), message: s.t('two_step_disable_confirm'), destructive: true);
    if (!ok || !mounted) return;
    final state = await guard(context, () => ref.read(accountProvider).setPassword(oldPassword: old, newPassword: ''));
    if (state != null && mounted) setState(() => _state = state);
  }

  Future<void> _changeEmail() async {
    final s = context.s;
    final password = await _prompt(s.t('two_step_current'), '', obscure: true);
    if (password == null || !mounted) return;
    final email = await _prompt(s.t('recovery_email'), '');
    if (email == null || !mounted) return;
    final state = await guard(context, () => ref.read(accountProvider).setRecoveryEmail(password, email.trim()));
    if (state != null && mounted) await _afterChange(state);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final state = _state;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('two_step'))),
      body: state == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(state.hasPassword ? Icons.verified_user_rounded : Icons.shield_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(s.t(state.hasPassword ? 'two_step_on' : 'two_step_off'), textAlign: TextAlign.center),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.password_rounded),
                  title: Text(s.t(state.hasPassword ? 'two_step_change' : 'two_step_set')),
                  onTap: _setOrChange,
                ),
                if (state.recoveryEmailAddressCodeInfo case final pending?)
                  ...pendingRecoveryEmailTiles(context, ref, pending, (next) => setState(() => _state = next)),
                if (state.hasPassword) ...[
                  ListTile(
                    leading: const Icon(Icons.email_rounded),
                    title: Text(s.t(state.hasRecoveryEmailAddress ? 'recovery_email_change' : 'recovery_email_set')),
                    onTap: _changeEmail,
                  ),
                  if (state.hasRecoveryEmailAddress)
                    ListTile(
                      leading: const Icon(Icons.visibility_rounded),
                      title: Text(s.t('recovery_email_show')),
                      onTap: () => showRecoveryEmail(context, ref),
                    ),
                  if (state.pendingResetDate != 0)
                    ListTile(
                      leading: const Icon(Icons.timer_rounded),
                      title: Text(s.t('two_step_reset_pending', {'date': formatChatTime(state.pendingResetDate, s.locale)})),
                      subtitle: Text(s.t('two_step_reset_cancel')),
                      onTap: () async {
                        final next = await cancelPasswordReset(context, ref);
                        if (next != null && mounted) setState(() => _state = next);
                      },
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.help_outline_rounded),
                      title: Text(s.t('forgot_password')),
                      onTap: () async {
                        if (!state.hasRecoveryEmailAddress) {
                          await resetForgottenPassword(context, ref);
                          await _load();
                          return;
                        }
                        final next = await recoverForgottenPassword(context, ref);
                        if (next != null && mounted) setState(() => _state = next);
                      },
                    ),
                  ListTile(
                    leading: Icon(Icons.no_encryption_rounded, color: Theme.of(context).colorScheme.error),
                    title: Text(s.t('two_step_disable'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onTap: _remove,
                  ),
                ],
              ],
            ),
    );
  }
}
