import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/contacts/connect_screen.dart';
import 'package:gene/src/contacts/conversation_screen.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_providers.dart';

/// Home: a tall list of the people you're connected to. Empty at first, with a
/// warm nudge toward the one unusual step — creating an invite link.
class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(contactsProvider);
    ref.watch(identityProvider); // warm the device identity on first launch

    return Scaffold(
      appBar: AppBar(title: const Text('gene')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ConnectScreen()),
        ),
        icon: const Icon(Icons.add_link),
        label: const Text('Connect'),
      ),
      body: contacts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text('Could not load contacts.\n$error',
              textAlign: TextAlign.center),
        ),
        data: (list) =>
            list.isEmpty ? const _EmptyState() : _ContactList(contacts: list),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.waving_hand_outlined, size: 56, color: accent),
            const SizedBox(height: 20),
            const Text(
              'No one here yet',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'gene connects you one friend at a time. Create an invite link, '
              "send it to someone, and they're in — no phone numbers, no "
              'address book.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactList extends StatelessWidget {
  const _ContactList({required this.contacts});

  final List<Contact> contacts;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: contacts.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 84),
      itemBuilder: (context, index) {
        final contact = contacts[index];
        final label = contact.name ?? contact.shortId;
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: CircleAvatar(
            radius: 28,
            backgroundColor: accent.withValues(alpha: 0.18),
            child: Text(
              label.isEmpty ? '?' : label[0].toUpperCase(),
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w700,
                fontSize: 22,
              ),
            ),
          ),
          title: Text(
            label,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          subtitle: contact.name == null ? const Text('Tap to open') : null,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: ConversationScreen.routeName),
              builder: (_) => ConversationScreen(contact: contact),
            ),
          ),
        );
      },
    );
  }
}
