import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
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
                        onPressed: () async {
                          final ok = await confirm(context, title: s.t('delete_folder'), message: folder.name.text.text, destructive: true);
                          if (ok && context.mounted) {
                            await guard(context, () => account.send<td.Ok>(td.DeleteChatFolder(chatFolderId: folder.id, leaveChatIds: const [])));
                          }
                        },
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
