import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../settings/folders_screen.dart' show folderIconData;

/// [tabs] (key, title) in the user's [order]; tabs the order does not know yet (a new folder, type tabs just
/// turned on) keep their default place after the ordered ones.
List<(String, String)> orderTabs(List<(String, String)> tabs, List<String> order) => [
      for (final key in order) ...tabs.where((tab) => tab.$1 == key),
      ...tabs.where((tab) => !order.contains(tab.$1)),
    ];

/// The chat list tabs as the home screen shows them. Default order: personal chats first, then all chats, the
/// other chat types and the Telegram folders; the user's own order (Tab order screen) replaces it.
List<(String, String)> homeTabs(WidgetRef ref, Strings s) {
  final settings = ref.watch(settingsProvider.select((st) => (st.chatTypeTabs, st.chatTabOrder)));
  final folders = ref.watch(foldersProvider);
  final tabs = [
    ('main', s.t('all_chats')),
    if (settings.$1)
      for (final type in chatTypeTabs) (type, s.t('tab_${type.substring(5)}')),
    for (final folder in folders) ('folder:${folder.id}', folder.name.text.text),
  ];
  // The personal-chats tab leads: the type tab, else a Telegram folder with Telegram's "Private" icon.
  final personal = settings.$1 ? 'type:private' : folders.where((f) => f.icon.name == 'Private').map((f) => 'folder:${f.id}').firstOrNull;
  return orderTabs(tabs, settings.$2.isEmpty && personal != null ? [personal] : settings.$2);
}

/// Drag the chat list tabs into any order; the first one opens when the app starts.
class TabOrderScreen extends ConsumerWidget {
  const TabOrderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final tabs = homeTabs(ref, s);
    final notifier = ref.read(settingsProvider.notifier);
    final folderIcons = {for (final f in ref.watch(foldersProvider)) 'folder:${f.id}': f.icon.name};
    // A folder shows its Telegram icon; Telegram's default "Custom" one stays a plain folder.
    IconData iconOf(String key) => switch (folderIcons[key]) {
          final name? when name.isNotEmpty && name != 'Custom' => folderIconData(name),
          _ => key.startsWith('folder:') ? Icons.folder_rounded : folderIconData(key),
        };
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('tab_order')),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt_rounded),
            tooltip: s.t('tab_order_reset'),
            onPressed: () => notifier.setChatTabOrder(const []),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(s.t('tab_order_hint'), style: TextStyle(color: Theme.of(context).hintColor)),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: tabs.length,
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                final keys = [for (final tab in tabs) tab.$1];
                keys.insert(to, keys.removeAt(from));
                notifier.setChatTabOrder(keys);
              },
              itemBuilder: (context, i) => ListTile(
                key: ValueKey(tabs[i].$1),
                leading: Icon(iconOf(tabs[i].$1)),
                title: Text(tabs[i].$2),
                trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle_rounded)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
