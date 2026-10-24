import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../state/telegram.dart';

enum SaveResult { saved, denied, failed }

/// Asks for gallery access if needed; true when granted.
Future<bool> ensureGalleryAccess() async {
  try {
    return await Gal.hasAccess(toAlbum: true) || await Gal.requestAccess(toAlbum: true);
  } on GalException catch (error) {
    debugPrint('gallery access failed: ${error.type}');
    return false;
  }
}

/// Videos bigger than this are not auto-saved (they would be downloaded only for the gallery).
const autoSaveVideoLimit = 50 * 1024 * 1024;

/// "Save to gallery" setting: incoming photos and videos of the chosen chat kinds go to the gallery.
Future<void> autoSaveToGallery(TelegramAccount account, td.Message message, Set<String> kinds) async {
  if (kinds.isEmpty || message.isOutgoing) return;
  final chat = account.chats[message.chatId];
  if (chat == null) return;
  final kind = account.isChannel(chat) ? 'channels' : (account.isGroup(chat) ? 'groups' : 'private');
  if (!kinds.contains(kind)) return;
  final (file, isVideo) = switch (message.content) {
    td.MessagePhoto(:final photo) when photo.sizes.isNotEmpty => (photo.sizes.last.photo, false),
    td.MessageVideo(:final video) => (video.video, true),
    _ => (null, false),
  };
  if (file == null) return;
  final size = file.size == 0 ? file.expectedSize : file.size;
  if (isVideo && size > autoSaveVideoLimit) return;
  // Only when access was granted earlier: never prompt from the background.
  if (!await Gal.hasAccess(toAlbum: true)) return;
  await saveToGallery(account, file, isVideo: isVideo);
}

/// Saves a downloaded photo or video into the system gallery (album "UZARO").
Future<SaveResult> saveToGallery(TelegramAccount account, td.File file, {required bool isVideo}) async {
  try {
    if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) return SaveResult.denied;
    final path = file.local.isDownloadingCompleted ? file.local.path : await account.downloadFile(file.id, priority: 32);
    if (path == null || path.isEmpty) return SaveResult.failed;
    if (isVideo) {
      await Gal.putVideo(path, album: 'UZARO');
    } else {
      await Gal.putImage(path, album: 'UZARO');
    }
    return SaveResult.saved;
  } on GalException catch (error) {
    debugPrint('save to gallery failed: ${error.type}');
    return error.type == GalExceptionType.accessDenied ? SaveResult.denied : SaveResult.failed;
  }
}
