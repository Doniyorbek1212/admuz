import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;
import 'package:url_launcher/url_launcher.dart';

import '../../core/phone_numbers.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';
import '../profile/chat_info_screen.dart';

/// Telegram user behind a phone number, or null when the number has no account or hides it (privacy:
/// "Who can find me by my number"). Kept for the session: Telegram rate-limits phone lookups hard.
final phoneUserProvider = FutureProvider.family<int?, String>((ref, phone) async {
  final account = ref.watch(accountProvider);
  try {
    final user = await account.send<td.User>(td.SearchUserByPhoneNumber(phoneNumber: phone, onlyLocal: false));
    return user.id == account.myId ? null : user.id;
  } on TdException catch (error) {
    debugPrint('phone lookup: ${error.message}');
    return null;
  }
});

/// A phone number tapped in a message: when it has Telegram, offer to write to that person or open their
/// profile (calling stays one tap away); otherwise the phone's dialer opens, as before.
Future<void> openPhoneNumber(BuildContext context, String written) async {
  Future<void> dial() => launchUrl(Uri(scheme: 'tel', path: written));
  final phone = phoneNumbersIn(written).firstOrNull ?? written.replaceAll(RegExp(r'\D'), '');
  final container = ProviderScope.containerOf(context, listen: false);
  final userId = await container.read(phoneUserProvider(phone).future);
  if (!context.mounted) return;
  if (userId == null) return dial();
  final account = container.read(accountProvider);
  final s = context.s;
  final name = account.userName(userId);
  final choice = await showModalBottomSheet<_PhoneAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(name.isEmpty ? written : name, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(written)),
          for (final (action, icon, key) in [
            (_PhoneAction.chat, Icons.chat_bubble_outline_rounded, 'send_message'),
            (_PhoneAction.profile, Icons.person_outline_rounded, 'tab_profile'),
            (_PhoneAction.call, Icons.call_outlined, 'call'),
          ])
            ListTile(leading: Icon(icon), title: Text(s.t(key)), onTap: () => Navigator.pop(context, action)),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == _PhoneAction.call) return dial();
  final chat = await guard(context, () => account.openPrivateChat(userId));
  if (chat == null || !context.mounted) return;
  if (choice == _PhoneAction.chat) return openChat(context, chat.id);
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatInfoScreen(chatId: chat.id)));
}

enum _PhoneAction { chat, profile, call }
