import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../state/telegram.dart';
import 'autosave.dart';
import 'tdlib/td_client.dart';

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

/// "Save to gallery": incoming photos and videos go to the gallery when the app's switch for the chat
/// kind is on, or when Telegram's own autosave rules (synced across devices, with per-chat exceptions) say so.
Future<void> autoSaveToGallery(TelegramAccount account, td.Message message, Set<String> kinds) async {
  if (message.isOutgoing) return;
  final chat = account.chats[message.chatId];
  if (chat == null || chat.type is td.ChatTypeSecret) return;
  final kind = account.isChannel(chat) ? 'channels' : (account.isGroup(chat) ? 'groups' : 'private');
  final telegramKind = switch (kind) {
    'channels' => AutosaveChatKind.channel,
    'groups' => AutosaveChatKind.group,
    _ => AutosaveChatKind.private,
  };
  final rule = kinds.contains(kind)
      ? const td.ScopeAutosaveSettings(autosavePhotos: true, autosaveVideos: true, maxVideoFileSize: autoSaveVideoLimit)
      : autosaveRuleFor(account.autosaveSettings, chat.id, telegramKind);
  final file = autosaveFileOf(message.content, rule);
  if (file == null) return;
  final isVideo = message.content is td.MessageVideo;
  // Only when access was granted earlier: never prompt from the background.
  if (!await Gal.hasAccess(toAlbum: true)) return;
  await saveToGallery(account, file, isVideo: isVideo);
}

/// Saves a downloaded photo or video into the system gallery (album "UZARO").
Future<SaveResult> saveToGallery(TelegramAccount account, td.File file, {required bool isVideo}) async {
  try {
    if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) return SaveResult.denied;
    var path = file.local.isDownloadingCompleted ? file.local.path : await account.downloadFile(file.id, priority: 32);
    // A file id from an older session (e.g. a kept copy of a deleted message) may be unknown now;
    // the remote id still identifies the file on Telegram's servers.
    if ((path == null || path.isEmpty) && file.remote.id.isNotEmpty) {
      try {
        final fresh = await account.send<td.File>(td.GetRemoteFile(remoteFileId: file.remote.id, fileType: null));
        path = await account.downloadFile(fresh.id, priority: 32);
      } on TdException catch (error) {
        debugPrint('remote file unavailable: $error');
      }
    }
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
