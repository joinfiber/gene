import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/messaging/messaging_providers.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_providers.dart';
import 'package:gene/src/playback/playback_screen.dart';
import 'package:gene/src/recorder/recorder_screen.dart';

/// One conversation: the missives you've received from a contact, a pull to
/// fetch new ones, and the button to record one back. Sending lives one level
/// down (record → review → send), keeping this screen about what's arrived.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, required this.contact});

  final Contact contact;

  /// Route name so the compose flow can pop straight back here after sending.
  static const routeName = 'conversation';

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  /// The live contact (its cursor advances as we sync), falling back to the one
  /// we were opened with.
  Contact get _contact {
    final list = ref.read(contactsProvider).asData?.value ?? const <Contact>[];
    return list.firstWhere(
      (c) => c.outboundFeedId == widget.contact.outboundFeedId,
      orElse: () => widget.contact,
    );
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      // Ensure the contact list is loaded first, so we sync the *live* contact
      // (with its real cursor) — not the snapshot we were opened with, which
      // could regress the cursor.
      await ref.read(contactsProvider.future);
      final count = await ref.read(conversationProvider).sync(_contact);
      if (mounted && count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count == 1 ? '1 new missive' : '$count new missives'),
        ));
      }
    } catch (_) {
      // Offline or transient — leave the existing library in place silently.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _showSafetyNumber() async {
    final String number;
    try {
      final me = await ref.read(identityProvider.future);
      number = await _contact.safetyNumber(me.publicKey);
    } catch (_) {
      return; // identity unavailable — nothing to show
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Safety number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Read these digits to each other over a channel you trust. If they '
              'match on both phones, your connection is private — no one is in '
              'the middle.',
            ),
            const SizedBox(height: 20),
            Center(
              child: SelectableText(
                number,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contact = _contact;
    final name = contact.name ?? contact.shortId;
    final library = ref.watch(libraryProvider);
    final mediaDir = ref.watch(missivesDirProvider).asData?.value;
    final missives = [
      ...?library.asData?.value
          .where((m) => m.inboundFeedId == contact.inboundFeedId),
    ]..sort((a, b) => b.seq.compareTo(a.seq));

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            tooltip: 'Verify safety number',
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: _showSafetyNumber,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecorderScreen(recipient: contact),
          ),
        ),
        icon: const Icon(Icons.videocam),
        label: const Text('Record'),
      ),
      body: RefreshIndicator(
        onRefresh: _sync,
        child: missives.isEmpty
            ? _EmptyConversation(name: name)
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: missives.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) =>
                    _MissiveTile(missive: missives[i], mediaDir: mediaDir),
              ),
      ),
    );
  }
}

class _MissiveTile extends StatelessWidget {
  const _MissiveTile({required this.missive, required this.mediaDir});

  final ReceivedMissive missive;

  /// The directory the (relative) [ReceivedMissive.fileName] resolves against;
  /// null until it has loaded, in which case the tile is not yet tappable.
  final Directory? mediaDir;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dir = mediaDir;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: accent.withValues(alpha: 0.18),
        child: Icon(Icons.play_arrow_rounded, color: accent),
      ),
      title:
          const Text('Missive', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${_relativeTime(missive.receivedAtMs)} · ${_duration(missive.durationMs)}',
      ),
      onTap: dir == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PlaybackScreen(path: '${dir.path}/${missive.fileName}'),
                ),
              ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    // A ListView so pull-to-refresh works even when there's nothing here yet.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            children: [
              Icon(
                Icons.all_inbox_outlined,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              const Text(
                'No missives yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                'Record one for $name, or pull down to check for theirs.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _duration(int ms) {
  final seconds = (ms / 1000).round();
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return m > 0 ? '${m}m ${s}s' : '${s}s';
}

String _relativeTime(int epochMs) {
  if (epochMs == 0) return 'just now';
  final delta = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(epochMs),
  );
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
