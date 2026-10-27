import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'composer_panels.dart';
import 'sticker_creator.dart';

/// Preview of a whole sticker set with Add/Remove, opened from a sticker in chat or a set list.
Future<void> showStickerSetSheet(BuildContext context, int setId) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _StickerSetSheet(setId: setId),
    );

class _StickerSetSheet extends ConsumerStatefulWidget {
  const _StickerSetSheet({required this.setId});

  final int setId;

  @override
  ConsumerState<_StickerSetSheet> createState() => _StickerSetSheetState();
}

class _StickerSetSheetState extends ConsumerState<_StickerSetSheet> {
  td.StickerSet? _set;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final set = await guard(context, () => ref.read(accountProvider).stickerSet(widget.setId));
    if (mounted) setState(() => _set = set);
  }

  Future<void> _toggleInstalled(td.StickerSet set) async {
    setState(() => _busy = true);
    final installed = !set.isInstalled || set.isArchived;
    await guard(context, () => ref.read(accountProvider).setStickerSetState(set.id, installed: installed));
    if (!mounted) return;
    showToast(context, context.t(installed ? 'sticker_set_added' : 'sticker_set_removed'));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final set = _set;
    final height = MediaQuery.sizeOf(context).height * 0.7;
    if (set == null) return SizedBox(height: 200, child: const Center(child: CircularProgressIndicator()));
    final installed = set.isInstalled && !set.isArchived;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          ListTile(
            title: Text(set.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(s.count('stickers_count', set.stickers.length)),
            trailing: IconButton(
              tooltip: s.t('share'),
              icon: const Icon(Icons.share_rounded),
              onPressed: () => SharePlus.instance.share(ShareParams(text: 'https://t.me/addstickers/${set.name}')),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 80, mainAxisSpacing: 6, crossAxisSpacing: 6),
              itemCount: set.stickers.length,
              itemBuilder: (context, index) => StickerThumb(sticker: set.stickers[index]),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: installed
                    ? OutlinedButton(onPressed: _busy ? null : () => _toggleInstalled(set), child: Text(s.t('sticker_set_remove')))
                    : FilledButton(onPressed: _busy ? null : () => _toggleInstalled(set), child: Text(s.count('sticker_set_add', set.stickers.length))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Installed (reorderable), archived and trending sticker sets, plus search.
class StickerSetsScreen extends ConsumerStatefulWidget {
  const StickerSetsScreen({super.key});

  @override
  ConsumerState<StickerSetsScreen> createState() => _StickerSetsScreenState();
}

class _StickerSetsScreenState extends ConsumerState<StickerSetsScreen> {
  List<td.StickerSetInfo>? _installed;
  List<td.StickerSetInfo>? _archived;
  List<td.StickerSetInfo>? _trending;
  List<td.StickerSetInfo>? _found;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final account = ref.read(accountProvider);
    final installed = await guard(context, account.installedStickerSets);
    final archived = mounted ? await guard(context, account.archivedStickerSets) : null;
    final trending = mounted ? await guard(context, account.trendingStickerSets) : null;
    if (!mounted) return;
    setState(() {
      _installed = installed ?? const [];
      _archived = archived ?? const [];
      _trending = trending ?? const [];
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _found = null);
      return;
    }
    final found = await guard(context, () => ref.read(accountProvider).searchStickerSets(query.trim()));
    if (mounted) setState(() => _found = found);
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = [...?_installed];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _installed = list);
    await guard(context, () => ref.read(accountProvider).reorderStickerSets([for (final set in list) set.id]));
  }

  Future<void> _setState(td.StickerSetInfo set, {required bool installed, bool archived = false}) async {
    await guard(context, () => ref.read(accountProvider).setStickerSetState(set.id, installed: installed, archived: archived));
    await _reload();
  }

  Widget _setTile(td.StickerSetInfo set, {Widget? trailing, Key? key}) => ListTile(
        key: key,
        leading: SizedBox.square(dimension: 44, child: set.covers.isEmpty ? const Icon(Icons.emoji_emotions_outlined) : StickerThumb(sticker: set.covers.first)),
        title: Text(set.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(context.s.count('stickers_count', set.size)),
        trailing: trailing,
        onTap: () async {
          await showStickerSetSheet(context, set.id);
          await _reload();
        },
      );

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final installed = _installed;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.t('stickers')),
          actions: [
            IconButton(
              tooltip: s.t('sticker_packs_mine'),
              icon: const Icon(Icons.brush_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MyStickerPacksScreen())),
            ),
          ],
          bottom: TabBar(tabs: [Tab(text: s.t('sticker_sets_mine')), Tab(text: s.t('sticker_sets_trending')), Tab(text: s.t('sticker_sets_archived'))]),
        ),
        body: installed == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  installed.isEmpty
                      ? Center(child: Text(s.t('nothing_here')))
                      : ReorderableListView(
                          onReorderItem: _reorder,
                          children: [
                            for (final set in installed)
                              _setTile(
                                set,
                                key: ValueKey(set.id),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (action) => _setState(set, installed: action == 'archive', archived: action == 'archive'),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(value: 'archive', child: Text(s.t('archive'))),
                                    PopupMenuItem(value: 'remove', child: Text(s.t('sticker_set_remove'))),
                                  ],
                                ),
                              ),
                          ],
                        ),
                  ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: s.t('sticker_sets_search')),
                          onSubmitted: _search,
                        ),
                      ),
                      for (final set in _found ?? _trending ?? const <td.StickerSetInfo>[])
                        _setTile(
                          set,
                          trailing: set.isInstalled && !set.isArchived
                              ? const Icon(Icons.check_rounded)
                              : TextButton(onPressed: () => _setState(set, installed: true), child: Text(s.t('add'))),
                        ),
                    ],
                  ),
                  (_archived ?? const []).isEmpty
                      ? Center(child: Text(s.t('nothing_here')))
                      : ListView(
                          children: [
                            for (final set in _archived!)
                              _setTile(set, trailing: TextButton(onPressed: () => _setState(set, installed: true), child: Text(s.t('add')))),
                          ],
                        ),
                ],
              ),
      ),
    );
  }
}
