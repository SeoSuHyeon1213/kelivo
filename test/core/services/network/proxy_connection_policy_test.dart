import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/network/proxy_connection_policy.dart';
import 'package:Kelivo/core/services/network/dio_http_client.dart';

void main() {
  test('failed DNS and empty results fail closed', () async {
    await expectLater(
      resolveRequiredProxyAddress(
        'proxy.invalid',
        lookup: (_) async => throw const SocketException('DNS failed'),
      ),
      throwsA(isA<ProxyConnectionException>()),
    );
    await expectLater(
      resolveRequiredProxyAddress('proxy.invalid', lookup: (_) async => []),
      throwsA(isA<ProxyConnectionException>()),
    );
  });

  test('literal address does not use DNS', () async {
    var called = false;
    final address = await resolveRequiredProxyAddress(
      '127.0.0.1',
      lookup: (_) async {
        called = true;
        return [];
      },
    );
    expect(address.address, '127.0.0.1');
    expect(called, isFalse);
  });

  test('invalid provider proxy cannot reach the destination', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    destination.listen((request) async {
      hits++;
      await request.response.close();
    });
    final client = DioHttpClient(
      proxy: const NetworkProxyConfig(enabled: true, host: '', port: 0),
      logRequests: false,
    );
    try {
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${destination.port}/')),
        throwsA(isA<Exception>()),
      );
      expect(hits, 0);
    } finally {
      client.close();
      await destination.close(force: true);
    }
  });

  test('invalid global proxy cannot reach the destination', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    destination.listen((request) async {
      hits++;
      await request.response.close();
    });
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          await expectLater(
            client.getUrl(Uri.parse('http://127.0.0.1:${destination.port}/')),
            throwsA(isA<ProxyConnectionException>()),
          );
        } finally {
          client.close(force: true);
        }
      }, BlockingProxyHttpOverrides());
      expect(hits, 0);
    } finally {
      await destination.close(force: true);
    }
  });
}
