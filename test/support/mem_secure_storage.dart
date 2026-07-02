import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// In-memory [FlutterSecureStorage] for tests — overrides only read/write so
/// stores work without the platform Keystore channel.
class MemSecureStorage extends FlutterSecureStorage {
  MemSecureStorage([Map<String, String>? seed]) : data = {...?seed};

  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}
