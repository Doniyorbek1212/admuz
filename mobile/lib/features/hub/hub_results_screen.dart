import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../home/home_screen.dart';

/// Opens a Google Maps search (the Maps app when installed).
Future<void> openMapSearch(String query) =>
    launchUrl(Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': query}), mode: LaunchMode.externalApplication);

/// Public Telegram channels and groups for a hub tile, with an optional map search.
class HubResultsScreen extends ConsumerStatefulWidget {
  const HubResultsScreen({super.key, required this.title, required this.query, this.mapQuery});

  final String title;
  final String query;
  final String? mapQuery;

  @override
  ConsumerState<HubResultsScreen> createState() => _HubResultsScreenState();
}

class _HubResultsScreenState extends ConsumerState<HubResultsScreen> {
  late final Future<List<int>> _results = _search();

  Future<List<int>> _search() async {
    try {
      final chats = await ref.read(accountProvider).send<td.Chats>(td.SearchPublicChats(query: widget.query, typeFilter: null));
      return chats.chatIds;
    } on TdException catch (error) {
      debugPrint('hub search failed: $error');
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final mapQuery = widget.mapQuery;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (mapQuery != null)
            IconButton(tooltip: s.t('hub_open_map'), icon: const Icon(Icons.map_outlined), onPressed: () => openMapSearch(mapQuery)),
        ],
      ),
      body: FutureBuilder<List<int>>(
        future: _results,
        builder: (context, snapshot) {
          final ids = snapshot.data;
          if (ids == null) return const Center(child: CircularProgressIndicator());
          final account = ref.read(accountProvider);
          final chats = ids.map((id) => account.chats[id]).whereType<td.Chat>().toList();
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            children: [
              if (mapQuery != null)
                SettingsGroup(children: [
                  ListTile(
                    leading: const TileIcon(Icons.location_on_rounded, Color(0xFF2EC27E)),
                    title: Text(s.t('hub_open_map')),
                    subtitle: Text(mapQuery),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                    onTap: () => openMapSearch(mapQuery),
                  ),
                ]),
              if (chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(s.t('hub_no_results'), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
                )
              else
                SettingsGroup(title: s.t('hub_channels'), children: [
                  for (final chat in chats)
                    ListTile(
                      leading: ChatAvatar(chatId: chat.id, size: 46),
                      title: Text(chatTitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(chatSubtitle(chat, account, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => openChat(context, chat.id),
                    ),
                ]),
            ],
          );
        },
      ),
    );
  }
}
