import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_providers.dart';
import 'package:gene/src/pairing/pairing_service.dart';
import 'package:gene/src/pairing/relay_transport.dart';
import 'package:share_plus/share_plus.dart';

enum _Step { choose, inviting, entering }

/// The one unusual flow in the app, made obvious: either create a single-use
/// link to send, or paste one you received. Either way it ends with naming the
/// person, who then appears in your list.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  _Step _step = _Step.choose;
  PendingPairing? _pending;
  Timer? _pollTimer;
  final _linkController = TextEditingController();
  bool _busy = false;
  bool _completing = false;
  String? _error;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _linkController.dispose();
    super.dispose();
  }

  RelayTransport get _relay => ref.read(relayTransportProvider);
  Future<LocalIdentity> get _identity => ref.read(identityProvider.future);

  Future<void> _createInvite() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pending = await PairingService.mintInvite(
        await _identity,
        _relay,
        linkBase: '${ref.read(relayBaseUrlProvider)}/i/',
      );
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _step = _Step.inviting;
        _busy = false;
      });
      _pollTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_poll()));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e);
        });
      }
    }
  }

  Future<void> _poll() async {
    final pending = _pending;
    // Bail if a redemption is already being finalized — ticks can overlap when
    // a poll takes longer than the interval, and we must add the contact once.
    if (pending == null || _completing) return;
    try {
      final contact = await pending.tryComplete(_relay);
      if (contact != null) {
        _pollTimer?.cancel();
        await _finish(contact);
      }
    } catch (_) {
      // transient; keep polling
    }
  }

  Future<void> _redeem() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final contact = await PairingService.redeemInvite(
        await _identity,
        _linkController.text.trim(),
        _relay,
      );
      await _finish(contact);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e);
        });
      }
    }
  }

  Future<void> _finish(Contact contact) async {
    // The single chokepoint for adding a paired contact — idempotent, so a
    // racing poll and a manual redeem can't both add it.
    if (_completing) return;
    _completing = true;
    _pollTimer?.cancel();
    final name = await _askName();
    if (!mounted) return;
    final named = (name != null && name.trim().isNotEmpty)
        ? contact.withName(name.trim())
        : contact;
    await ref.read(contactsProvider.notifier).add(named);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<String?> _askName() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("You're connected!"),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name this person'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  String _friendly(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a friend')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_step) {
          _Step.choose => _chooseView(),
          _Step.inviting => _invitingView(),
          _Step.entering => _enteringView(),
        },
      ),
    );
  }

  Widget _chooseView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'gene connects one friend at a time — no phone numbers, no address '
          'book. Send a one-time link; whoever opens it is connected to you.',
          style:
              TextStyle(color: Colors.white.withValues(alpha: 0.7), height: 1.4),
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: _busy ? null : _createInvite,
          icon: const Icon(Icons.link),
          label: const Text('Create an invite link'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => setState(() => _step = _Step.entering),
          icon: const Icon(Icons.input),
          label: const Text('I have a link'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
      ],
    );
  }

  Widget _invitingView() {
    final link = _pending?.link ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text(
          'Share this link with one person',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            link,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: link)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () =>
                    unawaited(SharePlus.instance.share(ShareParams(text: link))),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Waiting for them to open it…'),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'It works once. The moment they open it, they slide into your list.',
          textAlign: TextAlign.center,
          style:
              TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
        ),
      ],
    );
  }

  Widget _enteringView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text(
          'Paste the link a friend sent you',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _linkController,
          decoration: const InputDecoration(
            hintText: 'Paste the link your friend sent',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _redeem,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
      ],
    );
  }
}
