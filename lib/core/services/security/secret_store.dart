import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_protection.dart';

/// Production storage. Errors propagate; plaintext is never a fallback.
final class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    ),
  }) : _storage = storage;
  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<List<String>> keys() async => (await _storage.readAll()).keys.toList();
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
