import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/hub/hub_quick_links.dart';

void main() {
  test('accepts web addresses, adding https when the scheme is missing', () {
    expect(normalizeQuickUrl('uzum.uz'), 'https://uzum.uz');
    expect(normalizeQuickUrl('  https://my.gov.uz/uz  '), 'https://my.gov.uz/uz');
    expect(normalizeQuickUrl('http://olx.uz'), 'http://olx.uz');
  });

  test('picks the apple-touch-icon, then the biggest icon, skipping SVG and mask icons', () {
    // Uzum's minified markup: unquoted attributes.
    const uzum = '<link rel=icon type=image/svg+xml href=/i/favicon.svg>'
        '<link rel=icon sizes=32x32 href=/i/favicon-32.png>'
        '<link rel=apple-touch-icon sizes=180x180 href=/i/apple-touch-icon.png>';
    expect(pickIconHref(uzum), '/i/apple-touch-icon.png');
    const payme = '<link rel="mask-icon" href="/pin.svg"><link rel="icon" sizes="16x16" href="/16.png">'
        '<link rel="icon" type="image/png" sizes="32x32" href="/32.png">';
    expect(pickIconHref(payme), '/32.png');
    expect(pickIconHref('<link rel="stylesheet" href="/a.css">'), isNull);
  });

  test('reads admin-pinned links: empty logo and package mean none, and they cannot be removed', () {
    final bank = QuickLink.fromAdmin({'title': 'Bank', 'url': 'https://bank.uz', 'logo_url': '', 'android_package': ''});
    expect((bank.logo, bank.androidPackage, bank.fromAdmin), (null, null, true));
    final uzum = QuickLink.fromAdmin({'title': 'Uzum', 'url': 'https://uzum.uz', 'logo_url': 'https://x.uz/l.png', 'android_package': 'uz.uzum.app'});
    expect((uzum.logo, uzum.androidPackage), ('https://x.uz/l.png', 'uz.uzum.app'));
  });

  test('a saved link keeps its app package when its logo is set', () {
    final link = quickLinkPresets.first.withLogo('/data/pic.jpg');
    expect(link.toJson(), {'name': 'Uzum Market', 'url': 'https://uzum.uz', 'logo': '/data/pic.jpg', 'package': 'uz.uzum.app'});
  });

  test('rejects text that is not a web address', () {
    expect(normalizeQuickUrl(''), isNull);
    expect(normalizeQuickUrl('uzum market'), isNull);
    expect(normalizeQuickUrl('localhost'), isNull);
    expect(normalizeQuickUrl('javascript:alert(1)'), isNull);
    expect(normalizeQuickUrl('intent://scan#Intent;end'), isNull);
  });
}
