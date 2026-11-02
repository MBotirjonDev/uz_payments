import 'dart:convert';

import 'package:test/test.dart';
import 'package:uz_payments/uz_payments.dart';

void main() {
  group('md5', () {
    test('RFC 1321 test suite', () {
      const vectors = {
        '': 'd41d8cd98f00b204e9800998ecf8427e',
        'a': '0cc175b9c0f1b6a831c399e269772661',
        'abc': '900150983cd24fb0d6963f7d28e17f72',
        'message digest': 'f96b697d7cb7938d525a2f31aaf161d0',
        'abcdefghijklmnopqrstuvwxyz': 'c3fcd3d76192e4007dfb496cca67e13b',
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789': 'd174ab98d277d9f5a5611c2c9f419d9f',
        '12345678901234567890123456789012345678901234567890123456789012345678901234567890':
            '57edf4a22be3c955ac49da2e2107b67a',
      };
      vectors.forEach((input, hex) => expect(md5Hex(input), equals(hex), reason: input));
    });

    test('UTF-8 and multi-block input match Python hashlib', () {
      expect(md5Hex('oʻzbek soʻm'), equals('738c36fa3bfb2b150076fc50f9d1053a'));
      expect(md5Hex('a' * 1000), equals('cabe45dcc9ae5b66ba86600cca6b8ba8'));
    });

    test('constant-time comparison', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('money', () {
    test('formatSom', () {
      expect(formatSom(150000), equals('1500.00'));
      expect(formatSom(5), equals('0.05'));
      expect(formatSom(0), equals('0.00'));
      expect(() => formatSom(-1), throwsArgumentError);
    });

    test('parseSomToTiyin is exact and strict', () {
      expect(parseSomToTiyin('1000'), equals(100000));
      expect(parseSomToTiyin('1000.0'), equals(100000));
      expect(parseSomToTiyin('1000.5'), equals(100050));
      expect(parseSomToTiyin('1000.50'), equals(100050));
      expect(parseSomToTiyin('1000.500'), equals(100050));
      expect(parseSomToTiyin('0.01'), equals(1));
      expect(parseSomToTiyin('1000.505'), isNull);
      expect(parseSomToTiyin('-5'), isNull);
      expect(parseSomToTiyin('1e3'), isNull);
      expect(parseSomToTiyin('abc'), isNull);
      expect(parseSomToTiyin(''), isNull);
    });
  });

  group('PaymeCheckout', () {
    test('matches the example in the Payme documentation', () {
      final url =
          PaymeCheckout(merchantId: '587f72c72cac0d162c722ae2').url(account: {'order_id': '197'}, amountTiyin: 500);
      expect(url.toString(),
          equals('https://checkout.paycom.uz/bT01ODdmNzJjNzJjYWMwZDE2MmM3MjJhZTI7YWMub3JkZXJfaWQ9MTk3O2E9NTAw'));
    });

    test('optional parameters and sandbox host', () {
      final url = PaymeCheckout(merchantId: 'm1', test: true).url(
        account: {'order_id': '7'},
        amountTiyin: 150000,
        lang: 'uz',
        returnUrl: 'https://shop.example/paid',
        returnDelay: const Duration(seconds: 15),
      );
      expect(url.toString(), startsWith('https://test.paycom.uz/'));
      final plain = utf8.decode(base64.decode(url.pathSegments.single));
      expect(plain, equals('m=m1;ac.order_id=7;a=150000;l=uz;c=https://shop.example/paid;ct=15000'));
    });

    test('rejects values that could inject parameters', () {
      final p = PaymeCheckout(merchantId: 'm1');
      expect(() => p.url(account: {'order_id': '7;a=1'}, amountTiyin: 500), throwsArgumentError);
      expect(() => p.url(account: {'order_id': '7'}, amountTiyin: 0), throwsArgumentError);
      expect(() => p.url(account: {}, amountTiyin: 500), throwsArgumentError);
      expect(() => p.url(account: {'order_id': '7'}, amountTiyin: 500, lang: 'de'), throwsArgumentError);
      expect(() => PaymeCheckout(merchantId: ''), throwsArgumentError);
    });
  });

  group('ClickCheckout', () {
    test('builds the documented payment link', () {
      final url = ClickCheckout(serviceId: 36, merchantId: 46).url(
        transactionParam: 'user23151',
        amountTiyin: 100000,
        returnUrl: 'https://shop.example/paid?x=1',
        cardType: 'uzcard',
      );
      expect(url.host, equals('my.click.uz'));
      expect(url.path, equals('/services/pay'));
      expect(
          url.queryParameters,
          equals({
            'service_id': '36',
            'merchant_id': '46',
            'amount': '1000.00',
            'transaction_param': 'user23151',
            'return_url': 'https://shop.example/paid?x=1',
            'card_type': 'uzcard',
          }));
    });

    test('validates input', () {
      final c = ClickCheckout(serviceId: 36, merchantId: 46);
      expect(() => c.url(transactionParam: '', amountTiyin: 100), throwsArgumentError);
      expect(() => c.url(transactionParam: 'a', amountTiyin: -1), throwsArgumentError);
      expect(() => c.url(transactionParam: 'a', amountTiyin: 100, cardType: 'visa'), throwsArgumentError);
      expect(() => ClickCheckout(serviceId: 0, merchantId: 46), throwsArgumentError);
    });
  });
}
