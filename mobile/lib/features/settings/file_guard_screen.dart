import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_guard.dart';
import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// Settings → File protection: which incoming files are blocked, what happens to them, and the log.
class FileGuardScreen extends ConsumerWidget {
  const FileGuardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guard = ref.watch(settingsProvider.select((s) => s.fileGuard));
    final notifier = ref.read(settingsProvider.notifier);
    final log = ref.watch(blockedFilesProvider);
    final s = context.s;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('file_guard'))),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: const Color(0xFF2EAD5B).withValues(alpha: 0.14),
                  child: const Icon(Icons.verified_user_rounded, color: Color(0xFF2EAD5B), size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(s.t('file_guard_hint'), style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
          SwitchListTile(
            title: Text(s.t('file_guard_enabled'), style: const TextStyle(fontWeight: FontWeight.w600)),
            value: guard.enabled,
            onChanged: (value) => notifier.setFileGuard(guard.copyWith(enabled: value)),
          ),
          SwitchListTile(
            title: Text(s.t('file_guard_delete')),
            subtitle: Text(s.t('file_guard_delete_hint')),
            isThreeLine: true,
            value: guard.autoDelete,
            onChanged: guard.enabled ? (value) => notifier.setFileGuard(guard.copyWith(autoDelete: value)) : null,
          ),
          const Divider(),
          SectionHeader(s.t('file_guard_types')),
          for (final category in fileGuardCategories.keys)
            CheckboxListTile(
              title: Text(s.t('file_guard_kind_$category')),
              value: guard.categories.contains(category),
              onChanged: guard.enabled
                  ? (on) => notifier.setFileGuard(guard.copyWith(
                        categories: on == true ? {...guard.categories, category} : ({...guard.categories}..remove(category)),
                      ))
                  : null,
            ),
          ListTile(
            title: Text(s.t('file_guard_custom')),
            subtitle: Text(guard.customExtensions.isEmpty
                ? s.t('file_guard_custom_none')
                : (guard.customExtensions.toList()..sort()).map((e) => '.$e').join(', ')),
            trailing: const Icon(Icons.edit_rounded),
            enabled: guard.enabled,
            onTap: () async {
              final value = await _editCustom(context, guard.customExtensions);
              if (value != null) notifier.setFileGuard(guard.copyWith(customExtensions: value));
            },
          ),
          const Divider(),
          SectionHeader('${s.t('file_guard_log')} (${log.length})'),
          if (log.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(s.t('file_guard_log_empty'), style: TextStyle(color: theme.hintColor)),
            )
          else ...[
            for (final entry in log.take(30))
              ListTile(
                dense: true,
                leading: Icon(Icons.gpp_bad_rounded, color: theme.colorScheme.error),
                title: Text(entry.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${entry.chatTitle} · ${formatChatTime(entry.date, s.locale)} · ${s.t(entry.deleted ? 'file_guard_deleted' : 'file_guard_hidden')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_rounded),
              title: Text(s.t('file_guard_clear')),
              onTap: ref.read(blockedFilesProvider.notifier).clear,
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(s.t('file_guard_note'), style: TextStyle(color: theme.hintColor, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<Set<String>?> _editCustom(BuildContext context, Set<String> current) async {
    final controller = TextEditingController(text: (current.toList()..sort()).join(', '));
    final s = context.s;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.t('file_guard_custom')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: s.t('file_guard_custom_hint')),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(s.t('save'))),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return null;
    // "exe, .Torrent ;cdr" → {torrent, cdr, exe}: no dots, lowercase, letters/digits only.
    return {
      for (final part in result.split(RegExp(r'[\s,;]+')))
        if (part.replaceAll('.', '').toLowerCase() case final ext when RegExp(r'^[a-z0-9_-]{1,16}$').hasMatch(ext)) ext,
    };
  }
}
