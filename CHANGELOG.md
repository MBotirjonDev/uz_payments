# Changelog

## 0.1.0 - 2026-11-02

First release.

- `PaymeCheckout` and `ClickCheckout`: build checkout links, with sandbox support and input validation.
- `PaymeMerchantHandler`: the full Payme Merchant API (`CheckPerformTransaction`, `CreateTransaction`,
  `PerformTransaction`, `CancelTransaction`, `CheckTransaction`, `GetStatement`, `ChangePassword`).
- `ClickMerchantHandler`: the Click SHOP-API (Prepare and Complete) with MD5 signature verification.
- Money helpers in tiyin: `formatSom`, `parseSomToTiyin`, `somToTiyin`.
- `InMemoryPaymeBackend` and `InMemoryClickBackend` reference implementations.
- Client-safe entry point `package:uz_payments/checkout.dart`.
- 52 tests.
