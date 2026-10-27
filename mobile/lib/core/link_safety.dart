/// Telegram's service account; its messages carry login codes.
const telegramServiceUserId = 777000;

/// How risky a tapped link is. Pure string checks, so every message and button is assessed instantly.
enum LinkRiskLevel { safe, caution, danger, blocked }

class LinkRisk {
  const LinkRisk(this.level, [this.reasonKey = '']);

  final LinkRiskLevel level;

  /// Translation key that explains the risk to the user.
  final String reasonKey;

  bool get warns => level != LinkRiskLevel.safe;
  bool get isDangerous => level == LinkRiskLevel.danger || level == LinkRiskLevel.blocked;

  static const safe = LinkRisk(LinkRiskLevel.safe);
}

/// Real Telegram domains; anything else that imitates them is treated as phishing.
const _telegramHosts = {
  't.me', 'telegram.me', 'telegram.dog', 'telegram.org', 'core.telegram.org', 'web.telegram.org', 'desktop.telegram.org',
  'macos.telegram.org', 'translations.telegram.org', 'promote.telegram.org', 'my.telegram.org', 'telegra.ph', 'fragment.com',
};

/// Words scam sites put into look-alike domains of Telegram.
final _telegramLookalike = RegExp(r'te[l1i]e?[gq]r[a@4]m|t-me|tme-|fragment|tgram|telegrarn');

/// Bot usernames that pose as gift, airdrop or Premium give-aways.
final _baitBot = RegExp(r'(gift|premium|airdrop|free|bonus|prize|reward|stars?claim|nft|fragment|wallet|verify|support)', caseSensitive: false);

/// Uzbek payment and bank brands that scam sites put into their domains ("payme-bonus.site", "my-click-uz.net").
final _paymentBrand = RegExp(
  // Lookaheads keep "payment…" and "humor…" sites out.
  r'payme(?!nt)|click[-.]?uz|my-?click|uzcard|humo(?![a-z])|humocard|kapital-?bank|ipak-?yuli|agrobank|hamkor-?bank|anor-?bank|uzum|paynet|apelsin|xazna|tbc-?bank|davr-?bank|aloqa-?bank|sqb',
);

/// The real sites of those brands; a domain also covers its subdomains.
const _paymentHosts = {
  'payme.uz', 'click.uz', 'uzcard.uz', 'humocard.uz', 'humo.uz', 'kapitalbank.uz', 'ipakyulibank.uz', 'agrobank.uz',
  'hamkorbank.uz', 'anorbank.uz', 'uzum.uz', 'uzumbank.uz', 'paynet.uz', 'apelsin.uz', 'xazna.uz', 'tbcbank.uz',
  'davrbank.uz', 'aloqabank.uz', 'sqb.uz',
};

/// Installable programs: fake "Payme"/"Click" APKs are the most common account and card theft in Uzbekistan.
final _installerFile = RegExp(r'\.(apk|apks|xapk|exe|msi|scr|bat)$', caseSensitive: false);

/// Short-link services hide where a link really goes.
const _shorteners = {
  'bit.ly', 'tinyurl.com', 'cutt.ly', 'is.gd', 'goo.su', 'clck.ru', 'rb.gy', 'shorturl.at', 'tiny.cc', 'ow.ly', 't.ly', 'v.gd', 'u.to',
};

/// Free or near-free zones that prize and "bonus" scams favour.
final _throwawayZone = RegExp(r'\.(top|xyz|click|site|online|icu|buzz|monster|rest|cfd|sbs|cyou|live|shop|info|win|vip|loan|bond)$');

/// Text of a link that itself looks like an address ("t.me/x", "https://bank.uz", "bank.uz/login").
final _addressLike = RegExp(r'^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(/\S*)?$', caseSensitive: false);

/// What the user chose in Settings → Link safety.
class LinkPolicy {
  const LinkPolicy({
    this.enabled = true,
    this.strict = false,
    this.hideMessages = false,
    this.askExternal = false,
    this.blockedDomains = const {},
    this.trustedDomains = const {},
  });

  /// Warn about risky links at all. Account-takeover (login) links stay blocked even when this is off.
  final bool enabled;

  /// Dangerous links cannot be opened ("Open anyway" disappears).
  final bool strict;

  /// Messages with a dangerous link are folded behind a "show" button.
  final bool hideMessages;

  /// Confirm before any external website opens, even one that looks safe.
  final bool askExternal;

  /// Domains the user blocked or trusts; a domain also covers its subdomains.
  final Set<String> blockedDomains;
  final Set<String> trustedDomains;

  static const standard = LinkPolicy();

  LinkPolicy copyWith({bool? enabled, bool? strict, bool? hideMessages, bool? askExternal, Set<String>? blockedDomains, Set<String>? trustedDomains}) =>
      LinkPolicy(
        enabled: enabled ?? this.enabled,
        strict: strict ?? this.strict,
        hideMessages: hideMessages ?? this.hideMessages,
        askExternal: askExternal ?? this.askExternal,
        blockedDomains: blockedDomains ?? this.blockedDomains,
        trustedDomains: trustedDomains ?? this.trustedDomains,
      );
}

/// "https://www.Bank.uz/x" or "bank.uz" → "bank.uz"; empty when it is not a domain.
String normalizeDomain(String input) {
  final raw = input.trim().toLowerCase();
  final host = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw')?.host ?? '';
  final bare = _bareHost(host);
  return RegExp(r'^([a-z0-9-]+\.)+[a-z]{2,}$').hasMatch(bare) ? bare : '';
}

bool _inDomains(String host, Set<String> domains) {
  final bare = _bareHost(host);
  return domains.any((d) => bare == d || bare.endsWith('.$d'));
}

/// Assesses [url] under the user's [policy]; [shownText] is the visible text of a text link.
LinkRisk assessLink(String url, {String? shownText, LinkPolicy policy = LinkPolicy.standard}) {
  final base = _baseRisk(url, shownText);
  if (base.level == LinkRiskLevel.blocked) return base;
  final uri = Uri.tryParse(url.trim().contains('://') ? url.trim() : 'https://${url.trim()}');
  final host = uri?.host.toLowerCase() ?? '';
  final web = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && !_isTelegramShort(host);
  if (web && _inDomains(host, policy.blockedDomains)) return const LinkRisk(LinkRiskLevel.blocked, 'link_risk_user_blocked');
  if (web && _inDomains(host, policy.trustedDomains)) return LinkRisk.safe;
  if (!policy.enabled) return LinkRisk.safe;
  if (policy.strict && base.level == LinkRiskLevel.danger) return LinkRisk(LinkRiskLevel.blocked, base.reasonKey);
  if (policy.askExternal && web && base.level == LinkRiskLevel.safe) return const LinkRisk(LinkRiskLevel.caution, 'link_risk_external');
  return base;
}

LinkRisk _baseRisk(String url, String? shownText) {
  final raw = url.trim();
  final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
  if (uri == null) return LinkRisk.safe;
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();

  if (scheme == 'tg') return _assessTelegram(host, uri.pathSegments, uri.queryParameters);
  if (_isTelegramShort(host)) return _assessTelegram(_tmeAction(uri), uri.pathSegments.skip(1).toList(), uri.queryParameters, firstSegment: uri.pathSegments.firstOrNull);
  if (scheme != 'http' && scheme != 'https') {
    return const LinkRisk(LinkRiskLevel.caution, 'link_risk_scheme');
  }

  if (host.contains('xn--')) return const LinkRisk(LinkRiskLevel.danger, 'link_risk_punycode');
  if (!_telegramHosts.contains(host) && _telegramLookalike.hasMatch(host)) {
    return const LinkRisk(LinkRiskLevel.danger, 'link_risk_fake_telegram');
  }
  final shown = shownText?.trim() ?? '';
  if (shown.isNotEmpty && _addressLike.hasMatch(shown)) {
    final shownHost = Uri.tryParse(shown.contains('://') ? shown : 'https://$shown')?.host.toLowerCase() ?? '';
    if (shownHost.isNotEmpty && _bareHost(shownHost) != _bareHost(host)) {
      return const LinkRisk(LinkRiskLevel.danger, 'link_risk_mismatch');
    }
  }
  if (_installerFile.hasMatch(uri.path)) return const LinkRisk(LinkRiskLevel.danger, 'link_risk_installer');
  final bare = _bareHost(host);
  if (_paymentBrand.hasMatch(bare) && !_inDomains(bare, _paymentHosts)) {
    return const LinkRisk(LinkRiskLevel.danger, 'link_risk_fake_bank');
  }
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return const LinkRisk(LinkRiskLevel.caution, 'link_risk_ip');
  if (_shorteners.contains(bare)) return const LinkRisk(LinkRiskLevel.caution, 'link_risk_shortener');
  if (_throwawayZone.hasMatch(bare)) return const LinkRisk(LinkRiskLevel.caution, 'link_risk_zone');
  return LinkRisk.safe;
}

/// The riskiest of several links (url with its visible text); safe when there are none.
LinkRisk worstLinkRisk(Iterable<(String, String?)> links, {LinkPolicy policy = LinkPolicy.standard}) {
  var worst = LinkRisk.safe;
  for (final (url, shown) in links) {
    final risk = assessLink(url, shownText: shown, policy: policy);
    if (risk.level.index > worst.level.index) worst = risk;
  }
  return worst;
}

bool _isTelegramShort(String host) => host == 't.me' || host == 'telegram.me' || host == 'telegram.dog';

String _bareHost(String host) => host.startsWith('www.') ? host.substring(4) : host;

/// `t.me/{action}/…` mapped to the tg:// action name it stands for.
String _tmeAction(Uri uri) => switch (uri.pathSegments.firstOrNull?.toLowerCase()) {
      'share' => 'msg_url',
      'login' => 'login',
      'confirmphone' => 'confirmphone',
      'passport' => 'passport',
      'oauth' => 'oauth',
      _ => 'resolve',
    };

LinkRisk _assessTelegram(String action, List<String> path, Map<String, String> query, {String? firstSegment}) {
  switch (action.toLowerCase()) {
    // Logs someone else in with this account (login token or code): never open from a message.
    case 'login':
      return const LinkRisk(LinkRiskLevel.blocked, 'link_risk_login');
    // Prefills a message for forwarding: the classic self-spreading scam chain.
    case 'msg_url' || 'msg' || 'share':
      return const LinkRisk(LinkRiskLevel.danger, 'link_risk_share');
    case 'oauth' || 'passport' || 'confirmphone':
      return const LinkRisk(LinkRiskLevel.danger, 'link_risk_auth');
  }
  final bot = (query['domain'] ?? firstSegment ?? '').toLowerCase();
  final startsApp = query.containsKey('startapp') || query.containsKey('start') || query.containsKey('startattach') || path.isNotEmpty;
  if (bot.endsWith('bot') && startsApp && _baitBot.hasMatch(bot)) {
    return const LinkRisk(LinkRiskLevel.caution, 'link_risk_bot');
  }
  return LinkRisk.safe;
}
