import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../core/config.dart';
import '../core/tdlib/td_client.dart';
import 'contact_changes.dart';
import 'message_archive.dart';

/// Stable key for a chat list (main, archive or a folder).
/// Telegram's unread count minus what a ghost-mode local read already covered ([base] = the count at that read).
@visibleForTesting
int unreadAfterLocalRead(int unreadCount, int? base) => base == null ? unreadCount : max(0, unreadCount - base);

/// Telegram test-server numbers (99966XYYYY, login code = X five times) used by store reviewers.
bool isTestDcPhone(String phone) => RegExp(r'^\+?99966[1-3]\d{4}$').hasMatch(phone);

const phoneAuthSettings = td.PhoneNumberAuthenticationSettings(
  allowFlashCall: false,
  allowMissedCall: false,
  isCurrentPhoneNumber: false,
  hasUnknownPhoneNumber: false,
  allowSmsRetrieverApi: false,
  firebaseAuthenticationSettings: null,
  authenticationTokens: [],
);

String chatListKey(td.ChatList list) => switch (list) {
  td.ChatListMain() => 'main',
  td.ChatListArchive() => 'archive',
  td.ChatListFolder(:final chatFolderId) => 'folder:$chatFolderId',
  _ => list.getConstructor(),
};

td.ChatList chatListFromKey(String key) {
  if (key == 'archive') return const td.ChatListArchive();
  if (key.startsWith('folder:')) return td.ChatListFolder(chatFolderId: int.parse(key.substring(7)));
  return const td.ChatListMain();
}

/// A chat action (typing, recording...) currently shown for a chat.
class ActiveChatAction {
  const ActiveChatAction(this.senderId, this.action);

  final int senderId;
  final td.ChatAction action;
}

/// One Telegram account: the TDLib client plus an in-memory mirror of the objects TDLib pushes.
///
/// TDLib guarantees that every object referenced by an update has been sent before (updateNewChat,
/// updateUser, updateFile...), so these maps are the single source of truth for the UI.
class TelegramAccount {
  TelegramAccount._(this.slot, this.client, this.databaseDirectory)
      : archive = MessageArchive('$databaseDirectory${Platform.pathSeparator}sado_archive.json'),
        contactChanges = ContactChangeLog('$databaseDirectory${Platform.pathSeparator}sado_contact_changes.json');

  final int slot;
  final TdClient client;
  final String databaseDirectory;

  /// Copies of messages others deleted and earlier versions of edited ones.
  final MessageArchive archive;

  /// Profile changes of contacts (photo, phone, name, username).
  final ContactChangeLog contactChanges;

  final Map<int, td.Chat> chats = {};
  final Map<int, td.User> users = {};
  final Map<int, td.BasicGroup> basicGroups = {};
  final Map<int, td.Supergroup> supergroups = {};
  final Map<int, td.File> files = {};
  final Map<String, td.OptionValue> options = {};

  /// Mini Apps added to the attach menu (e.g. @wallet), as TDLib reports them.
  List<td.AttachmentMenuBot> attachmentMenuBots = const [];

  /// Ghost mode reads chats on this phone only: Telegram keeps them unread, so the sender sees nothing, while the
  /// badge here counts just what arrived after the local read. chatId -> Telegram's unread count at that moment.
  late final Map<int, int> _ghostReadBase = _loadGhostRead();

  String get _ghostReadPath => '$databaseDirectory${Platform.pathSeparator}sado_ghost_read.json';

  Map<int, int> _loadGhostRead() {
    try {
      final file = File(_ghostReadPath);
      if (!file.existsSync()) return {};
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return {for (final e in json.entries) int.parse(e.key): (e.value as num).toInt()};
    } on Object catch (error) {
      debugPrint('ghost read state unreadable: $error');
      return {};
    }
  }

  void _saveGhostRead() {
    final json = jsonEncode({for (final e in _ghostReadBase.entries) '${e.key}': e.value});
    unawaited(File(_ghostReadPath).writeAsString(json).catchError((Object error) {
      debugPrint('ghost read state not saved: $error');
      return File(_ghostReadPath);
    }));
  }

  /// Unread messages to show for [chat], after any ghost-mode local read.
  int unreadFor(td.Chat chat) => unreadAfterLocalRead(chat.unreadCount, _ghostReadBase[chat.id]);

  /// Ghost mode opened the chat: clear its badge here without telling Telegram.
  void markReadLocally(int chatId) {
    final chat = chats[chatId];
    if (chat == null || chat.unreadCount == 0 || _ghostReadBase[chatId] == chat.unreadCount) return;
    _ghostReadBase[chatId] = chat.unreadCount;
    _saveGhostRead();
    _markChat(chatId);
    foldersRevision.value++;
  }

  /// A list's unread total without the messages ghost mode already read locally.
  int unreadInList(String listKey) {
    final total = unreadCounts[listKey] ?? 0;
    var hidden = 0;
    for (final MapEntry(key: chatId, value: base) in _ghostReadBase.entries) {
      final chat = chats[chatId];
      if (chat != null && chat.chatLists.any((l) => chatListKey(l) == listKey)) hidden += min(base, chat.unreadCount);
    }
    return max(0, total - hidden);
  }
  final Map<int, Map<int, ActiveChatAction>> chatActions = {};
  final Map<int, int> onlineMemberCounts = {};
  final Map<String, bool> _listFullyLoaded = {};
  List<td.ChatFolderInfo> folders = const [];
  final Map<String, int> unreadCounts = {};

  /// Active stories per poster chat (updateChatActiveStories).
  final Map<int, td.ChatActiveStories> activeStories = {};
  final storiesRevision = ValueNotifier<int>(0);

  /// Chats with active stories in the main story list, newest first.
  List<td.ChatActiveStories> storyFeed() {
    final feed = activeStories.values.where((s) => s.stories.isNotEmpty && s.list is td.StoryListMain && s.order != 0).toList()
      ..sort((a, b) => b.order.compareTo(a.order));
    return feed;
  }

  final Map<int, td.SecretChat> secretChats = {};

  td.SecretChat? secretChatOf(td.Chat chat) => chat.type is td.ChatTypeSecret ? secretChats[(chat.type as td.ChatTypeSecret).secretChatId] : null;

  /// Forum topic currently open per chat; messages sent to that chat go into the topic.
  final Map<int, int> activeTopics = {};

  /// Comment thread currently open per discussion group; wins over a forum topic.
  final Map<int, int> activeThreads = {};

  td.MessageTopic? topicFor(int chatId) {
    final thread = activeThreads[chatId];
    if (thread != null) return td.MessageTopicThread(messageThreadId: thread);
    final topic = activeTopics[chatId];
    return topic == null ? null : td.MessageTopicForum(forumTopicId: topic);
  }

  bool isForum(td.Chat chat) => supergroupOf(chat)?.isForum ?? false;

  /// Message carrying the current bot reply keyboard of a chat (updateChatReplyMarkup).
  final Map<int, td.Message> replyMarkupMessages = {};

  /// Who may notify about reactions (updateReactionNotificationSettings, sent at start).
  td.ReactionNotificationSettings? reactionNotifications;

  /// Writing styles offered by Telegram's AI text composer (updateTextCompositionStyles).
  List<td.TextCompositionStyle> compositionStyles = const [];

  /// Name and profile color palettes (updateAccentColors / updateProfileAccentColors).
  List<td.AccentColor> accentColors = const [];
  List<td.ProfileAccentColor> profileAccentColors = const [];

  /// Emoji Telegram allows as reactions (updateActiveEmojiReactions).
  List<String> activeEmojiReactions = const [];

  /// Newest login Telegram wants the user to confirm ("Is this you?"), or null.
  final unconfirmedSession = ValueNotifier<td.UnconfirmedSession?>(null);

  /// Per-chat themes Telegram offers (updateEmojiChatThemes).
  List<td.EmojiChatTheme> emojiChatThemes = const [];

  /// Business quick replies by id, in Telegram's order; filled after LoadQuickReplyShortcuts.
  final quickReplies = <int, td.QuickReplyShortcut>{};
  List<int> quickReplyOrder = const [];
  final quickRepliesRevision = ValueNotifier<int>(0);

  final authState = ValueNotifier<td.AuthorizationState?>(null);
  final connectionState = ValueNotifier<td.ConnectionState>(const td.ConnectionStateConnecting());

  /// Bumped (coalesced per microtask) whenever anything shown in chat lists changes.
  final chatListRevision = ValueNotifier<int>(0);
  final usersRevision = ValueNotifier<int>(0);
  final foldersRevision = ValueNotifier<int>(0);
  final Map<int, ValueNotifier<int>> _chatRevisions = {};

  final _fileUpdates = StreamController<td.File>.broadcast(sync: true);
  final _messageEvents = StreamController<td.Update>.broadcast(sync: true);
  final _callEvents = StreamController<td.Update>.broadcast(sync: true);
  StreamSubscription<td.TdObject>? _subscription;
  final Map<int, Timer> _actionTimers = {};
  bool _listDirty = false;
  bool _disposed = false;
  bool _usersDirty = false;
  final Set<int> _dirtyChats = {};
  TelegramCredentials? _credentials;
  String _languageCode = 'en';
  bool _testDc = false;
  String? _pendingTestPhone;

  static bool _logConfigured = false;

  static Future<String> directoryFor(int slot) async {
    final support = await getApplicationSupportDirectory();
    return '${support.path}${Platform.pathSeparator}tdlib${Platform.pathSeparator}account_$slot';
  }

  /// Marker that makes a slot log in on Telegram's test servers; holds the phone number to submit.
  static File testDcMarker(String dir) => File('$dir${Platform.pathSeparator}.test_dc');

  static Future<TelegramAccount> start(int slot, TelegramCredentials credentials, {String languageCode = 'en'}) async {
    if (!_logConfigured) {
      _logConfigured = true;
      TdClient.executeStatic(const td.SetLogVerbosityLevel(newVerbosityLevel: kDebugMode ? 2 : 1));
    }
    final dir = await directoryFor(slot);
    await Directory(dir).create(recursive: true);
    final marker = testDcMarker(dir);
    final testPhone = await marker.exists() ? (await marker.readAsString()).trim() : null;
    final client = await TdClient.create();
    final account = TelegramAccount._(slot, client, dir)
      .._credentials = credentials
      .._languageCode = languageCode
      .._testDc = testPhone != null
      .._pendingTestPhone = testPhone;
    await account.archive.load();
    await account.contactChanges.load();
    account._subscription = client.updates.listen(account._onUpdate);
    return account;
  }

  /// Desktop/test entry point with an explicit database directory.
  @visibleForTesting
  static Future<TelegramAccount> startAt(String dir, TelegramCredentials credentials) async {
    await Directory(dir).create(recursive: true);
    final client = await TdClient.create();
    final account = TelegramAccount._(0, client, dir).._credentials = credentials;
    account._subscription = client.updates.listen(account._onUpdate);
    return account;
  }

  // ------------------------------------------------------------------ getters

  int get myId => switch (options['my_id']) {
    td.OptionValueInteger(:final value) => value,
    _ => 0,
  };

  bool get isReady => authState.value is td.AuthorizationStateReady;

  bool get usesTestDc => AppConfig.useTestDc || _testDc;

  td.User? get me => users[myId];

  Stream<td.File> fileUpdates(int fileId) => _fileUpdates.stream.where((f) => f.id == fileId);

  /// Message-level updates (new/edited/deleted messages, send results...) for chat history controllers.
  Stream<td.Update> get messageEvents => _messageEvents.stream;

  /// updateCall, updateNewCallSignalingData and group call updates, for the call service.
  Stream<td.Update> get callEvents => _callEvents.stream;

  ValueNotifier<int> chatRevision(int chatId) => _chatRevisions.putIfAbsent(chatId, () => ValueNotifier(0));

  td.ChatPosition? positionIn(td.Chat chat, td.ChatList list) {
    final key = chatListKey(list);
    for (final position in chat.positions) {
      if (chatListKey(position.list) == key) return position;
    }
    return null;
  }

  /// Chats of a list in display order (pinned first, then by TDLib's order).
  List<td.Chat> chatList(td.ChatList list) {
    final result = <(td.Chat, td.ChatPosition)>[];
    for (final chat in chats.values) {
      final position = positionIn(chat, list);
      if (position != null && position.order != 0) result.add((chat, position));
    }
    result.sort((a, b) {
      if (a.$2.isPinned != b.$2.isPinned) return a.$2.isPinned ? -1 : 1;
      return b.$2.order.compareTo(a.$2.order);
    });
    return [for (final entry in result) entry.$1];
  }

  bool isListFullyLoaded(td.ChatList list) => _listFullyLoaded[chatListKey(list)] ?? false;

  bool isSavedMessages(td.Chat chat) => chat.type is td.ChatTypePrivate && (chat.type as td.ChatTypePrivate).userId == myId;

  td.User? privateUser(td.Chat chat) => switch (chat.type) {
    td.ChatTypePrivate(:final userId) => users[userId],
    td.ChatTypeSecret(:final userId) => users[userId],
    _ => null,
  };

  td.Supergroup? supergroupOf(td.Chat chat) => chat.type is td.ChatTypeSupergroup ? supergroups[(chat.type as td.ChatTypeSupergroup).supergroupId] : null;

  td.BasicGroup? basicGroupOf(td.Chat chat) => chat.type is td.ChatTypeBasicGroup ? basicGroups[(chat.type as td.ChatTypeBasicGroup).basicGroupId] : null;

  bool isChannel(td.Chat chat) => chat.type is td.ChatTypeSupergroup && (chat.type as td.ChatTypeSupergroup).isChannel;

  bool isGroup(td.Chat chat) => chat.type is td.ChatTypeBasicGroup || (chat.type is td.ChatTypeSupergroup && !isChannel(chat));

  bool isBot(td.User? user) => user?.type is td.UserTypeBot;

  /// Default notification settings per scope (updateScopeNotificationSettings), keyed by scope type.
  final Map<Type, td.ScopeNotificationSettings> scopeNotificationSettings = {};

  td.NotificationSettingsScope notificationScopeOf(td.Chat chat) => switch (chat.type) {
    td.ChatTypePrivate() || td.ChatTypeSecret() => const td.NotificationSettingsScopePrivateChats(),
    _ when isChannel(chat) => const td.NotificationSettingsScopeChannelChats(),
    _ => const td.NotificationSettingsScopeGroupChats(),
  };

  /// A chat following its scope default ("use_default_mute_for") is muted when the scope is,
  /// as Telegram apps do; its own mute_for is ignored then.
  bool isMuted(td.Chat chat) {
    final settings = chat.notificationSettings;
    if (!settings.useDefaultMuteFor) return settings.muteFor > 0;
    return (scopeNotificationSettings[notificationScopeOf(chat).runtimeType]?.muteFor ?? 0) > 0;
  }

  td.ChatMemberStatus? myStatus(td.Chat chat) => supergroupOf(chat)?.status ?? basicGroupOf(chat)?.status;

  bool isAdmin(td.Chat chat) {
    final status = myStatus(chat);
    return status is td.ChatMemberStatusCreator || status is td.ChatMemberStatusAdministrator;
  }

  bool isMember(td.Chat chat) {
    final status = myStatus(chat);
    if (status == null) return true;
    return switch (status) {
      td.ChatMemberStatusLeft() || td.ChatMemberStatusBanned() => false,
      td.ChatMemberStatusRestricted(:final isMember) => isMember,
      td.ChatMemberStatusCreator(:final isMember) => isMember,
      _ => true,
    };
  }

  bool canSendMessages(td.Chat chat) {
    if (!isMember(chat)) return false;
    if (chat.type is td.ChatTypeSecret) return secretChatOf(chat)?.state is td.SecretChatStateReady;
    final user = privateUser(chat);
    if (user != null) return user.type is! td.UserTypeDeleted;
    if (isChannel(chat)) {
      final status = myStatus(chat);
      return status is td.ChatMemberStatusCreator || (status is td.ChatMemberStatusAdministrator && status.rights.canPostMessages);
    }
    final status = myStatus(chat);
    if (status is td.ChatMemberStatusCreator || status is td.ChatMemberStatusAdministrator) return true;
    if (status is td.ChatMemberStatusRestricted) return status.permissions.canSendBasicMessages;
    return chat.permissions.canSendBasicMessages;
  }

  int memberCount(td.Chat chat) => supergroupOf(chat)?.memberCount ?? basicGroupOf(chat)?.memberCount ?? 0;

  String? usernameOf(td.Chat chat) {
    final user = privateUser(chat);
    final usernames = user?.usernames ?? supergroupOf(chat)?.usernames;
    if (usernames == null || usernames.activeUsernames.isEmpty) return null;
    return usernames.activeUsernames.first;
  }

  String userName(int userId) {
    final user = users[userId];
    if (user == null) return '';
    if (user.type is td.UserTypeDeleted) return 'Deleted Account';
    return '${user.firstName} ${user.lastName}'.trim();
  }

  String senderName(td.MessageSender sender) => switch (sender) {
    td.MessageSenderUser(:final userId) => userName(userId),
    td.MessageSenderChat(:final chatId) => chats[chatId]?.title ?? '',
    _ => '',
  };

  int senderKey(td.MessageSender sender) => switch (sender) {
    td.MessageSenderUser(:final userId) => userId,
    td.MessageSenderChat(:final chatId) => chatId,
    _ => 0,
  };

  // ------------------------------------------------------------------ update handling

  void _markList() {
    if (_listDirty) return;
    _listDirty = true;
    scheduleMicrotask(() {
      _listDirty = false;
      chatListRevision.value++;
    });
  }

  void _markUsers() {
    if (_usersDirty) return;
    _usersDirty = true;
    scheduleMicrotask(() {
      _usersDirty = false;
      usersRevision.value++;
    });
  }

  void _markChat(int chatId, {bool affectsList = true}) {
    if (affectsList) _markList();
    if (_dirtyChats.add(chatId) && _dirtyChats.length == 1) {
      scheduleMicrotask(() {
        final dirty = _dirtyChats.toList();
        _dirtyChats.clear();
        for (final id in dirty) {
          final notifier = _chatRevisions[id];
          if (notifier != null) notifier.value++;
        }
      });
    }
  }

  /// Rebuilds an immutable TDLib object with some JSON fields replaced (supports setting fields to null).
  static T _patch<T extends td.TdObject>(T object, Map<String, dynamic> changes) {
    final json = object.toJson()..addAll(changes);
    return json.toTdObject()! as T;
  }

  void _updateChat(int chatId, td.Chat Function(td.Chat chat) change, {bool affectsList = true}) {
    final chat = chats[chatId];
    if (chat == null) return;
    chats[chatId] = change(chat);
    _markChat(chatId, affectsList: affectsList);
  }

  void _setPosition(int chatId, td.ChatPosition position) {
    _updateChat(chatId, (chat) {
      final key = chatListKey(position.list);
      final positions = chat.positions.where((p) => chatListKey(p.list) != key).toList();
      if (position.order != 0) positions.add(position);
      return chat.copyWith(positions: positions);
    });
  }

  void _setPositions(int chatId, List<td.ChatPosition> positions) {
    for (final position in positions) {
      _setPosition(chatId, position);
    }
  }

  /// Feeds an update as if it came from TDLib (tests only).
  @visibleForTesting
  void debugHandleUpdate(td.TdObject object) => _onUpdate(object);

  void _onUpdate(td.TdObject object) {
    switch (object) {
      case td.UpdateAuthorizationState(:final authorizationState):
        _onAuthorizationState(authorizationState);
      case td.UpdateOption(:final name, :final value):
        options[name] = value;
        if (name == 'my_id') _markUsers();
      case td.UpdateReactionNotificationSettings(:final notificationSettings):
        reactionNotifications = notificationSettings;
      case td.UpdateAttachmentMenuBots(:final bots):
        attachmentMenuBots = bots;
      case td.UpdateConnectionState(:final state):
        connectionState.value = state;
      case td.UpdateNewChat(:final chat):
        chats[chat.id] = chat;
        _markChat(chat.id);
      case td.UpdateChatTitle(:final chatId, :final title):
        _updateChat(chatId, (c) => c.copyWith(title: title));
      case td.UpdateChatPhoto(:final chatId, :final photo):
        _updateChat(chatId, (c) => _patch(c, {'photo': photo?.toJson()}));
      case td.UpdateChatBackground(:final chatId, :final background):
        _updateChat(chatId, (c) => _patch(c, {'background': background?.toJson()}));
      case td.UpdateChatTheme(:final chatId, :final theme):
        _updateChat(chatId, (c) => _patch(c, {'theme': theme?.toJson()}));
      case td.UpdateEmojiChatThemes(:final chatThemes):
        emojiChatThemes = chatThemes;
      case td.UpdateUnconfirmedSession(:final session):
        unconfirmedSession.value = session;
      case td.UpdateActiveEmojiReactions(:final emojis):
        activeEmojiReactions = emojis;
      case td.UpdateAccentColors(:final colors):
        accentColors = colors;
      case td.UpdateProfileAccentColors(:final colors):
        profileAccentColors = colors;
      case td.UpdateChatPermissions(:final chatId, :final permissions):
        _updateChat(chatId, (c) => c.copyWith(permissions: permissions), affectsList: false);
      case td.UpdateChatVideoChat(:final chatId, :final videoChat):
        _updateChat(chatId, (c) => c.copyWith(videoChat: videoChat), affectsList: false);
      case td.UpdateChatLastMessage(:final chatId, :final lastMessage, :final positions):
        _updateChat(chatId, (c) => _patch(c, {'last_message': lastMessage?.toJson()}));
        _setPositions(chatId, positions);
      case td.UpdateChatPosition(:final chatId, :final position):
        _setPosition(chatId, position);
      case td.UpdateChatAddedToList(:final chatId, :final chatList):
        _updateChat(chatId, (c) => c.copyWith(chatLists: [...c.chatLists, chatList]));
      case td.UpdateChatRemovedFromList(:final chatId, :final chatList):
        final key = chatListKey(chatList);
        _updateChat(chatId, (c) => c.copyWith(chatLists: c.chatLists.where((l) => chatListKey(l) != key).toList()));
      case td.UpdateChatReadInbox(:final chatId, :final lastReadInboxMessageId, :final unreadCount):
        _updateChat(chatId, (c) => c.copyWith(lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount));
        // Read for real (ghost off, or on another device): the local read shrinks or goes away.
        final base = _ghostReadBase[chatId];
        if (base != null && unreadCount < base) {
          if (unreadCount == 0) {
            _ghostReadBase.remove(chatId);
          } else {
            _ghostReadBase[chatId] = unreadCount;
          }
          _saveGhostRead();
        }
      case td.UpdateChatReadOutbox(:final chatId, :final lastReadOutboxMessageId):
        _updateChat(chatId, (c) => c.copyWith(lastReadOutboxMessageId: lastReadOutboxMessageId));
      case td.UpdateChatUnreadMentionCount(:final chatId, :final unreadMentionCount):
        _updateChat(chatId, (c) => c.copyWith(unreadMentionCount: unreadMentionCount));
      case td.UpdateChatUnreadReactionCount(:final chatId, :final unreadReactionCount):
        _updateChat(chatId, (c) => c.copyWith(unreadReactionCount: unreadReactionCount));
      case td.UpdateChatNotificationSettings(:final chatId, :final notificationSettings):
        _updateChat(chatId, (c) => c.copyWith(notificationSettings: notificationSettings));
      case td.UpdateScopeNotificationSettings(:final scope, :final notificationSettings):
        scopeNotificationSettings[scope.runtimeType] = notificationSettings;
        // Chat tiles read mute state on rebuild; the folder revision refreshes the lists.
        foldersRevision.value++;
      case td.UpdateChatDraftMessage(:final chatId, :final draftMessage, :final positions):
        _updateChat(chatId, (c) => _patch(c, {'draft_message': draftMessage?.toJson()}));
        _setPositions(chatId, positions);
      case td.UpdateChatHasScheduledMessages(:final chatId, :final hasScheduledMessages):
        _updateChat(chatId, (c) => c.copyWith(hasScheduledMessages: hasScheduledMessages), affectsList: false);
      case td.UpdateChatIsMarkedAsUnread(:final chatId, :final isMarkedAsUnread):
        _updateChat(chatId, (c) => c.copyWith(isMarkedAsUnread: isMarkedAsUnread));
      case td.UpdateChatOnlineMemberCount(:final chatId, :final onlineMemberCount):
        onlineMemberCounts[chatId] = onlineMemberCount;
        _markChat(chatId, affectsList: false);
      case td.UpdateChatActiveStories(:final activeStories):
        this.activeStories[activeStories.chatId] = activeStories;
        storiesRevision.value++;
      case td.UpdateChatReplyMarkup(:final chatId, :final replyMarkupMessage):
        if (replyMarkupMessage == null) {
          replyMarkupMessages.remove(chatId);
        } else {
          replyMarkupMessages[chatId] = replyMarkupMessage;
        }
        _updateChat(chatId, (c) => c.copyWith(replyMarkupMessageId: replyMarkupMessage?.id ?? 0), affectsList: false);
      case td.UpdateChatAction(:final chatId, :final senderId, :final action):
        _onChatAction(chatId, senderKey(senderId), action);
      case td.UpdateUser(:final user):
        users[user.id] = user;
        contactChanges.onUser(user);
        _markUsers();
        _markList();
      case td.UpdateUserStatus(:final userId, :final status):
        final user = users[userId];
        if (user != null) {
          users[userId] = user.copyWith(status: status);
          _markUsers();
          _markList();
        }
      case td.UpdateSecretChat(:final secretChat):
        secretChats[secretChat.id] = secretChat;
        _markList();
        for (final chat in chats.values) {
          if (chat.type case td.ChatTypeSecret(:final secretChatId) when secretChatId == secretChat.id) _markChat(chat.id);
        }
      case td.UpdateBasicGroup(:final basicGroup):
        basicGroups[basicGroup.id] = basicGroup;
        _markList();
      case td.UpdateSupergroup(:final supergroup):
        supergroups[supergroup.id] = supergroup;
        _markList();
      case td.UpdateFile(:final file):
        files[file.id] = file;
        _fileUpdates.add(file);
      case td.UpdateChatFolders(:final chatFolders):
        folders = chatFolders;
        foldersRevision.value++;
      case td.UpdateUnreadMessageCount(:final chatList, :final unreadCount):
        unreadCounts[chatListKey(chatList)] = unreadCount;
        foldersRevision.value++;
      case td.UpdateTextCompositionStyles(:final styles):
        compositionStyles = styles;
      case td.UpdateQuickReplyShortcut(:final shortcut):
        quickReplies[shortcut.id] = shortcut;
        quickRepliesRevision.value++;
      case td.UpdateQuickReplyShortcuts(:final shortcutIds):
        quickReplyOrder = shortcutIds;
        quickRepliesRevision.value++;
      case td.UpdateQuickReplyShortcutDeleted(:final shortcutId):
        quickReplies.remove(shortcutId);
        quickRepliesRevision.value++;
      case td.UpdateNewMessage(:final message):
        _clearAction(message.chatId, senderKey(message.senderId));
        archive.remember(message);
        _messageEvents.add(object);
      // The archive sees each change before chat histories do, so they can ask it what was kept.
      case td.UpdateMessageSendSucceeded(:final message, :final oldMessageId):
        archive.onSendSucceeded(message, oldMessageId);
        _messageEvents.add(object);
      case td.UpdateMessageContent(:final chatId, :final messageId, :final newContent):
        archive.onContentChanged(chatId, messageId, newContent);
        _messageEvents.add(object);
      case td.UpdateMessageEdited(:final chatId, :final messageId, :final editDate):
        archive.onEdited(chatId, messageId, editDate);
        _messageEvents.add(object);
      case td.UpdateDeleteMessages(:final chatId, :final messageIds, :final isPermanent, :final fromCache):
        if (isPermanent && !fromCache) archive.onDeleted(chatId, messageIds);
        _messageEvents.add(object);
      case td.UpdateMessageSendFailed() || td.UpdateMessageInteractionInfo() || td.UpdateMessageIsPinned() || td.UpdateMessageSendAcknowledged():
        _messageEvents.add(object as td.Update);
      case td.UpdateSavedMessagesTopic() || td.UpdateSavedMessagesTags() || td.UpdateQuickReplyShortcutMessages():
        _messageEvents.add(object as td.Update);
      case td.UpdateCall() || td.UpdateNewCallSignalingData() || td.UpdateGroupCall() || td.UpdateGroupCallParticipant():
        _callEvents.add(object as td.Update);
      default:
        break;
    }
  }

  void _onChatAction(int chatId, int senderId, td.ChatAction action) {
    final timerKey = chatId ^ (senderId << 20);
    _actionTimers.remove(timerKey)?.cancel();
    if (action is td.ChatActionCancel) {
      _clearAction(chatId, senderId);
      return;
    }
    chatActions.putIfAbsent(chatId, () => {})[senderId] = ActiveChatAction(senderId, action);
    _markChat(chatId);
    // TDLib re-sends active actions every few seconds; expire stale ones defensively.
    _actionTimers[timerKey] = Timer(const Duration(seconds: 6), () => _clearAction(chatId, senderId));
  }

  void _clearAction(int chatId, int senderId) {
    final actions = chatActions[chatId];
    if (actions == null || actions.remove(senderId) == null) return;
    if (actions.isEmpty) chatActions.remove(chatId);
    _markChat(chatId);
  }

  Future<void> _onAuthorizationState(td.AuthorizationState state) async {
    authState.value = state;
    if (state is td.AuthorizationStateWaitTdlibParameters) {
      final credentials = _credentials!;
      try {
        final databaseKey = await _databaseKey();
        // The account may have been disposed (log out, account removed, test teardown) while the key loaded.
        if (_disposed) return;
        await client.send<td.Ok>(
          td.SetTdlibParameters(
            useTestDc: usesTestDc,
            databaseDirectory: databaseDirectory,
            filesDirectory: '$databaseDirectory${Platform.pathSeparator}files',
            databaseEncryptionKey: databaseKey,
            useFileDatabase: true,
            useChatInfoDatabase: true,
            useMessageDatabase: true,
            useSecretChats: true,
            apiId: credentials.apiId,
            apiHash: credentials.apiHash,
            systemLanguageCode: _languageCode,
            deviceModel: await _deviceModel(),
            systemVersion: Platform.operatingSystemVersion,
            applicationVersion: AppConfig.appVersion,
          ),
        );
      } on TdException catch (error) {
        debugPrint('setTdlibParameters failed: $error');
      } on FileSystemException catch (error) {
        // Without the key the encrypted database cannot be opened; TDLib stays waiting for parameters.
        if (!_disposed) debugPrint('database key unavailable: ${error.message}');
      }
    } else if (state is td.AuthorizationStateWaitPhoneNumber && _pendingTestPhone != null) {
      // The number was typed before the restart onto the test servers; submit it once.
      final phone = _pendingTestPhone!;
      _pendingTestPhone = null;
      try {
        await client.send<td.Ok>(td.SetAuthenticationPhoneNumber(phoneNumber: phone, settings: phoneAuthSettings));
      } on TdException catch (error) {
        debugPrint('test phone submit failed: $error');
      }
    } else if (state is td.AuthorizationStateReady) {
      unawaited(_afterLogin());
    }
  }

  Future<String> _databaseKey() async {
    // The database is encrypted with a random per-account key kept next to it in app-private storage.
    final file = File('$databaseDirectory${Platform.pathSeparator}.key');
    if (await file.exists()) return (await file.readAsString()).trim();
    final random = Random.secure();
    final key = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
    await file.writeAsString(key, flush: true);
    return key;
  }

  /// Shown to the user in Settings → Devices on every device, e.g. "Redmi Note 12 Pro" instead of "Android".
  static Future<String> _deviceModel() async {
    if (Platform.isAndroid) {
      try {
        Future<String> prop(String name) async => ((await Process.run('getprop', [name])).stdout as String).trim();
        // Xiaomi and others keep the marketing name ("Redmi Note 12 Pro") apart from the model code ("2209116AG").
        final marketName = await prop('ro.product.marketname');
        if (marketName.isNotEmpty) return marketName.replaceAll(RegExp(r'\s+'), ' ');
        final brand = await prop('ro.product.brand');
        final model = await prop('ro.product.model');
        if (model.isNotEmpty) return model.toLowerCase().startsWith(brand.toLowerCase()) ? model : '$brand $model'.trim();
      } on ProcessException {
        // Fall through to the generic name.
      }
      return 'Android';
    }
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return Platform.localHostname;
    return Platform.operatingSystem;
  }

  Future<void> _afterLogin() async {
    try {
      await loadChats(const td.ChatListMain(), limit: 50);
    } on TdException catch (error) {
      debugPrint('initial loadChats failed: $error');
    }
    await loadStories();
  }

  bool _storiesFullyLoaded = false;

  /// Loads the main story list; TDLib answers 404 once every chat with stories was sent.
  Future<void> loadStories() async {
    if (_storiesFullyLoaded) return;
    try {
      await client.send<td.Ok>(const td.LoadActiveStories(storyList: td.StoryListMain()));
    } on TdException catch (error) {
      if (error.code == 404) {
        _storiesFullyLoaded = true;
      } else {
        debugPrint('loadActiveStories failed: $error');
      }
    }
  }

  // ------------------------------------------------------------------ requests

  Future<T> send<T extends td.TdObject>(td.TdFunction function) => client.send<T>(function);

  /// Asks TDLib to load more chats of a list; returns false when everything is already loaded.
  Future<bool> loadChats(td.ChatList list, {int limit = 100}) async {
    final key = chatListKey(list);
    if (_listFullyLoaded[key] ?? false) return false;
    try {
      await client.send<td.Ok>(td.LoadChats(chatList: list, limit: limit));
      return true;
    } on TdException catch (error) {
      if (error.code == 404) {
        _listFullyLoaded[key] = true;
        _markList();
        return false;
      }
      rethrow;
    }
  }

  /// Starts (or joins) a download and completes with the local path once finished.
  Future<String?> downloadFile(int fileId, {int priority = 16}) async {
    final cached = files[fileId];
    if (cached != null && cached.local.isDownloadingCompleted) return cached.local.path;
    try {
      final file = await client.send<td.File>(td.DownloadFile(fileId: fileId, priority: priority, offset: 0, limit: 0, synchronous: true));
      files[file.id] = file;
      return file.local.isDownloadingCompleted ? file.local.path : null;
    } on TdException catch (error) {
      debugPrint('download $fileId failed: $error');
      return null;
    }
  }

  void cancelDownload(int fileId) {
    unawaited(client.send<td.Ok>(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false)).catchError((Object _) => const td.Ok()));
  }

  Future<td.Chat> getChat(int chatId) async {
    final chat = chats[chatId];
    if (chat != null) return chat;
    return client.send<td.Chat>(td.GetChat(chatId: chatId));
  }

  Future<td.User?> getUser(int userId) async {
    final user = users[userId];
    if (user != null) return user;
    try {
      return await client.send<td.User>(td.GetUser(userId: userId));
    } on TdException {
      return null;
    }
  }

  /// Ghost mode: stop broadcasting online status.
  Future<void> setOnline(bool online) async {
    try {
      await client.send<td.Ok>(
        td.SetOption(
          name: 'online',
          value: td.OptionValueBoolean(value: online),
        ),
      );
    } on TdException catch (error) {
      debugPrint('set online failed: $error');
    }
  }

  Future<void> logOut() => client.send<td.Ok>(const td.LogOut());

  Future<void> dispose() async {
    _disposed = true;
    await archive.save();
    try {
      if (!client.isClosed) await client.send<td.Ok>(const td.Close()).timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      debugPrint('close failed: $error');
    }
    await _subscription?.cancel();
    for (final timer in _actionTimers.values) {
      timer.cancel();
    }
    await _fileUpdates.close();
    await _messageEvents.close();
    await _callEvents.close();
  }
}
