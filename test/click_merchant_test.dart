import 'dart:convert';

import 'package:test/test.dart';
import 'package:uz_payments/uz_payments.dart';

const _secret = 'S3cr3tK3y';

void main() {
  late InMemoryClickBackend backend;
  late ClickMerchantHandler click;

  Map<String, String> fields({
    int action = 0,
    String amount = '1000.00',
    String order = 'order-197',
    String? prepareId,
    String error = '0',
    String service = '36',
    String signTime = '2026-11-02 10:00:00',
    String? sign,
  }) {
    final f = {
      'click_trans_id': '123456789',
      'service_id': service,
      'click_paydoc_id': '555',
      'merchant_trans_id': order,
      if (action == 1) 'merchant_prepare_id': prepareId ?? '1',
      'amount': amount,
      'action': '$action',
      'error': error,
      'error_note': error == '0' ? 'Success' : 'Failed',
      'sign_time': signTime,
    };
    f['sign_string'] = sign ??
        md5Hex([
          f['click_trans_id'],
          f['service_id'],
          _secret,
          f['merchant_trans_id'],
          if (action == 1) f['merchant_prepare_id'],
          f['amount'],
          f['action'],
          f['sign_time']
        ].join());
    return f;
  }

  Future<Map<String, dynamic>> send(Map<String, String> f, {bool json = false}) async {
    final body = json ? jsonEncode(f) : Uri(queryParameters: f).query;
    final res = await click.handle(MerchantRequest(headers: const {}, body: body));
    expect(res.headers['content-type'], startsWith('application/json'));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  setUp(() {
    backend = InMemoryClickBackend()..orders['order-197'] = 100000;
    click = ClickMerchantHandler(serviceId: 36, secretKey: _secret, backend: backend);
  });

  test('sign_string matches the documented formula (cross-checked with Python hashlib)', () {
    expect(fields()['sign_string'], equals('e509100b2fb9a2e5d1cd5a285987075f'));
    expect(
        fields(action: 1, signTime: '2026-11-02 10:01:00')['sign_string'], equals('8f2b568dd21262b8f6fd74258c45ead2'));
  });

  test('Prepare succeeds and returns the prepare id', () async {
    final r = await send(fields());
    expect(
        r,
        equals({
          'click_trans_id': 123456789,
          'merchant_trans_id': 'order-197',
          'merchant_prepare_id': 1,
          'error': 0,
          'error_note': 'Success',
        }));
  });

  test('a repeated Prepare returns the same prepare id', () async {
    final a = await send(fields());
    final b = await send(fields());
    expect(b['merchant_prepare_id'], equals(a['merchant_prepare_id']));
    expect(backend.prepares.length, equals(1));
  });

  test('accepts JSON bodies and an upper-case signature', () async {
    final f = fields();
    f['sign_string'] = f['sign_string']!.toUpperCase();
    expect((await send(f, json: true))['error'], equals(0));
  });

  test('bad signature → -1 and nothing is recorded', () async {
    final r = await send(fields(sign: '0' * 32));
    expect(r['error'], equals(-1));
    expect(backend.prepares, isEmpty);
  });

  test('a tampered amount breaks the signature', () async {
    final f = fields();
    f['amount'] = '1.00';
    expect((await send(f))['error'], equals(-1));
  });

  test('missing fields or a different service id → -8', () async {
    final f = fields()..remove('click_paydoc_id');
    expect((await send(f))['error'], equals(-8));
    expect((await send(fields(service: '99')))['error'], equals(-8));
    expect((await send(fields(action: 1)..remove('merchant_prepare_id')))['error'], equals(-8));
    final res = await click.handle(MerchantRequest(headers: const {}, body: '%%%'));
    expect((jsonDecode(res.body) as Map)['error'], equals(-8));
  });

  test('unknown action → -3', () async {
    expect((await send(fields(action: 2)))['error'], equals(-3));
  });

  test('unknown order → -5, wrong amount → -2 (exact, no float rounding)', () async {
    expect((await send(fields(order: 'nope')))['error'], equals(-5));
    expect((await send(fields(amount: '999.99')))['error'], equals(-2));
    expect((await send(fields(amount: '1000')))['error'], equals(0));
  });

  test('Complete marks the order paid; a repeat → -4', () async {
    final p = await send(fields());
    final r = await send(fields(action: 1, prepareId: '${p['merchant_prepare_id']}', signTime: '2026-11-02 10:01:00'));
    expect(r['error'], equals(0));
    expect(r['merchant_confirm_id'], equals(1));
    expect(r.containsKey('merchant_prepare_id'), isFalse);
    expect(backend.status['order-197'], equals(ClickOrderStatus.paid));
    final again = await send(fields(action: 1, prepareId: '${p['merchant_prepare_id']}'));
    expect(again['error'], equals(-4));
    expect((await send(fields()))['error'], equals(-4));
  });

  test('Complete with an unknown prepare id → -6', () async {
    await send(fields());
    expect((await send(fields(action: 1, prepareId: '77')))['error'], equals(-6));
  });

  test('Complete with error < 0 from Click cancels the order → -9', () async {
    final p = await send(fields());
    final r = await send(fields(action: 1, prepareId: '${p['merchant_prepare_id']}', error: '-5017'));
    expect(r['error'], equals(-9));
    expect(backend.status['order-197'], equals(ClickOrderStatus.cancelled));
    expect((await send(fields(action: 1, prepareId: '${p['merchant_prepare_id']}')))['error'], equals(-9));
  });

  test('an unsigned cancel is ignored', () async {
    final p = await send(fields());
    final r = await send(fields(action: 1, prepareId: '${p['merchant_prepare_id']}', error: '-1', sign: 'x' * 32));
    expect(r['error'], equals(-1));
    expect(backend.status['order-197'], isNull);
  });

  test('backend failure → -7', () async {
    click = ClickMerchantHandler(serviceId: 36, secretKey: _secret, backend: _Broken());
    expect((await send(fields()))['error'], equals(-7));
  });
}

class _Broken extends InMemoryClickBackend {
  @override
  Future<ClickOrder?> findOrder(String merchantTransId) async => throw StateError('db down');
}
