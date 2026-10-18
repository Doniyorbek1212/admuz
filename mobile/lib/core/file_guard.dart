import 'package:tdlib_ex/td_api.dart' as td;

/// Incoming-file screening ("Fayl xavfsizligi").
///
/// Telegram files can't be virus-scanned without downloading them, so the guard works on what is known
/// before any byte arrives: the file name, its extension and the declared MIME type. That is what catches
/// the files that actually hurt on a phone or PC — installers, executables and scripts, including names
/// disguised with right-to-left override characters ("photo" + U+202E + "gpj.exe" shows as "photoexe.jpg").

/// Blockable file kinds, each a set of lowercase extensions.
const fileGuardCategories = <String, Set<String>>{
  'android': {'apk', 'aab', 'apks', 'apkm', 'xapk', 'apkx', 'obb', 'dex'},
  'windows': {
    'exe', 'msi', 'msix', 'msixbundle', 'appx', 'appxbundle', 'msp', 'bat', 'cmd', 'com', 'scr', 'pif', //
    'cpl', 'lnk', 'url', 'reg', 'dll', 'sys', 'drv', 'ocx', 'hta', 'inf', 'gadget', 'msc', 'application', 'appref-ms',
  },
  'apple': {'ipa', 'dmg', 'pkg', 'mpkg', 'app', 'mobileconfig', 'command', 'workflow'},
  'linux': {'deb', 'rpm', 'appimage', 'snap', 'flatpak', 'run', 'bin'},
  'scripts': {
    'js', 'jse', 'vbs', 'vbe', 'wsf', 'wsh', 'ws', 'ps1', 'psm1', 'psd1', 'ps1xml', 'sh', 'bash', 'zsh', //
    'py', 'pyw', 'pyc', 'jar', 'jnlp', 'applescript', 'scpt', 'php', 'pl', 'lua',
  },
  'macros': {'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'xla', 'pptm', 'potm', 'ppam', 'ppsm', 'sldm'},
  'archives': {'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', 'cab', 'iso', 'img', 'vhd', 'vhdx'},
};

/// Archives are off by default: they are mostly harmless photos/documents and blocking them surprises people.
const defaultFileGuardCategories = {'android', 'windows', 'apple', 'linux', 'scripts', 'macros'};

/// MIME types that mean "program" whatever the file is called.
const _executableMimeTypes = <String, String>{
  'application/vnd.android.package-archive': 'android',
  'application/x-msdownload': 'windows',
  'application/x-msdos-program': 'windows',
  'application/x-ms-installer': 'windows',
  'application/x-msi': 'windows',
  'application/vnd.microsoft.portable-executable': 'windows',
  'application/x-dosexec': 'windows',
  'application/x-executable': 'linux',
  'application/x-sh': 'scripts',
  'application/x-shellscript': 'scripts',
  'application/javascript': 'scripts',
  'application/java-archive': 'scripts',
  'application/x-java-archive': 'scripts',
  'application/vnd.debian.binary-package': 'linux',
  'application/x-rpm': 'linux',
  'application/x-apple-diskimage': 'apple',
  'application/x-itunes-ipa': 'apple',
  'application/vnd.ms-word.document.macroenabled.12': 'macros',
  'application/vnd.ms-excel.sheet.macroenabled.12': 'macros',
  'application/vnd.ms-powerpoint.presentation.macroenabled.12': 'macros',
};

/// Bidi controls and zero-width marks: legitimate file names never need them, disguised ones do.
final _disguiseChars = RegExp('[\u200B-\u200F\u202A-\u202E\u2066-\u2069]');

/// Why a file is blocked: [kind] is a category id, 'custom' or 'disguised'; [extension] is what matched.
class FileVerdict {
  const FileVerdict(this.kind, this.extension);

  final String kind;
  final String extension;

  @override
  bool operator ==(Object other) => other is FileVerdict && other.kind == kind && other.extension == extension;

  @override
  int get hashCode => Object.hash(kind, extension);

  @override
  String toString() => 'FileVerdict($kind, $extension)';
}

/// The file a message carries, as far as screening is concerned.
typedef Attachment = ({td.File file, String name, String mimeType});

Attachment? attachmentOf(td.MessageContent content) => switch (content) {
      td.MessageDocument(:final document) => (file: document.document, name: document.fileName, mimeType: document.mimeType),
      td.MessageAudio(:final audio) => (file: audio.audio, name: audio.fileName, mimeType: audio.mimeType),
      td.MessageVideo(:final video) => (file: video.video, name: video.fileName, mimeType: video.mimeType),
      td.MessageAnimation(:final animation) => (file: animation.animation, name: animation.fileName, mimeType: animation.mimeType),
      _ => null,
    };

/// Lowercase extension after the last dot, ignoring trailing dots/spaces ("setup.exe. " → "exe").
String fileExtension(String name) {
  final trimmed = name.trim().replaceAll(RegExp(r'[.\s]+$'), '').toLowerCase();
  final dot = trimmed.lastIndexOf('.');
  return dot < 0 || dot == trimmed.length - 1 ? '' : trimmed.substring(dot + 1);
}

/// User-facing guard configuration (persisted with the app settings).
class FileGuardSettings {
  const FileGuardSettings({
    this.enabled = true,
    this.autoDelete = true,
    this.categories = defaultFileGuardCategories,
    this.customExtensions = const {},
  });

  final bool enabled;

  /// Delete blocked messages where Telegram allows deleting just for this user (private chats, basic groups).
  /// Elsewhere deleting would remove the message for everyone, so it is only hidden.
  final bool autoDelete;
  final Set<String> categories;

  /// Extra lowercase extensions without the dot, e.g. {'torrent'}.
  final Set<String> customExtensions;

  FileGuardSettings copyWith({bool? enabled, bool? autoDelete, Set<String>? categories, Set<String>? customExtensions}) =>
      FileGuardSettings(
        enabled: enabled ?? this.enabled,
        autoDelete: autoDelete ?? this.autoDelete,
        categories: categories ?? this.categories,
        customExtensions: customExtensions ?? this.customExtensions,
      );

  /// Verdict for a file name + MIME type, or null when it may pass.
  FileVerdict? checkFile(String name, String mimeType) {
    if (!enabled) return null;
    final ext = fileExtension(name);
    if (_disguiseChars.hasMatch(name)) return FileVerdict('disguised', ext);
    for (final category in categories) {
      if (fileGuardCategories[category]?.contains(ext) ?? false) return FileVerdict(category, ext);
    }
    if (customExtensions.contains(ext)) return FileVerdict('custom', ext);
    final mimeCategory = _executableMimeTypes[mimeType.toLowerCase()];
    if (mimeCategory != null && categories.contains(mimeCategory)) return FileVerdict(mimeCategory, ext);
    return null;
  }

  /// Verdict for an incoming message's attachment; own messages are never blocked.
  /// [myId] matters because TDLib marks some own messages incoming (e.g. forwards into Saved Messages).
  FileVerdict? checkMessage(td.Message message, int myId) {
    if (!enabled || message.isOutgoing || message.chatId == myId) return null;
    if (message.senderId case td.MessageSenderUser(:final userId) when userId == myId) return null;
    final attachment = attachmentOf(message.content);
    return attachment == null ? null : checkFile(attachment.name, attachment.mimeType);
  }
}
