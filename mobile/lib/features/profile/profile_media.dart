import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/formatters.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/telegram.dart';
import '../../widgets/common.dart';

// ------------------------------------------------------------------ profile music

/// Whether the audio file is on the user's own profile (IsProfileAudio answers Ok or an error).
Future<bool> isProfileAudio(TelegramAccount account, int fileId) async {
  try {
    await account.send<td.Ok>(td.IsProfileAudio(fileId: fileId));
    return true;
  } on TdException {
    return false;
  }
}

/// Puts a music message's track on the user's profile, or takes it off.
Future<void> toggleProfileAudio(BuildContext context, TelegramAccount account, td.Audio audio, {required bool onProfile}) async {
  final s = context.s;
  final done = await guard(context, () async {
    if (onProfile) {
      await account.send<td.Ok>(td.RemoveProfileAudio(fileId: audio.audio.id));
    } else {
      await account.send<td.Ok>(td.AddProfileAudio(
        audio: td.InputAudio(
          audio: td.InputFileId(id: audio.audio.id),
          albumCoverThumbnail: null,
          duration: audio.duration,
          title: audio.title,
          performer: audio.performer,
        ),
      ));
    }
    return true;
  });
  if (done == true && context.mounted) showToast(context, s.t(onProfile ? 'profile_audio_removed' : 'profile_audio_added'));
}

final _profileAudiosProvider = FutureProvider.autoDispose.family<td.Audios, int>(
  (ref, userId) => ref.watch(accountProvider).send<td.Audios>(td.GetUserProfileAudios(userId: userId, offset: 0, limit: 100)),
);

/// Profile row "Music · N" that opens the list; hidden when the user has none.
class ProfileAudiosTile extends ConsumerWidget {
  const ProfileAudiosTile({super.key, required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audios = ref.watch(_profileAudiosProvider(userId)).value;
    final mine = userId == ref.watch(accountProvider).myId;
    if (audios == null || (audios.audios.isEmpty && !mine)) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.library_music_outlined),
      title: Text(context.t('profile_audio')),
      trailing: Text('${audios.totalCount}'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProfileAudiosScreen(userId: userId))),
    );
  }
}

/// Tracks a person keeps on their profile; plays them here, and on one's own profile reorders or removes them.
class ProfileAudiosScreen extends ConsumerStatefulWidget {
  const ProfileAudiosScreen({super.key, required this.userId});

  final int userId;

  @override
  ConsumerState<ProfileAudiosScreen> createState() => _ProfileAudiosScreenState();
}

class _ProfileAudiosScreenState extends ConsumerState<ProfileAudiosScreen> {
  final _player = AudioPlayer();
  int? _playing;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _play(td.Audio audio) async {
    if (_playing == audio.audio.id) {
      await _player.stop();
      setState(() => _playing = null);
      return;
    }
    setState(() => _playing = audio.audio.id);
    final path = await guard(context, () => ref.read(accountProvider).downloadFile(audio.audio.id, priority: 32));
    if (path == null || !mounted || _playing != audio.audio.id) return;
    await _player.setFilePath(path);
    await _player.play();
  }

  Future<void> _reorder(List<td.Audio> audios, int from, int to) async {
    final moved = audios[from];
    final rest = [...audios]..removeAt(from);
    final after = to == 0 ? 0 : rest[to - 1].audio.id;
    await guard(context, () => ref.read(accountProvider).send<td.Ok>(td.SetProfileAudioPosition(fileId: moved.audio.id, afterFileId: after)));
    ref.invalidate(_profileAudiosProvider(widget.userId));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final account = ref.watch(accountProvider);
    final mine = widget.userId == account.myId;
    final audios = ref.watch(_profileAudiosProvider(widget.userId)).value?.audios;
    Widget tile(td.Audio audio) => ListTile(
          key: ValueKey(audio.audio.id),
          leading: IconButton(
            icon: Icon(_playing == audio.audio.id ? Icons.stop_circle_rounded : Icons.play_circle_rounded, size: 34),
            onPressed: () => _play(audio),
          ),
          title: Text(audio.title.isNotEmpty ? audio.title : audio.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([audio.performer, formatDuration(Duration(seconds: audio.duration))].where((p) => p.isNotEmpty).join(' · ')),
          trailing: mine
              ? IconButton(
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: () async {
                    await guard(context, () => account.send<td.Ok>(td.RemoveProfileAudio(fileId: audio.audio.id)));
                    ref.invalidate(_profileAudiosProvider(widget.userId));
                  },
                )
              : null,
        );
    return Scaffold(
      appBar: AppBar(title: Text(s.t('profile_audio'))),
      body: audios == null
          ? const Center(child: CircularProgressIndicator())
          : audios.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.t(mine ? 'profile_audio_hint' : 'nothing_here'), textAlign: TextAlign.center)))
              : mine
                  ? ReorderableListView(onReorderItem: (from, to) => _reorder(audios, from, to), children: [for (final a in audios) tile(a)])
                  : ListView(children: [for (final a in audios) tile(a)]),
    );
  }
}

// ------------------------------------------------------------------ contact photos

/// A photo of a contact that only the user sees (replaces theirs on this account), or removes it.
Future<void> setPersonalContactPhoto(BuildContext context, TelegramAccount account, int userId, {required bool remove}) async {
  td.InputChatPhoto? photo;
  if (!remove) {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
    if (file == null || !context.mounted) return;
    photo = td.InputChatPhotoStatic(photo: td.InputFileLocal(path: file.path));
  }
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.SetUserPersonalProfilePhoto(userId: userId, photo: photo));
    return true;
  });
  if (done == true && context.mounted) showToast(context, context.t('done'));
}

/// Offers a photo to another user as their new profile photo; they see it in the chat and can accept.
Future<void> suggestProfilePhoto(BuildContext context, TelegramAccount account, int userId) async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1280);
  if (file == null || !context.mounted) return;
  final done = await guard(context, () async {
    await account.send<td.Ok>(td.SuggestUserProfilePhoto(userId: userId, photo: td.InputChatPhotoStatic(photo: td.InputFileLocal(path: file.path))));
    return true;
  });
  if (done == true && context.mounted) showToast(context, context.t('photo_suggested'));
}
