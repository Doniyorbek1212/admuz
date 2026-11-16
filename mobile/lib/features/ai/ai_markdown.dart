import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The Markdown UZARO AI writes: headings, bullet and numbered lists, quotes, code blocks, **bold**, *italic*
/// and `code`. shortcut: no tables or links as widgets (shown as text), add them if answers start using them.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdItem extends MdBlock {
  const MdItem(this.marker, this.text, this.indent);
  final String marker; // '•' or '3.'
  final String text;
  final int indent;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.language, this.code);
  final String language;
  final String code;
}

final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');

List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isNotEmpty) blocks.add(MdParagraph(paragraph.join('\n')));
    paragraph.clear();
  }

  final lines = source.replaceAll('\r\n', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    // ```code``` on one line is inline code, not a fence that would swallow the rest of the answer.
    if (trimmed.startsWith('```') && !trimmed.substring(3).contains('```')) {
      flush();
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      while (++i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        code.add(lines[i]);
      }
      blocks.add(MdCode(language, code.join('\n'))); // an unclosed block (still streaming) runs to the end
      continue;
    }
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    final h = _heading.firstMatch(trimmed);
    final b = _bullet.firstMatch(line);
    final n = _numbered.firstMatch(line);
    if (h != null) {
      flush();
      blocks.add(MdHeading(h.group(1)!.length, h.group(2)!));
    } else if (b != null && !RegExp(r'^\s*[-*_]{3,}\s*$').hasMatch(line)) {
      flush();
      blocks.add(MdItem('•', b.group(2)!, b.group(1)!.length ~/ 2));
    } else if (n != null) {
      flush();
      blocks.add(MdItem('${n.group(2)}.', n.group(3)!, n.group(1)!.length ~/ 2));
    } else if (trimmed.startsWith('>')) {
      flush();
      blocks.add(MdQuote(trimmed.substring(1).trim()));
    } else if (RegExp(r'^[-*_]{3,}$').hasMatch(trimmed)) {
      flush();
    } else {
      paragraph.add(line.trim());
    }
  }
  flush();
  return blocks;
}

final _inline = RegExp(r'(\*\*|__)(.+?)\1|`([^`]+)`|(?<![\w*])[*_](?![\s*_])(.+?)(?<![\s*_])[*_](?![\w*])');

/// **bold**, *italic* and `code` inside one line of text.
List<InlineSpan> inlineSpans(String text, TextStyle code) {
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    if (m.group(2) != null) {
      spans.add(TextSpan(text: m.group(2), style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (m.group(3) != null) {
      spans.add(TextSpan(text: m.group(3), style: code));
    } else {
      spans.add(TextSpan(text: m.group(4), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

class AiMarkdown extends StatelessWidget {
  const AiMarkdown(this.text, {super.key, this.onCopyCode});

  final String text;
  final ValueChanged<String>? onCopyCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge!.copyWith(height: 1.45);
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: (base.fontSize ?? 16) * 0.9,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    );
    Widget rich(String t, [TextStyle? style]) => Text.rich(TextSpan(style: style ?? base, children: inlineSpans(t, codeStyle)));
    final children = <Widget>[];
    for (final block in parseMarkdown(text)) {
      children.add(switch (block) {
        MdHeading(:final level, :final text) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: rich(text, base.copyWith(fontSize: level <= 1 ? 22 : level == 2 ? 19 : 17, fontWeight: FontWeight.w700)),
          ),
        MdParagraph(:final text) => rich(text),
        MdItem(:final marker, :final text, :final indent) => Padding(
            padding: EdgeInsets.only(left: 4.0 + indent * 18),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: marker == '•' ? 18 : 26, child: Text(marker, style: base.copyWith(fontWeight: FontWeight.w600))),
              Expanded(child: rich(text)),
            ]),
          ),
        MdQuote(:final text) => Container(
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 3))),
            child: rich(text, base.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        MdCode(:final language, :final code) => _CodeBlock(language: language, code: code, onCopy: onCopyCode),
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code, this.onCopy});

  final String language;
  final String code;
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: const Color(0xFF1E1F24), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(children: [
            Text(language.isEmpty ? 'code' : language, style: const TextStyle(color: Colors.white60, fontSize: 12)),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.white70),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                onCopy?.call(code);
              },
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(code, style: TextStyle(fontFamily: 'monospace', fontSize: 13.5, color: const Color(0xFFE6E6E6), height: theme.textTheme.bodySmall?.height)),
        ),
      ]),
    );
  }
}
