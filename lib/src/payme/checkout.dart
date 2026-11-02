import 'dart:convert';

/// Builds Payme checkout links (GET method of "Инициализация платежей").
///
/// Safe to use in a Flutter app: it needs only the public merchant id, never
/// the cashbox key.
///
/// ```dart
/// final payme = PaymeCheckout(merchantId: '587f72c72cac0d162c722ae2');
/// final url = payme.url(account: {'order_id': '197'}, amountTiyin: 500);
/// // https://checkout.paycom.uz/bT01ODdmNzJjNzJjYWMwZDE2MmM3MjJhZTI7YWMub3JkZXJfaWQ9MTk3O2E9NTAw
/// ```
class PaymeCheckout {
  PaymeCheckout({required this.merchantId, this.test = false}) {
    if (merchantId.trim().isEmpty) throw ArgumentError.value(merchantId, 'merchantId', 'must not be empty');
    _checkValue('merchantId', merchantId);
  }

  /// Merchant (cashbox) id or alias from the Payme Business cabinet.
  final String merchantId;

  /// Use the sandbox checkout (`test.paycom.uz`) instead of production.
  final bool test;

  /// Production checkout host.
  static const productionBase = 'https://checkout.paycom.uz';

  /// Sandbox checkout host.
  static const testBase = 'https://test.paycom.uz';

  /// Returns the checkout URL.
  ///
  /// * [account]: the `ac.*` fields configured for the cashbox, e.g. `{'order_id': '197'}`.
  /// * [amountTiyin]: amount in tiyin (1 so'm = 100 tiyin), must be positive.
  /// * [lang]: `uz`, `ru` or `en`.
  /// * [returnUrl]: where the payer returns after paying or cancelling (`c`).
  /// * [returnDelay]: how long to wait after a successful payment before returning (`ct`).
  /// * [currency]: ISO currency code (`cr`), omitted by default.
  Uri url({
    required Map<String, String> account,
    required int amountTiyin,
    String? lang,
    String? returnUrl,
    Duration? returnDelay,
    String? currency,
  }) {
    if (account.isEmpty) throw ArgumentError.value(account, 'account', 'must contain at least one field');
    if (amountTiyin <= 0) throw ArgumentError.value(amountTiyin, 'amountTiyin', 'must be positive');
    if (lang != null && !const {'uz', 'ru', 'en'}.contains(lang)) {
      throw ArgumentError.value(lang, 'lang', 'must be uz, ru or en');
    }
    final parts = <String>['m=$merchantId'];
    account.forEach((key, value) {
      _checkValue('account key', key);
      _checkValue('account.$key', value);
      parts.add('ac.$key=$value');
    });
    parts.add('a=$amountTiyin');
    if (lang != null) parts.add('l=$lang');
    if (returnUrl != null) {
      _checkValue('returnUrl', returnUrl);
      parts.add('c=$returnUrl');
    }
    if (returnDelay != null) parts.add('ct=${returnDelay.inMilliseconds}');
    if (currency != null) {
      _checkValue('currency', currency);
      parts.add('cr=$currency');
    }
    final encoded = base64.encode(utf8.encode(parts.join(';')));
    return Uri.parse('${test ? testBase : productionBase}/$encoded');
  }

  static void _checkValue(String name, String value) {
    // ';' separates parameters in the encoded string; a value containing it
    // would let user input inject extra parameters such as a different amount.
    if (value.contains(';')) throw ArgumentError.value(value, name, 'must not contain ";"');
  }
}
