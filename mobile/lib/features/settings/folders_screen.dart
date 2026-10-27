import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

final _recommendedProvider = FutureProvider.autoDispose<List<td.RecommendedChatFolder>>((ref) async {
  final account = ref.watch(accountProvider);
  return (await account.send<td.RecommendedChatFolders>(const td.GetRecommendedChatFolders())).chatFolders;
});

/// Chat folders (Plus Messenger style tabs) synced with Telegram's own folders.
class FoldersScreen extends ConsumerWidget {
  const FoldersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final recommended = ref.watch(_recommendedProvider).value ?? const [];
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('chat_folders'))),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FolderEditScreen())),
        child: const Icon(Icons.add_rounded),
      ),
      body: ListView(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(s.t('folders_hint'), style: TextStyle(color: Theme.of(context).hintColor))),
          if (folders.isNotEmpty) SectionHeader(s.t('my_folders')),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: (oldIndex, newIndex) {
              final ids = folders.map((f) => f.id).toList();
              final id = ids.removeAt(oldIndex);
              ids.insert(newIndex, id);
              guard(context, () => account.send<td.Ok>(td.ReorderChatFolders(chatFolderIds: ids, mainChatListPosition: 0)));
            },
            children: [
              for (final folder in folders)
                ListTile(
                  key: ValueKey(folder.id),
                  leading: const Icon(Icons.folder_rounded),
                  title: Text(folder.name.text.text),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: s.t('folder_share'),
                        icon: const Icon(Icons.ios_share_rounded),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => _FolderLinksScreen(folderId: folder.id, name: folder.name.text.text)),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => deleteChatFolder(context, account, folder.id, folder.name.text.text),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FolderEditScreen(folderId: folder.id))),
                ),
            ],
          ),
          if (recommended.isNotEmpty) ...[
            SectionHeader(s.t('recommended_folders')),
            for (final item in recommended)
              ListTile(
                title: Text(item.folder.name.text.text),
                subtitle: Text(item.description),
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    await guard(context, () => account.send<td.ChatFolderInfo>(td.CreateChatFolder(folder: item.folder)));
                    ref.invalidate(_recommendedProvider);
                  },
                  child: Text(s.t('add')),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Deletes a folder; for a shared (added by link) folder also offers to leave its chats.
Future<void> deleteChatFolder(BuildContext context, TelegramAccount account, int folderId, String name) async {
  final s = context.s;
  var leave = const <int>[];
  try {
    leave = (await account.send<td.Chats>(td.GetChatFolderChatsToLeave(chatFolderId: folderId))).chatIds;
  } on TdException {
    // Not a shared folder.
  }
  if (!context.mounted) return;
  var leaveChats = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(s.t('delete_folder')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name),
          if (leave.isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: leaveChats,
              title: Text(s.t('folder_leave_chats', {'n': '${leave.length}'})),
              onChanged: (v) => setState(() => leaveChats = v ?? false),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('delete')),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await guard(context, () => account.send<td.Ok>(td.DeleteChatFolder(chatFolderId: folderId, leaveChatIds: leaveChats ? leave : const [])));
}

/// Long-press menu of a chat list tab: mark everything read; edit or delete a folder.
Future<void> showFolderMenu(BuildContext context, TelegramAccount account, String listKey, String title) async {
  if (listKey != 'main' && !listKey.startsWith('folder:')) return;
  final s = context.s;
  final list = chatListFromKey(listKey);
  final folderId = list is td.ChatListFolder ? list.chatFolderId : null;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.mark_chat_read_rounded), title: Text(s.t('mark_all_read')), onTap: () => Navigator.pop(context, 'read')),
        ListTile(leading: const Icon(Icons.push_pin_outlined), title: Text(s.t('pinned_reorder')), onTap: () => Navigator.pop(context, 'pinned')),
        if (folderId != null) ...[
          ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('edit_folder')), onTap: () => Navigator.pop(context, 'edit')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete_folder'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ]),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'read':
      await guard(context, () => account.send<td.Ok>(td.ReadChatList(chatList: list)));
    case 'pinned':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PinnedOrderScreen(listKey: listKey)));
    case 'edit':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FolderEditScreen(folderId: folderId)));
    case 'delete':
      await deleteChatFolder(context, account, folderId!, title);
  }
}

/// Drag to reorder the pinned chats of one chat list.
class PinnedOrderScreen extends ConsumerStatefulWidget {
  const PinnedOrderScreen({super.key, required this.listKey});

  final String listKey;

  @override
  ConsumerState<PinnedOrderScreen> createState() => _PinnedOrderScreenState();
}

class _PinnedOrderScreenState extends ConsumerState<PinnedOrderScreen> {
  late List<int> _ids;

  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider);
    final list = chatListFromKey(widget.listKey);
    _ids = [for (final chat in ref.read(chatListProvider(widget.listKey))) if (account.positionIn(chat, list)?.isPinned ?? false) chat.id];
  }

  Future<void> _reorder(int from, int to) async {
    setState(() => _ids.insert(to, _ids.removeAt(from)));
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetPinnedChats(chatList: chatListFromKey(widget.listKey), chatIds: _ids)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('pinned_reorder'))),
      body: _ids.isEmpty
          ? Center(child: Text(s.t('nothing_here')))
          : ReorderableListView(
              onReorderItem: _reorder,
              children: [
                for (final id in _ids)
                  ListTile(
                    key: ValueKey(id),
                    leading: ChatAvatar(chatId: id, size: 40, showOnline: false),
                    title: Text(account.chats[id] == null ? '$id' : chatTitle(account.chats[id]!, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.drag_handle_rounded),
                  ),
              ],
            ),
    );
  }
}

/// Adds a chat to one of the folders Telegram says it can go to.
Future<void> addChatToFolder(BuildContext context, TelegramAccount account, td.Chat chat) async {
  final lists = await guard(context, () => account.send<td.ChatLists>(td.GetChatListsToAddChat(chatId: chat.id)));
  if (lists == null || !context.mounted) return;
  final names = {for (final f in account.folders) f.id: f.name.text.text};
  final folderIds = [for (final l in lists.chatLists) if (l case td.ChatListFolder(:final chatFolderId)) chatFolderId];
  if (folderIds.isEmpty) {
    showToast(context, context.t('folder_none_available'));
    return;
  }
  final picked = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final id in folderIds)
          ListTile(leading: const Icon(Icons.folder_rounded), title: Text(names[id] ?? '$id'), onTap: () => Navigator.pop(context, id)),
      ]),
    ),
  );
  if (picked == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.AddChatToList(chatId: chat.id, chatList: td.ChatListFolder(chatFolderId: picked)));
    return true;
  });
  if (done == true && context.mounted) showToast(context, context.t('folder_chat_added', {'name': names[picked] ?? ''}));
}

/// Shareable t.me/addlist links of one folder: create, copy/share, delete.
class _FolderLinksScreen extends ConsumerStatefulWidget {
  const _FolderLinksScreen({required this.folderId, required this.name});

  final int folderId;
  final String name;

  @override
  ConsumerState<_FolderLinksScreen> createState() => _FolderLinksScreenState();
}

class _FolderLinksScreenState extends ConsumerState<_FolderLinksScreen> {
  List<td.ChatFolderInviteLink>? _links;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(context, () => ref.read(accountProvider).send<td.ChatFolderInviteLinks>(td.GetChatFolderInviteLinks(chatFolderId: widget.folderId)));
    if (mounted) setState(() => _links = result?.inviteLinks ?? const []);
  }

  Future<void> _create() async {
    final account = ref.read(accountProvider);
    // Telegram decides which folder chats can be shared (groups and channels the user may invite to).
    final chats = await guard(context, () => account.send<td.Chats>(td.GetChatsForChatFolderInviteLink(chatFolderId: widget.folderId)));
    if (chats == null || !mounted) return;
    if (chats.chatIds.isEmpty) {
      showToast(context, context.t('folder_share_empty'));
      return;
    }
    await guard(context, () => account.send<td.ChatFolderInviteLink>(td.CreateChatFolderInviteLink(chatFolderId: widget.folderId, name: '', chatIds: chats.chatIds)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final links = _links;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_link_rounded), label: Text(s.t('folder_link_create'))),
      body: links == null
          ? const Center(child: CircularProgressIndicator())
          : links.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t('folder_share_hint'), textAlign: TextAlign.center)))
              : ListView(
                  children: [
                    for (final link in links)
                      ListTile(
                        leading: const Icon(Icons.link_rounded),
                        title: Text(link.name.isNotEmpty ? link.name : link.inviteLink, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s.count('chats', link.chatIds.length)),
                        onTap: () => SharePlus.instance.share(ShareParams(text: link.inviteLink)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () async {
                            final ok = await confirm(context, title: s.t('folder_link_delete'), destructive: true);
                            if (!ok || !context.mounted) return;
                            await guard(
                              context,
                              () => ref.read(accountProvider).send<td.Ok>(td.DeleteChatFolderInviteLink(chatFolderId: widget.folderId, inviteLink: link.inviteLink)),
                            );
                            await _load();
                          },
                        ),
                      ),
                  ],
                ),
    );
  }
}

class FolderEditScreen extends ConsumerStatefulWidget {
  const FolderEditScreen({super.key, this.folderId});

  final int? folderId;

  @override
  ConsumerState<FolderEditScreen> createState() => _FolderEditScreenState();
}

class _FolderEditScreenState extends ConsumerState<FolderEditScreen> {
  final _name = TextEditingController();
  td.ChatFolder? _original;
  final Set<String> _types = {};
  final Set<int> _included = {};
  bool _excludeMuted = false;
  bool _excludeRead = false;
  bool _excludeArchived = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.folderId != null) {
      _loading = true;
      ref.read(accountProvider).send<td.ChatFolder>(td.GetChatFolder(chatFolderId: widget.folderId!)).then((folder) {
        if (!mounted) return;
        setState(() {
          _original = folder;
          _loading = false;
          _name.text = folder.name.text.text;
          if (folder.includeContacts) _types.add('contacts');
          if (folder.includeNonContacts) _types.add('non_contacts');
          if (folder.includeGroups) _types.add('groups');
          if (folder.includeChannels) _types.add('channels');
          if (folder.includeBots) _types.add('bots');
          _included.addAll(folder.includedChatIds);
          _excludeMuted = folder.excludeMuted;
          _excludeRead = folder.excludeRead;
          _excludeArchived = folder.excludeArchived;
        });
      }, onError: (Object error) {
        if (mounted) {
          setState(() => _loading = false);
          showError(context, error);
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.s;
    final name = _name.text.trim();
    if (name.isEmpty || (_types.isEmpty && _included.isEmpty)) {
      showToast(context, s.t('folder_invalid'));
      return;
    }
    final folder = td.ChatFolder(
      name: td.ChatFolderName(text: plainText(name), animateCustomEmoji: false),
      icon: _original?.icon,
      colorId: _original?.colorId ?? -1,
      isShareable: _original?.isShareable ?? false,
      pinnedChatIds: _original?.pinnedChatIds ?? const [],
      includedChatIds: _included.toList(),
      excludedChatIds: _original?.excludedChatIds ?? const [],
      excludeMuted: _excludeMuted,
      excludeRead: _excludeRead,
      excludeArchived: _excludeArchived,
      includeContacts: _types.contains('contacts'),
      includeNonContacts: _types.contains('non_contacts'),
      includeBots: _types.contains('bots'),
      includeGroups: _types.contains('groups'),
      includeChannels: _types.contains('channels'),
    );
    final account = ref.read(accountProvider);
    final ok = await guard(context, () => widget.folderId == null
        ? account.send<td.ChatFolderInfo>(td.CreateChatFolder(folder: folder))
        : account.send<td.ChatFolderInfo>(td.EditChatFolder(chatFolderId: widget.folderId!, folder: folder)));
    if (ok != null && mounted) Navigator.pop(context);
  }

  Future<void> _addChats() async {
    final account = ref.read(accountProvider);
    final chats = account.chatList(const td.ChatListMain());
    final s = context.s;
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final selection = {..._included};
        return StatefulBuilder(
          builder: (context, setSheetState) => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.75,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      for (final chat in chats)
                        CheckboxListTile(
                          value: selection.contains(chat.id),
                          onChanged: (v) => setSheetState(() => v == true ? selection.add(chat.id) : selection.remove(chat.id)),
                          secondary: ChatAvatar(chatId: chat.id, size: 40),
                          title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(onPressed: () => Navigator.pop(context, selection), child: Text(s.t('done'))),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _included
          ..clear()
          ..addAll(picked);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t(widget.folderId == null ? 'new_folder' : 'edit_folder')),
        actions: [IconButton(icon: const Icon(Icons.check_rounded), onPressed: _loading ? null : _save)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(controller: _name, maxLength: 12, decoration: InputDecoration(labelText: s.t('folder_name'))),
                ),
                SectionHeader(s.t('included_chats')),
                for (final type in const ['contacts', 'non_contacts', 'groups', 'channels', 'bots'])
                  CheckboxListTile(
                    value: _types.contains(type),
                    title: Text(s.t('folder_type_$type')),
                    onChanged: (v) => setState(() => v == true ? _types.add(type) : _types.remove(type)),
                  ),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: Text(s.t('add_chats')),
                  subtitle: _included.isEmpty ? null : Text(s.count('chats', _included.length)),
                  onTap: _addChats,
                ),
                for (final id in _included)
                  if (account.chats[id] case final chat?)
                    ListTile(
                      leading: ChatAvatar(chatId: id, size: 36),
                      title: Text(chatTitle(chat, account, s)),
                      trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _included.remove(id))),
                    ),
                SectionHeader(s.t('excluded_chats')),
                SwitchListTile(title: Text(s.t('exclude_muted')), value: _excludeMuted, onChanged: (v) => setState(() => _excludeMuted = v)),
                SwitchListTile(title: Text(s.t('exclude_read')), value: _excludeRead, onChanged: (v) => setState(() => _excludeRead = v)),
                SwitchListTile(
                  title: Text(s.t('exclude_archived')),
                  value: _excludeArchived,
                  onChanged: (v) => setState(() => _excludeArchived = v),
                ),
              ],
            ),
    );
  }
}
