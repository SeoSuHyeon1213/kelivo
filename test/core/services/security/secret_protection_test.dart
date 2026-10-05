import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/services/security/secret_protection.dart';

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('locked');
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<List<String>> keys() async => values.keys.toList();
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'rotating string keys and environment values never stay plaintext',
    () async {
      final protection = SecretProtection(MemorySecretStore());
      for (final (key, value) in [
        (
          'search_services_v1',
          jsonEncode([
            {
              'apiKeys': ['ROTATED_SECRET'],
            },
          ]),
        ),
        (
          'environment_variables_v1',
          jsonEncode([
            {'name': 'TOKEN', 'value': 'VARIABLE_SECRET', 'note': ''},
          ]),
        ),
      ]) {
        final persisted = await protection.preference(key, value);
        expect(persisted.toString(), isNot(contains('_SECRET')));
        expect(
          await protection.preference(key, persisted, hydrate: true),
          value,
        );
        expect(
          SecretProtection.redactPreference(key, value).toString(),
          isNot(contains('_SECRET')),
        );
      }
    },
  );
  test('secrets are references at rest and remain usable in memory', () async {
    final store = MemorySecretStore();
    final protection = SecretProtection(store);
    final original = {
      'name': 'Provider',
      'apiKey': 'API_SECRET',
      'apiKeys': [
        {'key': 'MULTI_SECRET'},
      ],
      'oauthCredentials': {
        'accessToken': 'ACCESS_SECRET',
        'refreshToken': 'REFRESH_SECRET',
      },
      'proxyPassword': 'PROXY_SECRET',
      'customHeaders': [
        {'name': 'Authorization', 'value': 'HEADER_SECRET'},
      ],
    };
    final source = BusinessSnapshot(
      entities: {
        BusinessEntityKind.provider: [
          BusinessEntityValue(
            id: 'p',
            sortOrder: 0,
            payload: jsonEncode(original),
          ),
        ],
      },
      preferences: {
        'global_proxy_password_v1': 'GLOBAL_SECRET',
        'webdav_config_v1': jsonEncode({
          'password': 'WEBDAV_SECRET',
          'url': 'https://example.com',
        }),
      },
    );
    final persisted = await protection.snapshot(source);
    expect(
      persisted.entities[BusinessEntityKind.provider]!.single.payload,
      isNot(contains('_SECRET')),
    );
    expect(persisted.preferences.toString(), isNot(contains('_SECRET')));
    final hydrated = await protection.snapshot(persisted, hydrate: true);
    expect(
      jsonDecode(
        hydrated.entities[BusinessEntityKind.provider]!.single.payload,
      ),
      original,
    );
    expect(hydrated.preferences, source.preferences);
    expect(
      SecretProtection.redact(
        jsonDecode(
          persisted.entities[BusinessEntityKind.provider]!.single.payload,
        ),
      ).toString(),
      isNot(contains(SecretProtection.referencePrefix)),
    );
    expect(
      SecretProtection.redact(original).toString(),
      isNot(contains('_SECRET')),
    );
  });
  test('storage failure never returns a plaintext fallback', () async {
    final store = MemorySecretStore()..failWrites = true;
    await expectLater(
      SecretProtection(store).preference('global_proxy_password_v1', 'secret'),
      throwsStateError,
    );
  });
  test('missing referenced secret fails closed', () async {
    await expectLater(
      SecretProtection(MemorySecretStore()).preference(
        'global_proxy_password_v1',
        '${SecretProtection.referencePrefix}missing',
        hydrate: true,
      ),
      throwsStateError,
    );
  });
  test(
    'garbage collection preserves committed references and other apps',
    () async {
      final store = MemorySecretStore()..values['unrelated'] = 'other';
      final protection = SecretProtection(store);
      final kept = await protection.preference(
        'global_proxy_password_v1',
        'keep',
      );
      final orphan = await protection.preference(
        'global_proxy_password_v1',
        'orphan',
      );
      await protection.collectGarbage(
        BusinessSnapshot(
          entities: {},
          preferences: {'global_proxy_password_v1': kept},
        ),
      );
      expect(store.values[kept], 'keep');
      expect(store.values.containsKey(orphan), isFalse);
      expect(store.values['unrelated'], 'other');
    },
  );
}
