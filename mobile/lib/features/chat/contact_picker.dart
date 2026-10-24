import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as phone;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib_ex/td_api.dart' as td;

import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../contacts/contacts_screen.dart';

/// Telegram's "share contact": Telegram contacts and the phone book, both searchable. Pops with a [td.Contact].
class ContactPickerScreen extends ConsumerStatefulWidget {
  const ContactPickerScreen({super.key});

  @override
  ConsumerState<ContactPickerScreen> createState() => _ContactPickerScreenState();
}

class _ContactPickerScreenState extends ConsumerState<ContactPickerScreen> {
  String _query = '';
  late final Future<List<phone.Contact>?> _phoneBook = _loadPhoneBook();

  /// Null when contacts permission is denied.
  Future<List<phone.Contact>?> _loadPhoneBook() async {
    final status = await phone.FlutterContacts.permissions.request(phone.PermissionType.read);
    if (status != phone.PermissionStatus.granted && status != phone.PermissionStatus.limited) return null;
    final contacts = await phone.FlutterContacts.getAll(properties: {phone.ContactProperty.name, phone.ContactProperty.phone});
    return contacts.where((c) => c.phones.isNotEmpty).toList()
      ..sort((a, b) => (a.displayName ?? '').toLowerCase().compareTo((b.displayName ?? '').toLowerCase()));
  }

  bool _matches(String name, String number) =>
      _query.isEmpty || name.toLowerCase().contains(_query) || number.replaceAll(RegExp(r'\D'), '').contains(_query);

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            autofocus: false,
            decoration: InputDecoration(hintText: s.t('search'), border: InputBorder.none, prefixIcon: const Icon(Icons.search_rounded)),
            onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
          ),
          bottom: TabBar(tabs: [Tab(text: 'Telegram'), Tab(text: s.t('phone'))]),
        ),
        body: TabBarView(children: [_telegramContacts(), _phoneContacts()]),
      ),
    );
  }

  Widget _telegramContacts() {
    final account = ref.watch(accountProvider);
    return ref.watch(contactsProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(errorText(context, error))),
          data: (ids) {
            final users = [
              for (final id in ids)
                if (account.users[id] case final user? when _matches('${user.firstName} ${user.lastName}', user.phoneNumber)) user,
            ];
            return ListView.builder(
              itemCount: users.length,
              itemBuilder: (context, i) {
                final user = users[i];
                return ListTile(
                  leading: UserAvatar(userId: user.id, size: 44),
                  title: Text('${user.firstName} ${user.lastName}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: user.phoneNumber.isEmpty ? null : Text('+${user.phoneNumber}'),
                  onTap: () => Navigator.pop(
                    context,
                    td.Contact(phoneNumber: user.phoneNumber, firstName: user.firstName, lastName: user.lastName, vcard: '', userId: user.id),
                  ),
                );
              },
            );
          },
        );
  }

  Widget _phoneContacts() {
    final s = context.s;
    return FutureBuilder<List<phone.Contact>?>(
      future: _phoneBook,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final contacts = snapshot.data;
        if (contacts == null) return Center(child: Text(s.t('contacts_permission')));
        final shown = [
          for (final contact in contacts)
            if (_matches(contact.displayName ?? '', contact.phones.first.number)) contact,
        ];
        return ListView.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final contact = shown[i];
            final name = contact.displayName ?? '';
            return ListTile(
              leading: CircleAvatar(child: Text(name.isEmpty ? '#' : name.characters.first.toUpperCase())),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(contact.phones.map((p) => p.number).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(
                context,
                // userId 0: TDLib links the card to a Telegram account by phone number if there is one.
                td.Contact(
                  phoneNumber: contact.phones.first.number,
                  firstName: contact.name?.first ?? name,
                  lastName: contact.name?.last ?? '',
                  vcard: '',
                  userId: 0,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
