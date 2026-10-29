import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../settings/privacy_screen.dart' show promptText;

/// Telegram's AI writing styles ("tones"): the user's list, own styles to create/edit, and styles found by name.
class AiStylesScreen extends ConsumerWidget {
  const AiStylesScreen({super.key});

  Future<void> _create(BuildContext context, TelegramAccount account, {td.TextCompositionStyle? editing}) async {
    final s = context.s;
    final draft = await showDialog<(String, String)>(context: context, builder: (_) => _StyleDialog(initial: editing));
    if (draft == null || !context.mounted) return;
    final (title, prompt) = draft;
    final done = await guard(context, () async {
      if (editing == null) {
        await account.send<td.TextCompositionStyle>(td.CreateTextCompositionStyle(title: title, customEmojiId: 0, prompt: prompt, showCreator: true));
      } else {
        await account.send<td.Ok>(
          td.EditTextCompositionStyle(name: editing.name, title: title, customEmojiId: editing.customEmojiId, prompt: prompt, showCreator: true),
        );
      }
      return true;
    });
    if (done == true && context.mounted) showToast(context, s.t('done'));
  }

  Future<void> _findByName(BuildContext context, TelegramAccount account) async {
    final s = context.s;
    final name = await promptText(context, title: s.t('ai_style_find'), label: s.t('ai_style_name'));
    if (name == null || name.isEmpty || !context.mounted) return;
    final style = await guard(context, () => account.send<td.TextCompositionStyle>(td.SearchTextCompositionStyle(name: name)));
    if (style == null || !context.mounted) return;
    final add = await confirm(context, title: style.title, message: style.prompt.isEmpty ? null : style.prompt, confirmLabel: s.t('add'));
    if (add && context.mounted) await guard(context, () => account.send<td.Ok>(td.AddTextCompositionStyle(name: style.name)));
  }

  Future<void> _example(BuildContext context, TelegramAccount account, td.TextCompositionStyle style) async {
    final example = await guard(
      context,
      () => account.send<td.TextCompositionStyleExample>(td.GetTextCompositionStyleExample(name: style.name, exampleNumber: 0)),
    );
    if (example == null || !context.mounted) return;
    final s = context.s;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(style.title),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(s.t('ai_style_before'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5)),
            SelectableText(example.sourceText.text),
            const SizedBox(height: 12),
            Text(s.t('ai_style_after'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5)),
            SelectableText(example.resultText.text),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('ok')))],
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, TelegramAccount account, td.TextCompositionStyle style, String action) async {
    final s = context.s;
    switch (action) {
      case 'edit':
        await _create(context, account, editing: style);
      case 'remove':
        await guard(context, () => account.send<td.Ok>(td.RemoveTextCompositionStyle(name: style.name)));
      case 'delete':
        if (await confirm(context, title: s.t('delete'), message: style.title, destructive: true) && context.mounted) {
          await guard(context, () => account.send<td.Ok>(td.DeleteTextCompositionStyle(name: style.name)));
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final s = context.s;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('ai_styles')),
        actions: [IconButton(icon: const Icon(Icons.search_rounded), tooltip: s.t('ai_style_find'), onPressed: () => _findByName(context, account))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, account),
        icon: const Icon(Icons.add_rounded),
        label: Text(s.t('ai_style_create')),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: account.compositionStylesRevision,
        builder: (context, _, _) => ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final style in account.compositionStyles)
              ListTile(
                leading: const Icon(Icons.auto_awesome_rounded),
                title: Text(style.title),
                subtitle: style.isCustom && style.prompt.isNotEmpty
                    ? Text(style.prompt, maxLines: 2, overflow: TextOverflow.ellipsis)
                    : (style.installCount > 0 ? Text(s.count('ai_style_users', style.installCount)) : null),
                onTap: () => _example(context, account, style),
                trailing: style.isCustom
                    ? PopupMenuButton<String>(
                        onSelected: (action) => _onMenu(context, account, style, action),
                        itemBuilder: (context) => [
                          if (style.isCreator) PopupMenuItem(value: 'edit', child: Text(s.t('edit'))),
                          PopupMenuItem(value: 'remove', child: Text(s.t('ai_style_remove'))),
                          if (style.isCreator) PopupMenuItem(value: 'delete', child: Text(s.t('delete'))),
                        ],
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _StyleDialog extends StatefulWidget {
  const _StyleDialog({this.initial});

  final td.TextCompositionStyle? initial;

  @override
  State<_StyleDialog> createState() => _StyleDialogState();
}

class _StyleDialogState extends State<_StyleDialog> {
  late final _title = TextEditingController(text: widget.initial?.title);
  late final _prompt = TextEditingController(text: widget.initial?.prompt);

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AlertDialog(
      title: Text(s.t(widget.initial == null ? 'ai_style_create' : 'edit')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _title, autofocus: true, maxLength: 32, decoration: InputDecoration(labelText: s.t('ai_style_title'))),
        TextField(
          controller: _prompt,
          minLines: 3,
          maxLines: 6,
          maxLength: 1024,
          decoration: InputDecoration(labelText: s.t('ai_style_prompt'), hintText: s.t('ai_style_prompt_hint')),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            final prompt = _prompt.text.trim();
            if (title.isEmpty || prompt.isEmpty) return;
            Navigator.pop(context, (title, prompt));
          },
          child: Text(s.t('save')),
        ),
      ],
    );
  }
}
