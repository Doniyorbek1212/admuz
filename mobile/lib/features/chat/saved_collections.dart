import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// A user-made group of Saved Messages ("Learning", "Work"…) with an emoji icon.
@immutable
class SavedCollection {
  const SavedCollection({
    required this.id,
    required this.name,
    required this.icon,
    this.messageIds = const [],
  });

  final String id;
  final String name;
  final String icon;

  /// Newest first.
  final List<int> messageIds;

  SavedCollection copyWith({
    String? name,
    String? icon,
    List<int>? messageIds,
  }) => SavedCollection(
    id: id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    messageIds: messageIds ?? this.messageIds,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'ids': messageIds,
  };

  static SavedCollection? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'],
        name = json['name'],
        icon = json['icon'],
        ids = json['ids'];
    if (id is! String || name is! String || icon is! String) return null;
    return SavedCollection(
      id: id,
      name: name,
      icon: icon,
      messageIds: [if (ids is List) ...ids.whereType<int>()],
    );
  }
}

/// Icons offered for a new collection.
const collectionIcons = [
  '🧠',
  '💼',
  '🛍',
  '💎',
  '🍔',
  '💪',
  '🎧',
  '📍',
  '💸',
  '🌐',
  '🎮',
  '🎬',
  '📚',
  '✈️',
  '🏠',
  '❤️',
  '⭐',
  '📝',
];

/// The user's Saved Messages collections, kept on this device (per account) in shared preferences.
// shortcut: device-local only, not synced to other devices; move to Telegram saved-message tags if they become free.
final savedCollectionsProvider =
    NotifierProvider<SavedCollectionsNotifier, List<SavedCollection>>(
      SavedCollectionsNotifier.new,
    );

class SavedCollectionsNotifier extends Notifier<List<SavedCollection>> {
  String get _key => 'saved.collections.${ref.read(accountProvider).myId}';

  @override
  List<SavedCollection> build() {
    ref.watch(accountProvider);
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      return [
        if (list is List)
          for (final item in list) ?SavedCollection.fromJson(item),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> _save(List<SavedCollection> next) async {
    state = List.unmodifiable(next);
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, jsonEncode([for (final c in next) c.toJson()]));
  }

  Future<SavedCollection> create(String name, String icon) async {
    final collection = SavedCollection(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: name,
      icon: icon,
    );
    await _save([...state, collection]);
    return collection;
  }

  Future<void> delete(String id) => _save([
    for (final c in state)
      if (c.id != id) c,
  ]);

  /// Puts [messageIds] in exactly the collections in [ids] (adds where missing, removes elsewhere).
  Future<void> assign(List<int> messageIds, Set<String> ids) => _save([
    for (final c in state)
      ids.contains(c.id)
          ? c.copyWith(
              messageIds: [
                ...messageIds.where((m) => !c.messageIds.contains(m)),
                ...c.messageIds,
              ],
            )
          : c.copyWith(
              messageIds: [
                for (final m in c.messageIds)
                  if (!messageIds.contains(m)) m,
              ],
            ),
  ]);

  /// Drops ids of messages that no longer exist in Saved Messages.
  Future<void> forget(String id, Iterable<int> gone) => _save([
    for (final c in state)
      c.id == id
          ? c.copyWith(
              messageIds: [
                for (final m in c.messageIds)
                  if (!gone.contains(m)) m,
              ],
            )
          : c,
  ]);
}

/// Name and icon for a new collection; null when cancelled.
Future<(String, String)?> promptNewCollection(BuildContext context) async {
  final s = context.s;
  final name = TextEditingController();
  var icon = collectionIcons.first;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(s.t('collection_new')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                maxLength: 32,
                decoration: InputDecoration(
                  labelText: s.t('collection_name'),
                  prefixText: '$icon  ',
                ),
              ),
              Text(
                s.t('collection_icon'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 2,
                children: [
                  for (final e in collectionIcons)
                    ChoiceChip(
                      label: Text(e, style: const TextStyle(fontSize: 18)),
                      selected: e == icon,
                      showCheckmark: false,
                      onSelected: (_) => setDialogState(() => icon = e),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('done')),
          ),
        ],
      ),
    ),
  );
  // Not disposed: the dialog's TextField still uses it while the dialog animates out.
  final text = name.text.trim();
  return ok == true && text.isNotEmpty ? (text, icon) : null;
}

/// "Add to collection" for Saved Messages: tick the collections [messageIds] belong in, or make a new one.
Future<void> pickCollections(
  BuildContext context,
  WidgetRef ref,
  List<int> messageIds,
) async {
  final s = context.s;
  final notifier = ref.read(savedCollectionsProvider.notifier);
  final chosen = {
    for (final c in ref.read(savedCollectionsProvider))
      if (messageIds.every(c.messageIds.contains)) c.id,
  };
  final result = await showModalBottomSheet<Set<String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final collections = ref.watch(savedCollectionsProvider);
        return StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.t('collection_add'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final c in collections)
                        CheckboxListTile(
                          value: chosen.contains(c.id),
                          secondary: Text(
                            c.icon,
                            style: const TextStyle(fontSize: 24),
                          ),
                          title: Text(c.name),
                          subtitle: Text(
                            s.count('messages', c.messageIds.length),
                          ),
                          onChanged: (on) => setSheetState(
                            () => on == true
                                ? chosen.add(c.id)
                                : chosen.remove(c.id),
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.add_rounded),
                        title: Text(s.t('collection_new')),
                        onTap: () async {
                          final created = await promptNewCollection(context);
                          if (created == null) return;
                          final c = await notifier.create(
                            created.$1,
                            created.$2,
                          );
                          setSheetState(() => chosen.add(c.id));
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, chosen),
                    child: Text(s.t('done')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (result == null) return;
  await notifier.assign(messageIds, result);
}

/// Saved Messages collections; pops the id of a message to show in the chat.
class SavedCollectionsScreen extends ConsumerWidget {
  const SavedCollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final collections = ref.watch(savedCollectionsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('collections'))),
      floatingActionButton: FloatingActionButton(
        tooltip: s.t('collection_new'),
        onPressed: () async {
          final created = await promptNewCollection(context);
          if (created != null) {
            await ref
                .read(savedCollectionsProvider.notifier)
                .create(created.$1, created.$2);
          }
        },
        child: const Icon(Icons.create_new_folder_rounded),
      ),
      body: ListView(
        children: [
          for (final c in collections)
            ListTile(
              leading: CircleAvatar(
                child: Text(c.icon, style: const TextStyle(fontSize: 20)),
              ),
              title: Text(c.name),
              subtitle: Text(
                c.messageIds.isEmpty
                    ? s.t('collection_empty')
                    : s.count('messages', c.messageIds.length),
              ),
              onTap: () async {
                final id = await Navigator.of(context).push<int>(
                  MaterialPageRoute(
                    builder: (_) => _CollectionScreen(collectionId: c.id),
                  ),
                );
                if (id != null && context.mounted) Navigator.pop(context, id);
              },
              onLongPress: () async {
                final ok = await confirm(
                  context,
                  title: s.t('collection_delete'),
                  message: '${c.icon} ${c.name}',
                  destructive: true,
                );
                if (ok) {
                  await ref
                      .read(savedCollectionsProvider.notifier)
                      .delete(c.id);
                }
              },
            ),
        ],
      ),
    );
  }
}

class _CollectionScreen extends ConsumerStatefulWidget {
  const _CollectionScreen({required this.collectionId});

  final String collectionId;

  @override
  ConsumerState<_CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<_CollectionScreen> {
  List<td.Message>? _messages;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    final collection = ref
        .read(savedCollectionsProvider)
        .where((c) => c.id == widget.collectionId)
        .firstOrNull;
    if (collection == null) return;
    final found = await guard(
      context,
      () => account.send<td.Messages>(
        td.GetMessages(chatId: account.myId, messageIds: collection.messageIds),
      ),
    );
    if (!mounted || found == null) return;
    final messages = [
      for (final m in found.messages ?? const <td.Message?>[]) ?m,
    ];
    final gone = collection.messageIds.toSet().difference({
      for (final m in messages) m.id,
    });
    if (gone.isNotEmpty) {
      await ref
          .read(savedCollectionsProvider.notifier)
          .forget(collection.id, gone);
    }
    if (mounted) setState(() => _messages = messages);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final collection = ref
        .watch(savedCollectionsProvider)
        .where((c) => c.id == widget.collectionId)
        .firstOrNull;
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          collection == null ? '' : '${collection.icon} ${collection.name}',
        ),
      ),
      body: messages == null
          ? const Center(child: CircularProgressIndicator())
          : messages.isEmpty
          ? Center(child: Text(s.t('collection_empty')))
          : ListView.separated(
              itemCount: messages.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) {
                final message = messages[index];
                return ListTile(
                  title: Text(
                    messagePreview(message, account, s),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    formatChatTime(message.date, s.locale),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, message.id),
                  onLongPress: () async {
                    await ref
                        .read(savedCollectionsProvider.notifier)
                        .assign(
                          [message.id],
                          {
                            for (final c in ref.read(savedCollectionsProvider))
                              if (c.id != widget.collectionId &&
                                  c.messageIds.contains(message.id))
                                c.id,
                          },
                        );
                    if (mounted) {
                      setState(
                        () => _messages = [...messages]..removeAt(index),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}
