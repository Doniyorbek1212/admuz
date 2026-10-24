import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import 'media_preview.dart';

/// One picked photo or video, with the size and length receivers need before it downloads.
class PickedMedia {
  const PickedMedia({required this.path, required this.isVideo, this.width = 0, this.height = 0, this.duration = 0});

  final String path;
  final bool isVideo;
  final int width;
  final int height;
  final int duration;
}

sealed class AttachChoice {
  const AttachChoice();
}

/// Photos/videos picked in the sheet's gallery, sent as albums (or as files without compression).
class AttachMedia extends AttachChoice {
  const AttachMedia({required this.media, required this.caption, this.asFiles = false, this.silent = false});

  final List<PickedMedia> media;
  final String caption;
  final bool asFiles;
  final bool silent;
}

/// One of the sheet's other actions: camera, record_video, system_gallery, file, location, article, poll, checklist,
/// contact, music, or bot:USER_ID for a Mini App.
class AttachAction extends AttachChoice {
  const AttachAction(this.action);

  final String action;
}

/// Telegram's attach menu: recent photos and videos in a grid with numbered multi-select and a caption,
/// the other attachment kinds in a bottom row.
Future<AttachChoice?> showAttachSheet(BuildContext context, {List<td.AttachmentMenuBot> bots = const []}) =>
    showModalBottomSheet<AttachChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AttachSheet(bots: bots),
    );

class _AttachSheet extends StatefulWidget {
  const _AttachSheet({required this.bots});

  /// Mini Apps shown as extra tabs (Wallet and the like).
  final List<td.AttachmentMenuBot> bots;

  @override
  State<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<_AttachSheet> {
  static const _pageSize = 60;

  final _selection = AttachSelection();
  final List<AssetEntity> _assets = [];
  final Map<String, Future<Uint8List?>> _thumbnails = {};
  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  bool? _hasAccess;
  bool _loading = false;
  bool _hasMore = true;
  bool _sending = false;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (!permission.hasAccess) {
      setState(() => _hasAccess = false);
      return;
    }
    // The first path is "Recent" (all media); the rest are the device's folders.
    final albums = await PhotoManager.getAssetPathList(type: RequestType.common);
    if (!mounted) return;
    setState(() {
      _hasAccess = true;
      _albums = albums;
      _album = albums.isEmpty ? null : albums.first;
    });
    await _loadMore();
  }

  Future<void> _openAlbum(AssetPathEntity album) async {
    setState(() {
      _album = album;
      _assets.clear();
      _page = 0;
      _hasMore = true;
      _loading = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loading || !_hasMore) return;
    _loading = true;
    final page = await album.getAssetListPaged(page: _page, size: _pageSize);
    // A different album was opened while this page loaded.
    if (!mounted || album != _album) return;
    setState(() {
      _assets.addAll(page);
      _page++;
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  void _toggle(AssetEntity asset) => setState(() => _selection.toggle(asset));

  Future<void> _preview(AssetEntity asset) async {
    final send = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => MediaPreviewScreen(assets: _assets, initialIndex: _assets.indexOf(asset), selection: _selection),
    ));
    if (!mounted) return;
    setState(() {});
    if (send == true) await _send();
  }

  Future<void> _send({bool asFiles = false, bool silent = false}) async {
    setState(() => _sending = true);
    final media = <PickedMedia>[];
    for (final asset in _selection.selected) {
      final edited = _selection.edited[asset.id];
      final file = edited == null ? await asset.file : File(edited);
      if (file == null) continue; // Cloud-only or deleted meanwhile.
      media.add(PickedMedia(
        path: file.path,
        isVideo: asset.type == AssetType.video,
        // Crop and drawing change the size; TDLib measures edited photos itself.
        width: edited == null ? asset.orientatedWidth : 0,
        height: edited == null ? asset.orientatedHeight : 0,
        duration: asset.duration,
      ));
    }
    if (!mounted) return;
    Navigator.pop(context, AttachMedia(media: media, caption: _selection.caption.text.trim(), asFiles: asFiles, silent: silent));
  }

  Future<void> _sendOptions() async {
    final s = context.s;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_rounded),
              title: Text(s.t('send_without_compression')),
              onTap: () => Navigator.pop(context, 'files'),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_rounded),
              title: Text(s.t('send_silent')),
              onTap: () => Navigator.pop(context, 'silent'),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) await _send(asFiles: choice == 'files', silent: choice == 'silent');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.4,
      snap: true,
      builder: (context, scroll) => Material(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(color: theme.hintColor.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            _albumPicker(),
            Expanded(child: _gallery(scroll)),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _selection.selected.isEmpty ? _actionRow() : _captionBar(),
            ),
          ],
        ),
      ),
    );
  }

  /// "Recent ▾" header that switches the grid to another device folder, like Telegram.
  Widget _albumPicker() {
    final album = _album;
    if (album == null || _albums.length < 2) return const SizedBox(height: 10);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: PopupMenuButton<AssetPathEntity>(
        onSelected: _openAlbum,
        itemBuilder: (_) => [for (final a in _albums) PopupMenuItem(value: a, child: Text(a.name))],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(album.isAll ? context.t('gallery') : album.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const Icon(Icons.arrow_drop_down_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gallery(ScrollController scroll) {
    final s = context.s;
    if (_hasAccess == false) {
      return ListView(
        controller: scroll,
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.photo_library_outlined, size: 56, color: Theme.of(context).hintColor),
          const SizedBox(height: 12),
          Text(s.t('gallery_permission'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: PhotoManager.openSetting, child: Text(s.t('open_settings'))),
          TextButton(
            onPressed: () => Navigator.pop(context, const AttachAction('system_gallery')),
            child: Text(s.t('gallery')),
          ),
        ],
      );
    }
    if (_hasAccess == null) return const Center(child: CircularProgressIndicator());
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 800) _loadMore();
        return false;
      },
      child: GridView.builder(
        controller: scroll,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
        itemCount: _assets.length + 1,
        itemBuilder: (context, index) => index == 0 ? _cameraTile() : _assetTile(_assets[index - 1]),
      ),
    );
  }

  Widget _cameraTile() {
    final s = context.s;
    return Material(
      color: Colors.black87,
      child: InkWell(
        onTap: () => Navigator.pop(context, const AttachAction('camera')),
        onLongPress: () => Navigator.pop(context, const AttachAction('record_video')),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_camera_rounded, color: Colors.white, size: 34),
            const SizedBox(height: 4),
            Text(s.t('camera'), style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  Widget _assetTile(AssetEntity asset) {
    final order = _selection.indexOf(asset);
    final selected = order >= 0;
    final primary = Theme.of(context).colorScheme.primary;
    final thumbnail = _thumbnails.putIfAbsent(asset.id, () => asset.thumbnailDataWithSize(const ThumbnailSize.square(240)));
    final edited = _selection.edited[asset.id];
    // Like Telegram: the tile opens the viewer, the corner circle selects.
    return GestureDetector(
      onTap: () => _preview(asset),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedScale(
            scale: selected ? 0.86 : 1,
            duration: const Duration(milliseconds: 140),
            child: edited != null
                ? Image.file(File(edited), fit: BoxFit.cover, cacheWidth: 360)
                : FutureBuilder<Uint8List?>(
                    future: thumbnail,
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      return bytes == null
                          ? ColoredBox(color: Theme.of(context).hintColor.withValues(alpha: 0.15))
                          : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                    },
                  ),
          ),
          if (asset.type == AssetType.video)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
                    Text(formatDuration(asset.videoDuration), style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                  ],
                ),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggle(asset),
              // Padding widens the circle's touch target to 40 points.
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? primary : Colors.black26,
                    border: Border.all(color: Colors.white, width: 1.6),
                  ),
                  child: selected
                      ? Text('${order + 1}', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700))
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// aka/Telegram attach tabs: a floating, horizontally scrolling pill; Gallery is the open tab,
  /// the rest (Mini Apps from the attach menu included) leave the sheet with their action.
  Widget _actionRow() {
    final s = context.s;
    final scheme = Theme.of(context).colorScheme;
    final tabs = <(IconData, String, String, bool)>[
      (Icons.photo_library_rounded, s.t('gallery'), 'system_gallery', false),
      for (final bot in widget.bots)
        (bot.name.toLowerCase().contains('wallet') ? Icons.account_balance_wallet_rounded : Icons.apps_rounded, bot.name, 'bot:${bot.botUserId}', false),
      (Icons.insert_drive_file_rounded, s.t('file'), 'file', false),
      (Icons.location_on_rounded, s.t('location'), 'location', false),
      (Icons.article_rounded, s.t('article'), 'article', false),
      (Icons.poll_rounded, s.t('poll'), 'poll', false),
      (Icons.checklist_rounded, s.t('checklist'), 'checklist', true),
      (Icons.person_rounded, s.t('contact'), 'contact', false),
      (Icons.headphones_rounded, s.t('music'), 'music', false),
    ];
    return SafeArea(
      key: const ValueKey('actions'),
      top: false,
      child: Container(
        height: 72,
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(36),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          children: [
            for (final (i, (icon, label, action, premium)) in tabs.indexed)
              // Gallery is already open, so its tab does nothing, like Telegram.
              _tab(icon, label, premium: premium, selected: i == 0, onTap: i == 0 ? () {} : () => Navigator.pop(context, AttachAction(action))),
          ],
        ),
      ),
    );
  }

  Widget _tab(IconData icon, String label, {required bool premium, required bool selected, required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 78),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: selected ? BoxDecoration(color: scheme.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(30)) : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Badge(
              isLabelVisible: premium,
              backgroundColor: const Color(0xFF8E7CF6),
              label: const Icon(Icons.star_rounded, size: 10, color: Colors.white),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, style: TextStyle(fontSize: 12.5, color: color, fontWeight: selected ? FontWeight.w600 : null)),
          ],
        ),
      ),
    );
  }

  Widget _captionBar() {
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return SafeArea(
      key: const ValueKey('caption'),
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + MediaQuery.viewInsetsOf(context).bottom),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _selection.caption,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: s.t('caption'),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onLongPress: _sending ? null : _sendOptions,
              child: Badge(
                label: Text('${_selection.selected.length}'),
                backgroundColor: primary,
                child: FloatingActionButton.small(
                  heroTag: null,
                  tooltip: s.t('send'),
                  onPressed: _sending ? null : _send,
                  child: _sending
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
