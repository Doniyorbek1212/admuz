import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart' show pickOption, promptText;

/// Amount in the smallest currency units as text ("12.50 USD"); 2 decimals cover nearly every currency.
String formatInvoiceAmount(int amount, String currency) => '${(amount / 100).toStringAsFixed(2)} $currency';

/// Pays a card (regular) invoice: order info and shipping when asked, then a card saved in Telegram,
/// unlocked with a temporary 2-step password. New cards need the provider's own form (opened outside).
Future<String> payRegularInvoice(BuildContext context, TelegramAccount account, td.InputInvoice input, td.PaymentForm form, td.PaymentFormTypeRegular regular) async {
  final s = context.s;
  final invoice = regular.invoice;
  var orderInfoId = '';
  var shippingId = '';
  var shippingAmount = 0;
  if (invoice.needName || invoice.needPhoneNumber || invoice.needEmailAddress || invoice.needShippingAddress) {
    var saved = regular.savedOrderInfo;
    if (saved == null) {
      try {
        saved = await account.send<td.OrderInfo>(const td.GetSavedOrderInfo());
      } on TdException catch (error) {
        debugPrint('no saved order info: $error');
      }
    }
    if (!context.mounted) return 'cancelled';
    final info = await _askOrderInfo(context, invoice, saved);
    if (info == null || !context.mounted) return 'cancelled';
    final validated = await guard(context, () => account.send<td.ValidatedOrderInfo>(td.ValidateOrderInfo(inputInvoice: input, orderInfo: info, allowSave: true)));
    if (validated == null || !context.mounted) return 'failed';
    orderInfoId = validated.orderInfoId;
    if (validated.shippingOptions.isNotEmpty) {
      int total(td.ShippingOption o) => o.priceParts.fold(0, (sum, p) => sum + p.amount);
      final picked = await pickOption<String>(
        context,
        s.t('payment_shipping'),
        {for (final o in validated.shippingOptions) o.id: '${o.title} · ${formatInvoiceAmount(total(o), invoice.currency)}'},
        null,
      );
      if (picked == null || !context.mounted) return 'cancelled';
      shippingId = picked;
      shippingAmount = total(validated.shippingOptions.firstWhere((o) => o.id == picked));
    }
  }
  if (regular.savedCredentials.isEmpty) {
    if (regular.paymentProvider case td.PaymentProviderOther(:final url)) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return 'pending';
    }
    showToast(context, s.t('payment_card_unsupported'));
    return 'failed';
  }
  final credentialsId = regular.savedCredentials.length == 1
      ? regular.savedCredentials.first.id
      : await pickOption<String>(context, s.t('payment_card'), {for (final c in regular.savedCredentials) c.id: c.title}, regular.savedCredentials.first.id);
  if (credentialsId == null || !context.mounted) return 'cancelled';
  if (!await _ensureTemporaryPassword(context, account)) return 'cancelled';
  if (!context.mounted) return 'cancelled';
  final price = invoice.priceParts.fold(0, (sum, p) => sum + p.amount) + shippingAmount;
  final card = regular.savedCredentials.firstWhere((c) => c.id == credentialsId).title;
  final ok = await confirm(
    context,
    title: form.productInfo.title,
    message: s.t('payment_card_confirm', {'amount': formatInvoiceAmount(price, invoice.currency), 'card': card}),
    confirmLabel: s.t('pay'),
  );
  if (!ok || !context.mounted) return 'cancelled';
  final result = await guard(
    context,
    () => account.send<td.PaymentResult>(td.SendPaymentForm(
      inputInvoice: input,
      paymentFormId: form.id,
      orderInfoId: orderInfoId,
      shippingOptionId: shippingId,
      credentials: td.InputCredentialsSaved(savedCredentialsId: credentialsId),
      tipAmount: 0,
    )),
  );
  if (result == null || !context.mounted) return 'failed';
  if (result.verificationUrl.isNotEmpty) {
    await launchUrl(Uri.parse(result.verificationUrl), mode: LaunchMode.externalApplication);
    return 'pending';
  }
  if (result.success) showToast(context, s.t('payment_done'));
  return result.success ? 'paid' : 'failed';
}

/// Saved cards are used only with a short-lived password made from the 2-step verification password.
Future<bool> _ensureTemporaryPassword(BuildContext context, TelegramAccount account) async {
  final state = await guard(context, () => account.send<td.TemporaryPasswordState>(const td.GetTemporaryPasswordState()));
  if (state == null || !context.mounted) return false;
  if (state.hasPassword && state.validFor > 60) return true;
  final s = context.s;
  final password = await promptText(context, title: s.t('payment_password'), label: s.t('password'), obscure: true);
  if (password == null || password.isEmpty || !context.mounted) return false;
  final created = await guard(context, () => account.send<td.TemporaryPasswordState>(td.CreateTemporaryPassword(password: password, validFor: 30 * 60)));
  return created?.hasPassword ?? false;
}

Future<td.OrderInfo?> _askOrderInfo(BuildContext context, td.Invoice invoice, td.OrderInfo? saved) {
  final s = context.s;
  final address = saved?.shippingAddress;
  final fields = <String, TextEditingController>{
    if (invoice.needName) 'name': TextEditingController(text: saved?.name ?? ''),
    if (invoice.needPhoneNumber) 'phone': TextEditingController(text: saved?.phoneNumber ?? ''),
    if (invoice.needEmailAddress) 'email': TextEditingController(text: saved?.emailAddress ?? ''),
    if (invoice.needShippingAddress) ...{
      'country': TextEditingController(text: address?.countryCode ?? 'UZ'),
      'state': TextEditingController(text: address?.state ?? ''),
      'city': TextEditingController(text: address?.city ?? ''),
      'street1': TextEditingController(text: address?.streetLine1 ?? ''),
      'street2': TextEditingController(text: address?.streetLine2 ?? ''),
      'postal': TextEditingController(text: address?.postalCode ?? ''),
    },
  };
  return showDialog<td.OrderInfo>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('payment_order_info')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final MapEntry(key: key, value: controller) in fields.entries)
            TextField(controller: controller, decoration: InputDecoration(labelText: s.t('order_$key'))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        TextButton(
          onPressed: () {
            String v(String key) => fields[key]?.text.trim() ?? '';
            Navigator.pop(
              context,
              td.OrderInfo(
                name: v('name'),
                phoneNumber: v('phone'),
                emailAddress: v('email'),
                shippingAddress: invoice.needShippingAddress
                    ? td.Address(
                        countryCode: v('country').toUpperCase(),
                        state: v('state'),
                        city: v('city'),
                        streetLine1: v('street1'),
                        streetLine2: v('street2'),
                        postalCode: v('postal'),
                      )
                    : null,
              ),
            );
          },
          child: Text(s.t('next')),
        ),
      ],
    ),
  );
}

/// Tapped card number in a message: what Telegram knows about the card (bank, actions) plus copy.
Future<void> showBankCardInfo(BuildContext context, TelegramAccount account, String number) async {
  final digits = number.replaceAll(RegExp(r'\D'), '');
  td.BankCardInfo? info;
  try {
    info = await account.send<td.BankCardInfo>(td.GetBankCardInfo(bankCardNumber: digits));
  } on TdException catch (error) {
    debugPrint('bank card info unavailable: $error');
  }
  if (!context.mounted) return;
  final s = context.s;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(info?.title.isNotEmpty == true ? info!.title : number, style: const TextStyle(fontWeight: FontWeight.w700))),
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: Text(s.t('copy')),
          onTap: () {
            Clipboard.setData(ClipboardData(text: digits));
            Navigator.pop(context);
            showToast(context, s.t('copied'));
          },
        ),
        for (final action in info?.actions ?? const <td.BankCardActionOpenUrl>[])
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: Text(action.text),
            onTap: () {
              Navigator.pop(context);
              launchUrl(Uri.parse(action.url), mode: LaunchMode.externalApplication);
            },
          ),
      ]),
    ),
  );
}
