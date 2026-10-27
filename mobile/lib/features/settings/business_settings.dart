import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'business_quick_replies.dart';
import 'privacy_screen.dart';

/// Telegram's reserved shortcut names for the automatic greeting and away messages.
const greetingShortcut = 'hello';
const awayShortcut = 'away';

/// Settings → Telegram Business for Premium users: location, hours, quick replies, auto messages,
/// chat links and the start page.
class BusinessSettingsScreen extends ConsumerStatefulWidget {
  const BusinessSettingsScreen({super.key});

  @override
  ConsumerState<BusinessSettingsScreen> createState() => _BusinessSettingsScreenState();
}

class _BusinessSettingsScreenState extends ConsumerState<BusinessSettingsScreen> {
  td.BusinessInfo? _info;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    account.send<td.Ok>(const td.LoadQuickReplyShortcuts()).ignore();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final full = await guard(context, () => account.send<td.UserFullInfo>(td.GetUserFullInfo(userId: account.myId)));
    if (mounted) {
      setState(() {
        _info = full?.businessInfo;
        _loaded = true;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    final ok = await guard(context, () async {
      await action();
      return true;
    });
    if (ok == true) await _load();
  }

  Future<void> _editLocation() async {
    final s = context.s;
    final address = await promptText(context, title: s.t('biz_location'), label: s.t('biz_address'), initial: _info?.location?.address ?? '');
    if (address == null || !mounted) return;
    final account = ref.read(accountProvider);
    await _run(() => account.send<td.Ok>(td.SetBusinessLocation(
          location: address.trim().isEmpty ? null : td.BusinessLocation(location: null, address: address.trim()),
        )));
  }

  Future<void> _editStartPage() async {
    final s = context.s;
    final page = _info?.startPage;
    final title = await promptText(context, title: s.t('biz_intro'), label: s.t('biz_intro_title'), initial: page?.title ?? '');
    if (title == null || !mounted) return;
    final message = await promptText(context, title: s.t('biz_intro'), label: s.t('biz_intro_message'), initial: page?.message ?? '');
    if (message == null || !mounted) return;
    final empty = title.trim().isEmpty && message.trim().isEmpty;
    final account = ref.read(accountProvider);
    await _run(() => account.send<td.Ok>(td.SetBusinessStartPage(
          startPage: empty ? null : td.InputBusinessStartPage(title: title.trim(), message: message.trim(), sticker: null),
        )));
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)).then((_) => _load());

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final info = _info;
    final hint = Theme.of(context).hintColor;
    Widget sub(String text) => Text(text, style: TextStyle(color: hint), maxLines: 1, overflow: TextOverflow.ellipsis);
    final hours = info?.openingHours;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('telegram_business'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                SettingsGroup(children: [
                  ListTile(
                    leading: const TileIcon(Icons.location_on_rounded, Color(0xFFFF8A1F)),
                    title: Text(s.t('biz_location')),
                    subtitle: sub(info?.location?.address.isNotEmpty == true ? info!.location!.address : s.t('off')),
                    onTap: _editLocation,
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.schedule_rounded, Color(0xFFFF7A59)),
                    title: Text(s.t('biz_hours')),
                    subtitle: sub(hours == null ? s.t('off') : hoursSummary(hours, s)),
                    onTap: () => _push(BusinessHoursScreen(initial: hours)),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.quickreply_rounded, Color(0xFFF2625E)),
                    title: Text(s.t('biz_quick_replies')),
                    onTap: () => _push(const QuickRepliesScreen()),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.waving_hand_rounded, Color(0xFFE5486A)),
                    title: Text(s.t('biz_greeting')),
                    subtitle: sub(s.t(info?.greetingMessageSettings == null ? 'off' : 'state_on')),
                    onTap: () => _push(AutoMessageScreen(away: false, greeting: info?.greetingMessageSettings)),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.bedtime_rounded, Color(0xFFD457A8)),
                    title: Text(s.t('biz_away')),
                    subtitle: sub(s.t(info?.awayMessageSettings == null ? 'off' : 'state_on')),
                    onTap: () => _push(AutoMessageScreen(away: true, awaySettings: info?.awayMessageSettings)),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.link_rounded, Color(0xFFB45CD9)),
                    title: Text(s.t('biz_links')),
                    onTap: () => _push(const BusinessChatLinksScreen()),
                  ),
                  ListTile(
                    leading: const TileIcon(Icons.info_rounded, Color(0xFF8A72EA)),
                    title: Text(s.t('biz_intro')),
                    subtitle: sub(info?.startPage?.title.isNotEmpty == true ? info!.startPage!.title : s.t('off')),
                    onTap: _editStartPage,
                  ),
                ]),
                GroupHint(s.t('biz_premium_hint')),
              ],
            ),
    );
  }
}

const _minutesPerDay = 24 * 60;

/// "Mon–Fri 09:00–18:00" style summary of the first interval, plus the count of open days.
String hoursSummary(td.BusinessOpeningHours hours, Strings s) {
  if (hours.openingHours.isEmpty) return s.t('off');
  final days = {for (final i in hours.openingHours) (i.startMinute ~/ _minutesPerDay) % 7};
  final first = hours.openingHours.first;
  String hm(int minute) => '${(minute % _minutesPerDay ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
  final allDay = first.endMinute - first.startMinute >= _minutesPerDay;
  return '${s.t('biz_days_n', {'n': '${days.length}'})} · ${allDay ? s.t('biz_24h') : '${hm(first.startMinute)}–${hm(first.endMinute)}'}';
}

/// Same opening time on the chosen weekdays (Telegram counts minutes from Monday 00:00).
class BusinessHoursScreen extends ConsumerStatefulWidget {
  const BusinessHoursScreen({super.key, this.initial});

  final td.BusinessOpeningHours? initial;

  @override
  ConsumerState<BusinessHoursScreen> createState() => _BusinessHoursScreenState();
}

class _BusinessHoursScreenState extends ConsumerState<BusinessHoursScreen> {
  late bool _enabled = widget.initial != null;
  late Set<int> _days = widget.initial == null || widget.initial!.openingHours.isEmpty
      ? {0, 1, 2, 3, 4}
      : {for (final i in widget.initial!.openingHours) (i.startMinute ~/ _minutesPerDay) % 7};
  late TimeOfDay _from = _time(widget.initial?.openingHours.firstOrNull?.startMinute ?? 9 * 60);
  late TimeOfDay _to = _time(widget.initial?.openingHours.firstOrNull?.endMinute ?? 18 * 60);
  late bool _allDay = switch (widget.initial?.openingHours.firstOrNull) {
    final i? => i.endMinute - i.startMinute >= _minutesPerDay,
    null => false,
  };

  static TimeOfDay _time(int minute) => TimeOfDay(hour: minute % _minutesPerDay ~/ 60, minute: minute % 60);

  Future<void> _save() async {
    final account = ref.read(accountProvider);
    final ok = await guard(context, () async {
      td.BusinessOpeningHours? hours;
      if (_enabled) {
        final zones = await account.send<td.TimeZones>(const td.GetTimeZones());
        final offset = DateTime.now().timeZoneOffset.inSeconds;
        final zone = zones.timeZones.where((z) => z.utcTimeOffset == offset).firstOrNull ?? zones.timeZones.first;
        final start = _allDay ? 0 : _from.hour * 60 + _from.minute;
        var end = _allDay ? _minutesPerDay : _to.hour * 60 + _to.minute;
        if (end <= start) end += _minutesPerDay; // closes after midnight
        hours = td.BusinessOpeningHours(
          timeZoneId: zone.id,
          openingHours: [
            for (final day in _days.toList()..sort())
              td.BusinessOpeningHoursInterval(startMinute: day * _minutesPerDay + start, endMinute: day * _minutesPerDay + end),
          ],
        );
      }
      await account.send<td.Ok>(td.SetBusinessOpeningHours(openingHours: hours));
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final weekdays = s.t('biz_weekdays').split(',');
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('biz_hours')), actions: [TextButton(onPressed: _save, child: Text(s.t('save')))]),
      body: ListView(
        children: [
          SettingsGroup(children: [
            SwitchListTile(title: Text(s.t('biz_hours_show')), value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
          ]),
          if (_enabled) ...[
            SettingsGroup(title: s.t('biz_open_days'), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var day = 0; day < 7; day++)
                    FilterChip(
                      label: Text(weekdays.length == 7 ? weekdays[day] : '${day + 1}'),
                      selected: _days.contains(day),
                      onSelected: (on) => setState(() => _days = on ? {..._days, day} : ({..._days}..remove(day))),
                    ),
                ]),
              ),
            ]),
            SettingsGroup(children: [
              SwitchListTile(title: Text(s.t('biz_24h')), value: _allDay, onChanged: (v) => setState(() => _allDay = v)),
              if (!_allDay) ...[
                ListTile(
                  title: Text(s.t('biz_opens')),
                  trailing: Text(_from.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: _from);
                    if (t != null) setState(() => _from = t);
                  },
                ),
                ListTile(
                  title: Text(s.t('biz_closes')),
                  trailing: Text(_to.format(context)),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: _to);
                    if (t != null) setState(() => _to = t);
                  },
                ),
              ],
            ]),
          ],
        ],
      ),
    );
  }
}

/// Greeting (first message after inactivity) or away message, both sent from a reserved quick reply.
class AutoMessageScreen extends ConsumerStatefulWidget {
  const AutoMessageScreen({super.key, required this.away, this.greeting, this.awaySettings});

  final bool away;
  final td.BusinessGreetingMessageSettings? greeting;
  final td.BusinessAwayMessageSettings? awaySettings;

  @override
  ConsumerState<AutoMessageScreen> createState() => _AutoMessageScreenState();
}

class _AutoMessageScreenState extends ConsumerState<AutoMessageScreen> {
  late bool _enabled = (widget.away ? widget.awaySettings : widget.greeting) != null;
  late td.BusinessRecipients _recipients = (widget.away ? widget.awaySettings?.recipients : widget.greeting?.recipients) ??
      const td.BusinessRecipients(
        chatIds: [],
        excludedChatIds: [],
        selectExistingChats: false,
        selectNewChats: true,
        selectContacts: false,
        selectNonContacts: true,
        excludeSelected: false,
      );
  late int _inactivityDays = widget.greeting?.inactivityDays ?? 7;
  late bool _outsideHours = widget.awaySettings?.schedule is td.BusinessAwayMessageScheduleOutsideOfOpeningHours;
  late bool _offlineOnly = widget.awaySettings?.offlineOnly ?? false;

  String get _shortcutName => widget.away ? awayShortcut : greetingShortcut;

  td.QuickReplyShortcut? _shortcut(TelegramAccount account) => account.quickReplies.values.where((q) => q.name == _shortcutName).firstOrNull;

  td.BusinessRecipients _with({bool? existing, bool? fresh, bool? contacts, bool? nonContacts}) => td.BusinessRecipients(
        chatIds: _recipients.chatIds,
        excludedChatIds: _recipients.excludedChatIds,
        selectExistingChats: existing ?? _recipients.selectExistingChats,
        selectNewChats: fresh ?? _recipients.selectNewChats,
        selectContacts: contacts ?? _recipients.selectContacts,
        selectNonContacts: nonContacts ?? _recipients.selectNonContacts,
        excludeSelected: _recipients.excludeSelected,
      );

  Future<void> _save() async {
    final account = ref.read(accountProvider);
    final shortcut = _shortcut(account);
    if (_enabled && shortcut == null) {
      showToast(context, context.t('biz_message_needed'));
      return;
    }
    final ok = await guard(context, () async {
      if (widget.away) {
        await account.send<td.Ok>(td.SetBusinessAwayMessageSettings(
          awayMessageSettings: !_enabled
              ? null
              : td.BusinessAwayMessageSettings(
                  shortcutId: shortcut!.id,
                  recipients: _recipients,
                  schedule: _outsideHours ? const td.BusinessAwayMessageScheduleOutsideOfOpeningHours() : const td.BusinessAwayMessageScheduleAlways(),
                  offlineOnly: _offlineOnly,
                ),
        ));
      } else {
        await account.send<td.Ok>(td.SetBusinessGreetingMessageSettings(
          greetingMessageSettings: !_enabled ? null : td.BusinessGreetingMessageSettings(shortcutId: shortcut!.id, recipients: _recipients, inactivityDays: _inactivityDays),
        ));
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder(
      valueListenable: account.quickRepliesRevision,
      builder: (context, _, _) {
        final shortcut = _shortcut(account);
        return Scaffold(
          backgroundColor: groupedBackground(context),
          appBar: AppBar(title: Text(s.t(widget.away ? 'biz_away' : 'biz_greeting')), actions: [TextButton(onPressed: _save, child: Text(s.t('save')))]),
          body: ListView(
            children: [
              SettingsGroup(children: [
                SwitchListTile(title: Text(s.t(widget.away ? 'biz_away_send' : 'biz_greeting_send')), value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
              ]),
              GroupHint(s.t(widget.away ? 'biz_away_sub' : 'biz_greeting_sub')),
              if (_enabled) ...[
                SettingsGroup(children: [
                  ListTile(
                    leading: const Icon(Icons.edit_note_rounded),
                    title: Text(s.t(shortcut == null ? 'biz_message_create' : 'biz_message_edit')),
                    subtitle: shortcut == null ? null : Text(quickReplyPreview(shortcut.firstMessage, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => shortcut == null
                        ? addQuickReplyText(context, account, _shortcutName)
                        : Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuickReplyMessagesScreen(shortcutId: shortcut.id))),
                  ),
                ]),
                SettingsGroup(title: s.t('biz_recipients'), children: [
                  CheckboxListTile(title: Text(s.t('biz_new_chats')), value: _recipients.selectNewChats, onChanged: (v) => setState(() => _recipients = _with(fresh: v))),
                  CheckboxListTile(title: Text(s.t('biz_existing_chats')), value: _recipients.selectExistingChats, onChanged: (v) => setState(() => _recipients = _with(existing: v))),
                  CheckboxListTile(title: Text(s.t('biz_contacts')), value: _recipients.selectContacts, onChanged: (v) => setState(() => _recipients = _with(contacts: v))),
                  CheckboxListTile(title: Text(s.t('biz_non_contacts')), value: _recipients.selectNonContacts, onChanged: (v) => setState(() => _recipients = _with(nonContacts: v))),
                ]),
                if (!widget.away)
                  SettingsGroup(title: s.t('biz_inactivity'), children: [
                    RadioGroup<int>(
                      groupValue: _inactivityDays,
                      onChanged: (v) => setState(() => _inactivityDays = v ?? 7),
                      child: Column(children: [
                        for (final days in const [7, 14, 21, 28]) RadioListTile<int>(value: days, title: Text(s.t('keep_days', {'n': '$days'}))),
                      ]),
                    ),
                  ])
                else
                  SettingsGroup(title: s.t('biz_schedule'), children: [
                    SwitchListTile(title: Text(s.t('biz_outside_hours')), value: _outsideHours, onChanged: (v) => setState(() => _outsideHours = v)),
                    SwitchListTile(title: Text(s.t('biz_offline_only')), value: _offlineOnly, onChanged: (v) => setState(() => _offlineOnly = v)),
                  ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// t.me/m/… links that open a chat with the user and a prefilled message.
class BusinessChatLinksScreen extends ConsumerStatefulWidget {
  const BusinessChatLinksScreen({super.key});

  @override
  ConsumerState<BusinessChatLinksScreen> createState() => _BusinessChatLinksScreenState();
}

class _BusinessChatLinksScreenState extends ConsumerState<BusinessChatLinksScreen> {
  List<td.BusinessChatLink>? _links;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(context, () => ref.read(accountProvider).send<td.BusinessChatLinks>(const td.GetBusinessChatLinks()));
    if (mounted) setState(() => _links = result?.links ?? const []);
  }

  Future<td.InputBusinessChatLink?> _prompt({td.BusinessChatLink? link}) async {
    final s = context.s;
    final text = await promptText(context, title: s.t('biz_links'), label: s.t('biz_link_text'), initial: link?.text.text ?? '');
    if (text == null || !mounted) return null;
    final title = await promptText(context, title: s.t('biz_links'), label: s.t('biz_link_title'), initial: link?.title ?? '');
    if (title == null) return null;
    return td.InputBusinessChatLink(text: plainText(text.trim()), title: title.trim());
  }

  Future<void> _create() async {
    final info = await _prompt();
    if (info == null || !mounted) return;
    await guard(context, () => ref.read(accountProvider).send<td.BusinessChatLink>(td.CreateBusinessChatLink(linkInfo: info)));
    await _load();
  }

  Future<void> _actions(td.BusinessChatLink link) async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.copy_rounded), title: Text(s.t('copy_link')), onTap: () => Navigator.pop(context, 'copy')),
          ListTile(leading: const Icon(Icons.share_rounded), title: Text(s.t('share')), onTap: () => Navigator.pop(context, 'share')),
          ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('edit')), onTap: () => Navigator.pop(context, 'edit')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: link.link));
        if (mounted) showToast(context, s.t('link_copied'));
      case 'share':
        await SharePlus.instance.share(ShareParams(text: link.link));
      case 'edit':
        final info = await _prompt(link: link);
        if (info != null && mounted) await guard(context, () => account.send<td.BusinessChatLink>(td.EditBusinessChatLink(link: link.link, linkInfo: info)));
      case 'delete':
        await guard(context, () => account.send<td.Ok>(td.DeleteBusinessChatLink(link: link.link)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final links = _links;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('biz_links'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_link_rounded), label: Text(s.t('create_link'))),
      body: links == null
          ? const Center(child: CircularProgressIndicator())
          : links.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t('biz_links_sub'), textAlign: TextAlign.center)))
              : ListView(children: [
                  for (final link in links)
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.link_rounded)),
                      title: Text(link.title.isNotEmpty ? link.title : link.link, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${link.text.text.isEmpty ? link.link : link.text.text}\n${s.t('biz_link_views', {'n': formatCount(link.viewCount)})}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      onTap: () => _actions(link),
                    ),
                  const SizedBox(height: 80),
                ]),
    );
  }
}
