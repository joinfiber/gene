import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/identity/identity_store.dart';
import 'package:gene/src/pairing/contact_store.dart';
import 'package:gene/src/pairing/http_relay_transport.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/relay_transport.dart';

/// The relay base URL — the one piece of config a build needs. Point it at your
/// own relay at build/run time:
///
///   flutter run --dart-define=GENE_RELAY_URL=https://your-worker.workers.dev
///
/// Two devices that want to exchange missives must point at the **same** relay
/// (it's the shared rendezvous). Defaults to the local dev relay — `npm run dev`
/// in `relay/`, plus `adb reverse tcp:8787 tcp:8787` for a USB device.
final relayBaseUrlProvider = Provider<String>(
  (ref) => const String.fromEnvironment(
    'GENE_RELAY_URL',
    defaultValue: 'http://localhost:8787',
  ),
);

final relayTransportProvider = Provider<RelayTransport>(
  (ref) => HttpRelayTransport(baseUrl: ref.watch(relayBaseUrlProvider)),
);

final identityStoreProvider = Provider<IdentityStore>((ref) => IdentityStore());
final contactStoreProvider = Provider<ContactStore>((ref) => ContactStore());

/// The device identity — loaded (or created) once on first use.
final identityProvider = FutureProvider<LocalIdentity>(
  (ref) => ref.watch(identityStoreProvider).loadOrCreate(),
);

/// The contacts list, loaded from storage and mutated through its controller.
final contactsProvider =
    AsyncNotifierProvider<ContactsController, List<Contact>>(
  ContactsController.new,
);

class ContactsController extends AsyncNotifier<List<Contact>> {
  Future<void> _writes = Future.value();

  @override
  Future<List<Contact>> build() => ref.read(contactStoreProvider).load();

  Future<void> add(Contact contact) =>
      _commit([...?state.asData?.value, contact]);

  /// Remove a contact (matched by its stable outbound feed id), purging its
  /// on-device crown-jewel secrets — the conversation key and the per-feed write
  /// seed — from secure storage along with it.
  Future<void> remove(Contact contact) => _commit([
        for (final c in state.asData?.value ?? const <Contact>[])
          if (c.outboundFeedId != contact.outboundFeedId) c,
      ]);

  Future<void> rename(Contact contact, String name) =>
      replace(contact.withName(name));

  /// Replace a contact in place (matched by its stable outbound feed id) — used
  /// to persist advanced send/receive bookkeeping after a missive. (Named
  /// `replace`, not `update`, since `AsyncNotifier.update` already exists.)
  Future<void> replace(Contact updated) => _commit([
        for (final c in state.asData?.value ?? const <Contact>[])
          if (c.outboundFeedId == updated.outboundFeedId) updated else c,
      ]);

  /// Apply [change] to the *current* stored contact (matched by outbound feed
  /// id) and persist — merging onto the live contact, so a concurrent send and
  /// sync that touch different fields can't clobber each other.
  Future<void> mutate(
    String outboundFeedId,
    Contact Function(Contact) change,
  ) =>
      _commit([
        for (final c in state.asData?.value ?? const <Contact>[])
          if (c.outboundFeedId == outboundFeedId) change(c) else c,
      ]);

  /// Advance a contact's inbound cursor monotonically (never regress it).
  Future<void> advanceInboundCursor(String outboundFeedId, int cursor) =>
      mutate(
        outboundFeedId,
        (c) =>
            cursor > c.inboundCursor ? c.copyWith(inboundCursor: cursor) : c,
      );

  /// Publish [next] immediately, then persist — with writes serialized so two
  /// near-simultaneous pairings can't clobber each other's contact in storage
  /// (a read-modify-write race on the single stored blob).
  Future<void> _commit(List<Contact> next) {
    state = AsyncData(next);
    final store = ref.read(contactStoreProvider);
    final write = _writes.then((_) => store.save(next));
    // Keep the chain alive even if one write fails, so a single error doesn't
    // wedge every later write.
    _writes = write.catchError((Object _) {});
    return write;
  }
}
