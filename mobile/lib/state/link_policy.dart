import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/link_safety.dart';
import 'settings.dart';

/// Settings → Link safety, saved on this device.
final linkPolicyProvider = NotifierProvider<LinkPolicyNotifier, LinkPolicy>(LinkPolicyNotifier.new);

class LinkPolicyNotifier extends Notifier<LinkPolicy> {
  static const _prefix = 'linkSafety.';

  @override
  LinkPolicy build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return LinkPolicy(
      enabled: prefs.getBool('${_prefix}enabled') ?? true,
      strict: prefs.getBool('${_prefix}strict') ?? false,
      hideMessages: prefs.getBool('${_prefix}hide') ?? false,
      askExternal: prefs.getBool('${_prefix}askExternal') ?? false,
      blockedDomains: (prefs.getStringList('${_prefix}blocked') ?? const <String>[]).toSet(),
      trustedDomains: (prefs.getStringList('${_prefix}trusted') ?? const <String>[]).toSet(),
    );
  }

  void _save(LinkPolicy next) {
    final prefs = ref.read(sharedPreferencesProvider);
    prefs
      ..setBool('${_prefix}enabled', next.enabled)
      ..setBool('${_prefix}strict', next.strict)
      ..setBool('${_prefix}hide', next.hideMessages)
      ..setBool('${_prefix}askExternal', next.askExternal)
      ..setStringList('${_prefix}blocked', next.blockedDomains.toList())
      ..setStringList('${_prefix}trusted', next.trustedDomains.toList());
    state = next;
  }

  void setEnabled(bool on) => _save(state.copyWith(enabled: on));
  void setStrict(bool on) => _save(state.copyWith(strict: on));
  void setHideMessages(bool on) => _save(state.copyWith(hideMessages: on));
  void setAskExternal(bool on) => _save(state.copyWith(askExternal: on));

  /// Adds [domain] to the blocked (or trusted) list, removing it from the other one; false when it is not a domain.
  bool addDomain(String input, {required bool blocked}) {
    final domain = normalizeDomain(input);
    if (domain.isEmpty) return false;
    final block = {...state.blockedDomains}..remove(domain);
    final trust = {...state.trustedDomains}..remove(domain);
    (blocked ? block : trust).add(domain);
    _save(state.copyWith(blockedDomains: block, trustedDomains: trust));
    return true;
  }

  void removeDomain(String domain) =>
      _save(state.copyWith(blockedDomains: {...state.blockedDomains}..remove(domain), trustedDomains: {...state.trustedDomains}..remove(domain)));
}
