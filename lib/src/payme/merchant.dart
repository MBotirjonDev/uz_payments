import 'dart:convert';

import '../http.dart';
import '../md5.dart' show constantTimeEquals;
import 'models.dart';

/// IP addresses Payme Business sends Merchant API requests from
/// (185.234.113.1 – 185.234.113.15, per the Payme developer documentation).
final Set<String> paymeIps = {for (var i = 1; i <= 15; i++) '185.234.113.$i'};

/// Server-side handler for the Payme **Merchant API** (JSON-RPC 2.0).
///
/// It implements the full transaction state machine from the official Payme
/// integration template: authorization, amount and account checks, idempotent
/// retries, the 12-hour timeout, cancellation before and after perform, and
/// `GetStatement`. Your [PaymeBackend] only stores data.
///
/// ```dart
/// final payme = PaymeMerchantHandler(key: env['PAYME_KEY']!, backend: MyBackend());
/// // in your route:
/// final res = await payme.handle(MerchantRequest(headers: headers, body: body));
/// ```
class PaymeMerchantHandler {
  PaymeMerchantHandler({
    required String key,
    required this.backend,
    this.login = 'Paycom',
    this.timeout = const Duration(hours: 12),
    this.accountField = 'order_id',
    this.allowedIps,
    this.onChangePassword,
    int Function()? clock,
  })  : _key = key,
        _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (key.isEmpty) throw ArgumentError.value(key, 'key', 'must not be empty');
  }

  final PaymeBackend backend;

  /// Basic-auth login. Payme always uses `Paycom`.
  final String login;

  /// A created transaction that is not performed within this time is cancelled
  /// with reason 4. Payme specifies 12 hours (43 200 000 ms).
  final Duration timeout;

  /// The `account` field that identifies the order, used in error `data`.
  final String accountField;

  /// If set, requests from other IPs are rejected with -32504. Use [paymeIps],
  /// and make sure [MerchantRequest.remoteAddress] is the real client IP (not
  /// your proxy's).
  final Set<String>? allowedIps;

  /// Persists a new cashbox key sent by Payme's `ChangePassword`. Return `true`
  /// once it is stored. If `null`, `ChangePassword` is rejected.
  final Future<bool> Function(String newKey)? onChangePassword;

  String _key;
  final int Function() _now;

  /// Handles one HTTP request from Payme and returns the response to send.
  Future<MerchantResponse> handle(MerchantRequest request) async {
    Object? id;
    try {
      if (allowedIps != null && !allowedIps!.contains(request.remoteAddress)) {
        throw _error(PaymeErrorCode.insufficientPrivilege, 'Insufficient privilege to perform this method.');
      }
      final Object? payload;
      try {
        payload = jsonDecode(request.body);
      } on FormatException {
        throw _error(PaymeErrorCode.parseError, 'Parse error.');
      }
      if (payload is! Map<String, dynamic>) throw _error(PaymeErrorCode.invalidRequest, 'Invalid JSON-RPC object.');
      id = payload['id'];
      if (!_authorized(request.headers['authorization'])) {
        throw _error(PaymeErrorCode.insufficientPrivilege, 'Insufficient privilege to perform this method.');
      }
      final method = payload['method'];
      final params = payload['params'];
      if (method is! String || params is! Map<String, dynamic>) {
        throw _error(PaymeErrorCode.invalidRequest, 'Invalid JSON-RPC object.');
      }
      final result = await _dispatch(method, params);
      return MerchantResponse.json({'jsonrpc': '2.0', 'id': id, 'result': result});
    } on PaymeError catch (e) {
      return MerchantResponse.json({'jsonrpc': '2.0', 'id': id, 'error': e.toJson()});
    } catch (_) {
      // Never leak internals (stack traces, SQL) to the caller.
      final e = _error(PaymeErrorCode.internal, 'Internal system error.');
      return MerchantResponse.json({'jsonrpc': '2.0', 'id': id, 'error': e.toJson()});
    }
  }

  bool _authorized(String? header) {
    if (header == null) return false;
    final m = RegExp(r'^\s*Basic\s+(\S+)\s*$', caseSensitive: false).firstMatch(header);
    if (m == null) return false;
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(m.group(1)!));
    } on FormatException {
      return false;
    }
    return constantTimeEquals(decoded, '$login:$_key');
  }

  Future<Map<String, dynamic>> _dispatch(String method, Map<String, dynamic> p) {
    switch (method) {
      case 'CheckPerformTransaction':
        return _checkPerform(p);
      case 'CreateTransaction':
        return _create(p);
      case 'PerformTransaction':
        return _perform(p);
      case 'CancelTransaction':
        return _cancel(p);
      case 'CheckTransaction':
        return _check(p);
      case 'GetStatement':
        return _statement(p);
      case 'ChangePassword':
        return _changePassword(p);
      default:
        throw _error(PaymeErrorCode.methodNotFound, 'Method not found.', data: method);
    }
  }

  // ── methods ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _checkPerform(Map<String, dynamic> p) async {
    final amount = _amount(p);
    final order = await _payableOrder(_account(p), amount);
    if (await backend.findOpenTransactionForOrder(order.id) != null) {
      throw _error(PaymeErrorCode.cannotPerform, 'There is another active or completed transaction for this order.');
    }
    return {'allow': true, if (order.detail != null) 'detail': order.detail};
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> p) async {
    final paymeId = _string(p, 'id');
    final time = _int(p, 'time');
    final amount = _amount(p);
    final account = _account(p);
    final now = _now();

    final existing = await backend.findTransaction(paymeId);
    if (existing != null) {
      if (!existing.isActive) throw _error(PaymeErrorCode.cannotPerform, 'Transaction found, but is not active.');
      if (_expired(existing, now)) {
        await _cancelTx(existing, PaymeReason.timeout, now);
        throw _error(PaymeErrorCode.cannotPerform, 'Transaction is expired.');
      }
      return _createResult(existing);
    }

    final order = await _payableOrder(account, amount);
    final open = await backend.findOpenTransactionForOrder(order.id);
    if (open != null && open.paymeId != paymeId) {
      throw PaymeError(
          PaymeErrorCode.invalidAccount,
          const {
            'ru': 'Для этого заказа уже есть активная или проведённая транзакция.',
            'uz': 'Bu buyurtma uchun faol yoki bajarilgan tranzaksiya mavjud.',
            'en': 'There is another active or completed transaction for this order.',
          },
          data: accountField);
    }
    if (now - time > timeout.inMilliseconds) {
      throw _error(PaymeErrorCode.cannotPerform, 'Transaction time is older than the timeout.');
    }
    final tx = await backend.insertTransaction(PaymeTransaction(
      paymeId: paymeId,
      paymeTime: time,
      amountTiyin: amount,
      account: account,
      orderId: order.id,
      createTime: now,
    ));
    return _createResult(tx);
  }

  Future<Map<String, dynamic>> _perform(Map<String, dynamic> p) async {
    final tx = await _found(_string(p, 'id'));
    final now = _now();
    switch (tx.state) {
      case PaymeState.created:
        if (_expired(tx, now)) {
          await _cancelTx(tx, PaymeReason.timeout, now);
          throw _error(PaymeErrorCode.cannotPerform, 'Transaction is expired.');
        }
        final next = tx.copy()
          ..state = PaymeState.performed
          ..performTime = now;
        await backend.perform(next);
        return {'transaction': next.merchantId, 'perform_time': next.performTime, 'state': next.state};
      case PaymeState.performed:
        return {'transaction': tx.merchantId, 'perform_time': tx.performTime, 'state': tx.state};
      default:
        throw _error(PaymeErrorCode.cannotPerform, 'Could not perform this operation.');
    }
  }

  Future<Map<String, dynamic>> _cancel(Map<String, dynamic> p) async {
    final tx = await _found(_string(p, 'id'));
    final reason = _int(p, 'reason');
    final now = _now();
    switch (tx.state) {
      case PaymeState.cancelled:
      case PaymeState.cancelledAfterPerform:
        break;
      case PaymeState.created:
        await _cancelTx(tx, reason, now);
      case PaymeState.performed:
        if (!await backend.canCancelPerformed(tx)) {
          throw _error(PaymeErrorCode.cannotCancel, 'Could not cancel transaction. The order is already delivered.');
        }
        await _cancelTx(tx, reason, now);
    }
    final fresh = await _found(tx.paymeId);
    return {'transaction': fresh.merchantId, 'cancel_time': fresh.cancelTime, 'state': fresh.state};
  }

  Future<Map<String, dynamic>> _check(Map<String, dynamic> p) async {
    final tx = await _found(_string(p, 'id'));
    return {
      'create_time': tx.createTime,
      'perform_time': tx.performTime,
      'cancel_time': tx.cancelTime,
      'transaction': tx.merchantId,
      'state': tx.state,
      'reason': tx.reason,
    };
  }

  Future<Map<String, dynamic>> _statement(Map<String, dynamic> p) async {
    final from = _int(p, 'from');
    final to = _int(p, 'to');
    if (from >= to) throw _error(PaymeErrorCode.invalidRequest, 'Incorrect period (from >= to).', data: 'from');
    final list = await backend.transactionsBetween(from, to);
    return {
      'transactions': [
        for (final tx in list)
          {
            'id': tx.paymeId,
            'time': tx.paymeTime,
            'amount': tx.amountTiyin,
            'account': tx.account,
            'create_time': tx.createTime,
            'perform_time': tx.performTime,
            'cancel_time': tx.cancelTime,
            'transaction': tx.merchantId,
            'state': tx.state,
            'reason': tx.reason,
            'receivers': tx.receivers,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _changePassword(Map<String, dynamic> p) async {
    final password = _string(p, 'password');
    if (password.trim().isEmpty) {
      throw _error(PaymeErrorCode.invalidRequest, 'New password is not specified.', data: 'password');
    }
    if (onChangePassword == null) throw _error(PaymeErrorCode.internal, 'Changing the password is not supported.');
    if (constantTimeEquals(password, _key)) {
      throw _error(PaymeErrorCode.insufficientPrivilege, 'Insufficient privilege. Incorrect new password.');
    }
    if (!await onChangePassword!(password)) throw _error(PaymeErrorCode.internal, 'Could not save the new password.');
    _key = password;
    return {'success': true};
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  bool _expired(PaymeTransaction tx, int now) => tx.isActive && now - tx.createTime > timeout.inMilliseconds;

  Future<void> _cancelTx(PaymeTransaction tx, int reason, int now) async {
    final next = tx.copy()
      ..state = tx.state == PaymeState.performed ? PaymeState.cancelledAfterPerform : PaymeState.cancelled
      ..cancelTime = now
      ..reason = reason;
    await backend.cancel(next);
  }

  Map<String, dynamic> _createResult(PaymeTransaction tx) =>
      {'create_time': tx.createTime, 'transaction': tx.merchantId, 'state': tx.state, 'receivers': tx.receivers};

  Future<PaymeTransaction> _found(String paymeId) async {
    final tx = await backend.findTransaction(paymeId);
    if (tx == null) throw _error(PaymeErrorCode.transactionNotFound, 'Transaction not found.');
    return tx;
  }

  Future<PaymeOrder> _payableOrder(Map<String, dynamic> account, int amount) async {
    final order = await backend.findOrder(account);
    if (order == null) throw PaymeError.account(accountField);
    if (order.amountTiyin != amount) throw _error(PaymeErrorCode.invalidAmount, 'Incorrect amount.');
    if (!order.payable) throw _error(PaymeErrorCode.cannotPerform, 'The order cannot be paid.');
    return order;
  }

  int _amount(Map<String, dynamic> p) {
    final a = p['amount'];
    if (a is int && a > 0) return a;
    if (a is double && a > 0 && a == a.roundToDouble() && a < 9007199254740992) return a.toInt();
    throw _error(PaymeErrorCode.invalidAmount, 'Incorrect amount.');
  }

  Map<String, dynamic> _account(Map<String, dynamic> p) {
    final a = p['account'];
    if (a is Map<String, dynamic>) return a;
    throw PaymeError.account(accountField);
  }

  String _string(Map<String, dynamic> p, String name) {
    final v = p[name];
    if (v is String && v.isNotEmpty) return v;
    throw _error(PaymeErrorCode.invalidRequest, 'Missing or invalid parameter "$name".', data: name);
  }

  int _int(Map<String, dynamic> p, String name) {
    final v = p[name];
    if (v is int) return v;
    if (v is double && v == v.roundToDouble()) return v.toInt();
    throw _error(PaymeErrorCode.invalidRequest, 'Missing or invalid parameter "$name".', data: name);
  }

  static PaymeError _error(int code, String en, {Object? data}) =>
      PaymeError(code, {'ru': _ru[code] ?? en, 'uz': _uz[code] ?? en, 'en': en}, data: data);

  static const _ru = <int, String>{
    PaymeErrorCode.internal: 'Внутренняя ошибка системы.',
    PaymeErrorCode.insufficientPrivilege: 'Недостаточно привилегий для выполнения метода.',
    PaymeErrorCode.invalidRequest: 'Неверный JSON-RPC запрос.',
    PaymeErrorCode.methodNotFound: 'Метод не найден.',
    PaymeErrorCode.parseError: 'Ошибка разбора JSON.',
    PaymeErrorCode.invalidAmount: 'Неверная сумма.',
    PaymeErrorCode.transactionNotFound: 'Транзакция не найдена.',
    PaymeErrorCode.cannotCancel: 'Невозможно отменить транзакцию.',
    PaymeErrorCode.cannotPerform: 'Невозможно выполнить данную операцию.',
  };

  static const _uz = <int, String>{
    PaymeErrorCode.internal: 'Tizimning ichki xatosi.',
    PaymeErrorCode.insufficientPrivilege: 'Ushbu amalni bajarish uchun huquq yetarli emas.',
    PaymeErrorCode.invalidRequest: "JSON-RPC so'rovi noto'g'ri.",
    PaymeErrorCode.methodNotFound: 'Metod topilmadi.',
    PaymeErrorCode.parseError: "JSON'ni o'qishda xato.",
    PaymeErrorCode.invalidAmount: "Summa noto'g'ri.",
    PaymeErrorCode.transactionNotFound: 'Tranzaksiya topilmadi.',
    PaymeErrorCode.cannotCancel: 'Tranzaksiyani bekor qilib bo\'lmaydi.',
    PaymeErrorCode.cannotPerform: "Bu amalni bajarib bo'lmaydi.",
  };
}
