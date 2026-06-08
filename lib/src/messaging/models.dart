import 'dart:convert';

/// The cleartext of a feed entry — sealed end-to-end under a per-message key, so
/// the relay never sees it. A video missive references its encrypted blob by
/// object id and carries that blob's own decryption key, so the media key never
/// reaches the relay either.
class Missive {
  Missive({
    required this.mediaId,
    required this.mediaKey,
    required this.durationMs,
    this.kind = 'video',
  });

  /// Reserved for future payload types; only 'video' is handled today.
  final String kind;
  final String mediaId;
  final List<int> mediaKey;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'media': mediaId,
        'mk': base64.encode(mediaKey),
        'dur': durationMs,
      };

  factory Missive.fromJson(Map<String, dynamic> json) => Missive(
        kind: json['kind'] as String? ?? 'video',
        mediaId: json['media'] as String,
        mediaKey: base64.decode(json['mk'] as String),
        durationMs: json['dur'] as int? ?? 0,
      );
}

/// A received missive in the local library. The relay copy is destroyed on ack,
/// so this device keeps the only copy.
class ReceivedMissive {
  ReceivedMissive({
    required this.inboundFeedId,
    required this.seq,
    required this.fileName,
    required this.durationMs,
    required this.receivedAtMs,
  });

  /// The feed it arrived on (our [Contact.inboundFeedId]) — ties the missive to
  /// its sender and namespaces its file.
  final String inboundFeedId;
  final int seq;

  /// The decrypted media file's name, **relative** to the missives directory.
  /// Stored relative (not absolute) so the library survives the app's container
  /// path changing across reinstall/restore — it's re-joined with the live
  /// directory at read time.
  final String fileName;
  final int durationMs;
  final int receivedAtMs;

  Map<String, dynamic> toJson() => {
        'feed': inboundFeedId,
        'seq': seq,
        'file': fileName,
        'dur': durationMs,
        'at': receivedAtMs,
      };

  factory ReceivedMissive.fromJson(Map<String, dynamic> json) =>
      ReceivedMissive(
        inboundFeedId: json['feed'] as String,
        seq: json['seq'] as int,
        fileName: json['file'] as String,
        durationMs: json['dur'] as int? ?? 0,
        receivedAtMs: json['at'] as int? ?? 0,
      );
}
