import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/api/gift_models.dart';
import 'package:sado/features/gifts/gift_widgets.dart' show premiumShowOrder;
import 'package:sado/features/home/tab_order_screen.dart' show orderTabs;
import 'package:sado/features/hub/hub_quick_links.dart' show parseAppStoreResults;
import 'package:sado/l10n/strings.dart';
import 'package:sado/l10n/translations.dart';
import 'package:sado/state/actions.dart';

SentGift _sent(String id, String kind, int price, {bool premium = true}) => SentGift(
      id: id,
      gift: GiftItem(id: kind, title: kind, priceUzs: price, animationUrl: '', effect: premium ? kind : null),
      senderTelegramId: 1,
      recipientTelegramId: 2,
      text: '',
      hidden: false,
      createdAt: DateTime(2026),
    );

void main() {
  test('profile gift shows: premium only, one per kind, dearest first', () {
    final order = premiumShowOrder([
      _sent('a', 'rose', 5000, premium: false),
      _sent('b', 'lion', 100000),
      _sent('c', 'jet', 400000),
      _sent('d', 'lion', 100000),
    ]);
    expect(order.map((g) => g.id), ['c', 'b']);
  });

  group('voice note waveform', () {
    test('5-bit packing round-trips', () {
      final samples = [for (var i = 0; i < 100; i++) (i * 7) % 32];
      final decoded = decodeWaveform(encodeWaveform(samples));
      expect(decoded.sublist(0, samples.length), samples);
    });

    test('values are clamped to 0..31', () {
      expect(decodeWaveform(encodeWaveform([-5, 40, 31])).take(3), [0, 31, 31]);
    });

    test('empty waveform decodes to nothing', () => expect(decodeWaveform(''), isEmpty));
  });

  group('translations', () {
    test('every language defines the same keys', () {
      final reference = translations['en']!.keys.toSet();
      for (final entry in translations.entries) {
        final keys = entry.value.keys.where((k) => !k.endsWith('_few')).toSet();
        expect(keys.difference(reference), isEmpty, reason: '${entry.key} has extra keys');
        expect(reference.difference(keys), isEmpty, reason: '${entry.key} is missing keys');
      }
    });

    test('Russian plurals have all three forms', () {
      final ru = translations['ru']!;
      for (final key in ru.keys.where((k) => k.endsWith('_many'))) {
        final base = key.substring(0, key.length - 5);
        expect(ru.containsKey('${base}_one') && ru.containsKey('${base}_few'), isTrue, reason: base);
      }
    });

    test('every key used in the code exists', () {
      final used = <String>{};
      final literal = RegExp(r"'([a-z][a-z0-9_]*)'");
      final call = RegExp(r'(\.t\(|\.count\(|context\.t\()');
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        if (file.path.contains('l10n')) continue;
        for (final line in file.readAsLinesSync().where(call.hasMatch)) {
          used.addAll(literal.allMatches(line).map((m) => m.group(1)!));
        }
      }
      final en = translations['en']!;
      // Literals on t()/count() lines that are values or placeholders, not keys.
      const notKeys = {
        'history', 'mark', 'actor', 'p', 'ad', 'users', 'title', 'n', 'name', 'time', 'date', 'email', 'phone', 'prefix', 'lang', 'hint', 'link',
        'main', 'fix', 'translate', 'emoji', 'summarize', 'clear', 'mute', 'delete', 'pin', 'retry', 'reply', 'copy',
        'edit', 'forward', 'share', 'select', 'gallery', 'camera', 'video', 'file', 'location', 'poll', 'contact', 'read',
        'archive', 'count', 'domain', 'seconds', 'bot', 'now', 'scheduled', 'reschedule', 'admins', 'dismiss', 'remove', 'version',
        'amount', 'code', 'days', 'default', 'first', 'list', 'my_shop', 'old', 'period', 'price', 'reason', 'region', 'regions',
        'soon', 'wallpaper', 'what', 'total', 'store', 'system_gallery', 'set', 'moderate', 'everyone', 'rejoin', 'renew',
        'b', 'd', 'r', 'replace', 'saved_topics', 'display_as', 'invite', 'lower_hand', 'mute_all', 'mute_me', 'mute_new',
        'record', 'rtmp', 'schedule', 'start', 'unmute_all', 'unmute_me', 'volume', 'folder', 'transfer', 'resale', 'upgrade',
        'conference_invite', 'conference_link', 'conference_revoke', 'messages_allowed', 'paid_messages',
        'rich_compose', 'rich_create', 'rich_fix', 'rich_translate',
        'add_tasks', 'author', 'block_replies', 'calendar', 'edit_checklist', 'embed', 'one',
        'album', 'all', 'device', 'none', 'pinned', 'some', 'stats', 'where', 'site', 'country',
        'as_messages', 'by_date', 'chin', 'cover', 'cover_reset', 'emojis', 'eyes', 'forehead', 'key', 'keywords', 'mask', 'mouth',
        'new', 'order', 'revenue', 'strings', 'tag',
        'card', 'collections', 'export', 'gift', 'inline', 'live', 'prize', 'rate', 'size', 'text', 'top',
        'clicks', 'collapse', 'collection', 'icon', 'mono', 'serif', 'strike', 'underline',
        'tone',
        // Wallet ledger kinds, payment method and history filter values.
        'badge', 'bonus', 'in', 'out', 'payme', 'refund', 'topup',
      };
      final missing = used.where((k) => !notKeys.contains(k) && !en.containsKey(k) && !en.containsKey('${k}_one')).toList()..sort();
      expect(missing, isEmpty);
    });

    test('placeholders and plural selection', () {
      const ru = Strings('ru');
      expect(ru.count('members', 1), '1 участник');
      expect(ru.count('members', 3), '3 участника');
      expect(ru.count('members', 11), '11 участников');
      expect(ru.count('members', 21), '21 участник');
      expect(const Strings('en').count('votes', 2), '2 votes');
      expect(const Strings('uz').t('resend_in', {'n': '30'}), 'Kodni qayta yuborish: 30 s');
      expect(const Strings('uz').error('NOT_A_REAL_CODE'), const Strings('uz').t('err_GENERIC'));
    });
  });

  test('chat tabs follow the saved order; tabs it does not know keep their place at the end', () {
    const tabs = [('type:private', 'P'), ('main', 'A'), ('type:group', 'G'), ('folder:3', 'F')];
    expect(orderTabs(tabs, const []).map((t) => t.$1), ['type:private', 'main', 'type:group', 'folder:3']);
    expect(orderTabs(tabs, const ['main', 'folder:3', 'gone']).map((t) => t.$1), ['main', 'folder:3', 'type:private', 'type:group']);
  });

  test('App Store search results become quick links: own site first, App Store page kept, bad rows skipped', () {
    final links = parseAppStoreResults({
      'results': [
        {'trackName': 'Uzum', 'trackViewUrl': 'https://apps.apple.com/uz/app/id1', 'sellerUrl': 'https://uzum.uz', 'artworkUrl512': 'https://is1/512.png'},
        {'trackName': 'NoSite', 'trackViewUrl': 'https://apps.apple.com/uz/app/id2', 'sellerUrl': 'http://plain.uz', 'artworkUrl100': 'https://is1/100.png'},
        {'trackName': 'Broken'},
        'junk',
      ],
    });
    expect(links.map((l) => (l.name, l.url, l.logo, l.appStoreUrl)), [
      ('Uzum', 'https://uzum.uz', 'https://is1/512.png', 'https://apps.apple.com/uz/app/id1'),
      ('NoSite', 'https://apps.apple.com/uz/app/id2', 'https://is1/100.png', 'https://apps.apple.com/uz/app/id2'),
    ]);
    expect(parseAppStoreResults('nope'), isEmpty);
  });
}
