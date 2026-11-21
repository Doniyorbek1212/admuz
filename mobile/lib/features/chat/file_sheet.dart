import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

/// Where [pickDocument] sends the user for a new file: the system file browser, the in-app gallery
/// (photos and videos sent as files, without compression) or the audio picker.
enum FileSource { device, galleryFiles, music }

/// Telegram's file tab: ways to pick a new file on top, the files sent recently below to resend at once.
/// Pops a [FileSource] or a recently sent [td.Document]; null when dismissed.
Future<Object?> pickDocument(BuildContext context, TelegramAccount account) => showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _FileSheet(account: account),
    );

class _FileSheet extends StatefulWidget {
  const _FileSheet({required this.account});

  final TelegramAccount account;

  @override
  State<_FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends State<_FileSheet> {
  // The sheet opens at once; recent files fill in when TDLib answers.
  late final Future<List<td.Message>> _recent = _loadRecent();

  Future<List<td.Message>> _loadRecent() async {
    try {
      final found = await widget.account.send<td.FoundMessages>(const td.SearchOutgoingDocumentMessages(query: '', limit: 30));
      return [for (final m in found.messages) if (m.content is td.MessageDocument) m];
    } on TdException catch (error) {
      debugPrint('recent documents failed: $error');
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: FutureBuilder<List<td.Message>>(
          future: _recent,
          builder: (context, snapshot) {
            final recent = snapshot.data ?? const <td.Message>[];
            return ListView(shrinkWrap: true, children: [
              _source(Icons.folder_rounded, const Color(0xFF3E88F7), s.t('files_device'), s.t('files_device_sub'), FileSource.device),
              _source(Icons.photo_rounded, const Color(0xFF34C759), s.t('gallery'), s.t('files_gallery_sub'), FileSource.galleryFiles),
              _source(Icons.headphones_rounded, const Color(0xFFFF9500), s.t('music'), s.t('files_music_sub'), FileSource.music),
              if (snapshot.connectionState != ConnectionState.done)
                const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)))
              else if (recent.isNotEmpty) ...[
                SectionHeader(s.t('recent_files')),
                for (final message in recent) _recentTile(message, s),
              ],
            ]);
          },
        ),
      ),
    );
  }

  Widget _source(IconData icon, Color color, String title, String subtitle, FileSource source) => ListTile(
        leading: CircleAvatar(radius: 22, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 22)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        onTap: () => Navigator.pop(context, source),
      );

  Widget _recentTile(td.Message message, Strings s) {
    final document = (message.content as td.MessageDocument).document;
    final name = document.fileName.isEmpty ? s.t('file') : document.fileName;
    return ListTile(
      leading: FileTypeBadge(fileName: document.fileName),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${formatFileSize(document.document.size)} · ${formatChatTime(message.date, s.locale)}'),
      onTap: () => Navigator.pop(context, document),
    );
  }
}

/// A rounded square in the file kind's colour with its extension, like Telegram's document icons.
class FileTypeBadge extends StatelessWidget {
  const FileTypeBadge({super.key, required this.fileName, this.size = 44});

  final String fileName;
  final double size;

  static const _kinds = <(Color, Set<String>)>[
    (Color(0xFFE5484D), {'pdf'}),
    (Color(0xFF3E88F7), {'doc', 'docx', 'txt', 'rtf', 'odt', 'md'}),
    (Color(0xFF34A853), {'xls', 'xlsx', 'csv', 'ods', 'apk'}),
    (Color(0xFFFF9500), {'zip', 'rar', '7z', 'tar', 'gz', 'ppt', 'pptx'}),
    (Color(0xFFAF52DE), {'mp3', 'm4a', 'ogg', 'opus', 'wav', 'flac', 'aac'}),
    (Color(0xFFFF4D8D), {'mp4', 'mov', 'mkv', 'avi', 'webm', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}),
  ];

  @override
  Widget build(BuildContext context) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot < 0 || dot == fileName.length - 1 ? '' : fileName.substring(dot + 1).toLowerCase();
    final color = _kinds.where((k) => k.$2.contains(ext)).firstOrNull?.$1 ?? const Color(0xFF8E8E93);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.24)),
      child: ext.isEmpty || ext.length > 4
          ? Icon(Icons.insert_drive_file_rounded, color: Colors.white, size: size * 0.5)
          : Text(ext.toUpperCase(), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.27)),
    );
  }
}
