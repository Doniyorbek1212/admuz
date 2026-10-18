import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/api/market_models.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../hub/ad_banner_card.dart';
import 'business_widgets.dart';

/// One ad's state: pay by card transfer, upload the receipt, then wait for admin approval.
class AdPaymentScreen extends ConsumerStatefulWidget {
  const AdPaymentScreen({super.key, required this.ad});

  final Ad ad;

  @override
  ConsumerState<AdPaymentScreen> createState() => _AdPaymentScreenState();
}

class _AdPaymentScreenState extends ConsumerState<AdPaymentScreen> {
  late Ad _ad = widget.ad;
  late final Future<AdsConfig> _config = ref.read(sadoApiProvider).adsConfig();
  bool _uploading = false;

  bool get _canPay => _ad.status == AdStatus.awaitingPayment || _ad.status == AdStatus.rejected || _ad.status == AdStatus.pendingReview;

  Future<void> _uploadReceipt() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90, maxWidth: 2000);
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    final updated = await apiGuard(context, () => ref.read(sadoApiProvider).uploadReceipt(_ad.id, file.path));
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (updated != null) _ad = updated;
    });
    if (updated != null) showToast(context, context.t('ad_receipt_sent'));
  }

  Future<void> _cancel() async {
    final s = context.s;
    if (!await confirm(context, title: s.t('ad_cancel'), message: s.t('ad_cancel_confirm'), destructive: true)) return;
    if (!mounted) return;
    final done = await apiGuard(context, () async {
      await ref.read(sadoApiProvider).cancelAd(_ad.id);
      return true;
    });
    if (done == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: groupedBackground(context),
      appBar: AppBar(title: Text(s.t('ad_pay_title'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: AspectRatio(aspectRatio: 2.2, child: ClipRRect(borderRadius: BorderRadius.circular(22), child: AdBannerCard(ad: _ad, playVideo: false))),
          ),
          SettingsGroup(children: [
            ListTile(
              title: Text(_ad.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(s.t('ad_regions_list', {'list': _ad.regions.join(', ')})),
              trailing: StatusChip.ad(_ad),
            ),
            ListTile(
              title: Text(s.t('ad_price_total')),
              subtitle: Text(s.t('ad_days', {'n': '${_ad.days}'})),
              trailing: Text(formatUzs(context, _ad.priceUzs), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: theme.colorScheme.primary)),
            ),
            if (_ad.status == AdStatus.rejected && _ad.rejectReason != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(s.t('reject_reason', {'reason': _ad.rejectReason!}), style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_ad.status == AdStatus.approved && _ad.endsAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(s.t('ad_ends', {'date': DateFormat('dd.MM.yyyy HH:mm').format(_ad.endsAt!)})),
              ),
          ]),
          if (_canPay) _paymentSteps(context),
          if (_ad.status != AdStatus.approved)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextButton.icon(
                onPressed: _cancel,
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(s.t('ad_cancel')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _paymentSteps(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    Widget step(int n, String text, {bool done = false}) => ListTile(
          leading: CircleAvatar(
            radius: 15,
            backgroundColor: done ? const Color(0xFF2EAD5B) : theme.colorScheme.primary,
            child: done ? const Icon(Icons.check_rounded, size: 18, color: Colors.white) : Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          title: Text(text),
        );
    return FutureBuilder<AdsConfig>(
      future: _config,
      builder: (context, snapshot) {
        final config = snapshot.data;
        final card = config?.cardNumber ?? '';
        return SettingsGroup(title: s.t('ad_pay_title'), children: [
          step(1, s.t('ad_pay_step1', {'amount': formatUzs(context, _ad.priceUzs)}), done: _ad.hasReceipt),
          if (config != null && card.isEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(s.t('ad_card_missing'), style: TextStyle(color: theme.colorScheme.error))),
          if (card.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(colors: [Color(0xFF1F2A44), Color(0xFF3D5A80)]),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.t('ad_card'), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                          const SizedBox(height: 4),
                          Text(card, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                          if (config!.cardHolder.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(config.cardHolder, style: const TextStyle(color: Colors.white70)),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: s.t('copy'),
                      icon: const Icon(Icons.copy_rounded, color: Colors.white),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: card.replaceAll(' ', '')));
                        showToast(context, s.t('copied'));
                      },
                    ),
                  ],
                ),
              ),
            ),
          step(2, s.t('ad_pay_step2'), done: _ad.status == AdStatus.pendingReview),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: FilledButton.icon(
              onPressed: _uploading ? null : _uploadReceipt,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: _uploading ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long_rounded),
              label: Text(s.t(_ad.hasReceipt ? 'ad_reupload_receipt' : 'ad_upload_receipt')),
            ),
          ),
          step(3, s.t('ad_pay_step3')),
        ]);
      },
    );
  }
}
