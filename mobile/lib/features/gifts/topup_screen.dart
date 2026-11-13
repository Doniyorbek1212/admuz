import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/gift_models.dart';
import '../../core/api/sado_api.dart';
import '../../core/store_rules.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../business/business_widgets.dart';

/// Tops up the UZARO balance: transfer to the card, upload the receipt, an admin approves it.
class TopupScreen extends ConsumerStatefulWidget {
  const TopupScreen({super.key});

  @override
  ConsumerState<TopupScreen> createState() => _TopupScreenState();
}

class _TopupScreenState extends ConsumerState<TopupScreen> {
  static const _paymeTeal = Color(0xFF33CCCC);
  static const _minAmount = 1000;
  static const _quickAmounts = [10000, 25000, 50000, 100000];
  late Future<Wallet> _wallet = ref.read(sadoApiProvider).wallet();
  final _amount = TextEditingController(text: '25000');
  bool _sending = false;

  bool _openingPayme = false;

  /// Back from Payme: the balance may already be credited.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _wallet = ref.read(sadoApiProvider).wallet());
  }

  int get _enteredAmount => int.tryParse(_amount.text.replaceAll(RegExp(r'\D'), '')) ?? 0;

  /// Opens the Payme checkout for the entered amount; Payme credits the balance itself, no receipt needed.
  Future<void> _payWithPayme() async {
    final s = context.s;
    final amount = _enteredAmount;
    if (amount < _minAmount) return showToast(context, s.t('topup_min'));
    setState(() => _openingPayme = true);
    final url = await apiGuard(context, () => ref.read(sadoApiProvider).paymeCheckout(amount));
    if (!mounted) return;
    setState(() => _openingPayme = false);
    if (url == null) return;
    if (!await launchUrl(url, mode: LaunchMode.externalApplication) && mounted) showToast(context, s.t('topup_payme_open_failed'));
  }

  Future<void> _sendReceipt() async {
    final s = context.s;
    final amount = _enteredAmount;
    if (amount < _minAmount) return showToast(context, s.t('topup_min'));
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90, maxWidth: 2000);
    if (file == null || !mounted) return;
    setState(() => _sending = true);
    final done = await apiGuard(context, () async {
      await ref.read(sadoApiProvider).requestTopup(amount, file.path);
      return true;
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (done == true) _wallet = ref.read(sadoApiProvider).wallet();
    });
    if (done == true) showToast(context, s.t('topup_sent'));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('gifts_topup'))),
      body: FutureBuilder<Wallet>(
        future: _wallet,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final error = snapshot.error;
            return EmptyState(
              icon: Icons.wifi_off_rounded,
              title: error is ApiException ? apiErrorText(context, error) : errorText(context, error!),
              action: FilledButton(onPressed: () => setState(() {
                _wallet = ref.read(sadoApiProvider).wallet();
              }), child: Text(s.t('retry'))),
            );
          }
          final wallet = snapshot.data;
          if (wallet == null) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            BalanceCard(balanceUzs: wallet.balanceUzs),
            if (storeBlocksExternalPayments)
              Padding(padding: const EdgeInsets.all(20), child: Text(s.t('topup_unavailable'), textAlign: TextAlign.center))
            else
              _steps(context, wallet),
            // Approved receipts already show in the wallet history; only those still in review or rejected stay here.
            if (wallet.topups.any((t) => t.status != 'approved'))
              SettingsGroup(title: s.t('topup_history'), children: [
                for (final topup in wallet.topups)
                  if (topup.status != 'approved')
                  ListTile(
                    title: Text(formatUzs(context, topup.amountUzs), style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: topup.rejectReason.isNotEmpty ? Text(s.t('reject_reason', {'reason': topup.rejectReason})) : null,
                    trailing: Text(s.t('topup_${topup.status}'), style: TextStyle(color: _statusColor(context, topup.status), fontWeight: FontWeight.w600)),
                  ),
              ]),
          ]);
        },
      ),
    );
  }

  Color _statusColor(BuildContext context, String status) => switch (status) {
        'approved' => const Color(0xFF2EAD5B),
        'rejected' => Theme.of(context).colorScheme.error,
        _ => Theme.of(context).hintColor,
      };

  Widget _steps(BuildContext context, Wallet wallet) {
    final s = context.s;
    final theme = Theme.of(context);
    Widget step(int n, String text) => ListTile(
          leading: CircleAvatar(radius: 15, backgroundColor: theme.colorScheme.primary, child: Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
          title: Text(text),
        );
    return SettingsGroup(title: s.t('gifts_topup'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          controller: _amount,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
          decoration: InputDecoration(labelText: s.t('topup_amount'), border: const OutlineInputBorder(), suffixText: "so'm"),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(spacing: 8, children: [
          for (final amount in _quickAmounts)
            ActionChip(label: Text(formatUzs(context, amount)), onPressed: () => setState(() => _amount.text = '$amount')),
        ]),
      ),
      if (wallet.payme) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Semantics(
            button: true,
            label: s.t('topup_payme'),
            child: Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: _paymeTeal, width: 1.6)),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _openingPayme ? null : _payWithPayme,
                child: SizedBox(
                  height: 56,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (_openingPayme)
                      const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: _paymeTeal))
                    else
                      Image.asset('assets/payme.png', height: 28),
                    const SizedBox(width: 12),
                    Text(s.t('topup_payme_via'), style: const TextStyle(color: Color(0xFF1F2A30), fontSize: 16.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(s.t('topup_payme_hint'), textAlign: TextAlign.center, style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
        ),
      ] else ...[
      step(1, s.t('topup_step1')),
      if (wallet.card.isEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(s.t('ad_card_missing'), style: TextStyle(color: theme.colorScheme.error)))
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: const LinearGradient(colors: [Color(0xFF1F2A44), Color(0xFF3D5A80)])),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.t('ad_card'), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                  const SizedBox(height: 4),
                  Text(wallet.card, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                  if (wallet.cardHolder.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(wallet.cardHolder, style: const TextStyle(color: Colors.white70)),
                  ],
                ]),
              ),
              IconButton(
                tooltip: s.t('copy'),
                icon: const Icon(Icons.copy_rounded, color: Colors.white),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: wallet.card.replaceAll(' ', '')));
                  showToast(context, s.t('copied'));
                },
              ),
            ]),
          ),
        ),
      step(2, s.t('topup_step2')),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: FilledButton.icon(
          onPressed: _sending || wallet.card.isEmpty ? null : _sendReceipt,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: _sending ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long_rounded),
          label: Text(s.t('topup_send')),
        ),
      ),
      step(3, s.t('topup_step3')),
      ],
    ]);
  }
}

/// The UZARO balance, big, on a gradient card.
class BalanceCard extends StatelessWidget {
  const BalanceCard({super.key, required this.balanceUzs, this.action});

  final int balanceUzs;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [Color(0xFF0F8F7E), Color(0xFF26C6B0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('gifts_balance'), style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(formatUzs(context, balanceUzs), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
            ]),
          ),
          ?action,
        ]),
      );
}
