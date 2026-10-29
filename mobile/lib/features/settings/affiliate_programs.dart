import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

String _commission(td.AffiliateProgramParameters p, Strings s) =>
    '${(p.commissionPerMille / 10).toStringAsFixed(1)}% · ${p.monthCount == 0 ? s.t('affiliate_forever') : s.t('premium_months', {'n': '${p.monthCount}'})}';

/// Earn Stars by sharing bots: programs the user (or their channel) joined, and new ones to join.
class AffiliateProgramsScreen extends ConsumerStatefulWidget {
  const AffiliateProgramsScreen({super.key, this.affiliate = const td.AffiliateTypeCurrentUser()});

  final td.AffiliateType affiliate;

  @override
  ConsumerState<AffiliateProgramsScreen> createState() => _AffiliateProgramsScreenState();
}

class _AffiliateProgramsScreenState extends ConsumerState<AffiliateProgramsScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.ConnectedAffiliatePrograms? _connected;
  td.FoundAffiliatePrograms? _found;
  td.AffiliateProgramSortOrder _sort = const td.AffiliateProgramSortOrderProfitability();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final connected = await _account.send<td.ConnectedAffiliatePrograms>(td.GetConnectedAffiliatePrograms(affiliate: widget.affiliate, offset: '', limit: 50));
      final found = await _account.send<td.FoundAffiliatePrograms>(td.SearchAffiliatePrograms(affiliate: widget.affiliate, sortOrder: _sort, offset: '', limit: 50));
      if (mounted) {
        setState(() {
          _connected = connected;
          _found = found;
        });
      }
    } on TdException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _showLink(td.ConnectedAffiliateProgram program) async {
    final s = context.s;
    // Fresh numbers (users, revenue) for this one program.
    final fresh = await guard(
      context,
      () => _account.send<td.ConnectedAffiliateProgram>(td.GetConnectedAffiliateProgram(affiliate: widget.affiliate, botUserId: program.botUserId)),
    );
    if (!mounted) return;
    final p = fresh ?? program;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(_account.userName(p.botUserId), style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(_commission(p.parameters, s))),
          ListTile(dense: true, title: Text(s.t('affiliate_users')), trailing: Text('${p.userCount}')),
          ListTile(dense: true, title: Text(s.t('affiliate_earned')), trailing: Text('${p.revenueStarCount} ⭐')),
          ListTile(leading: const Icon(Icons.copy_rounded), title: SelectableText(p.url), onTap: () => Navigator.pop(context, 'copy')),
          if (!p.isDisconnected)
            ListTile(
              leading: Icon(Icons.link_off_rounded, color: Theme.of(context).colorScheme.error),
              title: Text(s.t('affiliate_disconnect'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'disconnect'),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: p.url));
      if (mounted) showToast(context, s.t('link_copied'));
    } else if (action == 'disconnect') {
      await guard(context, () => _account.send<td.ConnectedAffiliateProgram>(td.DisconnectAffiliateProgram(affiliate: widget.affiliate, url: p.url)));
      await _load();
    }
  }

  Future<void> _join(td.FoundAffiliateProgram program) async {
    final s = context.s;
    final ok = await confirm(
      context,
      title: _account.userName(program.botUserId),
      message: s.t('affiliate_join_hint', {'rate': _commission(program.info.parameters, s)}),
      confirmLabel: s.t('affiliate_join'),
    );
    if (!ok || !mounted) return;
    final connected = await guard(context, () => _account.send<td.ConnectedAffiliateProgram>(td.ConnectAffiliateProgram(affiliate: widget.affiliate, botUserId: program.botUserId)));
    if (connected == null || !mounted) return;
    await _load();
    if (mounted) await _showLink(connected);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final connected = _connected;
    final found = _found;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('affiliate_programs')),
        actions: [
          PopupMenuButton<td.AffiliateProgramSortOrder>(
            icon: const Icon(Icons.sort_rounded),
            onSelected: (order) {
              setState(() => _sort = order);
              _load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: const td.AffiliateProgramSortOrderProfitability(), child: Text(s.t('affiliate_sort_profit'))),
              PopupMenuItem(value: const td.AffiliateProgramSortOrderRevenue(), child: Text(s.t('affiliate_sort_revenue'))),
              PopupMenuItem(value: const td.AffiliateProgramSortOrderCreationDate(), child: Text(s.t('affiliate_sort_new'))),
            ],
          ),
        ],
      ),
      body: connected == null || found == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              Padding(padding: const EdgeInsets.all(16), child: Text(s.t('affiliate_hint'), style: TextStyle(color: Theme.of(context).hintColor))),
              if (connected.programs.isNotEmpty) SectionHeader(s.t('affiliate_my')),
              for (final p in connected.programs)
                ListTile(
                  leading: UserAvatar(userId: p.botUserId, size: 40),
                  title: Text(_account.userName(p.botUserId)),
                  subtitle: Text('${_commission(p.parameters, s)} · ${p.revenueStarCount} ⭐'),
                  onTap: () => _showLink(p),
                ),
              SectionHeader(s.t('affiliate_available')),
              for (final p in found.programs)
                ListTile(
                  leading: UserAvatar(userId: p.botUserId, size: 40),
                  title: Text(_account.userName(p.botUserId)),
                  subtitle: Text(_commission(p.info.parameters, s)),
                  trailing: TextButton(onPressed: () => _join(p), child: Text(s.t('affiliate_join'))),
                ),
            ]),
    );
  }
}

/// t.me/bot?start=_tgr_… links: the bot behind a referral link, opened in a chat.
Future<void> openAffiliateLink(BuildContext context, TelegramAccount account, String username, String referrer) async {
  final chat = await guard(context, () => account.send<td.Chat>(td.SearchChatAffiliateProgram(username: username, referrer: referrer)));
  if (chat != null && context.mounted) openChat(context, chat.id);
}
