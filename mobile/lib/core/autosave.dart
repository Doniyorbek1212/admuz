import 'package:tdlib_ex/td_api.dart' as td;

/// Kind of chat an autosave rule is chosen by.
enum AutosaveChatKind { private, group, channel }

/// The rule that applies to a chat: its own exception first, then the default of its kind.
td.ScopeAutosaveSettings? autosaveRuleFor(td.AutosaveSettings? settings, int chatId, AutosaveChatKind kind) {
  if (settings == null) return null;
  for (final exception in settings.exceptions) {
    if (exception.chatId == chatId) return exception.settings;
  }
  return switch (kind) {
    AutosaveChatKind.private => settings.privateChatSettings,
    AutosaveChatKind.group => settings.groupSettings,
    AutosaveChatKind.channel => settings.channelSettings,
  };
}

/// File of a new incoming message to save to the gallery under [rule], or null when the rule skips it.
td.File? autosaveFileOf(td.MessageContent content, td.ScopeAutosaveSettings? rule) {
  if (rule == null) return null;
  return switch (content) {
    td.MessagePhoto(:final photo) when rule.autosavePhotos && photo.sizes.isNotEmpty =>
      photo.sizes.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b).photo,
    td.MessageVideo(:final video) when rule.autosaveVideos && (video.video.size == 0 ? video.video.expectedSize : video.video.size) <= rule.maxVideoFileSize =>
      video.video,
    _ => null,
  };
}
