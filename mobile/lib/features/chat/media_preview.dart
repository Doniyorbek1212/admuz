import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:video_player/video_player.dart';

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import 'photo_draw_screen.dart';

/// Selection shared by the attach sheet's grid and the full-screen preview: picked assets in order,
/// edited copies of photos, and the caption.
class AttachSelection extends ChangeNotifier {
  final List<AssetEntity> selected = [];
  final Map<String, String> edited = {};
  final TextEditingController caption = TextEditingController();

  int indexOf(AssetEntity asset) => selected.indexOf(asset);

  void toggle(AssetEntity asset) {
    if (!selected.remove(asset)) selected.add(asset);
    notifyListeners();
  }

  void setEdited(AssetEntity asset, String path) {
    edited[asset.id] = path;
    if (!selected.contains(asset)) selected.add(asset);
    notifyListeners();
  }

  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }
}

/// Telegram's viewer inside the attach menu: swipe through the gallery, zoom, select with the corner circle,
/// crop/rotate or draw on photos, write the caption. Pops with true to send.
class MediaPreviewScreen extends StatefulWidget {
  const MediaPreviewScreen({super.key, required this.assets, required this.initialIndex, required this.selection});

  final List<AssetEntity> assets;
  final int initialIndex;
  final AttachSelection selection;

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final Map<String, Future<File?>> _files = {};

  AssetEntity get _current => widget.assets[_index];

  Future<File?> _fileOf(AssetEntity asset) => _files.putIfAbsent(asset.id, () => asset.file);

  // Videos start uploading while the user is still in the viewer; dropped ones are cancelled on close.
  final Map<String, int> _preUploads = {};
  bool _sent = false;
  TelegramAccount? _account;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_preUpload(_current));
    });
  }

  Future<void> _preUpload(AssetEntity asset) async {
    if (asset.type != AssetType.video || _preUploads.containsKey(asset.id)) return;
    final path = (await _fileOf(asset))?.path;
    if (path == null || !mounted) return;
    try {
      final TelegramAccount account = _account ?? ProviderScope.containerOf(context, listen: false).read(accountProvider);
      _account = account;
      // Sending later with the same local path reuses this upload.
      final file = await account.send<td.File>(td.PreliminaryUploadFile(file: td.InputFileLocal(path: path), fileType: const td.FileTypeVideo(), priority: 1));
      _preUploads[asset.id] = file.id;
    } on TdException catch (error) {
      debugPrint('preliminary upload failed: $error');
    }
  }

  @override
  void dispose() {
    for (final MapEntry(key: assetId, value: fileId) in _preUploads.entries) {
      if (_sent && widget.selection.selected.any((a) => a.id == assetId)) continue;
      _account?.send<td.Ok>(td.CancelPreliminaryUploadFile(fileId: fileId)).ignore();
    }
    _pages.dispose();
    super.dispose();
  }

  Future<String?> _photoPath(AssetEntity asset) async => widget.selection.edited[asset.id] ?? (await _fileOf(asset))?.path;

  Future<void> _crop() async {
    final s = context.s;
    final accent = Theme.of(context).colorScheme.primary;
    final source = await _photoPath(_current);
    if (source == null) return;
    final cropped = await ImageCropper().cropImage(
      sourcePath: source,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: s.t('crop'),
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          statusBarLight: false,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: accent,
          lockAspectRatio: false,
          initAspectRatio: CropAspectRatioPreset.original,
          aspectRatioPresets: const [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(title: s.t('crop')),
      ],
    );
    if (cropped != null && mounted) widget.selection.setEdited(_current, cropped.path);
  }

  Future<void> _draw() async {
    final source = await _photoPath(_current);
    if (source == null || !mounted) return;
    final drawn = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => PhotoDrawScreen(path: source)));
    if (drawn != null && mounted) widget.selection.setEdited(_current, drawn);
  }

  void _send() {
    // Sending from the viewer with nothing picked sends the photo on screen, like Telegram.
    if (widget.selection.selected.isEmpty) widget.selection.toggle(_current);
    _sent = true;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: widget.selection,
      builder: (context, _) {
        final order = widget.selection.indexOf(_current);
        final isPhoto = _current.type == AssetType.image;
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
            title: Text('${_index + 1} / ${widget.assets.length}'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => widget.selection.toggle(_current),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: order >= 0 ? primary : Colors.black26,
                      border: Border.all(color: Colors.white, width: 1.8),
                    ),
                    child: order >= 0 ? Text('${order + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)) : null,
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: widget.assets.length,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    unawaited(_preUpload(_current));
                  },
                  itemBuilder: (context, i) => _page(widget.assets[i]),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 6, 8, 8 + MediaQuery.viewInsetsOf(context).bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPhoto)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(icon: const Icon(Icons.crop_rotate_rounded, color: Colors.white), tooltip: s.t('crop'), onPressed: _crop),
                            const SizedBox(width: 24),
                            IconButton(icon: const Icon(Icons.brush_rounded, color: Colors.white), tooltip: s.t('draw'), onPressed: _draw),
                          ],
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: widget.selection.caption,
                              minLines: 1,
                              maxLines: 4,
                              style: const TextStyle(color: Colors.white),
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                hintText: s.t('caption'),
                                hintStyle: const TextStyle(color: Colors.white54),
                                isDense: true,
                                filled: true,
                                fillColor: Colors.white12,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Badge(
                            isLabelVisible: widget.selection.selected.isNotEmpty,
                            label: Text('${widget.selection.selected.length}'),
                            child: FloatingActionButton.small(heroTag: null, tooltip: s.t('send'), onPressed: _send, child: const Icon(Icons.send_rounded)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _page(AssetEntity asset) {
    if (asset.type == AssetType.video) return _VideoPage(file: _fileOf(asset));
    final edited = widget.selection.edited[asset.id];
    return FutureBuilder<File?>(
      future: edited == null ? _fileOf(asset) : Future.value(File(edited)),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return const Center(child: CircularProgressIndicator());
        return InteractiveViewer(maxScale: 5, child: Center(child: Image.file(file, key: ValueKey(file.path), fit: BoxFit.contain)));
      },
    );
  }
}

/// Video page: plays on tap, like Telegram's preview.
class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.file});

  final Future<File?> file;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final file = await widget.file;
    if (file == null || !mounted) return;
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const Center(child: CircularProgressIndicator());
    return GestureDetector(
      onTap: () => setState(() => controller.value.isPlaying ? controller.pause() : controller.play()),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.isPlaying
                ? const SizedBox.shrink()
                : const CircleAvatar(radius: 30, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40)),
          ),
        ],
      ),
    );
  }
}
