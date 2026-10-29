import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lottie/lottie.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/file_guard.dart';
import '../../core/link_safety.dart';
import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../core/live_location.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/link_policy.dart';
import '../../state/playback.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';
import '../../widgets/custom_emoji.dart';
import '../../widgets/map_thumbnail.dart';
import '../home/home_screen.dart';
import '../search/search_screen.dart';
import '../settings/misc_extras.dart' show SpeechRatingRow;
import '../settings/gifts_extras.dart' show GiftPurchaseOfferCard;
import '../settings/stars_extras.dart' show GiveawayCard;
import 'payments.dart' show showBankCardInfo;
import 'sticker_extras.dart' show StickerOutlinePlaceholder;
import 'bot_keyboard.dart';
import 'link_router.dart';
import 'media_gallery.dart';
import 'media_viewers.dart';
import 'message_extras.dart';
import 'message_tools.dart';
import 'rich_message.dart';
import '../calls/conference_calls.dart' show GroupCallMessageView;
import 'sticker_sets.dart';
import 'video_note_view.dart';

/// Picks the photo size best suited for a bubble (around 800px wide).
td.PhotoSize? bestPhotoSize(td.Photo photo, {int target = 800}) {
  if (photo.sizes.isEmpty) return null;
  final sorted = [...photo.sizes]..sort((a, b) => a.width.compareTo(b.width));
  return sorted.firstWhere((s) => s.width >= target, orElse: () => sorted.last);
}

/// Renders a FormattedText with Telegram entities (links, mentions, bold, code, spoilers...).
class FormattedTextView extends StatefulWidget {
  const FormattedTextView({super.key, required this.text, this.style, this.onMention, this.trailingSpace = 0});

  final td.FormattedText text;
  final TextStyle? style;

  /// Invisible room at the end of the last line (the bubble draws the time there when it fits).
  final double trailingSpace;
  final void Function(String username)? onMention;

  @override
  State<FormattedTextView> createState() => _FormattedTextViewState();
}

class _FormattedTextViewState extends State<FormattedTextView> {
  final List<TapGestureRecognizer> _recognizers = [];
  final Set<int> _revealedSpoilers = {};

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _openUrl(String url, {String? shownText}) => unawaited(openLink(context, url, shownText: shownText));

  /// Risky links are drawn in red behind a warning sign, so the danger is visible before the tap.
  InlineSpan _linkSpan(String part, String url, TextStyle link, {String? shownText}) {
    final risk = assessLink(url, shownText: shownText, policy: ProviderScope.containerOf(context, listen: false).read(linkPolicyProvider));
    final recognizer = _tap(() => _openUrl(url, shownText: shownText));
    if (!risk.isDangerous) return TextSpan(text: part, style: link, recognizer: recognizer);
    final danger = Theme.of(context).colorScheme.error;
    return TextSpan(children: [
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: const EdgeInsets.only(right: 2), child: Icon(Icons.gpp_maybe_rounded, size: 16, color: danger))),
      TextSpan(text: part, style: link.copyWith(color: danger, decorationColor: danger), recognizer: recognizer),
    ]);
  }

  void _openMention(String username) {
    if (widget.onMention != null) return widget.onMention!(username);
    final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
    unawaited(openUsernameChat(context, account, username));
  }

  Future<void> _openUserId(int userId) async {
    final account = ProviderScope.containerOf(context, listen: false).read(accountProvider);
    final chat = await guard(context, () => account.openPrivateChat(userId));
    if (chat != null && mounted) openChat(context, chat.id);
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final text = widget.text.text;
    final entities = [...widget.text.entities]..sort((a, b) => a.offset.compareTo(b.offset));
    final linkColor = Theme.of(context).colorScheme.primary;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < entities.length; i++) {
      final entity = entities[i];
      final start = entity.offset.clamp(0, text.length);
      final end = (entity.offset + entity.length).clamp(start, text.length);
      if (start < cursor) continue; // nested entities: keep the outer one
      if (start > cursor) spans.add(TextSpan(text: text.substring(cursor, start)));
      final part = text.substring(start, end);
      spans.add(_entitySpan(entity.type, part, i, linkColor, base));
      cursor = end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    if (widget.trailingSpace > 0) spans.add(WidgetSpan(child: SizedBox(width: widget.trailingSpace, height: 1)));
    return Text.rich(TextSpan(style: base, children: spans));
  }

  InlineSpan _entitySpan(td.TextEntityType type, String part, int index, Color linkColor, TextStyle base) {
    final link = TextStyle(color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor);
    switch (type) {
      case td.TextEntityTypeUrl():
        return _linkSpan(part, part, link);
      case td.TextEntityTypeTextUrl(:final url):
        return _linkSpan(part, url, link, shownText: part);
      case td.TextEntityTypeEmailAddress():
        return TextSpan(text: part, style: link, recognizer: _tap(() => launchUrl(Uri(scheme: 'mailto', path: part))));
      case td.TextEntityTypePhoneNumber():
        return TextSpan(text: part, style: link, recognizer: _tap(() => launchUrl(Uri(scheme: 'tel', path: part))));
      case td.TextEntityTypeBankCardNumber():
        return TextSpan(text: part, style: link, recognizer: _tap(() => showBankCardInfo(context, ProviderScope.containerOf(context, listen: false).read(accountProvider), part)));
      case td.TextEntityTypeMention():
        return TextSpan(
          text: part,
          style: TextStyle(color: linkColor),
          recognizer: _tap(() => _openMention(part.substring(1))),
        );
      case td.TextEntityTypeMentionName(:final userId):
        return TextSpan(text: part, style: TextStyle(color: linkColor), recognizer: _tap(() => _openUserId(userId)));
      case td.TextEntityTypeHashtag() || td.TextEntityTypeCashtag():
        return TextSpan(
          text: part,
          style: TextStyle(color: linkColor),
          recognizer: _tap(() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SearchScreen(initialQuery: part)))),
        );
      case td.TextEntityTypeBold():
        return TextSpan(text: part, style: const TextStyle(fontWeight: FontWeight.w700));
      case td.TextEntityTypeItalic():
        return TextSpan(text: part, style: const TextStyle(fontStyle: FontStyle.italic));
      case td.TextEntityTypeUnderline():
        return TextSpan(text: part, style: const TextStyle(decoration: TextDecoration.underline));
      case td.TextEntityTypeStrikethrough():
        return TextSpan(text: part, style: const TextStyle(decoration: TextDecoration.lineThrough));
      case td.TextEntityTypeCode() || td.TextEntityTypePre() || td.TextEntityTypePreCode():
        return TextSpan(
          text: part,
          style: TextStyle(fontFamily: 'monospace', color: linkColor, fontSize: (base.fontSize ?? 15) - 1),
          recognizer: _tap(() => Clipboard.setData(ClipboardData(text: part))),
        );
      case td.TextEntityTypeCustomEmoji(:final customEmojiId):
        final size = (base.fontSize ?? 15) * 1.3;
        return WidgetSpan(alignment: PlaceholderAlignment.middle, child: CustomEmojiView(id: customEmojiId, size: size, fallback: part));
      case td.TextEntityTypeSpoiler():
        final revealed = _revealedSpoilers.contains(index);
        return TextSpan(
          text: part,
          style: revealed ? null : TextStyle(color: Colors.transparent, backgroundColor: base.color?.withValues(alpha: 0.35)),
          recognizer: _tap(() => setState(() => _revealedSpoilers.add(index))),
        );
      case td.TextEntityTypeBlockQuote() || td.TextEntityTypeExpandableBlockQuote():
        return TextSpan(text: part, style: const TextStyle(fontStyle: FontStyle.italic));
      default:
        return TextSpan(text: part);
    }
  }
}

/// Media and special content of a message (text is rendered by the bubble).
class MessageMedia extends ConsumerWidget {
  const MessageMedia({super.key, required this.message, required this.maxWidth});

  final td.Message message;
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = message.content;
    final verdict = ref.watch(settingsProvider.select((s) => s.fileGuard)).checkMessage(message, ref.read(accountProvider).myId);
    if (verdict != null) return _BlockedFileView(name: attachmentOf(content)!.name, verdict: verdict);
    return switch (content) {
      td.MessagePhoto(:final photo, :final hasSpoiler) => _PhotoView(message: message, photo: photo, maxWidth: maxWidth, spoiler: hasSpoiler),
      td.MessageVideo(:final video) => _VideoThumb(
          message: message,
          file: video.video,
          thumbnail: video.thumbnail,
          minithumbnail: video.minithumbnail,
          width: video.width,
          height: video.height,
          duration: video.duration,
          maxWidth: maxWidth,
        ),
      td.MessageAnimation(:final animation) => _VideoThumb(
          file: animation.animation,
          thumbnail: animation.thumbnail,
          minithumbnail: animation.minithumbnail,
          width: animation.width,
          height: animation.height,
          duration: animation.duration,
          maxWidth: maxWidth,
          isGif: true,
        ),
      td.MessageVideoNote(:final videoNote, :final isViewed) => VideoNoteView(message: message, videoNote: videoNote, isViewed: isViewed),
      td.MessageVoiceNote(:final voiceNote) => VoiceNoteView(message: message, voiceNote: voiceNote),
      td.MessageAudio(:final audio) => _AudioView(message: message, audio: audio),
      td.MessageDocument(:final document) => _FileView(
          message: message,
          file: document.document,
          name: document.fileName,
          icon: Icons.insert_drive_file_rounded,
          mimeType: document.mimeType,
        ),
      td.MessageSticker(:final sticker) => _StickerView(sticker: sticker),
      td.MessageLocation(:final location) => _LocationView(latitude: location.latitude, longitude: location.longitude),
      td.MessageLiveLocation(:final location, :final expiresIn) => _LiveLocationView(message: message, location: location, expiresIn: expiresIn),
      td.MessageVenue(:final venue) =>
        _LocationView(latitude: venue.location.latitude, longitude: venue.location.longitude, title: venue.title, subtitle: venue.address),
      td.MessageContact(:final contact) => _ContactView(contact: contact),
      td.MessagePoll(:final poll, :final canAddOption) => PollView(message: message, poll: poll, canAddOption: canAddOption),
      td.MessageGiveaway() && final giveaway => GiveawayCard(message: message, giveaway: giveaway),
      td.MessageUpgradedGiftPurchaseOffer() && final offer => GiftPurchaseOfferCard(message: message, offer: offer),
      td.MessageChecklist(:final list) => ChecklistView(message: message, checklist: list),
      td.MessageRichMessage(message: final rich) => RichMessageView(message: message, rich: rich),
      final td.MessageGroupCall call => GroupCallMessageView(message: message, call: call),
      td.MessageCall(:final isVideo, :final duration) => _CallView(isVideo: isVideo, duration: duration, outgoing: message.isOutgoing),
      td.MessageInvoice() => InvoiceView(message: message),
      td.MessageAnimatedEmoji(:final animatedEmoji) when animatedEmoji.sticker != null => _AnimatedEmojiView(message: message, sticker: animatedEmoji.sticker!),
      td.MessageAnimatedEmoji(:final emoji) || td.MessageDice(:final emoji) =>
        Text(emoji, style: const TextStyle(fontSize: 56)),
      _ => const SizedBox.shrink(),
    };
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Stand-in for a file the guard blocked: no download, no open, just what it was and why.
class _BlockedFileView extends StatelessWidget {
  const _BlockedFileView({required this.name, required this.verdict});

  final String name;
  final FileVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 24, backgroundColor: error.withValues(alpha: 0.12), child: Icon(Icons.gpp_bad_rounded, color: error)),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.t('file_blocked'), style: TextStyle(fontWeight: FontWeight.w600, color: error)),
                const SizedBox(height: 2),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                Text(s.t('file_guard_kind_${verdict.kind}'), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Size _fit(int width, int height, double maxWidth, {double maxHeight = 380}) {
  if (width <= 0 || height <= 0) return Size(maxWidth, maxWidth * 0.75);
  var w = maxWidth;
  var h = w * height / width;
  if (h > maxHeight) {
    h = maxHeight;
    w = h * width / height;
  }
  return Size(max(w, 120), max(h, 80));
}

class _PhotoView extends StatefulWidget {
  const _PhotoView({required this.message, required this.photo, required this.maxWidth, required this.spoiler});

  final td.Message message;

  final td.Photo photo;
  final double maxWidth;
  final bool spoiler;

  @override
  State<_PhotoView> createState() => _PhotoViewState();
}

class _PhotoViewState extends State<_PhotoView> {
  late bool _hidden = widget.spoiler;
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final size = bestPhotoSize(widget.photo);
    if (size == null) return const SizedBox.shrink();
    final box = _fit(size.width, size.height, widget.maxWidth);
    return Consumer(builder: (context, ref, _) {
      final auto = ref.watch(settingsProvider.select((s) => s.autoDownloadPhotos));
      final download = auto || _requested || size.photo.local.isDownloadingCompleted;
      final image = TdImage(file: size.photo, minithumbnail: widget.photo.minithumbnail, width: box.width, height: box.height, download: download);
      return GestureDetector(
        onTap: () {
          if (!download) {
            setState(() => _requested = true);
            return;
          }
          if (_hidden) {
            setState(() => _hidden = false);
            return;
          }
        openMediaGallery(context, widget.message);
      },
        child: SizedBox(
          width: box.width,
          height: box.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _hidden ? ImageFiltered(imageFilter: _blur, child: image) : image,
              if (!download)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: const Icon(Icons.download_rounded, color: Colors.white, size: 28),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

final _blur = ImageFilter.blur(sigmaX: 18, sigmaY: 18);

/// Videos up to this size download by themselves to play muted in the bubble (Telegram's mobile-data default).
const _inlineAutoplayMaxBytes = 10 * 1024 * 1024;

class _VideoThumb extends ConsumerWidget {
  const _VideoThumb({
    this.message,
    required this.file,
    required this.thumbnail,
    required this.minithumbnail,
    required this.width,
    required this.height,
    required this.duration,
    required this.maxWidth,
    this.isGif = false,
  });

  /// Set for videos in chats: opens the swipeable media viewer instead of the single-file player.
  final td.Message? message;
  final td.File file;
  final td.Thumbnail? thumbnail;
  final td.Minithumbnail? minithumbnail;
  final int width;
  final int height;
  final int duration;
  final double maxWidth;
  final bool isGif;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = _fit(width, height, maxWidth);
    final thumb = thumbnail;
    Widget preview = thumb != null && thumb.format is! td.ThumbnailFormatMpeg4
        ? TdImage(file: thumb.file, minithumbnail: minithumbnail, width: box.width, height: box.height)
        : Container(width: box.width, height: box.height, color: Colors.black26);
    if (isGif && ref.watch(motionProvider.select((m) => m.gifs))) {
      // GIFs are small MP4s: download and loop them inline like Telegram.
      final current = ref.watch(fileProvider(file.id)).value ?? file;
      if (current.local.isDownloadingCompleted && current.local.path.isNotEmpty) {
        return GestureDetector(
          onTap: () => openVideoPlayer(context, file, loop: true),
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: ClipRect(child: LoopingVideo(key: ValueKey(current.local.path), path: current.local.path, fallback: preview)),
          ),
        );
      }
    }
    final chatMessage = message;
    void open() => chatMessage != null && !isGif ? openMediaGallery(context, chatMessage) : openVideoPlayer(context, file, loop: isGif);
    if (!isGif && ref.watch(motionProvider.select((m) => m.videos))) {
      // Like Telegram/aka: videos play muted in the bubble; small ones download for it on their own.
      final small = (file.size == 0 ? file.expectedSize : file.size) <= _inlineAutoplayMaxBytes;
      final current = (small ? ref.watch(fileProvider(file.id)).value : ref.watch(_fileStateProvider(file.id)).value) ?? file;
      if (current.local.isDownloadingCompleted && current.local.path.isNotEmpty) {
        return GestureDetector(
          onTap: open,
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(child: LoopingVideo(key: ValueKey(current.local.path), path: current.local.path, fallback: preview)),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatDuration(Duration(seconds: duration)), style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                        const SizedBox(width: 4),
                        const Icon(Icons.volume_off_rounded, color: Colors.white, size: 15),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    return GestureDetector(
      onTap: open,
      child: Stack(
        alignment: Alignment.center,
        children: [
          preview,
          Container(
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            padding: const EdgeInsets.all(10),
            child: Icon(isGif ? Icons.gif_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 30),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Not on this device yet: the arrow says tapping downloads it (aka/Telegram pill).
                  if (!isGif && !(ref.watch(fileProvider(file.id)).value ?? file).local.isDownloadingCompleted)
                    const Padding(padding: EdgeInsets.only(right: 3), child: Icon(Icons.arrow_downward_rounded, size: 14, color: Colors.white)),
                  Text(
                    isGif ? 'GIF' : '${formatDuration(Duration(seconds: duration))}  ${formatFileSize(file.size == 0 ? file.expectedSize : file.size)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileView extends ConsumerWidget {
  const _FileView({required this.message, required this.file, required this.name, required this.icon, required this.mimeType});

  final td.Message message;
  final td.File file;
  final String name;
  final IconData icon;
  final String mimeType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final current = ref.watch(_fileStateProvider(file.id)).value ?? account.files[file.id] ?? file;
    final total = current.size == 0 ? current.expectedSize : current.size;
    final done = current.local.isDownloadingCompleted;
    final downloading = current.local.isDownloadingActive;
    final progress = total > 0 ? current.local.downloadedSize / total : null;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () async {
        if (done) {
          await openLocalFile(context, current.local.path, mimeType: mimeType);
        } else if (downloading) {
          account.cancelDownload(file.id);
        } else {
          // Registered in TDLib's download list so it appears (and can be paused) in Downloads.
          await account.addToDownloads(message, file.id, priority: 32).catchError((Object _) {});
          final path = await account.downloadFile(file.id, priority: 32);
          if (path != null && context.mounted) await openLocalFile(context, path, mimeType: mimeType);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircleAvatar(radius: 24, backgroundColor: primary, child: Icon(done ? icon : (downloading ? Icons.close_rounded : Icons.download_rounded), color: Colors.white)),
                  if (downloading) CircularProgressIndicator(value: progress, strokeWidth: 2.5, color: Colors.white),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? context.t('file') : name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    downloading ? '${formatFileSize(current.local.downloadedSize)} / ${formatFileSize(total)}' : formatFileSize(total),
                    style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// File state without triggering a download (unlike [fileProvider]).
final _fileStateProvider = StreamProvider.autoDispose.family<td.File, int>((ref, fileId) {
  return ref.watch(accountProvider).fileUpdates(fileId);
});

/// Big animated emoji; a tap plays Telegram's full-screen effect and tells the chat partner (ClickAnimatedEmojiMessage).
class _AnimatedEmojiView extends ConsumerWidget {
  const _AnimatedEmojiView({required this.message, required this.sticker});

  final td.Message message;
  final td.Sticker sticker;

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    td.Sticker? effect;
    try {
      effect = await ref.read(accountProvider).send<td.Sticker>(td.ClickAnimatedEmojiMessage(chatId: message.chatId, messageId: message.id));
    } on TdException {
      effect = null; // 404: this emoji has no effect.
    }
    if (effect == null || !context.mounted) return;
    await ref.read(accountProvider).send<td.File>(td.DownloadFile(fileId: effect.sticker.id, priority: 32, offset: 0, limit: 0, synchronous: true));
    if (!context.mounted) return;
    final shown = effect;
    final overlay = OverlayEntry(builder: (_) => IgnorePointer(child: Center(child: _StickerView(sticker: shown, size: 320, repeat: false))));
    Overlay.of(context).insert(overlay);
    await Future<void>.delayed(const Duration(seconds: 3));
    overlay.remove();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      GestureDetector(onTap: () => _play(context, ref), child: _StickerView(sticker: sticker, size: 120, tappable: false));
}

class _StickerView extends ConsumerWidget {
  const _StickerView({required this.sticker, this.size = 160, this.repeat = true, this.tappable = true});

  final td.Sticker sticker;
  final double size;
  final bool repeat;

  /// False when the parent handles taps (animated emoji), so the set sheet does not open.
  final bool tappable;

  Widget _fallback() {
    final thumb = sticker.thumbnail;
    if (thumb != null && thumb.format is! td.ThumbnailFormatTgs && thumb.format is! td.ThumbnailFormatWebm) {
      return TdImage(file: thumb.file, width: size, height: size, fit: BoxFit.contain);
    }
    return StickerOutlinePlaceholder(sticker: sticker, size: size);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = _content(ref);
    if (sticker.setId == 0 || !tappable) return content;
    return GestureDetector(onTap: () => showStickerSetSheet(context, sticker.setId), child: content);
  }

  Widget _content(WidgetRef ref) {
    final format = sticker.format;
    if (format is td.StickerFormatWebp) {
      return TdImage(file: sticker.sticker, width: size, height: size, fit: BoxFit.contain);
    }
    // WebM (VP9 with alpha) plays through ExoPlayer on Android; AVPlayer on iOS cannot decode it.
    if (format is td.StickerFormatWebm && !Platform.isAndroid) return _fallback();
    final file = ref.watch(fileProvider(sticker.sticker.id)).value ?? sticker.sticker;
    if (!file.local.isDownloadingCompleted || file.local.path.isEmpty) return _fallback();
    final path = file.local.path;
    // Power saving / animated stickers off: the first frame stands still.
    final animate = ref.watch(motionProvider.select((m) => m.stickers));
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: format is td.StickerFormatTgs
            ? Lottie.file(
                File(path),
                decoder: LottieComposition.decodeGZip,
                width: size,
                height: size,
                fit: BoxFit.contain,
                repeat: repeat,
                animate: animate,
                errorBuilder: (_, _, _) => _fallback(),
              )
            : LoopingVideo(key: ValueKey(animate), path: path, fallback: _fallback(), autoplay: animate),
      ),
    );
  }
}

/// Silent looping video (WebM stickers, GIF previews).
class LoopingVideo extends StatefulWidget {
  const LoopingVideo({super.key, required this.path, required this.fallback, this.autoplay = true});

  final String path;
  final Widget fallback;

  /// false: shows the first frame without playing.
  final bool autoplay;

  @override
  State<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends State<LoopingVideo> {
  late final VideoPlayerController _controller = VideoPlayerController.file(File(widget.path));
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      await _controller.setVolume(0);
      await _controller.setLooping(true);
      if (widget.autoplay) await _controller.play();
      if (mounted) setState(() => _ready = true);
    } on Object catch (error) {
      debugPrint('webm sticker failed: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return widget.fallback;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(width: _controller.value.size.width, height: _controller.value.size.height, child: VideoPlayer(_controller)),
    );
  }
}

class _LocationView extends StatelessWidget {
  const _LocationView({required this.latitude, required this.longitude, this.title, this.subtitle});

  final double latitude;
  final double longitude;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse('https://maps.google.com/?q=$latitude,$longitude'),
        mode: LaunchMode.externalApplication,
      ),
      child: SizedBox(
        width: 240,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(12), child: MapThumbnail(latitude: latitude, longitude: longitude)),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(
                children: [
                  Icon(Icons.location_on_rounded, color: primary, size: 20),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title ?? context.t('location'), style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          subtitle ?? '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}',
                          style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveLocationView extends ConsumerWidget {
  const _LiveLocationView({required this.message, required this.location, required this.expiresIn});

  final td.Message message;
  final td.LiveLocation location;
  final int expiresIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final live = expiresIn > 0;
    final remaining = Duration(seconds: expiresIn);
    return ValueListenableBuilder<int>(
      valueListenable: LiveLocationService.instance.revision,
      builder: (context, _, _) {
        final sharing = message.isOutgoing && live && LiveLocationService.instance.isSharing(message.chatId, message.id);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LocationView(
              latitude: location.location.latitude,
              longitude: location.location.longitude,
              title: s.t(live ? 'live_location' : 'live_location_ended'),
              subtitle: live
                  ? s.t('live_location_left', {'time': remaining.inHours > 0 ? '${remaining.inHours} h ${remaining.inMinutes % 60} min' : '${remaining.inMinutes} min'})
                  : null,
            ),
            if (sharing)
              TextButton.icon(
                onPressed: () => LiveLocationService.instance.stop(ref.read(accountProvider), message.chatId, message.id),
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(s.t('stop_sharing')),
              ),
          ],
        );
      },
    );
  }
}

class _ContactView extends ConsumerWidget {
  const _ContactView({required this.contact});

  final td.Contact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = '${contact.firstName} ${contact.lastName}'.trim();
    return InkWell(
      onTap: contact.userId == 0
          ? () => launchUrl(Uri(scheme: 'tel', path: contact.phoneNumber))
          : () async {
              final account = ref.read(accountProvider);
              final chat = await guard(context, () => account.openPrivateChat(contact.userId));
              if (chat != null && context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
                openChatFromContent(context, chat.id);
              }
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Avatar(name: name, seed: contact.userId, size: 44),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(contact.phoneNumber, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Hook set by the chat screen so content widgets can open chats without importing navigation.
void Function(BuildContext context, int chatId) openChatFromContent = (_, _) {};

class _CallView extends StatelessWidget {
  const _CallView({required this.isVideo, required this.duration, required this.outgoing});

  final bool isVideo;
  final int duration;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final missed = duration == 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t(isVideo ? 'video_call' : 'voice_call'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Row(children: [
              Icon(
                outgoing ? Icons.call_made_rounded : Icons.call_received_rounded,
                size: 14,
                color: missed ? Colors.redAccent : Colors.green,
              ),
              const SizedBox(width: 4),
              Text(
                missed ? s.t(outgoing ? 'call_cancelled' : 'call_missed') : formatDuration(Duration(seconds: duration)),
                style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
              ),
            ]),
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ voice notes

class VoiceNoteView extends ConsumerWidget {
  const VoiceNoteView({super.key, required this.message, required this.voiceNote});

  final td.Message message;
  final td.VoiceNote voiceNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final file = ref.watch(fileProvider(voiceNote.voice.id)).value ?? voiceNote.voice;
    final primary = Theme.of(context).colorScheme.primary;
    final samples = decodeWaveform(voiceNote.waveform);
    final playback = Playback.instance;
    final recognition = voiceNote.speechRecognitionResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<NowPlaying?>(
          valueListenable: playback.nowPlaying,
          builder: (context, now, _) {
            final isCurrent = now?.fileId == voiceNote.voice.id;
            return StreamBuilder<PlayerState>(
              stream: playback.player.playerStateStream,
              builder: (context, snapshot) {
                final playing = isCurrent && (snapshot.data?.playing ?? false) &&
                    snapshot.data?.processingState != ProcessingState.completed;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () async {
                        // just_audio has no Windows/Linux implementation: play in the system player there.
                        if (isDesktop && !Platform.isMacOS) {
                          final path = file.local.isDownloadingCompleted ? file.local.path : await account.downloadFile(file.id, priority: 32);
                          if (path != null && context.mounted) await openLocalFile(context, path, mimeType: voiceNote.mimeType);
                        } else {
                          await playback.playMessage(account, message, title: context.t('voice_message'));
                        }
                      },
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: primary,
                        child: file.local.isDownloadingActive
                            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
                      ),
                    ),
                    const SizedBox(width: 10),
                    StreamBuilder<Duration>(
                      stream: isCurrent ? playback.player.positionStream : const Stream.empty(),
                      builder: (context, position) {
                        final total = Duration(seconds: voiceNote.duration);
                        final elapsed = position.data ?? Duration.zero;
                        final fraction = isCurrent && total.inMilliseconds > 0 ? elapsed.inMilliseconds / total.inMilliseconds : 0.0;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CustomPaint(
                              size: const Size(150, 26),
                              painter: WaveformPainter(samples: samples, progress: fraction.clamp(0, 1), color: primary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              formatDuration(isCurrent && elapsed > Duration.zero ? elapsed : total),
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                            ),
                          ],
                        );
                      },
                    ),
                    if (isCurrent)
                      ValueListenableBuilder<double>(
                        valueListenable: playback.speed,
                        builder: (context, speed, _) => InkWell(
                          onTap: playback.cycleSpeed,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(border: Border.all(color: primary), borderRadius: BorderRadius.circular(8)),
                            child: Text('${speed == speed.roundToDouble() ? speed.toInt() : speed}x',
                                style: TextStyle(color: primary, fontSize: 11.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: context.t('speech_to_text'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.text_fields_rounded, color: primary, size: 20),
                      onPressed: recognition is td.SpeechRecognitionResultText
                          ? null
                          : () => guard(context, () => account.recognizeSpeech(message)),
                    ),
                  ],
                );
              },
            );
          },
        ),
        if (recognition is td.SpeechRecognitionResultText) ...[
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(recognition.text)),
          SpeechRatingRow(message: message),
        ]
        else if (recognition is td.SpeechRecognitionResultPending)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${recognition.partialText}…', style: TextStyle(color: Theme.of(context).hintColor)),
          )
        else if (recognition is td.SpeechRecognitionResultError)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(errorTextFromCode(context, recognition.error.message), style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
      ],
    );
  }
}

/// Music plays in-app through the shared [Playback] player, like Telegram, instead of opening an external app.
class _AudioView extends ConsumerWidget {
  const _AudioView({required this.message, required this.audio});

  final td.Message message;
  final td.Audio audio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final fileId = audio.audio.id;
    final file = ref.watch(_fileStateProvider(fileId)).value ?? account.files[fileId] ?? audio.audio;
    final downloading = file.local.isDownloadingActive;
    final total = file.size == 0 ? file.expectedSize : file.size;
    final primary = Theme.of(context).colorScheme.primary;
    final hintStyle = TextStyle(fontSize: 13, color: Theme.of(context).hintColor);
    final playback = Playback.instance;

    Future<void> onTap() async {
      if (downloading) {
        account.cancelDownload(fileId);
        return;
      }
      // just_audio has no Windows/Linux implementation: play in the system player there.
      if (isDesktop && !Platform.isMacOS) {
        final path = await account.downloadFile(fileId, priority: 32);
        if (path != null && context.mounted) await openLocalFile(context, path, mimeType: audio.mimeType);
      } else {
        await playback.playMessage(account, message);
      }
    }

    return ValueListenableBuilder<NowPlaying?>(
      valueListenable: playback.nowPlaying,
      builder: (context, now, _) {
        final isCurrent = now?.fileId == fileId;
        return StreamBuilder<PlayerState>(
          stream: playback.player.playerStateStream,
          builder: (context, state) {
            final playing = isCurrent && (state.data?.playing ?? false) && state.data?.processingState != ProcessingState.completed;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: onTap,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: primary,
                          child: Icon(downloading ? Icons.close_rounded : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded), color: Colors.white, size: 28),
                        ),
                        if (downloading)
                          CircularProgressIndicator(value: total > 0 ? file.local.downloadedSize / total : null, strokeWidth: 2.5, color: Colors.white),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: StreamBuilder<Duration>(
                    stream: isCurrent ? playback.player.positionStream : const Stream.empty(),
                    builder: (context, position) {
                      final elapsed = isCurrent ? position.data ?? Duration.zero : Duration.zero;
                      // Files sent by bots often carry no duration; fall back to what the player read from the file.
                      final duration = audio.duration > 0 ? Duration(seconds: audio.duration) : (isCurrent ? playback.player.duration : null) ?? Duration.zero;
                      final totalMs = duration.inMilliseconds;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(audio.title.ifEmpty(audio.fileName), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (audio.performer.isNotEmpty) Text(audio.performer, maxLines: 1, overflow: TextOverflow.ellipsis, style: hintStyle),
                          if (isCurrent && totalMs > 0)
                            SizedBox(
                              height: 22,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2.5,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                ),
                                child: Slider(
                                  value: elapsed.inMilliseconds.clamp(0, totalMs).toDouble(),
                                  max: totalMs.toDouble(),
                                  onChanged: (v) => playback.player.seek(Duration(milliseconds: v.round())),
                                ),
                              ),
                            ),
                          Text(
                            downloading
                                ? '${formatFileSize(file.local.downloadedSize)} / ${formatFileSize(total)}'
                                : isCurrent
                                    ? [formatDuration(elapsed), if (totalMs > 0) formatDuration(duration)].join(' / ')
                                    : [if (totalMs > 0) formatDuration(duration), formatFileSize(total)].join(' · '),
                            style: hintStyle,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String errorTextFromCode(BuildContext context, String code) {
  final s = context.s;
  final known = s.error(code);
  return known == s.t('err_GENERIC') ? code.replaceAll('_', ' ') : known;
}

class WaveformPainter extends CustomPainter {
  WaveformPainter({required this.samples, required this.progress, required this.color});

  final List<int> samples;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barWidth = 2.5;
    const gap = 1.5;
    final count = (size.width / (barWidth + gap)).floor();
    final data = samples.isEmpty ? List<int>.filled(count, 4) : samples;
    final played = Paint()..color = color;
    final rest = Paint()..color = color.withValues(alpha: 0.35);
    for (var i = 0; i < count; i++) {
      final sample = data[(i * data.length / count).floor().clamp(0, data.length - 1)];
      final height = max(2.0, size.height * sample / 31);
      final x = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - height) / 2, barWidth, height),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(rect, i / count <= progress ? played : rest);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) => old.progress != progress || old.samples != samples || old.color != color;
}

// ------------------------------------------------------------------ polls

class PollView extends ConsumerWidget {
  const PollView({super.key, required this.message, required this.poll, this.canAddOption = false});

  final td.Message message;
  final td.Poll poll;
  final bool canAddOption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final voted = poll.options.any((o) => o.isChosen);
    final showResults = voted || poll.isClosed;
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(poll.question.text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(
            s.t(poll.isClosed ? 'poll_closed' : (poll.isAnonymous ? 'poll_anonymous' : 'poll_public')),
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < poll.options.length; i++)
            InkWell(
              onTap: poll.isClosed
                  ? null
                  : () {
                      final option = poll.options[i];
                      final chosen = [for (var j = 0; j < poll.options.length; j++) if (poll.options[j].isChosen) j];
                      final next = option.isChosen
                          ? chosen.where((j) => j != i).toList()
                          : (poll.allowsMultipleAnswers ? [...chosen, i] : [i]);
                      guard(context, () => account.vote(message, next));
                    },
              onLongPress: () => showPollOptionMenu(context, account, message, poll.options[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (showResults)
                          SizedBox(
                            width: 40,
                            child: Text('${poll.options[i].votePercentage}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              poll.allowsMultipleAnswers ? Icons.check_box_outline_blank_rounded : Icons.radio_button_unchecked_rounded,
                              size: 20,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        Expanded(child: Text(poll.options[i].text.text)),
                        if (poll.options[i].isChosen) Icon(Icons.check_circle_rounded, size: 18, color: primary),
                      ],
                    ),
                    if (showResults)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: poll.options[i].votePercentage / 100,
                            minHeight: 4,
                            color: primary,
                            backgroundColor: primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text(s.count('votes', poll.totalVoterCount), style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor))),
            if (poll.canGetVoters && poll.totalVoterCount > 0)
              TextButton(onPressed: () => showPollVoters(context, account, message, poll), child: Text(s.t('poll_view_votes'))),
          ]),
          if (canAddOption && !poll.isClosed)
            TextButton.icon(
              onPressed: () => addPollOption(context, account, message),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(s.t('poll_add_option')),
            ),
        ],
      ),
    );
  }
}

extension ChatColorsFor on BuildContext {
  Color metaColor(bool outgoing) => outgoing ? chatColors.outgoingMeta : chatColors.incomingMeta;
}

// ------------------------------------------------------------------ invoices

String formatInvoiceAmount(int amount, String currency) {
  if (currency == 'XTR') return '$amount ⭐';
  // Telegram amounts are in the smallest currency unit; most currencies use two decimals.
  const zeroDecimal = {'JPY', 'KRW', 'UZS', 'VND', 'CLP', 'ISK', 'UGX', 'XAF', 'XOF'};
  final value = zeroDecimal.contains(currency) ? amount.toString() : (amount / 100).toStringAsFixed(2);
  return '$value $currency';
}

class InvoiceView extends ConsumerWidget {
  const InvoiceView({super.key, required this.message});

  final td.Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoice = message.content as td.MessageInvoice;
    final info = invoice.productInfo;
    final photo = info.photo;
    final size = photo == null ? null : bestPhotoSize(photo, target: 600);
    final hasBuyButton = switch (message.replyMarkup) {
      td.ReplyMarkupInlineKeyboard(:final rows) => rows.expand((r) => r).any((b) => b.type is td.InlineKeyboardButtonTypeBuy),
      _ => false,
    };
    final paid = invoice.receiptMessageId != 0;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (size != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TdImage(file: size.photo, minithumbnail: photo!.minithumbnail, width: 260, height: 160),
            ),
          const SizedBox(height: 6),
          Text(info.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
          if (info.description.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(info.description.text)),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                formatInvoiceAmount(invoice.totalAmount, invoice.currency),
                style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary),
              ),
              if (invoice.isTest) Text('  ${context.t('test_invoice')}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ],
          ),
          if (!hasBuyButton && !paid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton.tonal(
                onPressed: () => payInvoice(context, ref, message),
                child: Text(context.t('pay')),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ albums

/// Photos and videos of one media album laid out as a grid (2 side by side, 3 = 1 + 2, 4 = 2 x 2, more in rows of 3).
class AlbumGrid extends StatelessWidget {
  const AlbumGrid({super.key, required this.messages, required this.maxWidth});

  /// Oldest first.
  final List<td.Message> messages;
  final double maxWidth;

  static const _gap = 2.0;

  List<List<td.Message>> _rows() {
    final n = messages.length;
    if (n <= 2) return [messages];
    if (n == 3) return [messages.sublist(0, 1), messages.sublist(1)];
    if (n == 4) return [messages.sublist(0, 2), messages.sublist(2)];
    final rows = <List<td.Message>>[];
    var i = 0;
    // Rows of 3, but never leave a single item on the last row.
    while (i < n) {
      final remaining = n - i;
      final take = remaining == 4 ? 2 : min(3, remaining);
      rows.add(messages.sublist(i, i + take));
      i += take;
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final media = messages.where((m) => m.content is td.MessagePhoto || m.content is td.MessageVideo).toList();
    if (media.length != messages.length) {
      // Document / audio albums are a plain vertical list.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final m in messages) Padding(padding: const EdgeInsets.only(bottom: 4), child: MessageMedia(message: m, maxWidth: maxWidth))],
      );
    }
    final rows = _rows();
    return SizedBox(
      width: maxWidth,
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == rows.length - 1 ? 0 : _gap),
              child: Row(
                children: [
                  for (var c = 0; c < rows[r].length; c++) ...[
                    if (c > 0) const SizedBox(width: _gap),
                    Expanded(
                      child: SizedBox(
                        // Square cells; a lone wide cell (top of a 3-item album) is shorter.
                        height: rows[r].length == 1 ? maxWidth * 0.66 : maxWidth / rows[r].length,
                        child: _AlbumTile(message: rows[r][c]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.message});

  final td.Message message;

  @override
  Widget build(BuildContext context) {
    switch (message.content) {
      case td.MessagePhoto(:final photo):
        final size = bestPhotoSize(photo, target: 600);
        if (size == null) return const ColoredBox(color: Colors.black12);
        return GestureDetector(
          onTap: () => openMediaGallery(context, message),
          child: TdImage(file: size.photo, minithumbnail: photo.minithumbnail, fit: BoxFit.cover),
        );
      case td.MessageVideo(:final video):
        final thumb = video.thumbnail;
        return GestureDetector(
          onTap: () => openMediaGallery(context, message),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb != null && thumb.format is! td.ThumbnailFormatMpeg4)
                TdImage(file: thumb.file, minithumbnail: video.minithumbnail, fit: BoxFit.cover)
              else
                const ColoredBox(color: Colors.black26),
              const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 40)),
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                  child: Text(formatDuration(Duration(seconds: video.duration)), style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                ),
              ),
            ],
          ),
        );
      default:
        return const ColoredBox(color: Colors.black12);
    }
  }
}
