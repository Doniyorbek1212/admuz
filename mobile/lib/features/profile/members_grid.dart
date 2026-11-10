import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/settings.dart';

/// Whether group members show as an avatar grid grouped by role (else the plain list). Kept per device.
final membersGridProvider = NotifierProvider<MembersGridNotifier, bool>(MembersGridNotifier.new);

class MembersGridNotifier extends Notifier<bool> {
  static const _key = 'members.grid';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? false;

  Future<void> toggle() async {
    state = !state;
    await ref.read(sharedPreferencesProvider).setBool(_key, state);
  }
}

/// Section of the members grid a member falls in; the first matching one wins.
enum MemberGroup { contacts, admins, bots, other }

MemberGroup memberGroup(td.ChatMember member, td.User? user) {
  if (member.status is td.ChatMemberStatusCreator || member.status is td.ChatMemberStatusAdministrator) return MemberGroup.admins;
  if (user?.type is td.UserTypeBot) return MemberGroup.bots;
  if (user?.isContact ?? false) return MemberGroup.contacts;
  return MemberGroup.other;
}

/// Members as avatar grids under collapsible "Contacts / Admins / Bots / Other members" headers.
class MembersGrid extends ConsumerStatefulWidget {
  const MembersGrid({super.key, required this.members, required this.cell});

  final List<td.ChatMember> members;

  /// One grid cell for a member (avatar, name and the member's tap actions).
  final Widget Function(td.ChatMember member) cell;

  @override
  ConsumerState<MembersGrid> createState() => _MembersGridState();
}

class _MembersGridState extends ConsumerState<MembersGrid> {
  final Set<MemberGroup> _closed = {};

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final groups = {for (final g in MemberGroup.values) g: <td.ChatMember>[]};
    for (final member in widget.members) {
      final user = switch (member.memberId) {
        td.MessageSenderUser(:final userId) => account.users[userId],
        _ => null,
      };
      groups[memberGroup(member, user)]!.add(member);
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(key: group, value: members) in groups.entries)
          if (members.isNotEmpty) ...[
            InkWell(
              onTap: () => setState(() => _closed.contains(group) ? _closed.remove(group) : _closed.add(group)),
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${s.t(switch (group) {
                          MemberGroup.contacts => 'members_contacts',
                          MemberGroup.admins => 'members_admins',
                          MemberGroup.bots => 'members_bots',
                          MemberGroup.other => 'members_other',
                        })} · ${members.length}',
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor),
                      ),
                    ),
                    Icon(_closed.contains(group) ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: 20, color: theme.hintColor),
                  ],
                ),
              ),
            ),
            if (!_closed.contains(group))
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                childAspectRatio: 0.82,
                children: [for (final member in members) widget.cell(member)],
              ),
          ],
      ],
    );
  }
}
