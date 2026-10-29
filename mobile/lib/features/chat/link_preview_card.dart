import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../widgets/common.dart';
import 'instant_view.dart';
import 'link_router.dart';
import 'message_content.dart' show bestPhotoSize;

/// Link preview under a text message: site, title, description, picture and the Instant View button.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({super.key, required this.preview, required this.textColor});

  final td.LinkPreview preview;
  final Color textColor;

  td.Photo? get _photo => switch (preview.type) {
        td.LinkPreviewTypeArticle(:final photo) => photo,
        td.LinkPreviewTypePhoto(:final photo) => photo,
        td.LinkPreviewTypeEmbeddedVideoPlayer(:final thumbnail) => thumbnail,
        td.LinkPreviewTypeApp(:final photo) => photo,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final accent = Theme.of(context).colorScheme.primary;
    final photo = _photo;
    final size = photo == null ? null : bestPhotoSize(photo, target: preview.showLargeMedia ? 800 : 160);
    final large = size != null && preview.showLargeMedia;
    final hasIv = preview.instantViewVersion > 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => hasIv ? _openInstantView(context) : openLink(context, preview.url),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (preview.siteName.isNotEmpty) Text(preview.siteName, style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13.5)),
                  if (preview.title.isNotEmpty)
                    Text(preview.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 14)),
                  if (preview.description.text.isNotEmpty)
                    Text(preview.description.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: textColor, fontSize: 13.5, height: 1.25)),
                ]),
              ),
              if (size != null && !large)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ClipRRect(borderRadius: BorderRadius.circular(6), child: TdImage(file: size.photo, minithumbnail: photo?.minithumbnail, width: 56, height: 56)),
                ),
            ]),
            if (large)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(
                    aspectRatio: size.height > 0 ? (size.width / size.height).clamp(0.6, 2.2) : 16 / 9,
                    child: TdImage(file: size.photo, minithumbnail: photo?.minithumbnail),
                  ),
                ),
              ),
            if (hasIv)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openInstantView(context),
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                    label: Text(s.t('instant_view')),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  void _openInstantView(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InstantViewScreen(url: preview.url, title: preview.siteName)));
}
