import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'sticker_extras.dart' show showAttachedStickerSets;
import '../profile/chat_info_screen.dart';
import 'media_viewers.dart';
import 'message_content.dart';
import 'sponsored_bubble.dart' show reportSponsored;

/// Lets the media viewer hand chat actions (reply, forward, delete, show) back to the open chat.
class MessageActionScope extends InheritedWidget {
  const MessageActionScope({super.key, required this.run, required super.child});

  final Future<void> Function(String action, td.Message message) run;

  static MessageActionScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<MessageActionScope>();

  @override
  bool updateShouldNotify(MessageActionScope old) => false;
}

/// Picture-in-picture for the video viewer (Android, MainActivity.kt).
class PictureInPicture {
  PictureInPicture._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') active.value = call.arguments == true;
    });
  }

  static final PictureInPicture instance = PictureInPicture._();
  static const _channel = MethodChannel('uz.sado.app/pip');

  final ValueNotifier<bool> active = ValueNotifier(false);

  static bool get supported => Platform.isAndroid;

  Future<bool> enter(int width, int height) async =>
      await _channel.invokeMethod<bool>('enter', {'width': width, 'height': height}).catchError((Object _) => false) ?? false;
}

/// Opens a photo/video message in Telegram's media viewer: swipe through the chat's photos and videos.
void openMediaGallery(BuildContext context, td.Message message) {
  final file = mediaFileOf(message);
  if (file == null) return;
  // video_player has no Windows/Linux implementation: the old viewer hands videos to the system player.
  if (isDesktop && !Platform.isMacOS && message.content is! td.MessagePhoto) {
    openVideoPlayer(context, file);
    return;
  }
  final scope = MessageActionScope.maybeOf(context);
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (_, _, _) => MediaGalleryScreen(message: message, onAction: scope?.run),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

class MediaGalleryScreen extends ConsumerStatefulWidget {
  const MediaGalleryScreen({super.key, required this.message, this.onAction});

  final td.Message message;
  final Future<void> Function(String action, td.Message message)? onAction;

  @override
  ConsumerState<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends ConsumerState<MediaGalleryScreen> {
  static const _filter = td.SearchMessagesFilterPhotoAndVideo();
  static const _window = 20;

  late List<td.Message> _items = [widget.message];
  final PageController _pages = PageController();
  int _index = 0;
  int _total = 0; // Media in the chat, for "k / total".
  int _firstPosition = 0; // 1-based position (oldest first) of _items.first; 0 while unknown.
  bool _hasOlder = true;
  bool _hasNewer = true;
  bool _loading = false;
  bool _chrome = true;
  final _videoKeys = <int, GlobalKey<_GalleryVideoState>>{};

  td.Message get _current => _items[_index];

  @override
  void initState() {
    super.initState();
    // GIFs and round videos are not in the photo/video filter: they open on their own.
    final content = widget.message.content;
    if (content is td.MessagePhoto || content is td.MessageVideo) _loadAround();
  }

  @override
  void dispose() {
    _pages.dispose();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<td.FoundChatMessages> _search(int fromId, int offset, int limit) => ref.read(accountProvider).send<td.FoundChatMessages>(
        td.SearchChatMessages(chatId: widget.message.chatId, query: '', fromMessageId: fromId, offset: offset, limit: limit, filter: _filter),
      );

  Future<void> _loadAround() async {
    final account = ref.read(accountProvider);
    try {
      final found = await _search(widget.message.id, -_window, _window * 2 + 1);
      final position = await account.send<td.Count>(td.GetChatMessagePosition(
        chatId: widget.message.chatId,
        topicId: null,
        filter: _filter,
        messageId: widget.message.id,
      ));
      if (!mounted) return;
      final items = _merge(found.messages);
      final index = items.indexWhere((m) => m.id == widget.message.id);
      setState(() {
        _items = items;
        _index = index;
        _total = found.totalCount;
        // TDLib counts from the newest message; the counter runs oldest first, like Telegram.
        _firstPosition = found.totalCount - position.count + 1 - index;
        _hasOlder = items.first.id != widget.message.id || found.messages.length > _window;
      });
      // The pages grew around the opened message: move the view onto it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(index);
      });
    } on Exception catch (error) {
      debugPrint('media gallery load failed: $error');
    }
  }

  /// Current items plus [more], without duplicates, oldest first; the opened message is always kept.
  List<td.Message> _merge(List<td.Message> more) {
    final byId = {for (final m in [..._items, ...more]) m.id: m};
    return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> _loadMore({required bool older}) async {
    if (_loading || (older ? !_hasOlder : !_hasNewer)) return;
    _loading = true;
    try {
      final found = older ? await _search(_items.first.id, 0, _window) : await _search(_items.last.id, -_window, _window + 1);
      if (!mounted) return;
      final before = _items.length;
      final items = _merge(found.messages);
      final added = items.length - before;
      final currentId = _current.id;
      setState(() {
        _items = items;
        if (older) {
          _hasOlder = added > 0;
          if (_firstPosition > 0) _firstPosition -= added;
        } else {
          _hasNewer = added > 0;
        }
        _index = items.indexWhere((m) => m.id == currentId);
      });
      // Items added in front shift the pages; stay on the same message.
      if (older && added > 0) _pages.jumpToPage(_index);
    } on Exception catch (error) {
      debugPrint('media gallery page failed: $error');
    } finally {
      _loading = false;
    }
  }

  void _onPage(int index) {
    setState(() => _index = index);
    if (index <= 2) _loadMore(older: true);
    if (index >= _items.length - 3) _loadMore(older: false);
  }

  Future<void> _runChatAction(String action) async {
    final onAction = widget.onAction;
    final message = _current;
    if (onAction == null) return;
    Navigator.pop(context);
    await onAction(action, message);
  }

  Future<void> _onMenu(String action) async {
    final account = ref.read(accountProvider);
    final message = _current;
    final file = mediaFileOf(message);
    final current = file == null ? null : account.files[file.id] ?? file;
    final ready = current != null && current.local.isDownloadingCompleted;
    switch (action) {
      case 'save':
        if (current != null) await saveMediaToGallery(context, ref, current, isVideo: message.content is! td.MessagePhoto);
      case 'open_with':
        if (ready) await openLocalFile(context, current.local.path);
      case 'share':
        if (ready) await SharePlus.instance.share(ShareParams(files: [XFile(current.local.path)]));
      case 'pip':
        await _videoKeys[message.id]?.currentState?.enterPip();
      case 'stickers':
        if (message.content case td.MessagePhoto(:final photo) when photo.sizes.isNotEmpty) {
          await showAttachedStickerSets(context, account, photo.sizes.last.photo.id);
        }
      case 'all_media':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: message.chatId)));
      case 'reply' || 'forward' || 'delete' || 'show_in_chat':
        await _runChatAction(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PictureInPicture.instance.active,
      builder: (context, pip, _) => Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () => setState(() => _chrome = !_chrome),
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0).abs() > 800) Navigator.pop(context);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: _pages,
                itemCount: _items.length,
                onPageChanged: _onPage,
                itemBuilder: (context, i) => _page(_items[i], active: i == _index, chrome: _chrome && !pip),
              ),
              if (_chrome && !pip) ...[_topBar(context), _bottomBar(context)],
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(td.Message message, {required bool active, required bool chrome}) => switch (message.content) {
        td.MessagePhoto(:final photo) => _GalleryPhoto(photo: photo),
        _ => _GalleryVideo(
            key: _videoKeys.putIfAbsent(message.id, GlobalKey<_GalleryVideoState>.new),
            message: message,
            active: active,
            chrome: chrome,
          ),
      };

  Widget _topBar(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final message = _current;
    final isVideo = message.content is! td.MessagePhoto;
    final canChat = widget.onAction != null;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        color: Colors.black54,
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const BackButton(color: Colors.white),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(account.senderName(message.senderId),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                        Text('${formatDayHeader(message.date, s)} ${formatTime(message.date, s.locale)}',
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (canChat)
                    IconButton(icon: const Icon(Icons.shortcut_rounded, color: Colors.white), tooltip: s.t('forward'), onPressed: () => _onMenu('forward')),
                  if (isVideo)
                    IconButton(
                      icon: const Icon(Icons.settings_rounded, color: Colors.white),
                      tooltip: s.t('speed'),
                      onPressed: () => _videoKeys[message.id]?.currentState?.pickSpeed(),
                    ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                    onSelected: _onMenu,
                    itemBuilder: (_) => [
                      _menuItem('save', Icons.add_photo_alternate_outlined, s.t('save_to_gallery')),
                      _menuItem('open_with', Icons.open_in_new_rounded, s.t('open_with')),
                      if (isVideo && PictureInPicture.supported) _menuItem('pip', Icons.picture_in_picture_alt_rounded, s.t('pip')),
                      if (message.content case td.MessagePhoto(:final photo) when photo.hasStickers)
                        _menuItem('stickers', Icons.emoji_emotions_outlined, s.t('attached_stickers')),
                      _menuItem('all_media', Icons.grid_view_rounded, s.t('all_media')),
                      if (canChat) _menuItem('show_in_chat', Icons.visibility_outlined, s.t('show_in_chat')),
                      if (canChat) _menuItem('reply', Icons.reply_rounded, s.t('reply')),
                      _menuItem('share', Icons.share_outlined, s.t('share')),
                      if (canChat) _menuItem('delete', Icons.delete_outline_rounded, s.t('delete'), destructive: true),
                    ],
                  ),
                ],
              ),
              if (_total > 1 && _firstPosition > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(14)),
                  child: Text('${_firstPosition + _index} / $_total', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool destructive = false}) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return PopupMenuItem(
      value: value,
      child: Row(children: [Icon(icon, color: color), const SizedBox(width: 14), Text(label, style: TextStyle(color: color))]),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final caption = captionOf(_current.content);
    if (caption == null || caption.text.isEmpty) return const SizedBox.shrink();
    final isVideo = _current.content is! td.MessagePhoto;
    return Positioned(
      left: 0,
      right: 0,
      // Videos keep their seek bar under the caption.
      bottom: isVideo ? 72 : 0,
      child: Container(
        color: Colors.black45,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: SafeArea(
          top: false,
          bottom: !isVideo,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: FormattedTextView(text: caption, style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryPhoto extends ConsumerStatefulWidget {
  const _GalleryPhoto({required this.photo});

  final td.Photo photo;

  @override
  ConsumerState<_GalleryPhoto> createState() => _GalleryPhotoState();
}

class _GalleryPhotoState extends ConsumerState<_GalleryPhoto> {
  @override
  Widget build(BuildContext context) {
    final full = bestPhotoSize(widget.photo, target: 2560);
    if (full == null) return const SizedBox.shrink();
    final file = ref.watch(fileProvider(full.photo.id)).value ?? full.photo;
    if (!file.local.isDownloadingCompleted) {
      return Stack(
        fit: StackFit.expand,
        children: [
          TdImage(file: full.photo, minithumbnail: widget.photo.minithumbnail, fit: BoxFit.contain),
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      );
    }
    return PhotoView(
      imageProvider: FileImage(File(file.local.path)),
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
    );
  }
}

/// One video page: plays while it is the current page, with Telegram's gestures —
/// double-tap the left/right half to skip 10 s, hold for 2x, seek bar and full-screen rotation.
class _GalleryVideo extends ConsumerStatefulWidget {
  const _GalleryVideo({super.key, required this.message, required this.active, required this.chrome});

  final td.Message message;
  final bool active;
  final bool chrome;

  @override
  ConsumerState<_GalleryVideo> createState() => _GalleryVideoState();
}

class _GalleryVideoState extends ConsumerState<_GalleryVideo> with WidgetsBindingObserver {
  static const _skip = Duration(seconds: 10);

  VideoPlayerController? _controller;
  bool _starting = false;
  double _speed = 1;
  bool _holdFast = false;
  bool _landscape = false;
  String? _skipHint; // "« 10" / "10 »" shown briefly after a double tap.
  Timer? _hintTimer;
  // Channel video ads: shown over the video after Telegram's start delay, one at a time.
  List<td.VideoMessageAdvertisement> _ads = const [];
  int _betweenDelay = 0;
  td.VideoMessageAdvertisement? _ad;
  bool _adClosable = false;
  final List<Timer> _adTimers = [];

  td.File? get _file => mediaFileOf(widget.message);

  bool get _loop => widget.message.content is td.MessageAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final file = _file;
    // Telegram streams while it downloads; here the download starts as soon as the page shows.
    if (file != null && !file.local.isDownloadingCompleted) unawaited(ref.read(accountProvider).downloadFile(file.id, priority: 32));
  }

  @override
  void didUpdateWidget(_GalleryVideo old) {
    super.didUpdateWidget(old);
    final controller = _controller;
    if (controller != null && old.active != widget.active) widget.active ? controller.play() : controller.pause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app pauses, except into picture-in-picture.
    if (state == AppLifecycleState.paused && !PictureInPicture.instance.active.value) _controller?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    for (final timer in _adTimers) {
      timer.cancel();
    }
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start(String path) async {
    if (_starting || _controller != null) return;
    _starting = true;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(_loop);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      if (widget.active) unawaited(controller.play());
      if (widget.message.isChannelPost) unawaited(_loadAds());
    } on Object catch (error) {
      await controller.dispose();
      debugPrint('video init failed: $error');
      if (mounted) showToast(context, context.t('err_GENERIC'));
    }
  }

  Future<void> _loadAds() async {
    final account = ref.read(accountProvider);
    try {
      final result = await account.send<td.VideoMessageAdvertisements>(
        td.GetVideoMessageAdvertisements(chatId: widget.message.chatId, messageId: widget.message.id),
      );
      if (!mounted || result.advertisements.isEmpty) return;
      _ads = result.advertisements;
      _betweenDelay = result.betweenDelay;
      _adTimers.add(Timer(Duration(seconds: result.startDelay), () => _showAd(0)));
    } on TdException catch (error) {
      // Most videos have no ads; the error only means none can be shown.
      debugPrint('video ads unavailable: $error');
    }
  }

  void _showAd(int index) {
    if (!mounted || index >= _ads.length) return;
    final ad = _ads[index];
    setState(() {
      _ad = ad;
      _adClosable = false;
    });
    unawaited(ref.read(accountProvider).send<td.Ok>(td.ViewVideoMessageAdvertisement(advertisementUniqueId: ad.uniqueId)).then<void>((_) {}, onError: (_) {}));
    _adTimers
      ..add(Timer(Duration(seconds: ad.minDisplayDuration), () {
        if (mounted) setState(() => _adClosable = true);
      }))
      ..add(Timer(Duration(seconds: ad.maxDisplayDuration), () => _hideAd(next: index + 1)));
  }

  void _hideAd({required int next}) {
    if (!mounted || _ad == null) return;
    setState(() => _ad = null);
    if (next < _ads.length) _adTimers.add(Timer(Duration(seconds: _betweenDelay), () => _showAd(next)));
  }

  Future<void> _openAd(td.VideoMessageAdvertisement ad) async {
    final account = ref.read(accountProvider);
    await guard(context, () => account.send<td.Ok>(td.ClickVideoMessageAdvertisement(advertisementUniqueId: ad.uniqueId)));
    final uri = Uri.tryParse(ad.sponsor.url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _adCard(td.VideoMessageAdvertisement ad) {
    final s = context.s;
    final account = ref.read(accountProvider);
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openAd(ad),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(s.t('sponsored'), style: const TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w600)),
                Text(ad.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                if (ad.text.isNotEmpty) Text(ad.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
            if (ad.canBeReported)
              IconButton(
                icon: const Icon(Icons.flag_outlined, color: Colors.white70, size: 20),
                tooltip: s.t('ad_report'),
                onPressed: () => reportSponsored(
                  context,
                  (optionId) => account.send<td.ReportSponsoredResult>(
                    td.ReportVideoMessageAdvertisement(advertisementUniqueId: ad.uniqueId, optionId: optionId),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(Icons.close_rounded, color: _adClosable ? Colors.white : Colors.white24, size: 20),
              tooltip: s.t('close'),
              onPressed: _adClosable ? () => _hideAd(next: _ads.indexOf(ad) + 1) : null,
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> pickSpeed() async {
    final controller = _controller;
    if (controller == null) return;
    final s = context.s;
    final picked = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s.t('speed'), style: Theme.of(context).textTheme.titleMedium)),
            for (final speed in const [0.25, 0.5, 1.0, 1.25, 1.5, 2.0])
              ListTile(
                leading: Icon(speed == _speed ? Icons.check_rounded : null),
                title: Text('${speed == speed.roundToDouble() ? speed.toInt() : speed}x'),
                onTap: () => Navigator.pop(context, speed),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _speed = picked);
    await controller.setPlaybackSpeed(picked);
  }

  Future<void> enterPip() async {
    final controller = _controller;
    if (controller == null) return;
    final size = controller.value.size;
    unawaited(controller.play());
    await PictureInPicture.instance.enter(size.width.round(), size.height.round());
  }

  Future<void> _toggleLandscape() async {
    setState(() => _landscape = !_landscape);
    await SystemChrome.setPreferredOrientations(
      _landscape ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(_landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _onDoubleTap(TapDownDetails details, double width) {
    final controller = _controller;
    if (controller == null) return;
    final forward = details.localPosition.dx > width / 2;
    final position = controller.value.position + (forward ? _skip : -_skip);
    final duration = controller.value.duration;
    unawaited(controller.seekTo(position < Duration.zero ? Duration.zero : (position > duration ? duration : position)));
    _hintTimer?.cancel();
    setState(() => _skipHint = forward ? '10 »' : '« 10');
    _hintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _skipHint = null);
    });
  }

  Future<void> _setHoldFast(bool fast) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _holdFast = fast);
    await controller.setPlaybackSpeed(fast ? 2 : _speed);
  }

  @override
  Widget build(BuildContext context) {
    final source = _file;
    if (source == null) return const SizedBox.shrink();
    final file = ref.watch(fileProvider(source.id)).value ?? source;
    if (file.local.isDownloadingCompleted && _controller == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start(file.local.path));
    }
    final controller = _controller;
    if (controller == null) {
      final total = file.size == 0 ? file.expectedSize : file.size;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white, value: total > 0 ? file.local.downloadedSize / total : null),
            const SizedBox(height: 12),
            Text('${formatFileSize(file.local.downloadedSize)} / ${formatFileSize(total)}', style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onDoubleTapDown: (details) => _onDoubleTap(details, constraints.maxWidth),
        onDoubleTap: () {},
        onLongPressStart: (_) => _setHoldFast(true),
        onLongPressEnd: (_) => _setHoldFast(false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller))),
            if (_skipHint != null) Center(child: _pill(_skipHint!, fontSize: 22)),
            if (_holdFast) Align(alignment: const Alignment(0, -0.6), child: _pill('2x ▶▶')),
            if (_ad case final ad?) Positioned(left: 12, right: 12, bottom: 96, child: SafeArea(top: false, child: _adCard(ad))),
            if (widget.chrome) ...[
              Center(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => IconButton.filled(
                    iconSize: 44,
                    style: IconButton.styleFrom(backgroundColor: Colors.black45),
                    icon: Icon(value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    onPressed: () => value.isPlaying ? controller.pause() : controller.play(),
                  ),
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 0, child: _seekBar(controller)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, {double fontSize = 15}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700)),
      );

  Widget _seekBar(VideoPlayerController controller) {
    final s = context.s;
    return Container(
      color: Colors.black45,
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final total = value.duration.inMilliseconds;
            final position = value.position.inMilliseconds.clamp(0, total > 0 ? total : 0);
            return Row(
              children: [
                Expanded(
                  child: Slider(
                    value: total > 0 ? position.toDouble() : 0,
                    max: total > 0 ? total.toDouble() : 1,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white30,
                    onChanged: total > 0 ? (v) => controller.seekTo(Duration(milliseconds: v.round())) : null,
                  ),
                ),
                Text('${formatDuration(value.position)} / ${formatDuration(value.duration)}', style: const TextStyle(color: Colors.white)),
                IconButton(
                  icon: Icon(_landscape ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white),
                  tooltip: s.t('fullscreen'),
                  onPressed: _toggleLandscape,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
