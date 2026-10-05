import 'dart:io';

class ProxyConnectionException implements IOException {
  const ProxyConnectionException(this.message);
  final String message;
  @override
  String toString() => 'ProxyConnectionException: $message';
}

/// Resolution failure must never silently change a request to a direct route.
Future<InternetAddress> resolveRequiredProxyAddress(
  String host, {
  Future<List<InternetAddress>> Function(String host)? lookup,
}) async {
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) return parsed;
  try {
    final addresses = await (lookup ?? InternetAddress.lookup)(host);
    if (addresses.isNotEmpty) return addresses.first;
  } catch (_) {
    throw const ProxyConnectionException(
      'Proxy address lookup failed; direct connection is blocked',
    );
  }
  throw const ProxyConnectionException(
    'Proxy address lookup returned no addresses; direct connection is blocked',
  );
}

class BlockingProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      throw const ProxyConnectionException(
        'Invalid proxy configuration; direct connection is blocked',
      );
    };
    return client;
  }
}
