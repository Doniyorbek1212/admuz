import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/link_safety.dart';

void main() {
  test('blocks links that log another device into the account', () {
    expect(assessLink('tg://login?token=AbCd').level, LinkRiskLevel.blocked);
    expect(assessLink('https://t.me/login/12345').level, LinkRiskLevel.blocked);
  });

  test('flags self-spreading share links', () {
    expect(assessLink('tg://msg_url?url=https://x.y&text=Gift').level, LinkRiskLevel.danger);
    expect(assessLink('https://t.me/share/url?url=x&text=y').level, LinkRiskLevel.danger);
  });

  test('flags look-alike Telegram and punycode domains', () {
    expect(assessLink('https://telegram-gift.org/claim').level, LinkRiskLevel.danger);
    expect(assessLink('https://teleqram.com').level, LinkRiskLevel.danger);
    expect(assessLink('https://xn--80ak6aa92e.com').level, LinkRiskLevel.danger);
    expect(assessLink('https://fragment.com/gifts').level, LinkRiskLevel.safe);
    expect(assessLink('https://web.telegram.org').level, LinkRiskLevel.safe);
  });

  test('flags text links that show one address but lead to another', () {
    expect(assessLink('https://evil.example/login', shownText: 'https://kapitalbank.uz').level, LinkRiskLevel.danger);
    expect(assessLink('https://www.kun.uz/news', shownText: 'kun.uz').level, LinkRiskLevel.safe);
    expect(assessLink('https://kun.uz/news', shownText: 'Batafsil o\'qish').level, LinkRiskLevel.safe);
  });

  test('user policy: blocked and trusted domains, strict mode, off switch, ask for external links', () {
    final policy = LinkPolicy(blockedDomains: {'scam.example'}, trustedDomains: {'telegram-gift.org'});
    expect(assessLink('https://pay.scam.example/x', policy: policy).level, LinkRiskLevel.blocked);
    expect(assessLink('https://telegram-gift.org', policy: policy).level, LinkRiskLevel.safe);
    expect(assessLink('tg://msg_url?url=x', policy: const LinkPolicy(strict: true)).level, LinkRiskLevel.blocked);
    expect(assessLink('https://teleqram.com', policy: const LinkPolicy(enabled: false)).level, LinkRiskLevel.safe);
    // Login links stay blocked whatever the settings say.
    expect(assessLink('tg://login?token=x', policy: const LinkPolicy(enabled: false)).level, LinkRiskLevel.blocked);
    expect(assessLink('https://kun.uz', policy: const LinkPolicy(askExternal: true)).level, LinkRiskLevel.caution);
    expect(assessLink('https://t.me/durov', policy: const LinkPolicy(askExternal: true)).level, LinkRiskLevel.safe);
  });

  test('normalizes typed domains', () {
    expect(normalizeDomain('https://www.Bank.uz/login'), 'bank.uz');
    expect(normalizeDomain('scam.example'), 'scam.example');
    expect(normalizeDomain('not a domain'), '');
  });

  test('cautions on bait bots and leaves ordinary links alone', () {
    expect(assessLink('https://t.me/FreeGiftPremiumBot?start=abc').level, LinkRiskLevel.caution);
    expect(assessLink('https://t.me/durov').level, LinkRiskLevel.safe);
    expect(assessLink('https://t.me/+AbCdEf').level, LinkRiskLevel.safe);
    expect(assessLink('https://google.com').level, LinkRiskLevel.safe);
    expect(assessLink('google.com').level, LinkRiskLevel.safe);
  });
}
