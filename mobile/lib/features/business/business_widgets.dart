import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/market_models.dart';
import '../../core/config.dart';
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../widgets/common.dart';

/// Localized message for a server error code.
String apiErrorText(BuildContext context, ApiException error) {
  final s = context.s;
  final key = 'api_${error.code}';
  final text = s.t(key);
  return text == key ? s.t('api_generic', {'code': error.code}) : text;
}

/// Runs a server call and shows failures as a toast. Returns null on failure.
Future<T?> apiGuard<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on ApiException catch (error) {
    if (context.mounted) showToast(context, apiErrorText(context, error));
    return null;
  }
}

/// "1 250 000 so'm".
String formatUzs(BuildContext context, int amount) {
  final digits = amount.toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(' ');
    grouped.write(digits[i]);
  }
  return context.t('som', {'n': grouped.toString()});
}

bool isHttpsUrl(String value) => RegExp(r'''^https://[^\s<>"']+$''').hasMatch(value.trim());

/// Loadable media: an https link or a file on the Sado server (which may be plain http in development).
bool _loadable(String url) => isHttpsUrl(url) || (AppConfig.apiUrl.isNotEmpty && url.startsWith('${AppConfig.apiUrl}/media/'));

/// Can [url] be played or shown (https, or a Sado server file)?
bool isLoadableMedia(String url) => _loadable(resolveMediaUrl(url.trim()));

String? validateRequired(BuildContext context, String? value) => (value ?? '').trim().isEmpty ? context.t('field_required') : null;

String? validateOptionalUrl(BuildContext context, String? value) =>
    (value ?? '').trim().isEmpty || isHttpsUrl(value!) ? null : context.t('url_invalid');

String? validateRequiredUrl(BuildContext context, String? value) => validateRequired(context, value) ?? validateOptionalUrl(context, value);

/// Required media: an https link or a file uploaded to the Sado server.
String? validateMediaUrl(BuildContext context, String? value) =>
    (value ?? '').trim().startsWith('/media/') ? null : validateRequiredUrl(context, value);

/// Colored pill for a shop or ad review state.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.labelKey, required this.color});

  factory StatusChip.listing(ListingStatus status) => switch (status) {
        ListingStatus.awaitingPayment => const StatusChip(labelKey: 'status_awaiting_payment', color: Color(0xFF3D8BFF)),
        ListingStatus.closed => const StatusChip(labelKey: 'status_closed', color: Color(0xFF8E8E93)),
        ListingStatus.pending => const StatusChip(labelKey: 'status_pending', color: Color(0xFFF5A623)),
        ListingStatus.approved => const StatusChip(labelKey: 'status_approved', color: Color(0xFF2EAD5B)),
        ListingStatus.rejected => const StatusChip(labelKey: 'status_rejected', color: Color(0xFFE5486A)),
      };

  factory StatusChip.ad(Ad ad) {
    final ended = ad.status == AdStatus.approved && ad.endsAt != null && ad.endsAt!.isBefore(DateTime.now());
    if (ended) return const StatusChip(labelKey: 'status_ended', color: Color(0xFF8E8E93));
    return switch (ad.status) {
      AdStatus.awaitingPayment => const StatusChip(labelKey: 'status_awaiting_payment', color: Color(0xFF3D8BFF)),
      AdStatus.pendingReview => const StatusChip(labelKey: 'status_pending_review', color: Color(0xFFF5A623)),
      AdStatus.approved => const StatusChip(labelKey: 'status_approved', color: Color(0xFF2EAD5B)),
      AdStatus.rejected => const StatusChip(labelKey: 'status_rejected', color: Color(0xFFE5486A)),
    };
  }

  final String labelKey;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Text(context.t(labelKey), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

/// Network image with a neutral placeholder and a broken-image fallback. Accepts "/media/..." server paths.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.icon = Icons.image_outlined});

  final String url;
  final BoxFit fit;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).hintColor.withValues(alpha: 0.12),
      child: Center(child: Icon(icon, color: Theme.of(context).hintColor)),
    );
    final resolved = resolveMediaUrl(url.trim());
    if (!_loadable(resolved)) return placeholder;
    return Image.network(
      resolved,
      fit: fit,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (context, child, progress) => progress == null ? child : placeholder,
    );
  }
}

/// Image for an ad: the picture itself, or a YouTube thumbnail with a play mark for videos.
class AdMediaPreview extends StatelessWidget {
  const AdMediaPreview({super.key, required this.url, required this.isVideo});

  final String url;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final yt = isVideo ? youtubeId(url) : null;
    final image = NetImage(yt != null ? 'https://img.youtube.com/vi/$yt/hqdefault.jpg' : (isVideo ? '' : url), icon: isVideo ? Icons.movie_outlined : Icons.image_outlined);
    if (!isVideo) return image;
    // A direct video has no still: a dark backdrop keeps the play mark readable.
    if (yt == null) {
      return const ColoredBox(
        color: Color(0xFF1C232D),
        child: Center(child: CircleAvatar(radius: 24, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32))),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        const Center(child: CircleAvatar(radius: 24, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32))),
      ],
    );
  }
}

/// Manual card-transfer payment: amount, card number with copy, and receipt upload.
class CardPaymentBox extends StatelessWidget {
  const CardPaymentBox({super.key, required this.config, required this.amountUzs, required this.hasReceipt, required this.uploading, required this.onUpload});

  final AdsConfig? config;
  final int amountUzs;
  final bool hasReceipt;
  final bool uploading;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final theme = Theme.of(context);
    final config = this.config;
    final card = config?.cardNumber ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(s.t('ad_pay_step1', {'amount': formatUzs(context, amountUzs)}), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (config != null && card.isEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(s.t('ad_card_missing'), style: TextStyle(color: theme.colorScheme.error))),
        if (config != null && card.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: const LinearGradient(colors: [Color(0xFF1F2A44), Color(0xFF3D5A80)])),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.t('ad_card'), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                        const SizedBox(height: 4),
                        Text(card, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                        if (config.cardHolder.isNotEmpty) Text(config.cardHolder, style: const TextStyle(color: Colors.white70)),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: FilledButton.icon(
            onPressed: uploading ? null : onUpload,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: uploading ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long_rounded),
            label: Text(s.t(hasReceipt ? 'ad_reupload_receipt' : 'ad_upload_receipt')),
          ),
        ),
      ],
    );
  }
}

/// Small stat tile for the shop dashboard.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.color, required this.label, required this.value, this.caption});

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09), borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.hintColor, fontSize: 12.5)),
          if (caption != null) Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Price with an optional crossed-out old price and discount badge, Uzum-style.
class PriceLine extends StatelessWidget {
  const PriceLine({super.key, required this.product, this.big = false});

  final Product product;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final old = product.oldPriceUzs;
    final percent = product.discountPercent;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 2,
      children: [
        Text(formatUzs(context, product.priceUzs),
            style: TextStyle(fontSize: big ? 24 : 15, fontWeight: FontWeight.w800, color: percent > 0 ? const Color(0xFFE5486A) : theme.colorScheme.onSurface)),
        if (percent > 0 && old != null)
          Text(formatUzs(context, old), style: TextStyle(fontSize: big ? 15 : 12, color: theme.hintColor, decoration: TextDecoration.lineThrough)),
      ],
    );
  }
}

/// "-25%" sticker for product photos.
class DiscountBadge extends StatelessWidget {
  const DiscountBadge({super.key, required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xFFE5486A), borderRadius: BorderRadius.circular(8)),
        child: Text(context.t('discount', {'n': '$percent'}), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
      );
}
