// A complete payment server with dart:io and no extra packages.
//
//   PAYME_KEY=... CLICK_SECRET=... dart run example/example.dart
//
// Point the Payme cabinet "endpoint URL" at  https://your.host/payme
// and both Click URLs (Prepare and Complete) at https://your.host/click.
import 'dart:convert';
import 'dart:io';

import 'package:uz_payments/uz_payments.dart';

Future<void> main() async {
  final env = Platform.environment;

  // Replace the in-memory backends with your database implementation.
  final paymeBackend = InMemoryPaymeBackend()..orders['197'] = 50000; // 500 so'm
  final clickBackend = InMemoryClickBackend()..orders['197'] = 50000;

  final payme = PaymeMerchantHandler(
    key: env['PAYME_KEY'] ?? 'sandbox-key',
    backend: paymeBackend,
    // Reject anything that is not Payme. Set LOCAL=1 to test with curl.
    allowedIps: env['LOCAL'] == '1' ? null : paymeIps,
  );
  final click = ClickMerchantHandler(
    serviceId: int.parse(env['CLICK_SERVICE_ID'] ?? '36'),
    secretKey: env['CLICK_SECRET'] ?? 'sandbox-secret',
    backend: clickBackend,
  );

  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  stdout.writeln('Listening on http://localhost:${server.port}');

  await for (final req in server) {
    final handler = switch (req.uri.path) {
      '/payme' => payme.handle,
      '/click' => click.handle,
      _ => null,
    };
    if (handler == null || req.method != 'POST') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      continue;
    }

    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.join(','));

    final res = await handler(MerchantRequest(
      headers: headers,
      body: await utf8.decodeStream(req),
      // Behind a reverse proxy use the client IP it forwards instead.
      remoteAddress: req.connectionInfo?.remoteAddress.address,
    ));

    req.response.statusCode = res.statusCode;
    res.headers.forEach(req.response.headers.set);
    req.response.write(res.body);
    await req.response.close();
  }
}
