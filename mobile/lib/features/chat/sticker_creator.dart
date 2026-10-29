import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart';
import 'composer_panels.dart';

/// Telegram wants static stickers as PNG/WEBP whose longer side is exactly 512 px.
const _stickerSide = 512;

/// Target size that makes the longer side [_stickerSide], keeping the aspect ratio.
(int, int) stickerSize(int width, int height) {
  if (width >= height) return (_stickerSide, (height * _stickerSide / width).round().clamp(1, _stickerSide));
  return ((width * _stickerSide / height).round().clamp(1, _stickerSide), _stickerSide);
}

/// Picks an image and writes it as a 512 px PNG ready for upload; null when cancelled.
Future<String?> pickStickerImage() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;
  final bytes = await File(picked.path).readAsBytes();
  final probe = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
  final (width, height) = stickerSize(probe.image.width, probe.image.height);
  probe.image.dispose();
  final frame = await (await ui.instantiateImageCodec(bytes, targetWidth: width, targetHeight: height)).getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  if (png == null) return null;
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}sticker_${DateTime.now().microsecondsSinceEpoch}.png');
  await file.writeAsBytes(png.buffer.asUint8List());
  return file.path;
}

Future<td.NewSticker?> _newSticker(BuildContext context) async {
  final path = await pickStickerImage();
  if (path == null || !context.mounted) return null;
  final emoji = await promptText(context, title: context.t('sticker_emoji'), label: context.t('sticker_emoji_hint'), initial: '🙂');
  if (emoji == null || emoji.trim().isEmpty) return null;
  return td.NewSticker(
    sticker: td.InputFileLocal(path: path),
    format: const td.StickerFormatWebp(),
    emojis: emoji.trim(),
    maskPosition: null,
    keywords: const [],
  );
}

/// Sticker packs the user created: make a new one or open one to edit.
class MyStickerPacksScreen extends ConsumerStatefulWidget {
  const MyStickerPacksScreen({super.key});

  @override
  ConsumerState<MyStickerPacksScreen> createState() => _MyStickerPacksScreenState();
}

class _MyStickerPacksScreenState extends ConsumerState<MyStickerPacksScreen> {
  List<td.StickerSetInfo>? _sets;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await guard(context, () => ref.read(accountProvider).send<td.StickerSets>(const td.GetOwnedStickerSets(offsetStickerSetId: 0, limit: 100)));
    if (mounted) setState(() => _sets = result?.sets ?? const []);
  }

  Future<void> _create() async {
    final s = context.s;
    final account = ref.read(accountProvider);
    final title = await promptText(context, title: s.t('sticker_pack_new'), label: s.t('sticker_pack_title'));
    if (title == null || title.trim().isEmpty || !mounted) return;
    final suggested = await guard(context, () => account.send<td.Text>(td.GetSuggestedStickerSetName(title: title.trim())));
    if (!mounted) return;
    final name = await promptText(context, title: s.t('sticker_pack_link'), label: 't.me/addstickers/…', initial: suggested?.text ?? '');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final check = await guard(context, () => account.send<td.CheckStickerSetNameResult>(td.CheckStickerSetName(name: name.trim())));
    if (check == null || !mounted) return;
    if (check is! td.CheckStickerSetNameResultOk) {
      showToast(context, s.t(check is td.CheckStickerSetNameResultNameOccupied ? 'sticker_pack_name_taken' : 'sticker_pack_name_invalid'));
      return;
    }
    final sticker = await _newSticker(context);
    if (sticker == null || !mounted) return;
    final set = await guard(
      context,
      () => account.send<td.StickerSet>(td.CreateNewStickerSet(
        userId: account.myId,
        title: title.trim(),
        name: name.trim(),
        stickerType: const td.StickerTypeRegular(),
        needsRepainting: false,
        stickers: [sticker],
        source: '',
      )),
    );
    if (set == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OwnedStickerSetScreen(setId: set.id)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final sets = _sets;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('sticker_packs_mine'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_rounded), label: Text(s.t('sticker_pack_new'))),
      body: sets == null
          ? const Center(child: CircularProgressIndicator())
          : sets.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t('sticker_packs_empty'), textAlign: TextAlign.center)))
              : ListView(children: [
                  for (final set in sets)
                    ListTile(
                      leading: SizedBox.square(dimension: 44, child: set.covers.isEmpty ? const Icon(Icons.emoji_emotions_outlined) : StickerThumb(sticker: set.covers.first)),
                      title: Text(set.title),
                      subtitle: Text(s.count('stickers_count', set.size)),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OwnedStickerSetScreen(setId: set.id)));
                        await _load();
                      },
                    ),
                ]),
    );
  }
}

/// One owned pack: add, re-emoji, move or remove stickers; rename, share or delete the pack.
class OwnedStickerSetScreen extends ConsumerStatefulWidget {
  const OwnedStickerSetScreen({super.key, required this.setId});

  final int setId;

  @override
  ConsumerState<OwnedStickerSetScreen> createState() => _OwnedStickerSetScreenState();
}

class _OwnedStickerSetScreenState extends ConsumerState<OwnedStickerSetScreen> {
  td.StickerSet? _set;

  TelegramAccount get _account => ref.read(accountProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final set = await guard(context, () => _account.send<td.StickerSet>(td.GetStickerSet(setId: widget.setId)));
    if (mounted) setState(() => _set = set);
  }

  Future<void> _run(Future<void> Function() action) async {
    await guard(context, () async {
      await action();
      return true;
    });
    await _load();
  }

  Future<void> _add(td.StickerSet set) async {
    final sticker = await _newSticker(context);
    if (sticker == null || !mounted) return;
    await _run(() => _account.send<td.Ok>(td.AddStickerToSet(userId: _account.myId, name: set.name, sticker: sticker)));
  }

  Future<void> _stickerMenu(td.Sticker sticker) async {
    final s = context.s;
    final file = td.InputFileRemote(id: sticker.sticker.remote.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.emoji_emotions_outlined), title: Text(s.t('sticker_emoji')), onTap: () => Navigator.pop(context, 'emoji')),
          ListTile(leading: const Icon(Icons.vertical_align_top_rounded), title: Text(s.t('sticker_move_first')), onTap: () => Navigator.pop(context, 'first')),
          ListTile(leading: const Icon(Icons.sell_outlined), title: Text(s.t('sticker_keywords')), onTap: () => Navigator.pop(context, 'keywords')),
          ListTile(leading: const Icon(Icons.find_replace_rounded), title: Text(s.t('sticker_replace')), onTap: () => Navigator.pop(context, 'replace')),
          ListTile(leading: const Icon(Icons.photo_size_select_actual_outlined), title: Text(s.t('sticker_set_cover')), onTap: () => Navigator.pop(context, 'cover')),
          ListTile(leading: const Icon(Icons.info_outline_rounded), title: Text(s.t('sticker_emojis_all')), onTap: () => Navigator.pop(context, 'emojis')),
          if (_set?.stickerType is td.StickerTypeMask)
            ListTile(leading: const Icon(Icons.face_retouching_natural_rounded), title: Text(s.t('sticker_mask_position')), onTap: () => Navigator.pop(context, 'mask')),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
            title: Text(s.t('delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'emoji':
        final emoji = await promptText(context, title: s.t('sticker_emoji'), label: s.t('sticker_emoji_hint'), initial: sticker.emoji);
        if (emoji != null && emoji.trim().isNotEmpty) await _run(() => _account.send<td.Ok>(td.SetStickerEmojis(sticker: file, emojis: emoji.trim())));
      case 'first':
        await _run(() => _account.send<td.Ok>(td.SetStickerPositionInSet(sticker: file, position: 0)));
      case 'keywords':
        final text = await promptText(context, title: s.t('sticker_keywords'), label: s.t('sticker_keywords_hint'));
        if (text == null) return;
        final keywords = [for (final k in text.split(',')) if (k.trim().isNotEmpty) k.trim()];
        await _run(() => _account.send<td.Ok>(td.SetStickerKeywords(sticker: file, keywords: keywords)));
      case 'replace':
        await _replace(sticker, file);
      case 'cover':
        final set = _set;
        if (set == null) return;
        await _run(() => switch (sticker.fullType) {
              td.StickerFullTypeCustomEmoji(:final customEmojiId) =>
                _account.send<td.Ok>(td.SetCustomEmojiStickerSetThumbnail(name: set.name, customEmojiId: customEmojiId)),
              _ => _account.send<td.Ok>(td.SetStickerSetThumbnail(userId: _account.myId, name: set.name, thumbnail: file, format: sticker.format)),
            });
      case 'emojis':
        final emojis = await guard(context, () => _account.send<td.Emojis>(td.GetStickerEmojis(sticker: file)));
        if (emojis != null && mounted) showToast(context, emojis.emojis.isEmpty ? sticker.emoji : emojis.emojis.join(' '));
      case 'mask':
        final point = await pickOption<String>(context, s.t('sticker_mask_position'), {
          'forehead': s.t('mask_forehead'),
          'eyes': s.t('mask_eyes'),
          'mouth': s.t('mask_mouth'),
          'chin': s.t('mask_chin'),
        }, null);
        if (point == null || !mounted) return;
        final td.MaskPoint maskPoint = switch (point) {
          'eyes' => const td.MaskPointEyes(),
          'mouth' => const td.MaskPointMouth(),
          'chin' => const td.MaskPointChin(),
          _ => const td.MaskPointForehead(),
        };
        await _run(() => _account.send<td.Ok>(td.SetStickerMaskPosition(
              sticker: file,
              maskPosition: td.MaskPosition(point: maskPoint, xShift: 0, yShift: 0, scale: 1),
            )));
      case 'delete':
        final ok = await confirm(context, title: s.t('delete'), message: s.t('sticker_delete_hint'), destructive: true);
        if (ok) await _run(() => _account.send<td.Ok>(td.RemoveStickerFromSet(sticker: file)));
    }
  }

  /// Swaps a sticker's picture while keeping its place and emoji: upload the new file, then replace in the set.
  Future<void> _replace(td.Sticker sticker, td.InputFile old) async {
    final set = _set;
    final path = await pickStickerImage();
    if (set == null || path == null || !mounted) return;
    await _run(() async {
      final uploaded = await _account.send<td.File>(
        td.UploadStickerFile(userId: _account.myId, stickerFormat: const td.StickerFormatWebp(), sticker: td.InputFileLocal(path: path)),
      );
      await _account.send<td.Ok>(td.ReplaceStickerInSet(
        userId: _account.myId,
        name: set.name,
        oldSticker: old,
        newSticker: td.NewSticker(
          sticker: td.InputFileRemote(id: uploaded.remote.id),
          format: const td.StickerFormatWebp(),
          emojis: sticker.emoji,
          maskPosition: null,
          keywords: const [],
        ),
      ));
    });
  }

  Future<void> _setMenu(String action, td.StickerSet set) async {
    final s = context.s;
    switch (action) {
      case 'cover_reset':
        await _run(() => _account.send<td.Ok>(td.SetStickerSetThumbnail(userId: _account.myId, name: set.name, thumbnail: null, format: null)));
      case 'rename':
        final title = await promptText(context, title: s.t('rename'), label: s.t('sticker_pack_title'), initial: set.title);
        if (title != null && title.trim().isNotEmpty) await _run(() => _account.send<td.Ok>(td.SetStickerSetTitle(name: set.name, title: title.trim())));
      case 'share':
        await SharePlus.instance.share(ShareParams(text: 'https://t.me/addstickers/${set.name}'));
      case 'delete':
        final ok = await confirm(context, title: s.t('sticker_pack_delete'), message: set.title, destructive: true);
        if (!ok || !mounted) return;
        final done = await guard(context, () async {
          await _account.send<td.Ok>(td.DeleteStickerSet(name: set.name));
          return true;
        });
        if (done == true && mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final set = _set;
    return Scaffold(
      appBar: AppBar(
        title: Text(set?.title ?? ''),
        actions: [
          if (set != null)
            PopupMenuButton<String>(
              onSelected: (action) => _setMenu(action, set),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Text(s.t('rename'))),
                PopupMenuItem(value: 'share', child: Text(s.t('share'))),
                PopupMenuItem(value: 'cover_reset', child: Text(s.t('sticker_set_cover_reset'))),
                PopupMenuItem(value: 'delete', child: Text(s.t('sticker_pack_delete'))),
              ],
            ),
        ],
      ),
      floatingActionButton: set == null ? null : FloatingActionButton(onPressed: () => _add(set), child: const Icon(Icons.add_photo_alternate_rounded)),
      body: set == null
          ? const Center(child: CircularProgressIndicator())
          : GridView.count(
              crossAxisCount: 4,
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final sticker in set.stickers)
                  InkWell(borderRadius: BorderRadius.circular(8), onTap: () => _stickerMenu(sticker), child: StickerThumb(sticker: sticker)),
              ],
            ),
    );
  }
}
