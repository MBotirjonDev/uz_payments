import 'dart:convert';

import '../http.dart';
import '../md5.dart';
import '../money.dart';
import 'models.dart';

/// Server-side handler for the Click **SHOP-API** (Prepare and Complete).
///
/// It verifies the MD5 `sign_string` with your secret key in constant time,
/// checks the service id, amount (exactly, in tiyin, no floating point), order
/// and prepare records, handles repeats and Click-side failures, and builds the
/// JSON reply Click expects.
///
/// Use one instance for both URLs (or one shared URL); the `action` field
/// tells Prepare (0) from Complete (1).
class ClickMerchantHandler {
  ClickMerchantHandler({required this.serviceId, required String secretKey, required this.backend})
      : _secret = secretKey {
    if (secretKey.isEmpty) throw ArgumentError.value(secretKey, 'secretKey', 'must not be empty');
  }

  final int serviceId;
  final ClickBackend backend;
  final String _secret;

  static const _required = [
    'click_trans_id',
    'service_id',
    'click_paydoc_id',
    'merchant_trans_id',
    'amount',
    'action',
    'error',
    'error_note',
    'sign_time',
    'sign_string',
  ];

  /// Handles one request from Click and returns the reply to send.
  Future<MerchantResponse> handle(MerchantRequest request) async {
    final f = _parse(request.body);
    Map<String, dynamic> reply(int error, String note, {int? prepareId, int? confirmId}) {
      final action = f['action'];
      return {
        'click_trans_id': int.tryParse(f['click_trans_id'] ?? '') ?? f['click_trans_id'],
        'merchant_trans_id': f['merchant_trans_id'],
        if (action == '1') 'merchant_confirm_id': confirmId else 'merchant_prepare_id': prepareId,
        'error': error,
        'error_note': note,
      };
    }

    if (_required.any((k) => f[k] == null) || (f['action'] == '1' && f['merchant_prepare_id'] == null)) {
      return MerchantResponse.json(reply(ClickErrorCode.badRequest, 'Error in request from click'));
    }

    final action = f['action']!;
    final expected = md5Hex([
      f['click_trans_id'],
      f['service_id'],
      _secret,
      f['merchant_trans_id'],
      if (action == '1') f['merchant_prepare_id'],
      f['amount'],
      action,
      f['sign_time'],
    ].join());
    if (!constantTimeEquals(expected, f['sign_string']!.toLowerCase())) {
      return MerchantResponse.json(reply(ClickErrorCode.signCheckFailed, 'SIGN CHECK FAILED!'));
    }

    if (action != '0' && action != '1') {
      return MerchantResponse.json(reply(ClickErrorCode.actionNotFound, 'Action not found'));
    }

    final clickTransId = int.tryParse(f['click_trans_id']!);
    final reqService = int.tryParse(f['service_id']!);
    final paydoc = int.tryParse(f['click_paydoc_id']!);
    final clickError = int.tryParse(f['error']!);
    final prepareId = action == '1' ? int.tryParse(f['merchant_prepare_id']!) : null;
    if (clickTransId == null ||
        reqService == null ||
        paydoc == null ||
        clickError == null ||
        (action == '1' && prepareId == null) ||
        reqService != serviceId) {
      return MerchantResponse.json(reply(ClickErrorCode.badRequest, 'Error in request from click'));
    }
    final amount = parseSomToTiyin(f['amount']!);
    if (amount == null)
      return MerchantResponse.json(reply(ClickErrorCode.incorrectAmount, 'Incorrect parameter amount'));

    final req = ClickRequest(
      clickTransId: clickTransId,
      serviceId: reqService,
      clickPaydocId: paydoc,
      merchantTransId: f['merchant_trans_id']!,
      amountTiyin: amount,
      action: int.parse(action),
      error: clickError,
      errorNote: f['error_note']!,
      signTime: f['sign_time']!,
      merchantPrepareId: prepareId,
    );

    try {
      final order = await backend.findOrder(req.merchantTransId);
      if (order == null) return MerchantResponse.json(reply(ClickErrorCode.orderNotFound, 'User does not exist'));

      ClickPrepare? prepare;
      if (req.action == 1) {
        prepare = await backend.findPrepare(req.merchantPrepareId!);
        if (prepare == null || prepare.orderId != order.id) {
          return MerchantResponse.json(
              reply(ClickErrorCode.transactionNotFound, 'Transaction does not exist', confirmId: prepareId));
        }
      }

      if (order.status == ClickOrderStatus.paid) {
        return MerchantResponse.json(
            reply(ClickErrorCode.alreadyPaid, 'Already paid', prepareId: prepareId, confirmId: prepareId));
      }
      if (order.status == ClickOrderStatus.cancelled) {
        return MerchantResponse.json(reply(ClickErrorCode.transactionCancelled, 'Transaction cancelled',
            prepareId: prepareId, confirmId: prepareId));
      }
      if (req.amountTiyin != order.amountTiyin) {
        return MerchantResponse.json(reply(ClickErrorCode.incorrectAmount, 'Incorrect parameter amount'));
      }

      if (req.action == 0) {
        final id = await backend.prepare(order, req);
        return MerchantResponse.json(reply(ClickErrorCode.success, 'Success', prepareId: id));
      }

      if (req.error < 0) {
        // Click could not charge the payer: release the order and confirm the cancellation.
        await backend.cancel(order, prepare!, req);
        return MerchantResponse.json(
            reply(ClickErrorCode.transactionCancelled, 'Transaction cancelled', confirmId: prepare.id));
      }
      final confirm = await backend.complete(order, prepare!, req);
      return MerchantResponse.json(reply(ClickErrorCode.success, 'Success', confirmId: confirm));
    } catch (_) {
      return MerchantResponse.json(reply(ClickErrorCode.failedToUpdate, 'Failed to update user'));
    }
  }

  static Map<String, String?> _parse(String body) {
    final text = body.trim();
    if (text.startsWith('{')) {
      try {
        final m = jsonDecode(text);
        if (m is Map) return {for (final e in m.entries) '${e.key}': e.value?.toString()};
      } on FormatException {
        return const {};
      }
      return const {};
    }
    try {
      return Uri.splitQueryString(text);
    } catch (_) {
      // Malformed percent-encoding throws ArgumentError; treat it as a bad request.
      return const {};
    }
  }
}
