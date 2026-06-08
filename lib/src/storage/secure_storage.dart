import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// gene's single secure-storage posture, shared by every store so the on-device
/// crown jewels — the identity seed, each conversation key, each per-feed write
/// seed — are held the same, deliberate way everywhere.
///
/// - **Android:** the v10 default — AES-GCM data encryption under an RSA-OAEP
///   key wrapped in the Android Keystore (hardware-backed where available). The
///   old `encryptedSharedPreferences` flag is deprecated and ignored in v10, so
///   we intentionally don't set it.
/// - **Apple:** `first_unlock_this_device` — readable after the first unlock
///   following a reboot, and never migrated to another device or iCloud backup.
///   That matches the zero-knowledge model: there is no cloud to restore from,
///   so secrets are bound to this device and recovered by re-pairing
///   (BACKEND.md §9), never silently copied off it.
const FlutterSecureStorage geneSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
  mOptions: MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);
