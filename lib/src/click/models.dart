/// Error codes of the Click SHOP-API.
abstract final class ClickErrorCode {
  static const success = 0;
  static const signCheckFailed = -1;
  static const incorrectAmount = -2;
  static const actionNotFound = -3;
  static const alreadyPaid = -4;
  static const orderNotFound = -5;
  static const transactionNotFound = -6;
  static const failedToUpdate = -7;
  static const badRequest = -8;
  static const transactionCancelled = -9;
}

/// Payment state of an order from Click's point of view.
enum ClickOrderStatus { pending, paid, cancelled }

/// An order that a Click payment is for (`merchant_trans_id`).
class ClickOrder {
  const ClickOrder({required this.id, required this.amountTiyin, this.status = ClickOrderStatus.pending});

  final String id;

  /// Exact amount to charge, in tiyin.
  final int amountTiyin;
  final ClickOrderStatus status;
}

/// The record your backend creates on a successful Prepare.
class ClickPrepare {
  const ClickPrepare({required this.id, required this.orderId, required this.clickTransId});

  /// Your prepare id, sent to Click as `merchant_prepare_id`.
  final int id;
  final String orderId;
  final int clickTransId;
}

/// A verified Prepare or Complete request from Click.
class ClickRequest {
  const ClickRequest({
    required this.clickTransId,
    required this.serviceId,
    required this.clickPaydocId,
    required this.merchantTransId,
    required this.amountTiyin,
    required this.action,
    required this.error,
    required this.errorNote,
    required this.signTime,
    this.merchantPrepareId,
  });

  final int clickTransId;
  final int serviceId;
  final int clickPaydocId;
  final String merchantTransId;
  final int amountTiyin;

  /// 0 = Prepare, 1 = Complete.
  final int action;

  /// Click's own status for the payment; negative on Complete means it failed.
  final int error;
  final String errorNote;
  final String signTime;
  final int? merchantPrepareId;
}

/// What [ClickMerchantHandler] needs from your application.
///
/// [complete] and [cancel] must update the prepare record and the order in one
/// database transaction.
abstract class ClickBackend {
  /// Finds the order by `merchant_trans_id`, or `null`.
  Future<ClickOrder?> findOrder(String merchantTransId);

  /// Records a Prepare and reserves the order. Must return the same id when
  /// Click repeats the Prepare for the same `click_trans_id`.
  Future<int> prepare(ClickOrder order, ClickRequest request);

  /// Finds a prepare record by your `merchant_prepare_id`, or `null`.
  Future<ClickPrepare?> findPrepare(int merchantPrepareId);

  /// Marks the order paid. Returns your confirm id (`merchant_confirm_id`).
  Future<int> complete(ClickOrder order, ClickPrepare prepare, ClickRequest request);

  /// Click reported a failed or cancelled payment: release the reservation.
  Future<void> cancel(ClickOrder order, ClickPrepare prepare, ClickRequest request);
}
