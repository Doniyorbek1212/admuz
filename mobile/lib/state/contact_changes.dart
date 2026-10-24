import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tdlib_ex/td_api.dart' as td;

/// What changed in a contact's profile.
enum ContactChangeKind { photoAdded, photoChanged, photoRemoved, phoneChanged, phoneHidden, nameChanged, usernameChanged }

/// One logged change; [before] is the earlier value for name/phone/username changes.
typedef ContactChange = ({int userId, ContactChangeKind kind, String before, int date});

/// The parts of a contact's profile that are compared between updates.
typedef _Snapshot = ({int photoId, String phone, String name, String username});

/// Log of profile changes made by the user's contacts (photo, phone, name, username), kept on this device.
///
/// A snapshot of every contact is stored with the log, so changes made while the app was closed are
/// detected when TDLib reports the user again after the next start.
class ContactChangeLog {
  ContactChangeLog(this._path);

  final String _path;
  final Map<int, _Snapshot> _snapshots = {};
  final List<ContactChange> _changes = [];
  Timer? _saveTimer;

  final revision = ValueNotifier<int>(0);

  static const _limit = 500;

  /// Newest first.
  List<ContactChange> get changes => List.unmodifiable(_changes.reversed);

  static _Snapshot _snapshotOf(td.User user) => (
        photoId: user.profilePhoto?.id ?? 0,
        phone: user.phoneNumber,
        name: '${user.firstName} ${user.lastName}'.trim(),
        username: user.usernames?.activeUsernames.firstOrNull ?? '',
      );

  /// Call with every updateUser.
  void onUser(td.User user) {
    if (!user.isContact || user.type is! td.UserTypeRegular) return;
    final next = _snapshotOf(user);
    final previous = _snapshots[user.id];
    _snapshots[user.id] = next;
    if (previous == null) {
      _scheduleSave();
      return;
    }
    if (previous == next) return;
    final date = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    void add(ContactChangeKind kind, [String before = '']) => _changes.add((userId: user.id, kind: kind, before: before, date: date));
    if (previous.photoId != next.photoId) {
      add(previous.photoId == 0
          ? ContactChangeKind.photoAdded
          : next.photoId == 0
              ? ContactChangeKind.photoRemoved
              : ContactChangeKind.photoChanged);
    }
    // An empty phone means the contact hid it with privacy settings.
    if (previous.phone != next.phone && previous.phone.isNotEmpty) {
      add(next.phone.isEmpty ? ContactChangeKind.phoneHidden : ContactChangeKind.phoneChanged, previous.phone);
    }
    if (previous.name != next.name) add(ContactChangeKind.nameChanged, previous.name);
    if (previous.username != next.username) add(ContactChangeKind.usernameChanged, previous.username);
    if (_changes.length > _limit) _changes.removeRange(0, _changes.length - _limit);
    revision.value++;
    _scheduleSave();
  }

  void clear() {
    _changes.clear();
    revision.value++;
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () => unawaited(save()));
  }

  Future<void> load() async {
    try {
      final file = File(_path);
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (json['s'] as Map<String, dynamic>? ?? const {}).entries) {
        final v = value as List<dynamic>;
        _snapshots[int.parse(key)] = (photoId: v[0] as int, phone: v[1] as String, name: v[2] as String, username: v[3] as String);
      }
      for (final raw in json['c'] as List<dynamic>? ?? const []) {
        final v = raw as List<dynamic>;
        final kind = ContactChangeKind.values.asNameMap()[v[1] as String];
        if (kind != null) _changes.add((userId: v[0] as int, kind: kind, before: v[2] as String, date: v[3] as int));
      }
      revision.value++;
    } on Object catch (error) {
      debugPrint('contact change log unreadable: $error');
    }
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    final data = jsonEncode({
      's': {for (final MapEntry(:key, :value) in _snapshots.entries) '$key': [value.photoId, value.phone, value.name, value.username]},
      'c': [for (final c in _changes) [c.userId, c.kind.name, c.before, c.date]],
    });
    try {
      final temp = File('$_path.tmp');
      await temp.writeAsString(data, flush: true);
      await temp.rename(_path);
    } on FileSystemException catch (error) {
      debugPrint('contact change log not saved: ${error.message}');
    }
  }
}
