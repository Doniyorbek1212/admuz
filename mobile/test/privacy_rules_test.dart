import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/settings/privacy_rules_screen.dart';
import 'package:sado/l10n/strings.dart';
import 'package:tdlib_ex/td_api.dart' as td;

void main() {
  final s = Strings('en');

  test('parse and build keep level and exceptions, exceptions first', () {
    const rules = td.UserPrivacySettingRules(rules: [
      td.UserPrivacySettingRuleRestrictUsers(userIds: [1, 2]),
      td.UserPrivacySettingRuleAllowChatMembers(chatIds: [9]),
      td.UserPrivacySettingRuleAllowContacts(),
    ]);
    final parsed = PrivacyRules.parse(rules);
    expect(parsed.level, PrivacyLevel.contacts);
    expect(parsed.label(s), 'My contacts (-2, +1)');
    final built = parsed.build().rules;
    expect(built.last, isA<td.UserPrivacySettingRuleAllowContacts>());
    expect(built.whereType<td.UserPrivacySettingRuleRestrictUsers>().single.userIds, [1, 2]);
  });

  test('exceptions that cannot apply are dropped from the request', () {
    // "Everybody" with an allow list: the allow list means nothing, so it is not sent.
    const parsed = PrivacyRules(level: PrivacyLevel.everybody, allowUsers: [5], restrictUsers: [6]);
    final built = parsed.build().rules;
    expect(built.whereType<td.UserPrivacySettingRuleAllowUsers>(), isEmpty);
    expect(built.whereType<td.UserPrivacySettingRuleRestrictUsers>().single.userIds, [6]);
    expect(parsed.label(s), 'Everybody (-1)');
  });

  test('contacts and premium round-trips', () {
    const rules = td.UserPrivacySettingRules(rules: [td.UserPrivacySettingRuleAllowPremiumUsers(), td.UserPrivacySettingRuleAllowContacts()]);
    final parsed = PrivacyRules.parse(rules);
    expect(parsed.label(s), 'Contacts and Premium');
    expect(parsed.build().rules.whereType<td.UserPrivacySettingRuleAllowPremiumUsers>(), hasLength(1));
  });
}
