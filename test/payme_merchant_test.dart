import 'dart:convert';

import 'package:test/test.dart';
import 'package:uz_payments/uz_payments.dart';

const _key = 'TEST_KEY_ONLY_FOR_UNIT_TESTS_0000000';
final _auth = {'Authorization': 'Basic ${base64.encode(utf8.encode('Paycom:$_key'))}'};
const _hour = 3600 * 1000;

void main() {
  late InMemoryPaymeBackend backend;
  late PaymeMerchantHandler payme;
  var now = 1700000000000;

  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> params,
      {Map<String, String>? headers, String? raw, String? ip}) async {
    final res = await payme.handle(MerchantRequest(
      headers: headers ?? _auth,
      body: raw ?? jsonEncode({'jsonrpc': '2.0', 'id': 42, 'method': method, 'params': params}),
      remoteAddress: ip,
    ));
    expect(res.statusCode, equals(200));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  int? code(Map<String, dynamic> r) => (r['error'] as Map<String, dynamic>?)?['code'] as int?;
  Map<String, dynamic> result(Map<String, dynamic> r) => r['result'] as Map<String, dynamic>;

  Map<String, dynamic> create(String id, {String order = '197', int amount = 50000, int? time}) => {
        'id': id,
        'time': time ?? now,
        'amount': amount,
        'account': {'order_id': order}
      };

  setUp(() {
    now = 1700000000000;
    backend = InMemoryPaymeBackend()..orders.addAll({'197': 50000, '198': 70000});
    payme = PaymeMerchantHandler(key: _key, backend: backend, clock: () => now);
  });

  group('protocol', () {
    test('missing, malformed or wrong credentials are rejected with -32504', () async {
      expect(code(await call('CheckTransaction', {'id': 'x'}, headers: {})), equals(-32504));
      expect(
          code(await call('CheckTransaction', {'id': 'x'}, headers: {'Authorization': 'Bearer abc'})), equals(-32504));
      expect(
          code(await call('CheckTransaction', {'id': 'x'}, headers: {'Authorization': 'Basic !!!'})), equals(-32504));
      final wrong = {'Authorization': 'Basic ${base64.encode(utf8.encode('Paycom:other'))}'};
      expect(code(await call('CheckTransaction', {'id': 'x'}, headers: wrong)), equals(-32504));
    });

    test('header names are case-insensitive', () async {
      final r = await call('CheckTransaction', {'id': 'x'}, headers: {'authorization': _auth['Authorization']!});
      expect(code(r), equals(-31003));
    });

    test('JSON-RPC envelope, parse errors and unknown methods', () async {
      final r = await call('Nope', {});
      expect(r['jsonrpc'], equals('2.0'));
      expect(r['id'], equals(42));
      expect(code(r), equals(-32601));
      expect(code(await call('', {}, raw: '{not json')), equals(-32700));
      expect(code(await call('', {}, raw: '[1,2]')), equals(-32600));
      expect(code(await call('', {}, raw: jsonEncode({'id': 1, 'method': 'CheckTransaction'}))), equals(-32600));
    });

    test('error messages are localized in ru, uz and en', () async {
      final err = (await call('CheckTransaction', {'id': 'x'}))['error'] as Map<String, dynamic>;
      expect((err['message'] as Map).keys.toSet(), equals({'ru', 'uz', 'en'}));
    });

    test('optional IP allowlist', () async {
      payme = PaymeMerchantHandler(key: _key, backend: backend, clock: () => now, allowedIps: paymeIps);
      expect(code(await call('CheckTransaction', {'id': 'x'}, ip: '10.0.0.5')), equals(-32504));
      expect(code(await call('CheckTransaction', {'id': 'x'}, ip: '185.234.113.7')), equals(-31003));
      expect(paymeIps.length, equals(15));
    });

    test('backend failures become -32400 without leaking details', () async {
      payme = PaymeMerchantHandler(key: _key, backend: _Broken(), clock: () => now);
      final r = await call('CheckPerformTransaction', {
        'amount': 50000,
        'account': {'order_id': '197'}
      });
      expect(code(r), equals(-32400));
      expect(jsonEncode(r).contains('database password'), isFalse);
    });
  });

  group('CheckPerformTransaction', () {
    test('allows a valid order', () async {
      final r = await call('CheckPerformTransaction', {
        'amount': 50000,
        'account': {'order_id': '197'}
      });
      expect(result(r), equals({'allow': true}));
    });

    test('wrong amount → -31001, unknown order → -31050 with field name', () async {
      expect(
          code(await call('CheckPerformTransaction', {
            'amount': 49999,
            'account': {'order_id': '197'}
          })),
          equals(-31001));
      expect(
          code(await call('CheckPerformTransaction', {
            'amount': -1,
            'account': {'order_id': '197'}
          })),
          equals(-31001));
      expect(
          code(await call('CheckPerformTransaction', {
            'amount': 1.5,
            'account': {'order_id': '197'}
          })),
          equals(-31001));
      final r = await call('CheckPerformTransaction', {
        'amount': 50000,
        'account': {'order_id': '999'}
      });
      expect(code(r), equals(-31050));
      expect((r['error'] as Map)['data'], equals('order_id'));
    });

    test('returns fiscal receipt detail when the order provides it', () async {
      payme = PaymeMerchantHandler(key: _key, backend: _WithDetail(backend), clock: () => now);
      final r = await call('CheckPerformTransaction', {
        'amount': 50000,
        'account': {'order_id': '197'}
      });
      expect((result(r)['detail'] as Map)['receipt_type'], equals(0));
    });

    test('an order with an open transaction cannot be paid again', () async {
      await call('CreateTransaction', create('t1'));
      expect(
          code(await call('CheckPerformTransaction', {
            'amount': 50000,
            'account': {'order_id': '197'}
          })),
          equals(-31008));
    });
  });

  group('CreateTransaction', () {
    test('creates, and a retry with the same id returns the same transaction', () async {
      final a = result(await call('CreateTransaction', create('t1')));
      expect(a['state'], equals(1));
      expect(a['create_time'], equals(now));
      now += 1000;
      final b = result(await call('CreateTransaction', create('t1')));
      expect(b, equals(a));
      expect(backend.transactions.length, equals(1));
    });

    test('a second transaction for the same order is rejected', () async {
      await call('CreateTransaction', create('t1'));
      final r = await call('CreateTransaction', create('t2'));
      expect(code(r), equals(-31050));
    });

    test('a different order can be paid in parallel', () async {
      await call('CreateTransaction', create('t1'));
      final r = await call('CreateTransaction', create('t2', order: '198', amount: 70000));
      expect(result(r)['state'], equals(1));
    });

    test('validates amount and account', () async {
      expect(code(await call('CreateTransaction', create('t1', amount: 1))), equals(-31001));
      expect(code(await call('CreateTransaction', create('t1', order: 'nope'))), equals(-31050));
      expect(
          code(await call('CreateTransaction', {
            'time': now,
            'amount': 50000,
            'account': {'order_id': '197'}
          })),
          equals(-32600));
    });

    test('a request whose Payme time is older than 12 hours is refused', () async {
      expect(code(await call('CreateTransaction', create('t1', time: now - 13 * _hour))), equals(-31008));
    });

    test('an expired created transaction is cancelled with reason 4', () async {
      await call('CreateTransaction', create('t1'));
      now += 12 * _hour + 1;
      expect(code(await call('CreateTransaction', create('t1'))), equals(-31008));
      final check = result(await call('CheckTransaction', {'id': 't1'}));
      expect(check['state'], equals(-1));
      expect(check['reason'], equals(4));
    });
  });

  group('PerformTransaction', () {
    test('performs once and is idempotent', () async {
      await call('CreateTransaction', create('t1'));
      now += 5000;
      final a = result(await call('PerformTransaction', {'id': 't1'}));
      expect(a['state'], equals(2));
      expect(a['perform_time'], equals(now));
      expect(backend.paid.contains('197'), isTrue);
      now += 5000;
      final b = result(await call('PerformTransaction', {'id': 't1'}));
      expect(b, equals(a));
    });

    test('unknown id → -31003, expired → -31008 and cancelled', () async {
      expect(code(await call('PerformTransaction', {'id': 'missing'})), equals(-31003));
      await call('CreateTransaction', create('t1'));
      now += 12 * _hour + 1;
      expect(code(await call('PerformTransaction', {'id': 't1'})), equals(-31008));
      expect(backend.paid.contains('197'), isFalse);
      expect(backend.transactions['t1']!.reason, equals(PaymeReason.timeout));
    });

    test('a cancelled transaction cannot be performed', () async {
      await call('CreateTransaction', create('t1'));
      await call('CancelTransaction', {'id': 't1', 'reason': 3});
      expect(code(await call('PerformTransaction', {'id': 't1'})), equals(-31008));
    });
  });

  group('CancelTransaction', () {
    test('cancel before perform → state -1, repeat returns the same', () async {
      await call('CreateTransaction', create('t1'));
      now += 1000;
      final a = result(await call('CancelTransaction', {'id': 't1', 'reason': 3}));
      expect(a['state'], equals(-1));
      expect(a['cancel_time'], equals(now));
      now += 1000;
      expect(result(await call('CancelTransaction', {'id': 't1', 'reason': 3})), equals(a));
    });

    test('cancel after perform → state -2 and the order is unpaid', () async {
      await call('CreateTransaction', create('t1'));
      await call('PerformTransaction', {'id': 't1'});
      final a = result(await call('CancelTransaction', {'id': 't1', 'reason': 5}));
      expect(a['state'], equals(-2));
      expect(backend.paid.contains('197'), isFalse);
      expect(result(await call('CheckTransaction', {'id': 't1'}))['reason'], equals(5));
    });

    test('a delivered order cannot be refunded → -31007', () async {
      await call('CreateTransaction', create('t1'));
      await call('PerformTransaction', {'id': 't1'});
      backend.delivered.add('197');
      expect(code(await call('CancelTransaction', {'id': 't1', 'reason': 5})), equals(-31007));
      expect(result(await call('CheckTransaction', {'id': 't1'}))['state'], equals(2));
    });

    test('after cancellation the order can be paid with a new transaction', () async {
      await call('CreateTransaction', create('t1'));
      await call('CancelTransaction', {'id': 't1', 'reason': 3});
      expect(result(await call('CreateTransaction', create('t2')))['state'], equals(1));
    });
  });

  group('CheckTransaction and GetStatement', () {
    test('CheckTransaction reports all times, 0 when not happened', () async {
      await call('CreateTransaction', create('t1'));
      final r = result(await call('CheckTransaction', {'id': 't1'}));
      expect(
          r,
          equals({
            'create_time': now,
            'perform_time': 0,
            'cancel_time': 0,
            'transaction': '1',
            'state': 1,
            'reason': null
          }));
    });

    test('GetStatement returns transactions in the period, sorted', () async {
      await call('CreateTransaction', create('t2', order: '198', amount: 70000, time: now + 10));
      await call('CreateTransaction', create('t1', time: now));
      final r = result(await call('GetStatement', {'from': now - 1, 'to': now + 100}));
      final list = r['transactions'] as List;
      expect(list.map((t) => (t as Map)['id']).toList(), equals(['t1', 't2']));
      expect((list.first as Map)['account'], equals({'order_id': '197'}));
      expect(code(await call('GetStatement', {'from': 10, 'to': 10})), equals(-32600));
    });
  });

  group('ChangePassword', () {
    test('rejected unless a persistence callback is configured', () async {
      expect(code(await call('ChangePassword', {'password': 'NEW_TEST_KEY'})), equals(-32400));
    });

    test('stores the new key and uses it for the next request', () async {
      String? saved;
      payme = PaymeMerchantHandler(
        key: _key,
        backend: backend,
        clock: () => now,
        onChangePassword: (k) async {
          saved = k;
          return true;
        },
      );
      expect(result(await call('ChangePassword', {'password': 'NEW_TEST_KEY'})), equals({'success': true}));
      expect(saved, equals('NEW_TEST_KEY'));
      expect(code(await call('CheckTransaction', {'id': 'x'})), equals(-32504));
      final fresh = {'Authorization': 'Basic ${base64.encode(utf8.encode('Paycom:NEW_TEST_KEY'))}'};
      expect(code(await call('CheckTransaction', {'id': 'x'}, headers: fresh)), equals(-31003));
    });

    test('the same key as the current one is refused', () async {
      payme = PaymeMerchantHandler(key: _key, backend: backend, onChangePassword: (_) async => true);
      expect(code(await call('ChangePassword', {'password': _key})), equals(-32504));
    });
  });
}

class _Broken extends InMemoryPaymeBackend {
  @override
  Future<PaymeOrder?> findOrder(Map<String, dynamic> account) async => throw StateError('database password is hunter2');
}

class _WithDetail extends InMemoryPaymeBackend {
  _WithDetail(InMemoryPaymeBackend base) {
    orders.addAll(base.orders);
  }

  @override
  Future<PaymeOrder?> findOrder(Map<String, dynamic> account) async {
    final o = await super.findOrder(account);
    if (o == null) return null;
    return PaymeOrder(id: o.id, amountTiyin: o.amountTiyin, detail: const {
      'receipt_type': 0,
      'items': [
        {
          'title': 'Book',
          'price': 50000,
          'count': 1,
          'code': '00702001001000001',
          'package_code': '123456',
          'vat_percent': 12
        },
      ],
    });
  }
}
