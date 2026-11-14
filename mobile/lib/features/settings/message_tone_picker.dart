import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/message_tones.dart';
import '../../l10n/strings.dart';

/// Tone list where each tap previews the tone. [inheritLabel] adds a first row returning ''
/// (follow the global tone). Null when cancelled.
Future<String?> pickMessageTone(BuildContext context, {required String current, String? inheritLabel}) {
  final s = context.s;
  var selected = current;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(s.t('message_tone')),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SingleChildScrollView(
          child: RadioGroup<String>(
            groupValue: selected,
            onChanged: (id) {
              if (id == null) return;
              setDialogState(() => selected = id);
              if (id.isNotEmpty) unawaited(MessageTones.play(id, preview: true));
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (inheritLabel != null) RadioListTile<String>(value: '', title: Text(inheritLabel)),
              for (final id in MessageTones.ids) RadioListTile<String>(value: id, title: Text(s.t('sound_$id'))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, selected), child: Text(s.t('ok'))),
        ],
      ),
    ),
  );
}
