import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import 'admin_screens.dart';

/// People who joined through one invite link.
Future<void> showInviteLinkMembers(BuildContext context, TelegramAccount account, int chatId, td.ChatInviteLink link) async {
  final result = await guard(
    context,
    () => account.send<td.ChatInviteLinkMembers>(
      td.GetChatInviteLinkMembers(chatId: chatId, inviteLink: link.inviteLink, onlyWithExpiredSubscription: false, offsetMember: null, limit: 100),
    ),
  );
  if (result == null || !context.mounted) return;
  final s = context.s;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: result.members.isEmpty
            ? Padding(padding: const EdgeInsets.all(24), child: Text(s.t('nothing_here'), textAlign: TextAlign.center))
            : ListView(
                shrinkWrap: true,
                children: [
                  SectionHeader(s.count('joined', result.totalCount)),
                  for (final member in result.members)
                    ListTile(
                      leading: UserAvatar(userId: member.userId, size: 40),
                      title: Text(account.userName(member.userId)),
                      subtitle: Text(formatChatTime(member.joinedChatDate, s.locale)),
                    ),
                ],
              ),
      ),
    ),
  );
}

/// Owner-only list of other admins who created invite links, each opening that admin's links.
class InviteLinkCountsSection extends ConsumerStatefulWidget {
  const InviteLinkCountsSection({super.key, required this.chatId});

  final int chatId;

  @override
  ConsumerState<InviteLinkCountsSection> createState() => _InviteLinkCountsSectionState();
}

class _InviteLinkCountsSectionState extends ConsumerState<InviteLinkCountsSection> {
  List<td.ChatInviteLinkCount> _counts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = ref.read(accountProvider);
    try {
      final result = await account.send<td.ChatInviteLinkCounts>(td.GetChatInviteLinkCounts(chatId: widget.chatId));
      if (mounted) setState(() => _counts = [for (final c in result.inviteLinkCounts) if (c.userId != account.myId) c]);
    } on TdException {
      // Only the owner may ask; for others the section just stays hidden.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_counts.isEmpty) return const SizedBox.shrink();
    final s = context.s;
    final account = ref.watch(accountProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        SectionHeader(s.t('admin_links')),
        for (final count in _counts)
          ListTile(
            leading: UserAvatar(userId: count.userId, size: 40),
            title: Text(account.userName(count.userId)),
            subtitle: Text(s.t('admin_links_count', {'n': '${count.inviteLinkCount}', 'r': '${count.revokedInviteLinkCount}'})),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => InviteLinksScreen(chatId: widget.chatId, creatorUserId: count.userId)),
            ),
          ),
      ],
    );
  }
}
