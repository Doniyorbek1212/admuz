import 'package:flutter/material.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../widgets/common.dart';

/// Telegram's checklist ("Ro'yxat"): a title and tasks others can tick off. Pops with the checklist to send.
/// Sending needs Telegram Premium; TDLib reports the error otherwise.
class ChecklistCreatorScreen extends StatefulWidget {
  const ChecklistCreatorScreen({super.key});

  static const maxTasks = 30;

  @override
  State<ChecklistCreatorScreen> createState() => _ChecklistCreatorScreenState();
}

class _ChecklistCreatorScreenState extends State<ChecklistCreatorScreen> {
  final _title = TextEditingController();
  final List<TextEditingController> _tasks = [TextEditingController()];
  bool _othersCanAdd = true;
  bool _othersCanMark = true;

  @override
  void dispose() {
    _title.dispose();
    for (final task in _tasks) {
      task.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final tasks = [for (final t in _tasks) if (t.text.trim().isNotEmpty) t.text.trim()];
    if (_title.text.trim().isEmpty || tasks.isEmpty) {
      showToast(context, context.t('checklist_invalid'));
      return;
    }
    Navigator.pop(
      context,
      td.InputChecklist(
        title: plainText(_title.text.trim()),
        tasks: [for (final (i, text) in tasks.indexed) td.InputChecklistTask(id: i + 1, text: plainText(text))],
        othersCanAddTasks: _othersCanAdd,
        othersCanMarkTasksAsDone: _othersCanMark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('checklist')), actions: [TextButton(onPressed: _submit, child: Text(s.t('send')))]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 255,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: s.t('checklist_title')),
          ),
          for (var i = 0; i < _tasks.length; i++)
            Row(
              key: ObjectKey(_tasks[i]),
              children: [
                const Icon(Icons.check_box_outline_blank_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _tasks[i],
                    maxLength: 100,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(hintText: '${s.t('checklist_task')} ${i + 1}', counterText: ''),
                    onSubmitted: (_) {
                      if (i == _tasks.length - 1 && _tasks.length < ChecklistCreatorScreen.maxTasks) {
                        setState(() => _tasks.add(TextEditingController()));
                      }
                    },
                  ),
                ),
                if (_tasks.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    tooltip: s.t('delete'),
                    onPressed: () => setState(() => _tasks.removeAt(i).dispose()),
                  ),
              ],
            ),
          if (_tasks.length < ChecklistCreatorScreen.maxTasks)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _tasks.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded),
                label: Text(s.t('checklist_add_task')),
              ),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('checklist_others_add')),
            value: _othersCanAdd,
            onChanged: (v) => setState(() => _othersCanAdd = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('checklist_others_mark')),
            value: _othersCanMark,
            onChanged: (v) => setState(() => _othersCanMark = v),
          ),
        ],
      ),
    );
  }
}
