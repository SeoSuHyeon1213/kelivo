import 'dart:convert';
import 'dart:math';

import '../../database/business_data.dart';

abstract interface class SecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<List<String>> keys();
  Future<void> delete(String key);
}

/// Persisted secrets are opaque, device-local references. Runtime values stay
/// hydrated; exports discard both secrets and references.
final class SecretProtection {
  SecretProtection(this.store);
  final SecretStore store;
  static const referencePrefix = 'kelivo-secret:v1:';
  static final _random = Random.secure();

  static bool _sensitive(String key, String parent) {
    final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    return const {
          'apikey',
          'accesstoken',
          'refreshtoken',
          'password',
          'proxypassword',
          'secretaccesskey',
          'sessiontoken',
          'clientsecret',
          'token',
          'authorization',
          'subscriptionkey',
          'secretkey',
          'globalproxypasswordv',
        }.contains(normalized) ||
        (key == 'key' && parent == 'apiKeys') ||
        (key == 'value' && parent == 'environment_variables_v1') ||
        const {
          'headers',
          'customHeaders',
          'customBody',
          'env',
          'environment',
        }.contains(parent);
  }

  Future<Object?> _map(
    Object? value, {
    required bool hydrate,
    String parent = '',
    bool sensitive = false,
  }) async {
    if (value is String) {
      final secretValue = sensitive || parent == 'apiKeys';
      if (secretValue && value.startsWith(referencePrefix)) {
        if (!hydrate) return value;
        final secret = await store.read(value);
        if (secret == null) throw StateError('secure_storage_secret_missing');
        return secret;
      }
      if (!hydrate && secretValue && value.isNotEmpty) {
        final id =
            '$referencePrefix${base64Url.encode(List<int>.generate(24, (_) => _random.nextInt(256)))}';
        await store.write(id, value);
        // Verify before replacing the database value.
        if (await store.read(id) != value)
          throw StateError('secure_storage_write_verification_failed');
        return id;
      }
      return value;
    }
    if (value is List) {
      return [
        for (final item in value)
          await _map(
            item,
            hydrate: hydrate,
            parent: parent,
            sensitive: sensitive,
          ),
      ];
    }
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): await _map(
            entry.value,
            hydrate: hydrate,
            parent: entry.key.toString(),
            sensitive: sensitive || _sensitive(entry.key.toString(), parent),
          ),
      };
    }
    return value;
  }

  Future<Object> preference(
    String key,
    Object value, {
    bool hydrate = false,
  }) async {
    if (value is String) {
      Object? json;
      try {
        json = jsonDecode(value);
      } on FormatException {
        /* plain string */
      }
      if (json is Map || json is List) {
        return jsonEncode(await _map(json, hydrate: hydrate, parent: key));
      }
    }
    return (await _map(
      value,
      hydrate: hydrate,
      sensitive: _sensitive(key, ''),
    ))!;
  }

  Future<List<BusinessEntityValue>> entities(
    List<BusinessEntityValue> rows, {
    bool hydrate = false,
  }) async => [
    for (final row in rows)
      row.copyWith(
        payload: jsonEncode(
          await _map(jsonDecode(row.payload), hydrate: hydrate),
        ),
      ),
  ];

  Future<BusinessSnapshot> snapshot(
    BusinessSnapshot source, {
    bool hydrate = false,
  }) async => BusinessSnapshot(
    entities: {
      for (final entry in source.entities.entries)
        entry.key: await entities(entry.value, hydrate: hydrate),
    },
    preferences: {
      for (final entry in source.preferences.entries)
        entry.key: await preference(entry.key, entry.value, hydrate: hydrate),
    },
  );

  static Object? redact(
    Object? value, {
    String parent = '',
    bool sensitive = false,
  }) {
    if (value is String)
      return sensitive ||
              parent == 'apiKeys' ||
              value.startsWith(referencePrefix)
          ? ''
          : value;
    if (value is List)
      return [
        for (final item in value)
          redact(item, parent: parent, sensitive: sensitive),
      ];
    if (value is Map)
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): redact(
            entry.value,
            parent: entry.key.toString(),
            sensitive: sensitive || _sensitive(entry.key.toString(), parent),
          ),
      };
    return value;
  }

  static Object redactPreference(String key, Object value) {
    if (value is String) {
      try {
        final json = jsonDecode(value);
        if (json is Map || json is List)
          return jsonEncode(redact(json, parent: key));
      } on FormatException {
        /* plain string */
      }
    }
    return redact(value, sensitive: _sensitive(key, ''))!;
  }

  Future<void> collectGarbage(BusinessSnapshot persisted) async {
    final retained = <String>{};
    void visit(Object? value) {
      if (value is String) {
        if (value.startsWith(referencePrefix)) {
          retained.add(value);
          return;
        }
        try {
          visit(jsonDecode(value));
        } on FormatException {
          /* plain value */
        }
      } else if (value is List) {
        for (final item in value) {
          visit(item);
        }
      } else if (value is Map) {
        for (final item in value.values) {
          visit(item);
        }
      }
    }

    for (final rows in persisted.entities.values) {
      for (final row in rows) {
        visit(row.payload);
      }
    }
    visit(persisted.preferences);
    for (final key in await store.keys()) {
      if (key.startsWith(referencePrefix) && !retained.contains(key))
        await store.delete(key);
    }
  }
}
