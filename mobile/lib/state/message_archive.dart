import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:tdlib_ex/td_api.dart' as td;

/// An earlier version of an edited message: its content and when that version was current from.
typedef MessageVersion = ({td.MessageContent content, int date});

/// Local copies of messages other people deleted and of earlier versions of edited messages.
///
/// Telegram removes both everywhere, so copies are taken from messages this device has already seen
/// and kept on this device only (one JSON file per account, next to its TDLib database).
class MessageArchive {
  MessageArchive(this._path);

  final String _path;
  bool keepDeleted = true;
  bool keepEdits = true;

  /// Recently seen messages, oldest first: the source the copies are taken from.
  final Map<String, td.Message> _recent = {};

  /// Text of messages seen before, kept across restarts: an edit made while the app was closed (or the message
  /// was not loaded) is noticed when the message shows up again with a newer text.
  final Map<String, ({String text, int date})> _seenTexts = {};
  Timer? _seenSaveTimer;
  String get _seenPath => '$_path.texts';
  final Map<String, td.Message> _deleted = {};
  final Map<String, List<MessageVersion>> _edits = {};

  /// Deletions this user asked for; those are not archived.
  final Set<String> _ownDeletes = {};
  final Map<int, DateTime> _clearedChats = {};
  Timer? _saveTimer;

  /// Bumped whenever the deleted or edited copies change.
  final revision = ValueNotifier<int>(0);

  static const _recentLimit = 5000;
  static const _storedLimit = 3000;
  static const _seenLimit = 5000;
  static const _seenSaveDelay = Duration(seconds: 15);

  static String _key(int chatId, int messageId) => '$chatId:$messageId';

  bool isDeleted(int chatId, int messageId) => keepDeleted && _deleted.containsKey(_key(chatId, messageId));

  List<td.Message> deletedIn(int chatId) =>
      keepDeleted ? [for (final message in _deleted.values) if (message.chatId == chatId) message] : const [];

  /// Earlier versions of a message, oldest first.
  List<MessageVersion> versionsOf(int chatId, int messageId) =>
      keepEdits ? _edits[_key(chatId, messageId)] ?? const [] : const [];

  void remember(td.Message message) {
    final key = _key(message.chatId, message.id);
    final text = _textOf(message.content);
    final seen = _seenTexts[key];
    // Edited since this device last saw it, and the change never arrived as an update: keep the text it saw.
    if (keepEdits && text != null && seen != null && seen.text != text && message.editDate > 0 && _recent[key] == null) {
      _addVersion(key, _plainText(seen.text), seen.date);
    }
    _recent
      ..remove(key)
      ..[key] = message;
    if (_recent.length > _recentLimit) _recent.remove(_recent.keys.first);
    if (text != null) _rememberText(key, text, message.editDate > 0 ? message.editDate : message.date);
  }

  void _rememberText(String key, String text, int date) {
    if (!keepEdits || _seenTexts[key]?.text == text) return;
    _seenTexts
      ..remove(key)
      ..[key] = (text: text, date: date);
    if (_seenTexts.length > _seenLimit) _seenTexts.remove(_seenTexts.keys.first);
    _seenSaveTimer?.cancel();
    _seenSaveTimer = Timer(_seenSaveDelay, () => unawaited(_saveSeen()));
  }

  void _addVersion(String key, td.MessageContent content, int date) {
    final versions = _edits.putIfAbsent(key, () => []);
    // The same old text can be noticed twice (an update, then a reload): keep one copy.
    if (versions.isNotEmpty && _textOf(versions.last.content) == _textOf(content)) return;
    versions.add((content: content, date: date));
    _changed();
  }

  void rememberAll(Iterable<td.Message> messages) => messages.forEach(remember);

  void onSendSucceeded(td.Message message, int oldMessageId) {
    _recent.remove(_key(message.chatId, oldMessageId));
    remember(message);
  }

  void onContentChanged(int chatId, int messageId, td.MessageContent content) {
    final key = _key(chatId, messageId);
    final old = _recent[key];
    final newText = _textOf(content);
    final seen = _seenTexts[key];
    if (old != null) _recent[key] = old.copyWith(content: content);
    // Polls, live locations and the like change content without an edit; only text changes are versions.
    // Not loaded this run, the text seen in an earlier one is the version that was replaced.
    final oldText = old == null ? seen?.text : _textOf(old.content);
    final oldDate = old == null ? seen?.date : (old.editDate > 0 ? old.editDate : old.date);
    if (keepEdits && newText != null && oldText != null && oldDate != null && oldText != newText) {
      _addVersion(key, old?.content ?? _plainText(oldText), oldDate);
    }
    if (newText != null) _rememberText(key, newText, DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  void onEdited(int chatId, int messageId, int editDate) {
    final key = _key(chatId, messageId);
    final old = _recent[key];
    if (old != null) _recent[key] = old.copyWith(editDate: editDate);
  }

  /// Call before deleting messages yourself, so they are not kept as "deleted by someone else".
  void markOwnDelete(int chatId, Iterable<int> messageIds) => _ownDeletes.addAll(messageIds.map((id) => _key(chatId, id)));

  /// Call before clearing a chat's history yourself: drops its copies and ignores the deletions that follow.
  void markChatCleared(int chatId) {
    _clearedChats[chatId] = DateTime.now();
    final prefix = '$chatId:';
    _deleted.removeWhere((key, _) => key.startsWith(prefix));
    _edits.removeWhere((key, _) => key.startsWith(prefix));
    _seenTexts.removeWhere((key, _) => key.startsWith(prefix));
    _changed();
  }

  void onDeleted(int chatId, List<int> messageIds) {
    final cleared = _clearedChats[chatId];
    // shortcut: a fixed window after clearing, upgrade if TDLib ever reports who deleted a message.
    final selfCleared = cleared != null && DateTime.now().difference(cleared) < const Duration(seconds: 30);
    var changed = false;
    for (final id in messageIds) {
      final key = _key(chatId, id);
      final message = _recent.remove(key);
      _seenTexts.remove(key);
      if (_ownDeletes.remove(key) || selfCleared) {
        changed |= _deleted.remove(key) != null;
        changed |= _edits.remove(key) != null;
        continue;
      }
      if (message == null || message.isOutgoing || !keepDeleted) continue;
      _deleted[key] = message;
      changed = true;
    }
    if (changed) _changed();
  }

  /// Removes one kept copy (the user dismissed it).
  void forget(int chatId, int messageId) {
    final key = _key(chatId, messageId);
    final hadDeleted = _deleted.remove(key) != null;
    final hadEdits = _edits.remove(key) != null;
    if (hadDeleted || hadEdits) _changed();
  }

  void clear() {
    _deleted.clear();
    _edits.clear();
    _seenTexts.clear();
    _changed();
    unawaited(_saveSeen());
  }

  int get deletedCount => _deleted.length;
  int get editedCount => _edits.length;

  void _changed() {
    revision.value++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(save()));
  }

  Future<void> load() async {
    try {
      if (!await File(_path).exists()) return;
      final (deleted, edits) = await _read(_path);
      _deleted.addAll(deleted);
      _edits.addAll(edits);
      revision.value++;
    } on Object catch (error) {
      debugPrint('message archive unreadable: $error');
    }
    try {
      if (await File(_seenPath).exists()) _seenTexts.addAll(await _readSeen(_seenPath));
    } on Object catch (error) {
      debugPrint('seen message texts unreadable: $error');
    }
  }

  static Future<Map<String, ({String text, int date})>> _readSeen(String path) => Isolate.run(() => {
        for (final MapEntry(:key, :value) in (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>).entries)
          if (value case [final String text, final int date]) key: (text: text, date: date),
      });

  Future<void> _saveSeen() async {
    _seenSaveTimer?.cancel();
    final data = jsonEncode({for (final MapEntry(:key, :value) in _seenTexts.entries) key: [value.text, value.date]});
    try {
      final temp = File('$_seenPath.tmp');
      await temp.writeAsString(data, flush: true);
      await temp.rename(_seenPath);
    } on FileSystemException catch (error) {
      debugPrint('seen message texts not saved: ${error.message}');
    }
  }

  /// Parses the file on a background isolate: thousands of messages would stall app start on the UI thread.
  static Future<(Map<String, td.Message>, Map<String, List<MessageVersion>>)> _read(String path) => Isolate.run(() {
        final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
        final deleted = <String, td.Message>{};
        for (final raw in json['deleted'] as List<dynamic>? ?? const []) {
          if ((raw as Map<String, dynamic>).toTdObject() case final td.Message message) {
            deleted[_key(message.chatId, message.id)] = message;
          }
        }
        final edits = <String, List<MessageVersion>>{
          for (final MapEntry(:key, :value) in (json['edits'] as Map<String, dynamic>? ?? const {}).entries)
            key: [
              for (final version in (value as List<dynamic>).cast<Map<String, dynamic>>())
                if ((version['c'] as Map<String, dynamic>).toTdObject() case final td.MessageContent content)
                  (content: content, date: version['d'] as int),
            ],
        };
        return (deleted, edits);
      });

  Future<void> save() async {
    _saveTimer?.cancel();
    if (_seenSaveTimer?.isActive ?? false) await _saveSeen();
    while (_deleted.length > _storedLimit) {
      _deleted.remove(_deleted.keys.first);
    }
    while (_edits.length > _storedLimit) {
      _edits.remove(_edits.keys.first);
    }
    final data = jsonEncode({
      'deleted': [for (final message in _deleted.values) message.toJson()],
      'edits': {
        for (final MapEntry(:key, :value) in _edits.entries) key: [for (final v in value) {'c': v.content.toJson(), 'd': v.date}],
      },
    });
    try {
      // Write-then-rename so a crash mid-write never loses the previous copy.
      final temp = File('$_path.tmp');
      await temp.writeAsString(data, flush: true);
      await temp.rename(_path);
    } on FileSystemException catch (error) {
      debugPrint('message archive not saved: ${error.message}');
    }
  }

  static td.MessageContent _plainText(String text) => td.MessageText(text: td.FormattedText(text: text, entities: const []));

  static String? _textOf(td.MessageContent content) => switch (content) {
        td.MessageText(:final text) => text.text,
        td.MessagePhoto(:final caption) ||
        td.MessageVideo(:final caption) ||
        td.MessageDocument(:final caption) ||
        td.MessageAudio(:final caption) ||
        td.MessageAnimation(:final caption) ||
        td.MessageVoiceNote(:final caption) =>
          caption.text,
        _ => null,
      };
}
