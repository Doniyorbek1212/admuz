import 'package:flutter/material.dart';

import '../../l10n/strings.dart';

/// Builds the article message: the title in bold above the body. Uses Telegram's markdown, which
/// `formattedText` turns into entities when sending.
@visibleForTesting
String articleMarkdown(String title, String body) {
  final t = title.trim();
  final b = body.trim();
  if (t.isEmpty) return b;
  return b.isEmpty ? '**$t**' : '**$t**\n\n$b';
}

/// aka's "Maqola": a title and a formatted body (bold, italic, underline, strike, code, spoiler, link,
/// list, quote) with undo/redo, sent as one message. Pops with the markdown text.
class ArticleEditorScreen extends StatefulWidget {
  const ArticleEditorScreen({super.key});

  @override
  State<ArticleEditorScreen> createState() => _ArticleEditorScreenState();
}

class _ArticleEditorScreenState extends State<ArticleEditorScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _history = UndoHistoryController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _history.dispose();
    super.dispose();
  }

  /// Wraps the selection (or inserts an empty pair at the cursor) in [marker].
  void _wrap(String marker, [String close = '']) {
    final end = close.isEmpty ? marker : close;
    final text = _body.text;
    final selection = _body.selection.isValid ? _body.selection : TextSelection.collapsed(offset: text.length);
    final selected = selection.textInside(text);
    _body.value = TextEditingValue(
      text: selection.textBefore(text) + marker + selected + end + selection.textAfter(text),
      selection: TextSelection(baseOffset: selection.start + marker.length, extentOffset: selection.start + marker.length + selected.length),
    );
  }

  /// Puts [prefix] at the start of every selected line (lists and quotes).
  void _prefixLines(String prefix) {
    final text = _body.text;
    final selection = _body.selection.isValid ? _body.selection : TextSelection.collapsed(offset: text.length);
    final lineStart = text.lastIndexOf('\n', selection.start == 0 ? 0 : selection.start - 1) + 1;
    final block = text.substring(lineStart, selection.end);
    final prefixed = block.split('\n').map((line) => '$prefix$line').join('\n');
    _body.value = TextEditingValue(
      text: text.substring(0, lineStart) + prefixed + text.substring(selection.end),
      selection: TextSelection.collapsed(offset: lineStart + prefixed.length),
    );
  }

  Future<void> _link() async {
    final s = context.s;
    final url = TextEditingController(text: 'https://');
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('link')),
        content: TextField(controller: url, autofocus: true, keyboardType: TextInputType.url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, url.text.trim()), child: Text(s.t('ok'))),
        ],
      ),
    );
    url.dispose();
    if (picked != null && picked.isNotEmpty) _wrap('[', ']($picked)');
  }

  void _send() {
    final text = articleMarkdown(_title.text, _body.text);
    if (text.isEmpty) return;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('article')),
        actions: [
          ValueListenableBuilder<UndoHistoryValue>(
            valueListenable: _history,
            builder: (context, value, _) => Row(
              children: [
                IconButton(icon: const Icon(Icons.undo_rounded), tooltip: s.t('undo'), onPressed: value.canUndo ? _history.undo : null),
                IconButton(icon: const Icon(Icons.redo_rounded), tooltip: s.t('redo'), onPressed: value.canRedo ? _history.redo : null),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              children: [
                TextField(
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(hintText: s.t('article_title'), border: InputBorder.none, hintStyle: TextStyle(color: hint)),
                ),
                TextField(
                  controller: _body,
                  undoController: _history,
                  autofocus: true,
                  minLines: 8,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(fontSize: 17, height: 1.4),
                  decoration: InputDecoration(hintText: s.t('article_body'), border: InputBorder.none, hintStyle: TextStyle(color: hint)),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(26),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _tool(Icons.format_bold_rounded, 'bold', () => _wrap('**')),
                            _tool(Icons.format_italic_rounded, 'italic', () => _wrap('__')),
                            _tool(Icons.format_strikethrough_rounded, 'strikethrough', () => _wrap('~~')),
                            _tool(Icons.code_rounded, 'monospace', () => _wrap('`')),
                            _tool(Icons.visibility_off_outlined, 'spoiler', () => _wrap('||')),
                            _tool(Icons.link_rounded, 'link', _link),
                            _tool(Icons.format_list_bulleted_rounded, 'list', () => _prefixLines('• ')),
                            _tool(Icons.format_quote_rounded, 'quote', () => _prefixLines('> ')),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton(heroTag: null, tooltip: s.t('send'), onPressed: _send, child: const Icon(Icons.send_rounded)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tool(IconData icon, String key, VoidCallback onPressed) =>
      IconButton(icon: Icon(icon), tooltip: context.t(key), onPressed: onPressed);
}
