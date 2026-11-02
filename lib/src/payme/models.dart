/// Transaction states of the Payme Merchant API.
abstract final class PaymeState {
  /// Created, waiting to be performed.
  static const created = 1;

  /// Performed: money is credited, the order is paid.
  static const performed = 2;

  /// Cancelled before it was performed.
  static const cancelled = -1;

  /// Cancelled after it was performed (refund).
  static const cancelledAfterPerform = -2;
}

/// Cancellation reasons sent by Payme in `CancelTransaction` (and reason 4,
/// which this package sets itself when a transaction times out).
abstract final class PaymeReason {
  static const receiversNotFound = 1;
  static const processingError = 2;
  static const executionError = 3;
  static const timeout = 4;
  static const refund = 5;
  static const unknown = 10;
}

/// Error codes of the Payme Merchant API.
abstract final class PaymeErrorCode {
  static const internal = -32400;
  static const insufficientPrivilege = -32504;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const parseError = -32700;
  static const invalidAmount = -31001;
  static const transactionNotFound = -31003;
  static const cannotCancel = -31007;
  static const cannotPerform = -31008;

  /// Start of the range for errors in the `account` fields (-31050 … -31099).
  static const invalidAccount = -31050;
}

/// An order (invoice, booking, top-up) that a Payme transaction pays for.
class PaymeOrder {
  const PaymeOrder({
    required this.id,
    required this.amountTiyin,
    this.payable = true,
    this.detail,
  });

  /// Your order id.
  final String id;

  /// The exact amount Payme must charge, in tiyin.
  final int amountTiyin;

  /// `false` if the order can no longer be paid (already paid, expired, cancelled).
  final bool payable;

  /// Optional fiscal receipt data returned in `CheckPerformTransaction` as
  /// `detail` (receipt_type, items with title, price, count, code, package_code,
  /// vat_percent …). Required by Payme for cashboxes with fiscalization.
  final Map<String, dynamic>? detail;
}

/// A Payme transaction as stored by your backend.
class PaymeTransaction {
  PaymeTransaction({
    required this.paymeId,
    required this.paymeTime,
    required this.amountTiyin,
    required this.account,
    required this.orderId,
    required this.createTime,
    this.merchantId = '',
    this.performTime = 0,
    this.cancelTime = 0,
    this.state = PaymeState.created,
    this.reason,
    this.receivers,
  });

  /// Payme's transaction id (`params.id`). Store it with a UNIQUE index.
  final String paymeId;

  /// Payme's creation time in ms (`params.time`), kept as received.
  final int paymeTime;
  final int amountTiyin;
  final Map<String, dynamic> account;
  final String orderId;

  /// Your transaction id (returned to Payme as `transaction`). Set by
  /// [PaymeBackend.insertTransaction].
  String merchantId;

  /// Times in ms since epoch; 0 when the event has not happened.
  int createTime;
  int performTime;
  int cancelTime;
  int state;
  int? reason;
  List<Map<String, dynamic>>? receivers;

  bool get isActive => state == PaymeState.created;

  PaymeTransaction copy() => PaymeTransaction(
        paymeId: paymeId,
        paymeTime: paymeTime,
        amountTiyin: amountTiyin,
        account: Map.of(account),
        orderId: orderId,
        createTime: createTime,
        merchantId: merchantId,
        performTime: performTime,
        cancelTime: cancelTime,
        state: state,
        reason: reason,
        receivers: receivers,
      );
}

/// A Merchant API error with a localized message.
class PaymeError implements Exception {
  PaymeError(this.code, this.message, {this.data});

  /// An error for one of the `account` fields (-31050 … -31099).
  factory PaymeError.account(String field, {int code = PaymeErrorCode.invalidAccount}) {
    if (code > -31050 || code < -31099) throw ArgumentError.value(code, 'code', 'must be in -31099 … -31050');
    return PaymeError(
        code,
        const {
          'ru': 'Неверные данные счёта.',
          'uz': "Hisob ma'lumotlari noto'g'ri.",
          'en': 'Invalid account details.',
        },
        data: field);
  }

  final int code;
  final Map<String, String> message;
  final Object? data;

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  @override
  String toString() => 'PaymeError($code, ${message['en']})';
}

/// What [PaymeMerchantHandler] needs from your application.
///
/// Implement it on top of your database. Two rules matter for correctness:
///
/// * Store `paymeId` with a UNIQUE constraint: Payme retries requests.
/// * [perform] and [cancel] must update the transaction **and** the order in one
///   database transaction, so a crash cannot leave an order paid without its
///   transaction marked performed (or the other way round).
abstract class PaymeBackend {
  /// Finds the order described by the payer's `account` fields, or `null`.
  Future<PaymeOrder?> findOrder(Map<String, dynamic> account);

  /// Finds a transaction by Payme's id, or `null`.
  Future<PaymeTransaction?> findTransaction(String paymeId);

  /// Returns a transaction for [orderId] in state 1 (created) or 2 (performed), if any.
  Future<PaymeTransaction?> findOpenTransactionForOrder(String orderId);

  /// Saves a new transaction, sets [PaymeTransaction.merchantId] and returns it.
  Future<PaymeTransaction> insertTransaction(PaymeTransaction tx);

  /// Saves [tx] (state 2, perform time set) and marks its order as paid. Atomically.
  Future<void> perform(PaymeTransaction tx);

  /// Saves [tx] (state -1 or -2, cancel time and reason set) and releases or
  /// refunds its order. Atomically.
  Future<void> cancel(PaymeTransaction tx);

  /// Whether a performed transaction may still be cancelled (refunded), for
  /// example because the goods were not delivered yet. Return `false` to send
  /// error -31007.
  Future<bool> canCancelPerformed(PaymeTransaction tx);

  /// Transactions whose Payme time is within [from]..[to] (ms), for `GetStatement`.
  Future<List<PaymeTransaction>> transactionsBetween(int from, int to);
}
