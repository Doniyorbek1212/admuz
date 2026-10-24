import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/contact_changes.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../contacts/contacts_screen.dart';
import '../home/home_screen.dart';
import '../profile/chat_info_screen.dart';

Future<void> _openUserChat(BuildContext context, WidgetRef ref, int userId) async {
  final chat = await guard(context, () => ref.read(accountProvider).openPrivateChat(userId));
  if (chat != null && context.mounted) openChat(context, chat.id);
}

/// Contacts who are online right now (aka "Onlayn kontaktlar").
class OnlineContactsScreen extends ConsumerWidget {
  const OnlineContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    // GetContacts makes TDLib push every contact with its current status.
    final contacts = ref.watch(contactsProvider);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('online_contacts'))),
      body: contacts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(errorText(context, error))),
        data: (ids) => ValueListenableBuilder(
          valueListenable: account.usersRevision,
          builder: (context, _, _) {
            final online = [
              for (final id in ids)
                if (account.users[id] case final user? when isOnline(user)) user,
            ]..sort((a, b) => account.userName(a.id).toLowerCase().compareTo(account.userName(b.id).toLowerCase()));
            if (online.isEmpty) return EmptyState(icon: Icons.wifi_tethering_off_rounded, title: s.t('online_contacts_empty'));
            return ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                SettingsGroup(children: [
                  for (final user in online)
                    ListTile(
                      leading: UserAvatar(userId: user.id, size: 46),
                      title: Text(account.userName(user.id), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(s.t('online'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                      onTap: () => _openUserChat(context, ref, user.id),
                    ),
                ]),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Log of contacts' profile changes (aka "Kontaktlar o'zgarishlari").
class ContactChangesScreen extends ConsumerWidget {
  const ContactChangesScreen({super.key});

  static String _describe(ContactChange change, Strings s) => switch (change.kind) {
        ContactChangeKind.photoAdded => s.t('cc_photo_added'),
        ContactChangeKind.photoChanged => s.t('cc_photo_changed'),
        ContactChangeKind.photoRemoved => s.t('cc_photo_removed'),
        ContactChangeKind.phoneChanged => s.t('cc_phone_changed', {'old': '+${change.before}'}),
        ContactChangeKind.phoneHidden => s.t('cc_phone_hidden'),
        ContactChangeKind.nameChanged => s.t('cc_name_changed', {'old': change.before}),
        ContactChangeKind.usernameChanged =>
          change.before.isEmpty ? s.t('cc_username_set') : s.t('cc_username_changed', {'old': '@${change.before}'}),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final log = ref.watch(accountProvider).contactChanges;
    final account = ref.watch(accountProvider);
    return ValueListenableBuilder(
      valueListenable: log.revision,
      builder: (context, _, _) {
        final changes = log.changes;
        return Scaffold(
          backgroundColor: groupedBackground(context),
          appBar: AppBar(
            title: Text(s.t('contact_changes')),
            actions: [
              if (changes.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: s.t('clear_log'),
                  onPressed: () async {
                    if (await confirm(context, title: s.t('contact_changes'), message: s.t('contact_changes_clear'), destructive: true)) log.clear();
                  },
                ),
            ],
          ),
          body: changes.isEmpty
              ? EmptyState(icon: Icons.manage_accounts_rounded, title: s.t('contact_changes_empty'), subtitle: s.t('contact_changes_hint'))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    SettingsGroup(children: [
                      for (final change in changes)
                        ListTile(
                          leading: UserAvatar(userId: change.userId, size: 46),
                          title: Text(account.userName(change.userId), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_describe(change, s), maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(formatChatTime(change.date, s.locale), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5)),
                          onTap: () => _openUserChat(context, ref, change.userId),
                        ),
                    ]),
                    GroupHint(s.t('contact_changes_hint')),
                  ],
                ),
        );
      },
    );
  }
}

/// Finds a user, group or channel by numeric ID or @username (aka "Id Qidiruvchisi").
class IdFinderScreen extends ConsumerStatefulWidget {
  const IdFinderScreen({super.key});

  @override
  ConsumerState<IdFinderScreen> createState() => _IdFinderScreenState();
}

class _IdFinderScreenState extends ConsumerState<IdFinderScreen> {
  final _input = TextEditingController();
  td.Chat? _chat;
  td.User? _user;
  bool _busy = false;
  bool _notFound = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _input.text.trim().replaceFirst(RegExp(r'^(https?://)?(t\.me/|@)'), '');
    if (query.isEmpty) return;
    setState(() {
      _busy = true;
      _notFound = false;
      _chat = null;
      _user = null;
    });
    final account = ref.read(accountProvider);
    td.Chat? chat;
    td.User? user;
    final id = int.tryParse(query);
    try {
      if (id == null) {
        chat = await account.send<td.Chat>(td.SearchPublicChat(username: query));
        if (chat.type case td.ChatTypePrivate(:final userId)) user = await account.getUser(userId);
      } else if (id > 0) {
        // Telegram only resolves IDs of users this account has met (contacts, shared chats, messages).
        user = await account.getUser(id);
        chat = await account.openPrivateChat(id);
      } else {
        chat = await account.send<td.Chat>(td.GetChat(chatId: id));
      }
    } on TdException {
      // Not found or not accessible; reported below.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _chat = chat;
      _user = user;
      _notFound = chat == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final chat = _chat;
    final user = _user;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('id_finder'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          SettingsGroup(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
              child: TextField(
                controller: _input,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: s.t('id_finder_label'),
                  hintText: s.t('id_finder_hint'),
                  suffixIcon: _busy
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(icon: const Icon(Icons.search_rounded), onPressed: _search),
                ),
              ),
            ),
          ]),
          GroupHint(s.t('id_finder_note')),
          if (_notFound) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s.t('nothing_found'), style: TextStyle(color: hint)))),
          if (chat != null)
            SettingsGroup(children: [
              ListTile(
                leading: ChatAvatar(chatId: chat.id, size: 54),
                title: Text(chat.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  if (user?.usernames?.activeUsernames.firstOrNull case final name?) '@$name',
                  if (user != null) formatUserStatus(user, s),
                ].join(' · ')),
              ),
              ListTile(
                leading: const Icon(Icons.tag_rounded),
                title: Text('${user?.id ?? chat.id}'),
                subtitle: Text(s.t('id_label')),
                trailing: const Icon(Icons.copy_rounded, size: 20),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: '${user?.id ?? chat.id}'));
                  showToast(context, s.t('copied'));
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat_rounded),
                title: Text(s.t('open_chat')),
                onTap: () => openChat(context, chat.id),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(s.t('tab_profile')),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: chat.id))),
              ),
            ]),
        ],
      ),
    );
  }
}
