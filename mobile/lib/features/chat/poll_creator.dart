import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../widgets/common.dart';

/// What [PollCreatorScreen] returns; [correctOption] is set for a quiz.
typedef PollDraft = ({
  String question,
  List<String> options,
  bool anonymous,
  bool multiple,
  bool allowAdding,
  int? correctOption,
  String explanation,
});

/// Telegram's "New poll" screen: question, up to 10 options, anonymous / multiple answers / quiz mode.
class PollCreatorScreen extends StatefulWidget {
  const PollCreatorScreen({super.key});

  static const maxOptions = 10;

  @override
  State<PollCreatorScreen> createState() => _PollCreatorScreenState();
}

class _PollCreatorScreenState extends State<PollCreatorScreen> {
  final _question = TextEditingController();
  final _explanation = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _anonymous = true;
  bool _multiple = false;
  bool _allowAdding = false;
  bool _quiz = false;
  int? _correct;

  @override
  void dispose() {
    _question.dispose();
    _explanation.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  void _addOption() => setState(() => _options.add(TextEditingController()));

  void _removeOption(int index) => setState(() {
        _options.removeAt(index).dispose();
        final correct = _correct;
        if (correct == index) {
          _correct = null;
        } else if (correct != null && correct > index) {
          _correct = correct - 1;
        }
      });

  void _submit() {
    final s = context.s;
    // Empty option rows are skipped; the quiz answer index follows the kept rows.
    final kept = [for (var i = 0; i < _options.length; i++) if (_options[i].text.trim().isNotEmpty) i];
    final question = _question.text.trim();
    if (question.isEmpty || kept.length < 2) {
      showToast(context, s.t('poll_invalid'));
      return;
    }
    final correct = _correct;
    if (_quiz && (correct == null || !kept.contains(correct))) {
      showToast(context, s.t('poll_pick_correct'));
      return;
    }
    Navigator.pop<PollDraft>(context, (
      question: question,
      options: [for (final i in kept) _options[i].text.trim()],
      anonymous: _anonymous,
      multiple: _multiple && !_quiz,
      allowAdding: _allowAdding && !_quiz,
      correctOption: _quiz && correct != null ? kept.indexOf(correct) : null,
      explanation: _quiz ? _explanation.text.trim() : '',
    ));
  }

  Widget _optionRow(int i) {
    final s = context.s;
    return Row(
      key: ObjectKey(_options[i]),
      children: [
        if (_quiz) Radio<int>(value: i),
        Expanded(
          child: TextField(
            controller: _options[i],
            maxLength: 100,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: i == _options.length - 1 ? TextInputAction.done : TextInputAction.next,
            decoration: InputDecoration(hintText: '${s.t('poll_option')} ${i + 1}', counterText: ''),
          ),
        ),
        if (_options.length > 2)
          IconButton(icon: const Icon(Icons.remove_circle_outline_rounded), tooltip: s.t('delete'), onPressed: () => _removeOption(i)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('new_poll')),
        actions: [TextButton(onPressed: _submit, child: Text(s.t('send')))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _question,
            autofocus: true,
            maxLength: 255,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: s.t('poll_question')),
          ),
          const SizedBox(height: 8),
          Text(s.t('poll_option'), style: TextStyle(color: primary, fontWeight: FontWeight.w600)),
          if (_quiz) Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.t('poll_quiz_hint'), style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13))),
          RadioGroup<int>(
            groupValue: _correct,
            onChanged: (value) => setState(() => _correct = value),
            child: Column(children: [for (var i = 0; i < _options.length; i++) _optionRow(i)]),
          ),
          if (_options.length < PollCreatorScreen.maxOptions)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(onPressed: _addOption, icon: const Icon(Icons.add_rounded), label: Text(s.t('poll_add_option'))),
            ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('poll_anonymous')),
            value: _anonymous,
            onChanged: (value) => setState(() => _anonymous = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('poll_multiple')),
            value: _multiple && !_quiz,
            onChanged: _quiz ? null : (value) => setState(() => _multiple = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('poll_allow_adding')),
            value: _allowAdding && !_quiz,
            onChanged: _quiz ? null : (value) => setState(() => _allowAdding = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('poll_quiz')),
            value: _quiz,
            onChanged: (value) => setState(() => _quiz = value),
          ),
          if (_quiz)
            TextField(
              controller: _explanation,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: s.t('poll_explanation')),
            ),
        ],
      ),
    );
  }
}
