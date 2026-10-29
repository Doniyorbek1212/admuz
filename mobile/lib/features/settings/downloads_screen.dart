import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

final _downloadFileProvider = StreamProvider.autoDispose.family<td.File, int>((ref, fileId) {
  return ref.watch(accountProvider).fileUpdates(fileId);
});

/// Files downloaded from chats (TDLib download list): progress, pause/resume, open, remove.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  List<td.FileDownload>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final found = await ref.read(accountProvider).fileDownloads();
      if (mounted) setState(() => _items = found.files);
    } on TdException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _clear() async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('downloads_clear'), message: s.t('downloads_clear_confirm'), destructive: true);
    if (!ok || !mounted) return;
    await guard(context, () => ref.read(accountProvider).clearDownloads(deleteFiles: true));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        leading: panelCloseButton(context),
        title: Text(s.t('downloads')),
        actions: [
          if (items != null && items.any((i) => i.completeDate == 0)) ...[
            IconButton(
              tooltip: s.t('downloads_pause_all'),
              icon: const Icon(Icons.pause_circle_outline_rounded),
              onPressed: () async {
                await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ToggleAllDownloadsArePaused(arePaused: true)));
                await _load();
              },
            ),
            IconButton(
              tooltip: s.t('downloads_resume_all'),
              icon: const Icon(Icons.play_circle_outline_rounded),
              onPressed: () async {
                await guard(context, () => ref.read(accountProvider).send<td.Ok>(const td.ToggleAllDownloadsArePaused(arePaused: false)));
                await _load();
              },
            ),
          ],
          if (items != null && items.isNotEmpty)
            IconButton(tooltip: s.t('downloads_clear'), icon: const Icon(Icons.delete_sweep_rounded), onPressed: _clear),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? EmptyState(icon: Icons.download_rounded, title: s.t('downloads_empty'), subtitle: '')
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                        itemBuilder: (context, index) => _DownloadTile(item: items[index], onChanged: _load),
                      ),
                    ),
    );
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.item, required this.onChanged});

  final td.FileDownload item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final file = ref.watch(_downloadFileProvider(item.fileId)).value ?? account.files[item.fileId];
    final total = file == null ? 0 : (file.size == 0 ? file.expectedSize : file.size);
    final done = file?.local.isDownloadingCompleted ?? item.completeDate > 0;
    final active = file?.local.isDownloadingActive ?? false;
    final progress = file != null && total > 0 ? file.local.downloadedSize / total : null;
    final chat = account.chats[item.message.chatId];
    final name = switch (item.message.content) {
      td.MessageDocument(:final document) => document.fileName,
      td.MessageAudio(:final audio) => audio.title.isNotEmpty ? audio.title : audio.fileName,
      td.MessageVideo(:final video) => video.fileName,
      _ => messagePreview(item.message, account, s),
    };
    final primary = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: primary.withValues(alpha: 0.15),
        child: Icon(done ? Icons.insert_drive_file_rounded : (active ? Icons.downloading_rounded : Icons.pause_rounded), color: primary),
      ),
      title: Text(name.isEmpty ? s.t('file') : name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [chat?.title ?? '', if (total > 0) formatFileSize(total)].where((p) => p.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (!done) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: progress, minHeight: 3)),
          if (!done && file != null && file.local.downloadedPrefixSize > 0)
            _PlayableNow(fileId: file.id),
        ],
      ),
      onTap: done && file != null ? () => openLocalFile(context, file.local.path) : null,
      trailing: PopupMenuButton<String>(
        onSelected: (action) async {
          switch (action) {
            case 'pause':
              await guard(context, () => account.setDownloadPaused(item.fileId, true));
            case 'resume':
              await guard(context, () => account.setDownloadPaused(item.fileId, false));
            case 'remove':
              await guard(context, () => account.removeDownload(item.fileId, deleteFile: true));
            case 'share':
              await shareDownloadedFile(context, account, item.fileId);
          }
          onChanged();
        },
        itemBuilder: (context) => [
          if (!done && !item.isPaused) PopupMenuItem(value: 'pause', child: Text(s.t('pause'))),
          if (!done && item.isPaused) PopupMenuItem(value: 'resume', child: Text(s.t('resume'))),
          if (done) PopupMenuItem(value: 'share', child: Text(s.t('share'))),
          PopupMenuItem(value: 'remove', child: Text(s.t('delete'))),
        ],
      ),
    );
  }
}

/// How much of a partly downloaded file can already be played from the start (TDLib's downloaded prefix).
class _PlayableNow extends ConsumerWidget {
  const _PlayableNow({required this.fileId});

  final int fileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefix = ref.watch(_prefixProvider(fileId)).value ?? 0;
    if (prefix <= 0) return const SizedBox.shrink();
    return Text(context.t('download_playable', {'size': formatFileSize(prefix)}), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor));
  }
}

final _prefixProvider = FutureProvider.autoDispose.family<int, int>((ref, fileId) async {
  try {
    return (await ref.watch(accountProvider).send<td.FileDownloadedPrefixSize>(td.GetFileDownloadedPrefixSize(fileId: fileId, offset: 0))).size;
  } on TdException {
    return 0;
  }
});

/// Shares a downloaded file under a clean, readable name (TDLib's suggested name, with an extension).
Future<void> shareDownloadedFile(BuildContext context, TelegramAccount account, int fileId) async {
  final file = await guard(context, () => account.send<td.File>(td.GetFile(fileId: fileId)));
  if (file == null || !file.local.isDownloadingCompleted || !context.mounted) return;
  final temp = await getTemporaryDirectory();
  if (!context.mounted) return;
  final name = await guard(context, () => account.send<td.Text>(td.GetSuggestedFileName(fileId: fileId, directory: temp.path)));
  var clean = name?.text ?? '';
  if (clean.isEmpty) clean = TdClient.executeStatic(td.CleanFileName(fileName: file.local.path))?['text'] as String? ?? '';
  if (clean.isEmpty) return;
  if (!clean.contains('.')) {
    final mime = TdClient.executeStatic(td.GetFileMimeType(fileName: file.local.path))?['text'] as String? ?? '';
    final ext = mime.isEmpty ? '' : TdClient.executeStatic(td.GetFileExtension(mimeType: mime))?['text'] as String? ?? '';
    if (ext.isNotEmpty) clean = '$clean.$ext';
  }
  final copy = File('${temp.path}${Platform.pathSeparator}$clean');
  await File(file.local.path).copy(copy.path);
  await SharePlus.instance.share(ShareParams(files: [XFile(copy.path)]));
}
