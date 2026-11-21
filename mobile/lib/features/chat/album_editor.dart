import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'message_content.dart' show bestPhotoSize;

/// The same, already uploaded photo/video as new input content (no re-upload), or null for other media.
td.InputMessageContent? reuseAlbumMedia(td.MessageContent content, td.FormattedText caption) => switch (content) {
      td.MessagePhoto(:final photo) when photo.sizes.isNotEmpty => td.InputMessagePhoto(
          photo: td.InputPhoto(
            photo: td.InputFileRemote(id: photo.sizes.last.photo.remote.id),
            thumbnail: null,
            video: null,
            addedStickerFileIds: const [],
            width: photo.sizes.last.width,
            height: photo.sizes.last.height,
          ),
          caption: caption,
          showCaptionAboveMedia: false,
          selfDestructType: null,
          hasSpoiler: false,
        ),
      td.MessageVideo(:final video) => td.InputMessageVideo(
          video: td.InputVideo(
            video: td.InputFileRemote(id: video.video.remote.id),
            thumbnail: null,
            cover: null,
            startTimestamp: 0,
            addedStickerFileIds: const [],
            duration: video.duration,
            width: video.width,
            height: video.height,
            supportsStreaming: video.supportsStreaming,
          ),
          caption: caption,
          showCaptionAboveMedia: false,
          selfDestructType: null,
          hasSpoiler: false,
        ),
      _ => null,
    };

/// One edit Telegram must make to turn the album into the new order: new media for a slot, a new caption, or a removal.
sealed class AlbumEdit {
  const AlbumEdit(this.messageId);
  final int messageId;
}

class AlbumMediaEdit extends AlbumEdit {
  const AlbumMediaEdit(super.messageId, this.source, this.caption);
  final td.Message source;
  final td.FormattedText caption;
}

class AlbumCaptionEdit extends AlbumEdit {
  const AlbumCaptionEdit(super.messageId, this.caption);
  final td.FormattedText caption;
}

class AlbumRemoval extends AlbumEdit {
  const AlbumRemoval(super.messageId);
}

/// Telegram can't reorder messages, so the album keeps its message slots (oldest first) and each slot gets the
/// media now placed there. [order] is the kept messages in their new order, [caption] the album caption (on the first).
List<AlbumEdit> planAlbumEdits(List<td.Message> album, List<td.Message> order, td.FormattedText caption) {
  const empty = td.FormattedText(text: '', entities: []);
  final slots = [...album]..sort((a, b) => a.id.compareTo(b.id));
  // The item that carried the album caption gives it up when it moves off the first slot.
  final holder = slots.where((m) => (captionOf(m.content)?.text ?? '').isNotEmpty).firstOrNull?.id;
  final edits = <AlbumEdit>[];
  for (var i = 0; i < slots.length; i++) {
    final slot = slots[i];
    if (i >= order.length) {
      edits.add(AlbumRemoval(slot.id));
      continue;
    }
    final source = order[i];
    final current = captionOf(slot.content) ?? empty;
    final wanted = i == 0 ? caption : (source.id == holder ? empty : captionOf(source.content) ?? empty);
    if (source.id != slot.id) {
      edits.add(AlbumMediaEdit(slot.id, source, wanted));
    } else if (wanted.text != current.text) {
      edits.add(AlbumCaptionEdit(slot.id, wanted));
    }
  }
  return edits;
}

/// "Edit album": drag to reorder, remove items, change the caption.
class AlbumEditorScreen extends ConsumerStatefulWidget {
  const AlbumEditorScreen({super.key, required this.album});

  final List<td.Message> album;

  @override
  ConsumerState<AlbumEditorScreen> createState() => _AlbumEditorScreenState();
}

class _AlbumEditorScreenState extends ConsumerState<AlbumEditorScreen> {
  late final List<td.Message> _items = [...widget.album]..sort((a, b) => a.id.compareTo(b.id));
  late final _caption = TextEditingController(
    text: markdownOf(widget.album.map((m) => captionOf(m.content)).firstWhere((c) => c != null && c.text.isNotEmpty, orElse: () => null) ??
        const td.FormattedText(text: '', entities: [])),
  );
  bool _saving = false;

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  List<AlbumEdit> get _edits => planAlbumEdits(widget.album, _items, formattedText(_caption.text.trim()));

  Future<void> _save() async {
    final account = ref.read(accountProvider);
    final edits = _edits;
    if (edits.isEmpty) return Navigator.pop(context);
    setState(() => _saving = true);
    final chatId = widget.album.first.chatId;
    final ok = await guard(context, () async {
      for (final edit in edits) {
        switch (edit) {
          case AlbumMediaEdit(:final messageId, :final source, :final caption):
            final content = reuseAlbumMedia(source.content, caption);
            if (content == null) continue;
            await account.send<td.Message>(td.EditMessageMedia(chatId: chatId, messageId: messageId, inputMessageContent: content));
          case AlbumCaptionEdit(:final messageId, :final caption):
            await account.send<td.Message>(
              td.EditMessageCaption(chatId: chatId, messageId: messageId, replyMarkup: null, caption: caption, showCaptionAboveMedia: false),
            );
          case AlbumRemoval():
            break;
        }
      }
      final removed = [for (final e in edits) if (e is AlbumRemoval) e.messageId];
      if (removed.isNotEmpty) await account.deleteMessages(chatId, removed, revoke: true);
      return true;
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok == true) {
      showToast(context, context.s.t('album_saved'));
      Navigator.pop(context);
    }
  }

  Widget _thumb(td.Message message) {
    final (file, mini) = switch (message.content) {
      td.MessagePhoto(:final photo) => (bestPhotoSize(photo, target: 320)?.photo, photo.minithumbnail),
      td.MessageVideo(:final video) => (video.thumbnail?.file, video.minithumbnail),
      _ => (null, null),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 64,
        child: file == null ? const ColoredBox(color: Colors.black12) : TdImage(file: file, minithumbnail: mini, width: 64, height: 64),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final changes = _edits.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('edit_album')),
        actions: [
          if (_saving)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            IconButton(tooltip: s.t('done'), icon: const Icon(Icons.check_rounded), onPressed: _items.isEmpty ? null : _save),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              changes == 0 ? s.t('edit_album_hint') : s.t('album_unsaved', {'n': '$changes'}),
              style: theme.textTheme.bodySmall?.copyWith(color: changes == 0 ? theme.hintColor : theme.colorScheme.primary),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: _items.length,
              onReorderItem: (from, to) => setState(() => _items.insert(to, _items.removeAt(from))),
              itemBuilder: (context, index) {
                final message = _items[index];
                return ListTile(
                  key: ValueKey(message.id),
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _thumb(message),
                      Positioned(
                        top: -4,
                        left: -4,
                        child: CircleAvatar(radius: 11, backgroundColor: theme.colorScheme.primary, child: Text('${index + 1}', style: const TextStyle(fontSize: 12, color: Colors.white))),
                      ),
                    ],
                  ),
                  title: Text(message.content is td.MessageVideo ? s.t('video') : s.t('photo')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: s.t('delete'),
                        icon: Icon(Icons.remove_circle_outline_rounded, color: theme.colorScheme.error),
                        // An album needs at least one item; deleting everything is the plain message delete.
                        onPressed: _items.length < 2 ? null : () => setState(() => _items.removeAt(index)),
                      ),
                      ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle_rounded)),
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                controller: _caption,
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: s.t('add_caption'), filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
