import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../core/phone_numbers.dart';
import '../../core/tdlib/td_client.dart';
import '../../l10n/strings.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../home/home_screen.dart';

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

/// Under a Saved Messages note that holds phone numbers: one "Write a message" button per number that has Telegram.
class PhoneChatButtons extends ConsumerWidget {
  const PhoneChatButtons({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buttons = [
      for (final phone in phoneNumbersIn(text))
        if (ref.watch(phoneUserProvider(phone)).value case final userId?) _button(context, ref, phone, userId),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons),
    );
  }

  Widget _button(BuildContext context, WidgetRef ref, String phone, int userId) {
    final account = ref.watch(accountProvider);
    final name = account.userName(userId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.45)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          visualDensity: VisualDensity.compact,
        ),
        icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
        label: Text(
          '${context.t('send_message')}${name.isEmpty ? '' : ' · $name'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onPressed: () async {
          final chat = await guard(context, () => account.openPrivateChat(userId));
          if (chat != null && context.mounted) openChat(context, chat.id);
        },
      ),
    );
  }
}
