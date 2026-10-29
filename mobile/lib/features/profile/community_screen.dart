import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import '../settings/privacy_screen.dart' show promptText;

/// Groups a supergroup or channel with other chats into a community (owner of the chat only).
Future<void> createCommunityFor(BuildContext context, TelegramAccount account, int chatId, String suggestedName) async {
  final s = context.s;
  final name = await promptText(context, title: s.t('community_create'), label: s.t('community_name'), initial: suggestedName);
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  final created = await guard(context, () => account.send<td.CommunityId>(td.CreateCommunity(name: name.trim(), chatId: chatId, isChatHidden: false)));
  if (created == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommunityScreen(communityId: created.id)));
}

/// A community: its chats, and for the owner the name, photo, permissions and deletion.
class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key, required this.communityId});

  final int communityId;

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  late final TelegramAccount _account = ref.read(accountProvider);
  td.CommunityFullInfo? _full;

  @override
  void initState() {
    super.initState();
    _account.communitiesRevision.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _account.communitiesRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final full = await guard(context, () => _account.send<td.CommunityFullInfo>(td.GetCommunityFullInfo(communityId: widget.communityId)));
    if (full != null && mounted) setState(() => _full = full);
  }

  Future<void> _rename(String current) async {
    final s = context.s;
    final name = await promptText(context, title: s.t('community_name'), label: s.t('title'), initial: current);
    if (name == null || name.trim().isEmpty || !mounted) return;
    await guard(context, () => _account.send<td.Ok>(td.SetCommunityName(communityId: widget.communityId, name: name.trim())));
  }

  Future<void> _photo({required bool remove}) async {
    td.InputChatPhoto? photo;
    if (!remove) {
      final path = await pickGalleryImage();
      if (path == null || !mounted) return;
      photo = td.InputChatPhotoStatic(photo: td.InputFileLocal(path: path));
    }
    await guard(context, () => _account.send<td.Ok>(td.SetCommunityPhoto(communityId: widget.communityId, photo: photo)));
    await _load();
  }

  Future<void> _delete(String name) async {
    final s = context.s;
    final ok = await confirm(context, title: s.t('community_delete'), message: s.t('community_delete_hint', {'name': name}), destructive: true);
    if (!ok || !mounted) return;
    final done = await guard(context, () async {
      await _account.send<td.Ok>(td.DeleteCommunity(communityId: widget.communityId));
      return true;
    });
    if (done == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final community = _account.communities[widget.communityId];
    final full = _full;
    final isOwner = community?.status is td.CommunityMemberStatusCreator;
    final name = community?.name ?? '';
    final photo = full?.photo;
    return Scaffold(
      appBar: AppBar(title: Text(name.isEmpty ? s.t('community') : name)),
      body: full == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              const SizedBox(height: 16),
              Center(
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: 96,
                    child: photo != null && photo.sizes.isNotEmpty
                        ? TdImage(file: photo.sizes.last.photo, fit: BoxFit.cover)
                        : ColoredBox(color: Theme.of(context).colorScheme.primaryContainer, child: const Icon(Icons.hub_rounded, size: 44)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              Text(s.count('chats', full.chats.length), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
              if (isOwner) ...[
                SectionHeader(s.t('manage')),
                ListTile(leading: const Icon(Icons.edit_rounded), title: Text(s.t('community_name')), subtitle: Text(name), onTap: () => _rename(name)),
                ListTile(leading: const Icon(Icons.add_a_photo_rounded), title: Text(s.t('set_photo')), onTap: () => _photo(remove: false)),
                if (photo != null) ListTile(leading: const Icon(Icons.no_photography_outlined), title: Text(s.t('delete_photo')), onTap: () => _photo(remove: true)),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_add_rounded),
                  title: Text(s.t('community_admins_edit_chats')),
                  value: community?.permissions.canEditChatList ?? false,
                  onChanged: (on) => guard(
                    context,
                    () => _account.send<td.Ok>(td.SetCommunityPermissions(communityId: widget.communityId, permissions: td.CommunityPermissions(canEditChatList: on))),
                  ),
                ),
              ],
              SectionHeader(s.t('chats')),
              for (final c in full.chats)
                if (_account.chats[c.chatId] case final chat?)
                  ListTile(
                    leading: ChatAvatar(chatId: c.chatId, size: 42, showOnline: false),
                    title: Text(chatTitle(chat, _account, s)),
                    subtitle: c.isHidden ? Text(s.t('community_hidden_chat')) : null,
                    onTap: c.canViewHistory ? () => openChat(context, c.chatId) : null,
                  ),
              if (isOwner)
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
                  title: Text(s.t('community_delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () => _delete(name),
                ),
              const SizedBox(height: 24),
            ]),
    );
  }
}
