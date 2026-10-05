import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/backup_portability.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_settings_router.dart';
import 'package:Kelivo/core/services/security/secret_protection.dart';

class _Store implements SecretStore {
  final values = <String, String>{};
  bool locked = false;
  @override
  Future<void> write(String key, String value) async {
    if (locked) throw StateError('locked');
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
    'database uses references, failed saves preserve committed credentials, backups omit secrets',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = BusinessRepository(database);
      final store = _Store();
      await repository.replaceSnapshot(
        BusinessSettingsRouter.normalizeAndRoute({
          'provider_configs_v1': jsonEncode({
            'provider': {'name': 'Provider', 'apiKey': 'OLD_SECRET'},
          }),
          'global_proxy_password_v1': 'PROXY_SECRET',
        }),
      );
      final preferences = BusinessPreferences(
        repository,
        secrets: SecretProtection(store),
      );
      await preferences.load();
      final before = await repository.readSnapshot();
      expect(
        before.entities[BusinessEntityKind.provider]!.single.payload,
        isNot(contains('OLD_SECRET')),
      );
      expect(
        before.preferences['global_proxy_password_v1'],
        startsWith(SecretProtection.referencePrefix),
      );
      expect(
        jsonDecode(
          preferences.getString('provider_configs_v1')!,
        )['provider']['apiKey'],
        'OLD_SECRET',
      );
      final reloaded = BusinessPreferences(
        repository,
        secrets: SecretProtection(store),
      );
      await reloaded.load();
      expect(
        jsonDecode(
          reloaded.getString('provider_configs_v1')!,
        )['provider']['apiKey'],
        'OLD_SECRET',
      );
      store.locked = true;
      await expectLater(
        preferences.setString(
          'provider_configs_v1',
          jsonEncode({
            'provider': {'name': 'Provider', 'apiKey': 'NEW_SECRET'},
          }),
        ),
        throwsStateError,
      );
      final after = await repository.readSnapshot();
      expect(
        after.entities[BusinessEntityKind.provider]!.single.payload,
        before.entities[BusinessEntityKind.provider]!.single.payload,
      );
      expect(
        jsonDecode(
          preferences.getString('provider_configs_v1')!,
        )['provider']['apiKey'],
        'OLD_SECRET',
      );
      final backup = BackupPortability.portable(after);
      expect(
        backup.entities[BusinessEntityKind.provider]!.single.payload,
        isNot(contains(SecretProtection.referencePrefix)),
      );
      expect(backup.preferences['global_proxy_password_v1'], '');
    },
  );
}
