import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/link_policy.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import 'privacy_screen.dart';

/// Settings → Privacy → Link safety: how strictly links in messages are filtered, plus the user's own
/// blocked and trusted sites.
class LinkSafetyScreen extends ConsumerWidget {
  const LinkSafetyScreen({super.key});

  Future<void> _addDomain(BuildContext context, WidgetRef ref, {required bool blocked}) async {
    final s = context.s;
    final input = await promptText(context, title: s.t(blocked ? 'link_add_blocked' : 'link_add_trusted'), label: s.t('link_domain_hint'));
    if (input == null || input.trim().isEmpty || !context.mounted) return;
    if (!ref.read(linkPolicyProvider.notifier).addDomain(input, blocked: blocked)) showToast(context, s.t('link_domain_invalid'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final policy = ref.watch(linkPolicyProvider);
    final notifier = ref.read(linkPolicyProvider.notifier);
    final hint = Theme.of(context).hintColor;
    Widget domainList(Set<String> domains, IconData icon, Color color) => Column(children: [
          if (domains.isEmpty) ListTile(title: Text(s.t('link_domains_empty'), style: TextStyle(color: hint))),
          for (final domain in domains.toList()..sort())
            ListTile(
              leading: Icon(icon, color: color),
              title: Text(domain),
              trailing: IconButton(tooltip: s.t('delete'), icon: const Icon(Icons.close_rounded), onPressed: () => notifier.removeDomain(domain)),
            ),
        ]);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('link_safety'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        SettingsGroup(children: [
          SwitchListTile(
            secondary: const Icon(Icons.shield_rounded),
            title: Text(s.t('link_protect')),
            subtitle: Text(s.t('link_protect_hint')),
            value: policy.enabled,
            onChanged: notifier.setEnabled,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block_rounded),
            title: Text(s.t('link_strict')),
            subtitle: Text(s.t('link_strict_hint')),
            value: policy.strict,
            onChanged: policy.enabled ? notifier.setStrict : null,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_rounded),
            title: Text(s.t('link_hide')),
            subtitle: Text(s.t('link_hide_hint')),
            value: policy.hideMessages,
            onChanged: policy.enabled ? notifier.setHideMessages : null,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.open_in_new_rounded),
            title: Text(s.t('link_ask_external')),
            subtitle: Text(s.t('link_ask_external_hint')),
            value: policy.askExternal,
            onChanged: policy.enabled ? notifier.setAskExternal : null,
          ),
        ]),
        GroupHint(s.t('link_always_blocked_hint')),
        SettingsGroup(title: s.t('link_blocked_sites'), children: [
          domainList(policy.blockedDomains, Icons.gpp_bad_outlined, Theme.of(context).colorScheme.error),
          ListTile(
            leading: Icon(Icons.add_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(s.t('link_add_blocked'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            onTap: () => _addDomain(context, ref, blocked: true),
          ),
        ]),
        SettingsGroup(title: s.t('link_trusted_sites'), children: [
          domainList(policy.trustedDomains, Icons.verified_user_outlined, const Color(0xFF2EBD59)),
          ListTile(
            leading: Icon(Icons.add_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text(s.t('link_add_trusted'), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            onTap: () => _addDomain(context, ref, blocked: false),
          ),
        ]),
        GroupHint(s.t('link_trusted_hint')),
      ]),
    );
  }
}
