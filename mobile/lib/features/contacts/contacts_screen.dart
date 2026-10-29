import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as phone;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../home/home_screen.dart';
import '../profile/profile_more.dart';

final contactsProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  final account = ref.watch(accountProvider);
  final users = await account.send<td.Users>(const td.GetContacts());
  return users.userIds;
});

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.pickToChat = false, this.createGroup = false, this.pickUser = false, this.pickMany = false});

  /// "New message" entry: shows new group/channel shortcuts.
  final bool pickToChat;

  /// Multi-select members, then name the group.
  final bool createGroup;

  /// Pops with the chosen [td.User].
  final bool pickUser;

  /// Pops with a list of user ids.
  final bool pickMany;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String _query = '';
  // TDLib's own contact search (handles transliteration); merged with the local word-prefix match.
  Set<int> _serverMatches = const {};
  final Set<int> _selected = {};
  bool _importing = false;
  bool _byName = false;

  bool get _multi => widget.createGroup || widget.pickMany;

  Future<void> _importPhoneContacts() async {
    final s = context.s;
    final status = await phone.FlutterContacts.permissions.request(phone.PermissionType.read);
    if (status != phone.PermissionStatus.granted && status != phone.PermissionStatus.limited) {
      if (mounted) showToast(context, s.t('contacts_permission'));
      return;
    }
    setState(() => _importing = true);
    try {
      final contacts = await phone.FlutterContacts.getAll(properties: {phone.ContactProperty.name, phone.ContactProperty.phone});
      final imported = <td.ImportedContact>[
        for (final contact in contacts)
          for (final number in contact.phones)
            td.ImportedContact(
              phoneNumber: number.number,
              firstName: contact.name?.first ?? contact.displayName ?? '',
              lastName: contact.name?.last ?? '',
              note: null,
            ),
      ];
      if (!mounted) return;
      // Replaces the synced list, so contacts deleted from the phone are dropped too.
      final done = await guard(context, () => ref.read(accountProvider).send<td.ImportedContacts>(td.ChangeImportedContacts(contacts: imported)));
      if (done == null || !mounted) return;
      ref.invalidate(contactsProvider);
      showToast(context, s.t('contacts_synced'));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Adds someone by phone number (ImportContacts); opens the chat when they use Telegram.
  Future<void> _addByPhone() async {
    final s = context.s;
    final phoneCtl = TextEditingController();
    final firstCtl = TextEditingController();
    final lastCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('add_contact')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: firstCtl, autofocus: true, decoration: InputDecoration(labelText: s.t('first_name'))),
          TextField(controller: lastCtl, decoration: InputDecoration(labelText: s.t('last_name'))),
          TextField(controller: phoneCtl, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: s.t('phone_number'), prefixText: '+')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('add'))),
        ],
      ),
    );
    final phoneNumber = phoneCtl.text.replaceAll(RegExp(r'[^\d]'), '');
    final first = firstCtl.text.trim();
    final last = lastCtl.text.trim();
    phoneCtl.dispose();
    firstCtl.dispose();
    lastCtl.dispose();
    if (ok != true || !mounted) return;
    if (phoneNumber.length < 7 || first.isEmpty) {
      showToast(context, s.t('contact_invalid'));
      return;
    }
    final account = ref.read(accountProvider);
    final result = await guard(
      context,
      () => account.send<td.ImportedContacts>(td.ImportContacts(contacts: [td.ImportedContact(phoneNumber: phoneNumber, firstName: first, lastName: last, note: null)])),
    );
    if (result == null || !mounted) return;
    final userId = result.userIds.firstOrNull ?? 0;
    if (userId == 0) {
      showToast(context, s.t('contact_not_on_telegram'));
      return;
    }
    ref.invalidate(contactsProvider);
    final chat = await guard(context, () => account.openPrivateChat(userId));
    if (chat == null || !mounted) return;
    Navigator.pop(context);
    openChat(context, chat.id);
  }

  Future<void> _onUserTap(td.User user) async {
    if (_multi) {
      setState(() => _selected.contains(user.id) ? _selected.remove(user.id) : _selected.add(user.id));
      return;
    }
    if (widget.pickUser) {
      Navigator.pop(context, user);
      return;
    }
    final account = ref.read(accountProvider);
    final chat = await guard(context, () => account.openPrivateChat(user.id));
    if (chat == null || !mounted) return;
    Navigator.pop(context);
    openChat(context, chat.id);
  }

  Future<void> _next() async {
    if (widget.pickMany) {
      Navigator.pop(context, _selected.toList());
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NewGroupScreen(memberIds: _selected.toList())));
  }

  /// Plain contacts tab: no picking, shows invite and sort controls.
  bool get _plain => !_multi && !widget.pickUser && !widget.pickToChat;

  /// Higher is more recently seen; online users come first.
  static int _lastSeenScore(td.User user) => switch (user.status) {
        _ when isOnline(user) => 1 << 40,
        td.UserStatusOffline(:final wasOnline) => wasOnline,
        td.UserStatusRecently() => -1,
        td.UserStatusLastWeek() => -2,
        td.UserStatusLastMonth() => -3,
        _ => -4,
      };

  Future<void> _onQuery(String value) async {
    final query = value.trim().toLowerCase();
    setState(() => _query = query);
    if (query.isEmpty) return;
    try {
      final found = await ref.read(accountProvider).send<td.Users>(td.SearchContacts(query: query, limit: 50));
      if (mounted && query == _query) setState(() => _serverMatches = found.userIds.toSet());
    } on TdException catch (error) {
      debugPrint('contact search failed: $error');
    }
  }

  List<td.User> _filterAndSort(List<int> userIds) {
    final account = ref.read(accountProvider);
    int byName(td.User a, td.User b) => '${a.firstName} ${a.lastName}'.toLowerCase().compareTo('${b.firstName} ${b.lastName}'.toLowerCase());
    final users = userIds.map((id) => account.users[id]).whereType<td.User>().toList();
    final Set<int>? prefixHits = _query.isEmpty
        ? null
        : prefixMatches([for (final u in users) '${u.firstName} ${u.lastName} ${u.usernames?.activeUsernames.join(' ') ?? ''}'], _query);
    return [
      for (final (i, u) in users.indexed)
        if (_query.isEmpty ||
            _serverMatches.contains(u.id) ||
            (prefixHits?.contains(i) ?? '${u.firstName} ${u.lastName}'.toLowerCase().contains(_query)) ||
            u.phoneNumber.contains(_query))
          u,
    ]
      ..sort((a, b) {
        if (_byName) return byName(a, b);
        final seen = _lastSeenScore(b).compareTo(_lastSeenScore(a));
        return seen != 0 ? seen : byName(a, b);
      });
  }

  Future<void> _invite() async {
    final username = ref.read(meProvider)?.usernames?.activeUsernames.firstOrNull;
    var link = username == null ? '' : 'https://t.me/$username';
    if (link.isEmpty) {
      // Telegram's personal invite link (counts the friends who join).
      try {
        link = (await ref.read(accountProvider).send<td.HttpUrl>(const td.GetApplicationDownloadLink())).url;
      } on TdException {
        link = 'https://telegram.org/dl';
      }
    }
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(text: context.t('invite_text', {'link': link})));
  }

  /// One horizontal slice of a rounded card, so long lists stay lazily built.
  Widget _slice(Widget child, {bool top = false, bool bottom = false}) => Padding(
        padding: EdgeInsets.fromLTRB(12, top ? 6 : 0, 12, bottom ? 6 : 0),
        child: Material(
          color: groupCardColor(context),
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.vertical(top: Radius.circular(top ? 18 : 0), bottom: Radius.circular(bottom ? 18 : 0)),
          child: Padding(padding: EdgeInsets.only(top: top ? 6 : 0, bottom: bottom ? 6 : 0), child: child),
        ),
      );

  Widget _searchField(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: TextField(
        onChanged: _onQuery,
        decoration: InputDecoration(
          hintText: s.t(widget.createGroup ? 'add_members' : 'search_contacts'),
          prefixIcon: const Icon(Icons.search_rounded),
          filled: true,
          fillColor: groupCardColor(context),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  List<Widget> _shortcuts(BuildContext context) {
    final s = context.s;
    if (_query.isNotEmpty) return const [];
    if (widget.pickToChat) {
      return [
        SettingsGroup(children: [
          ListTile(
            leading: const TileIcon(Icons.group_add_rounded, Color(0xFF2E9BF0)),
            title: Text(s.t('new_group')),
            onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const ContactsScreen(createGroup: true))),
          ),
          ListTile(
            leading: const TileIcon(Icons.campaign_rounded, Color(0xFFFF9F1A)),
            title: Text(s.t('new_channel')),
            onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const NewChannelScreen())),
          ),
        ]),
      ];
    }
    if (!_plain) return const [];
    return [
      SettingsGroup(children: [
        ListTile(
          leading: const TileIcon(Icons.person_add_alt_1_rounded, Color(0xFF2E9BF0)),
          title: Text(s.t('invite_friends')),
          onTap: _invite,
        ),
        ListTile(
          leading: const TileIcon(Icons.dialpad_rounded, Color(0xFF8E62E8)),
          title: Text(s.t('add_contact_by_phone')),
          onTap: _addByPhone,
        ),
        ListTile(
          leading: const TileIcon(Icons.sync_rounded, Color(0xFF2EAD5B)),
          title: Text(s.t('sync_contacts')),
          trailing: _importing ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: _importing ? null : _importPhoneContacts,
        ),
      ]),
      if (ref.read(accountProvider).closeBirthdays case final birthdays when birthdays.isNotEmpty) _birthdays(birthdays),
    ];
  }

  /// "Birthdays soon" card, as in Telegram's contact list; can be hidden for now.
  Widget _birthdays(List<td.CloseBirthdayUser> birthdays) {
    final s = context.s;
    final account = ref.read(accountProvider);
    return SettingsGroup(children: [
      ListTile(
        leading: const TileIcon(Icons.cake_rounded, Color(0xFFF2557A)),
        title: Text(s.t('birthdays_soon')),
        trailing: IconButton(
          tooltip: s.t('hide'),
          icon: const Icon(Icons.close_rounded),
          onPressed: () async {
            await guard(context, () => account.send<td.Ok>(const td.HideContactCloseBirthdays()));
            if (mounted) setState(() => account.closeBirthdays = const []);
          },
        ),
      ),
      for (final b in birthdays)
        if (account.users[b.userId] case final user?)
          ListTile(
            leading: UserAvatar(userId: user.id, size: 40),
            title: Text('${user.firstName} ${user.lastName}'.trim()),
            subtitle: Text('${b.birthdate.day.toString().padLeft(2, '0')}.${b.birthdate.month.toString().padLeft(2, '0')}'),
            onTap: () => _onUserTap(user),
          ),
    ]);
  }

  Widget _userTile(td.User user) {
    final s = context.s;
    return ListTile(
      leading: UserAvatar(userId: user.id, size: 46),
      title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        formatUserStatus(user, s),
        style: TextStyle(color: isOnline(user) ? Theme.of(context).colorScheme.primary : null),
      ),
      trailing: _multi ? Checkbox(value: _selected.contains(user.id), onChanged: (_) => _onUserTap(user)) : null,
      onTap: () => _onUserTap(user),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final ids = ref.watch(contactsProvider);
    ref.watch(usersRevisionProvider);
    final title = widget.createGroup ? 'new_group' : widget.pickToChat ? 'new_message' : 'contacts';
    // Opened from the bottom bar (not as a picker): the shared light tab header.
    final isTab = !widget.createGroup && !widget.pickToChat && !widget.pickUser;
    final sortAction = [
      if (!_multi && !widget.pickUser)
        IconButton(
          tooltip: s.t(_byName ? 'sort_last_seen' : 'sort_name'),
          icon: Icon(_byName ? Icons.schedule_rounded : Icons.sort_by_alpha_rounded),
          onPressed: () => setState(() => _byName = !_byName),
        ),
    ];
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: isTab ? BrandTabBar(title: s.t(title), actions: sortAction) : AppBar(title: Text(s.t(title)), actions: sortAction),
      floatingActionButton: _multi && (_selected.isNotEmpty || widget.createGroup)
          ? FloatingActionButton(onPressed: _next, child: const Icon(Icons.arrow_forward_rounded))
          : null,
      body: ids.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (userIds) {
          final users = _filterAndSort(userIds);
          final head = <Widget>[
            _searchField(context),
            ..._shortcuts(context),
            if (users.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(s.t('no_contacts'), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
              )
            else
              _slice(
                top: true,
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
                  child: Text(
                    s.t(_byName ? 'sort_name' : 'sort_last_seen'),
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 14.5),
                  ),
                ),
              ),
          ];
          return ListView.builder(
            // Clears the shell's floating bottom bar (reported as bottom padding).
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 12),
            itemCount: head.length + users.length,
            itemBuilder: (context, index) {
              if (index < head.length) return head[index];
              final i = index - head.length;
              return _slice(_userTile(users[i]), bottom: i == users.length - 1);
            },
          );
        },
      ),
    );
  }
}

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key, required this.memberIds});

  final List<int> memberIds;

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _title = TextEditingController();
  String? _photoPath;
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    setState(() => _creating = true);
    final account = ref.read(accountProvider);
    final chatId = await guard(context, () async {
      final created = await account.send<td.CreatedBasicGroupChat>(
        td.CreateNewBasicGroupChat(userIds: widget.memberIds, title: title, messageAutoDeleteTime: 0),
      );
      if (_photoPath != null) {
        await account.send<td.Ok>(td.SetChatPhoto(
          chatId: created.chatId,
          photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: _photoPath!)),
        ));
      }
      return created.chatId;
    });
    if (!mounted) return;
    setState(() => _creating = false);
    if (chatId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      openChat(context, chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('new_group'))),
      floatingActionButton: FloatingActionButton(
        onPressed: _creating ? null : _create,
        child: _creating
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : const Icon(Icons.check_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _PhotoPicker(path: _photoPath, onPicked: (path) => setState(() => _photoPath = path)),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(labelText: s.t('group_name')),
                  onSubmitted: (_) => _create(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SectionHeader(s.count('members', widget.memberIds.length + 1)),
          for (final id in widget.memberIds) ListTile(leading: UserAvatar(userId: id, size: 40), title: Text(ref.watch(accountProvider).userName(id))),
        ],
      ),
    );
  }
}

class NewChannelScreen extends ConsumerStatefulWidget {
  const NewChannelScreen({super.key});

  @override
  ConsumerState<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends ConsumerState<NewChannelScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _username = TextEditingController();
  String? _photoPath;
  bool _creating = false;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final account = ref.read(accountProvider);
    final wanted = _username.text.trim();
    if (wanted.isNotEmpty) {
      if (!await ensurePublicChatSlot(context, account) || !mounted) return;
      final problem = await usernameProblem(account, 0, wanted, context.s);
      if (!mounted) return;
      if (problem != null) {
        showToast(context, problem);
        return;
      }
    }
    setState(() => _creating = true);
    final chatId = await guard(context, () async {
      final chat = await account.send<td.Chat>(td.CreateNewSupergroupChat(
        title: title,
        isForum: false,
        isChannel: true,
        description: _description.text.trim(),
        location: null,
        messageAutoDeleteTime: 0,
        forImport: false,
      ));
      if (_photoPath != null) {
        await account.send<td.Ok>(td.SetChatPhoto(
          chatId: chat.id,
          photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: _photoPath!)),
        ));
      }
      final username = _username.text.trim();
      if (username.isNotEmpty && chat.type is td.ChatTypeSupergroup) {
        await account.send<td.Ok>(td.SetSupergroupUsername(
          supergroupId: (chat.type as td.ChatTypeSupergroup).supergroupId,
          username: username,
        ));
      }
      return chat.id;
    });
    if (!mounted) return;
    setState(() => _creating = false);
    if (chatId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      openChat(context, chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('new_channel'))),
      floatingActionButton: FloatingActionButton(
        onPressed: _creating ? null : _create,
        child: _creating
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : const Icon(Icons.check_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _PhotoPicker(path: _photoPath, onPicked: (path) => setState(() => _photoPath = path)),
              const SizedBox(width: 16),
              Expanded(child: TextField(controller: _title, autofocus: true, decoration: InputDecoration(labelText: s.t('channel_name')))),
            ],
          ),
          const SizedBox(height: 16),
          TextField(controller: _description, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: s.t('description'))),
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            decoration: InputDecoration(labelText: s.t('public_link'), prefixText: 't.me/', helperText: s.t('public_link_hint')),
          ),
        ],
      ),
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({required this.path, required this.onPicked});

  final String? path;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () async {
          final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
          if (file != null) onPicked(file.path);
        },
        child: CircleAvatar(
          radius: 34,
          backgroundColor: Theme.of(context).colorScheme.primary,
          backgroundImage: path == null ? null : ResizeImage(FileImage(File(path!)), width: 200),
          child: path == null ? const Icon(Icons.add_a_photo_rounded, color: Colors.white) : null,
        ),
      );
}
