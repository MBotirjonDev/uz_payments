import '../money.dart';

/// Builds Click payment links (`my.click.uz/services/pay`).
///
/// Safe to use in a Flutter app: it needs only the public service and merchant
/// ids, never the secret key.
///
/// ```dart
/// final click = ClickCheckout(serviceId: 36, merchantId: 46);
/// final url = click.url(transactionParam: 'order-197', amountTiyin: 100000,
///     returnUrl: 'https://shop.example/paid');
/// ```
class ClickCheckout {
  ClickCheckout({required this.serviceId, required this.merchantId}) {
    if (serviceId <= 0) throw ArgumentError.value(serviceId, 'serviceId', 'must be positive');
    if (merchantId <= 0) throw ArgumentError.value(merchantId, 'merchantId', 'must be positive');
  }

  final int serviceId;
  final int merchantId;

  static const base = 'https://my.click.uz/services/pay';

  /// Returns the payment URL.
  ///
  /// * [transactionParam]: your order id; Click sends it back as `merchant_trans_id`.
  /// * [amountTiyin]: amount in tiyin, sent to Click as so'm with two decimals.
  /// * [returnUrl]: where the payer returns after paying.
  /// * [cardType]: `uzcard` or `humo` to preselect the card type.
  /// * [merchantUserId]: your user id, if Click asked you to pass it.
  Uri url({
    required String transactionParam,
    required int amountTiyin,
    String? returnUrl,
    String? cardType,
    String? merchantUserId,
  }) {
    if (transactionParam.trim().isEmpty) {
      throw ArgumentError.value(transactionParam, 'transactionParam', 'must not be empty');
    }
    if (amountTiyin <= 0) throw ArgumentError.value(amountTiyin, 'amountTiyin', 'must be positive');
    if (cardType != null && !const {'uzcard', 'humo'}.contains(cardType)) {
      throw ArgumentError.value(cardType, 'cardType', 'must be uzcard or humo');
    }
    return Uri.parse(base).replace(queryParameters: {
      'service_id': '$serviceId',
      'merchant_id': '$merchantId',
      'amount': formatSom(amountTiyin),
      'transaction_param': transactionParam,
      if (returnUrl != null) 'return_url': returnUrl,
      if (cardType != null) 'card_type': cardType,
      if (merchantUserId != null) 'merchant_user_id': merchantUserId,
    });
  }
}
