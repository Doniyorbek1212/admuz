import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/state/contact_changes.dart';
import 'package:tdlib_ex/td_api.dart' as td;

td.User _user({String first = 'Ali', String phone = '998901112233', bool contact = true}) => td.User(
      id: 42,
      firstName: first,
      lastName: '',
      phoneNumber: phone,
      status: const td.UserStatusEmpty(),
      accentColorId: 0,
      backgroundCustomEmojiId: 0,
      profileAccentColorId: -1,
      profileBackgroundCustomEmojiId: 0,
      isContact: contact,
      isMutualContact: false,
      isCloseFriend: false,
      isPremium: false,
      isSupport: false,
      restrictsNewChats: false,
      paidMessageStarCount: 0,
      haveAccess: true,
      type: const td.UserTypeRegular(),
      languageCode: '',
      addedToAttachmentMenu: false,
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cc'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('first sighting only snapshots, later changes are logged', () {
    final log = ContactChangeLog('${dir.path}/log.json')..onUser(_user());
    expect(log.changes, isEmpty);
    log.onUser(_user(first: 'Vali'));
    expect(log.changes.single.kind, ContactChangeKind.nameChanged);
    expect(log.changes.single.before, 'Ali');
  });

  test('empty phone is reported as hidden, not as a new number', () {
    final log = ContactChangeLog('${dir.path}/log.json')
      ..onUser(_user())
      ..onUser(_user(phone: ''));
    expect(log.changes.single.kind, ContactChangeKind.phoneHidden);
  });

  test('non-contacts are ignored', () {
    final log = ContactChangeLog('${dir.path}/log.json')
      ..onUser(_user(contact: false))
      ..onUser(_user(contact: false, first: 'X'));
    expect(log.changes, isEmpty);
  });

  test('snapshot survives a restart so offline changes are caught', () async {
    final path = '${dir.path}/log.json';
    await (ContactChangeLog(path)..onUser(_user())).save();
    final reopened = ContactChangeLog(path);
    await reopened.load();
    reopened.onUser(_user(phone: '998909998877'));
    expect(reopened.changes.single.kind, ContactChangeKind.phoneChanged);
    expect(reopened.changes.single.before, '998901112233');
  });
}
