import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'link_router.dart';
import 'media_viewers.dart';
import 'message_content.dart' show bestPhotoSize;

/// Telegram Instant View: the article TDLib extracted from a web page, rendered natively.
class InstantViewScreen extends ConsumerStatefulWidget {
  const InstantViewScreen({super.key, required this.url, this.title = ''});

  final String url;
  final String title;

  @override
  ConsumerState<InstantViewScreen> createState() => _InstantViewScreenState();
}

class _InstantViewScreenState extends ConsumerState<InstantViewScreen> {
  td.WebPageInstantView? _page;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await ref.read(accountProvider).send<td.WebPageInstantView>(td.GetWebPageInstantView(url: widget.url, onlyLocal: false));
      if (mounted) setState(() => _page = page);
    } on Exception catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? Uri.tryParse(widget.url)?.host ?? '' : widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(icon: const Icon(Icons.share_rounded), tooltip: s.t('share'), onPressed: () => SharePlus.instance.share(ShareParams(text: widget.url))),
          IconButton(icon: const Icon(Icons.open_in_browser_rounded), tooltip: s.t('open_in_browser'), onPressed: () => openLink(context, widget.url)),
        ],
      ),
      body: switch ((page, _error)) {
        (_, final error?) => EmptyState(icon: Icons.article_outlined, title: errorText(context, error), action: TextButton(onPressed: () => openLink(context, widget.url), child: Text(s.t('open_in_browser')))),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final page?, _) => Directionality(
            textDirection: page.isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                for (final block in page.blocks) PageBlockView(block: block),
                if (page.viewCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text(s.t('iv_views', {'n': formatCount(page.viewCount)}), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
                  ),
              ],
            ),
          ),
      },
    );
  }
}

/// One Instant View block; nested blocks (lists, quotes, details) recurse.
class PageBlockView extends StatelessWidget {
  const PageBlockView({super.key, required this.block});

  final td.PageBlock block;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final base = theme.textTheme.bodyLarge?.copyWith(height: 1.45) ?? const TextStyle();
    Widget text(td.RichText value, TextStyle style) => Text.rich(richTextSpan(context, value, style));
    Widget pad(Widget child, [double top = 10]) => Padding(padding: EdgeInsets.only(top: top), child: child);

    return switch (block) {
      td.PageBlockTitle(:final title) => pad(text(title, base.copyWith(fontSize: 26, fontWeight: FontWeight.w700, height: 1.2)), 4),
      td.PageBlockSubtitle(:final subtitle) => pad(text(subtitle, base.copyWith(fontSize: 19, color: hint))),
      td.PageBlockKicker(:final kicker) => pad(text(kicker, base.copyWith(fontSize: 13, letterSpacing: 1, color: theme.colorScheme.primary))),
      td.PageBlockAuthorDate(:final author, :final publishDate) => pad(Text.rich(TextSpan(children: [
            richTextSpan(context, author, base.copyWith(fontSize: 13, color: hint)),
            if (publishDate > 0) TextSpan(text: ' • ${formatChatTime(publishDate, context.s.locale)}', style: base.copyWith(fontSize: 13, color: hint)),
          ]))),
      td.PageBlockHeader(:final header) => pad(text(header, base.copyWith(fontSize: 22, fontWeight: FontWeight.w700)), 18),
      td.PageBlockSubheader(:final subheader) => pad(text(subheader, base.copyWith(fontSize: 18, fontWeight: FontWeight.w600)), 14),
      td.PageBlockSectionHeading(:final text) => pad(Text.rich(richTextSpan(context, text, base.copyWith(fontSize: 18, fontWeight: FontWeight.w600))), 14),
      td.PageBlockParagraph(text: final value) => pad(text(value, base)),
      td.PageBlockPreformatted(text: final value) => pad(Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: text(value, base.copyWith(fontFamily: 'monospace', fontSize: 13.5))),
          )),
      td.PageBlockFooter(:final footer) => pad(text(footer, base.copyWith(fontSize: 13, color: hint)), 16),
      td.PageBlockDivider() => const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider()),
      td.PageBlockAnchor() => const SizedBox.shrink(),
      td.PageBlockList(:final items) => pad(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final item in items)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 28,
                  child: item.hasCheckbox
                      ? Icon(item.isChecked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 18)
                      : Padding(padding: const EdgeInsets.only(top: 10), child: Text(item.label.isEmpty ? '•' : item.label, style: base)),
                ),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final b in item.blocks) PageBlockView(block: b)])),
              ]),
          ])),
      td.PageBlockBlockQuote(:final blocks, :final credit) => pad(Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final b in blocks) PageBlockView(block: b),
              if (credit != null) pad(text(credit, base.copyWith(fontSize: 13, color: hint)), 4),
            ]),
          )),
      td.PageBlockPullQuote(text: final value, :final credit) || td.PageBlockExpandableBlockQuote(text: final value, :final credit) => pad(Column(children: [
            text(value, base.copyWith(fontSize: 19, fontStyle: FontStyle.italic)),
            if (credit != null) pad(text(credit, base.copyWith(fontSize: 13, color: hint)), 4),
          ])),
      td.PageBlockPhoto(:final photo?, :final caption) => pad(_Media(photo: photo, caption: caption)),
      td.PageBlockVideo(:final video?, :final caption) => pad(_Media(thumbnail: video.thumbnail?.file, minithumbnail: video.minithumbnail, video: video.video, caption: caption)),
      td.PageBlockAnimation(:final animation?, :final caption) =>
        pad(_Media(thumbnail: animation.thumbnail?.file, minithumbnail: animation.minithumbnail, video: animation.animation, caption: caption)),
      td.PageBlockCover(:final cover) => PageBlockView(block: cover),
      td.PageBlockCollage(:final blocks, :final caption) || td.PageBlockSlideshow(:final blocks, :final caption) => pad(Column(children: [
            for (final b in blocks) PageBlockView(block: b),
            if (caption != null) _Caption(caption: caption),
          ])),
      td.PageBlockEmbedded(:final url, :final posterPhoto, :final caption) => pad(Column(children: [
            if (posterPhoto != null) _Media(photo: posterPhoto),
            if (url.isNotEmpty) TextButton.icon(onPressed: () => openLink(context, url), icon: const Icon(Icons.open_in_new_rounded), label: Text(Uri.tryParse(url)?.host ?? url)),
            if (caption != null) _Caption(caption: caption),
          ])),
      td.PageBlockEmbeddedPost(:final url, :final author, :final date, :final blocks, :final caption) => pad(Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: hint, width: 2))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                onTap: url.isEmpty ? null : () => openLink(context, url),
                child: Text('$author${date > 0 ? ' • ${formatChatTime(date, context.s.locale)}' : ''}', style: base.copyWith(fontWeight: FontWeight.w600)),
              ),
              for (final b in blocks) PageBlockView(block: b),
              _Caption(caption: caption),
            ]),
          )),
      td.PageBlockDetails(:final header, :final blocks, :final isOpen) => ExpansionTile(
          initiallyExpanded: isOpen,
          tilePadding: EdgeInsets.zero,
          title: text(header, base.copyWith(fontWeight: FontWeight.w600)),
          children: [for (final b in blocks) PageBlockView(block: b)],
        ),
      td.PageBlockRelatedArticles(:final header, :final articles) => pad(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            text(header, base.copyWith(fontWeight: FontWeight.w700)),
            for (final article in articles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: switch (article.photo) {
                  final photo? when bestPhotoSize(photo, target: 160) != null =>
                    ClipRRect(borderRadius: BorderRadius.circular(6), child: TdImage(file: bestPhotoSize(photo, target: 160)!.photo, width: 56, height: 56)),
                  _ => null,
                },
                title: Text(article.title.isEmpty ? article.url : article.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: article.description.isEmpty ? null : Text(article.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InstantViewScreen(url: article.url, title: article.title))),
              ),
          ])),
      td.PageBlockTable(:final caption, :final cells) => pad(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (caption != null) text(caption, base.copyWith(fontWeight: FontWeight.w600)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                border: TableBorder.all(color: theme.dividerColor),
                children: [
                  for (final row in _squareRows(cells))
                    TableRow(children: [
                      for (final cell in row)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: cell?.text == null ? const SizedBox.shrink() : text(cell!.text!, base.copyWith(fontSize: 14, fontWeight: cell.isHeader ? FontWeight.w700 : null)),
                        ),
                    ]),
                ],
              ),
            ),
          ])),
      td.PageBlockChatLink(:final title, :final username) => pad(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.forum_rounded),
          title: Text(title),
          subtitle: Text('@$username'),
          onTap: () => openLink(context, 'https://t.me/$username'),
        )),
      td.PageBlockMap(:final location, :final caption) => pad(Column(children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.map_rounded),
              title: Text('${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}'),
              onTap: () => openLink(context, 'https://www.openstreetmap.org/?mlat=${location.latitude}&mlon=${location.longitude}'),
            ),
            _Caption(caption: caption),
          ])),
      td.PageBlockAudio(:final caption) || td.PageBlockVoiceNote(:final caption) => _Caption(caption: caption),
      _ => const SizedBox.shrink(),
    };
  }

  /// Table rows padded to equal length (Flutter's Table needs it); colspan/rowspan are flattened.
  static List<List<td.PageBlockTableCell?>> _squareRows(List<List<td.PageBlockTableCell>> rows) {
    final width = rows.fold(0, (w, r) => r.length > w ? r.length : w);
    return [for (final r in rows) [...r, for (var i = r.length; i < width; i++) null]];
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.caption});

  final td.PageBlockCaption? caption;

  @override
  Widget build(BuildContext context) {
    final caption = this.caption;
    if (caption == null) return const SizedBox.shrink();
    final style = TextStyle(fontSize: 13, color: Theme.of(context).hintColor);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(TextSpan(children: [
        richTextSpan(context, caption.text, style),
        if (caption.credit case final credit?) ...[const TextSpan(text: '\n'), richTextSpan(context, credit, style.copyWith(fontStyle: FontStyle.italic))],
      ])),
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({this.photo, this.thumbnail, this.minithumbnail, this.video, this.caption});

  final td.Photo? photo;
  final td.File? thumbnail;
  final td.Minithumbnail? minithumbnail;
  final td.File? video;
  final td.PageBlockCaption? caption;

  @override
  Widget build(BuildContext context) {
    final size = photo == null ? null : bestPhotoSize(photo!);
    final file = size?.photo ?? thumbnail;
    final mini = photo?.minithumbnail ?? minithumbnail;
    final aspect = size != null && size.height > 0 ? size.width / size.height : 16 / 9;
    final video = this.video;
    return Column(children: [
      GestureDetector(
        onTap: video != null ? () => openVideoPlayer(context, video) : (file == null ? null : () => openPhotoViewer(context, file, mini)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(fit: StackFit.expand, children: [
              if (file != null) TdImage(file: file, minithumbnail: mini) else ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
              if (video != null) const Center(child: Icon(Icons.play_circle_fill_rounded, size: 52, color: Colors.white70)),
            ]),
          ),
        ),
      ),
      _Caption(caption: caption),
    ]);
  }
}

/// Converts Instant View rich text to a span; links open through the app's link checker.
InlineSpan richTextSpan(BuildContext context, td.RichText value, TextStyle style) {
  final link = style.copyWith(color: Theme.of(context).colorScheme.primary);
  InlineSpan go(td.RichText v, TextStyle st) => richTextSpan(context, v, st);
  InlineSpan linked(td.RichText v, String url) => TextSpan(
        children: [go(v, link)],
        recognizer: TapGestureRecognizer()..onTap = () => openLink(context, url),
      );
  return switch (value) {
    td.RichTextPlain(:final text) => TextSpan(text: text, style: style),
    td.RichTexts(:final texts) => TextSpan(children: [for (final t in texts) go(t, style)]),
    td.RichTextBold(:final text) => go(text, style.copyWith(fontWeight: FontWeight.w700)),
    td.RichTextItalic(:final text) => go(text, style.copyWith(fontStyle: FontStyle.italic)),
    td.RichTextUnderline(:final text) => go(text, style.copyWith(decoration: TextDecoration.underline)),
    td.RichTextStrikethrough(:final text) => go(text, style.copyWith(decoration: TextDecoration.lineThrough)),
    td.RichTextFixed(:final text) => go(text, style.copyWith(fontFamily: 'monospace')),
    td.RichTextMarked(:final text) => go(text, style.copyWith(backgroundColor: Colors.yellow.withValues(alpha: 0.35))),
    td.RichTextSubscript(:final text) || td.RichTextSuperscript(:final text) => go(text, style.copyWith(fontSize: (style.fontSize ?? 16) * 0.75)),
    td.RichTextUrl(:final text, :final url) => linked(text, url),
    td.RichTextAnchorLink(:final text, :final url) => url.isEmpty ? go(text, link) : linked(text, url),
    td.RichTextEmailAddress(:final text, :final emailAddress) => linked(text, 'mailto:$emailAddress'),
    td.RichTextPhoneNumber(:final text, :final phoneNumber) => linked(text, 'tel:$phoneNumber'),
    td.RichTextReference(:final text) || td.RichTextSpoiler(:final text) => go(text, style),
    _ => const TextSpan(),
  };
}
