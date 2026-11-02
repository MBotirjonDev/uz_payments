import 'dart:convert';

/// A framework-neutral view of an incoming webhook request.
///
/// Build it from shelf, dart_frog, Serverpod, `dart:io` or anything else:
/// header names are matched case-insensitively and [body] is the raw body.
class MerchantRequest {
  MerchantRequest({
    required Map<String, String> headers,
    required this.body,
    this.remoteAddress,
  }) : headers = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

  /// Header map with lowercase names.
  final Map<String, String> headers;

  /// Raw request body (JSON for Payme, form-encoded for Click).
  final String body;

  /// The client IP, when you know it (used by optional IP allowlists).
  final String? remoteAddress;
}

/// The response to send back to the payment provider.
class MerchantResponse {
  const MerchantResponse(this.body, {this.statusCode = 200});

  /// Creates a JSON response.
  factory MerchantResponse.json(Object? value, {int statusCode = 200}) =>
      MerchantResponse(jsonEncode(value), statusCode: statusCode);

  final int statusCode;
  final String body;

  Map<String, String> get headers => const {'content-type': 'application/json; charset=utf-8'};
}
