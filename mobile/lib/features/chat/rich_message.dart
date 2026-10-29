import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import 'instant_view.dart' show PageBlockView;

/// A rich (article-like) message inside a bubble: its first blocks, with "Read more" when Telegram sent a preview.
class RichMessageView extends ConsumerWidget {
  const RichMessageView({super.key, required this.message, required this.rich});

  static const _previewBlocks = 6;

  final td.Message message;
  final td.RichMessage rich;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    final cut = rich.blocks.length > _previewBlocks;
    return SizedBox(
      width: 300,
      child: Directionality(
        textDirection: rich.isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final block in rich.blocks.take(_previewBlocks)) PageBlockView(block: block),
          if (!rich.isFull || cut)
            TextButton.icon(
              onPressed: () => openFullRichMessage(context, account, message, rich),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: Text(s.t('read_more')),
            ),
        ]),
      ),
    );
  }
}

/// Full rich message: fetched from the server when the bubble only had a preview.
Future<void> openFullRichMessage(BuildContext context, TelegramAccount account, td.Message message, td.RichMessage preview) async {
  final rich = preview.isFull
      ? preview
      : await guard(context, () => account.send<td.RichMessage>(td.GetFullRichMessage(chatId: message.chatId, messageId: message.id)));
  if (rich == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RichMessageScreen(rich: rich, source: message)));
}

/// A rich message page; with [onSend] it previews an AI result before sending, with [source] it can be translated.
class RichMessageScreen extends ConsumerStatefulWidget {
  const RichMessageScreen({super.key, required this.rich, this.source, this.onSend});

  final td.RichMessage rich;
  final td.Message? source;
  final VoidCallback? onSend;

  @override
  ConsumerState<RichMessageScreen> createState() => _RichMessageScreenState();
}

class _RichMessageScreenState extends ConsumerState<RichMessageScreen> {
  late td.RichMessage _rich = widget.rich;
  bool _translated = false;

  Future<void> _translate() async {
    final source = widget.source;
    if (source == null) return;
    if (_translated) {
      setState(() {
        _rich = widget.rich;
        _translated = false;
      });
      return;
    }
    final language = ref.read(settingsProvider).translateTo;
    final result = await guard(
      context,
      () => ref.read(accountProvider).send<td.RichMessage>(
            td.TranslateMessageRichMessage(chatId: source.chatId, messageId: source.id, toLanguageCode: language, tone: ''),
          ),
    );
    if (result != null && mounted) {
      setState(() {
        _rich = result;
        _translated = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.source != null)
            IconButton(icon: Icon(_translated ? Icons.translate_outlined : Icons.translate_rounded), tooltip: s.t('translate'), onPressed: _translate),
          if (widget.onSend != null) TextButton(onPressed: widget.onSend, child: Text(s.t('send'))),
        ],
      ),
      body: Directionality(
        textDirection: _rich.isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [for (final block in _rich.blocks) PageBlockView(block: block)],
        ),
      ),
    );
  }
}

/// The composer text as a rich-message source; Telegram detects headings, lists and quotes from markdown.
td.InputRichMessage richInputFromText(String text) =>
    td.InputRichMessage(source: td.RichMessageSourceMarkdown(text: text, media: const []), isRtl: false, detectAutomaticBlocks: true);

/// Rich blocks written back as markdown, so an AI result can be sent as a rich message.
String richToMarkdown(List<td.PageBlock> blocks) => blocks.map(_blockMarkdown).where((b) => b.isNotEmpty).join('\n\n');

String _blockMarkdown(td.PageBlock block) => switch (block) {
      td.PageBlockTitle(:final title) => '# ${_text(title)}',
      td.PageBlockHeader(:final header) => '# ${_text(header)}',
      td.PageBlockSubtitle(:final subtitle) => '## ${_text(subtitle)}',
      td.PageBlockSubheader(:final subheader) => '## ${_text(subheader)}',
      td.PageBlockSectionHeading(:final text) => '## ${_text(text)}',
      td.PageBlockParagraph(:final text) => _text(text),
      td.PageBlockPreformatted(:final text, :final language) => '```$language\n${_text(text)}\n```',
      td.PageBlockBlockQuote(:final blocks) => blocks.map(_blockMarkdown).map((line) => '> $line').join('\n'),
      td.PageBlockPullQuote(:final text) => '> ${_text(text)}',
      td.PageBlockDivider() => '---',
      td.PageBlockList(:final items) => [
          for (final item in items) '${item.hasCheckbox ? (item.isChecked ? '- [x]' : '- [ ]') : '-'} ${item.blocks.map(_blockMarkdown).join(' ')}',
        ].join('\n'),
      td.PageBlockFooter(:final footer) => _text(footer),
      _ => '',
    };

String _text(td.RichText text) => switch (text) {
      td.RichTextPlain(:final text) => text,
      td.RichTexts(:final texts) => texts.map(_text).join(),
      td.RichTextBold(:final text) => '**${_text(text)}**',
      td.RichTextItalic(:final text) => '__${_text(text)}__',
      td.RichTextStrikethrough(:final text) => '~~${_text(text)}~~',
      td.RichTextFixed(:final text) => '`${_text(text)}`',
      td.RichTextUrl(:final text, :final url) => '[${_text(text)}]($url)',
      td.RichTextUnderline(:final text) => _text(text),
      td.RichTextMarked(:final text) => _text(text),
      td.RichTextEmailAddress(:final text) => _text(text),
      td.RichTextPhoneNumber(:final text) => _text(text),
      td.RichTextSpoiler(:final text) => '||${_text(text)}||',
      _ => '',
    };
