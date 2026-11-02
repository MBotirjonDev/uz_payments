/// Money helpers. Amounts are always integers in **tiyin** (1 so'm = 100 tiyin)
/// inside this package, so no floating-point rounding ever touches a payment.
library;

/// Converts whole so'm to tiyin.
int somToTiyin(int som) => som * 100;

/// Formats tiyin as a so'm string with two decimals: `150000` → `"1500.00"`.
String formatSom(int tiyin) {
  if (tiyin < 0) throw ArgumentError.value(tiyin, 'tiyin', 'must not be negative');
  final som = tiyin ~/ 100;
  final rest = (tiyin % 100).toString().padLeft(2, '0');
  return '$som.$rest';
}

/// Parses a so'm amount as sent by Click (`"1000"`, `"1000.0"`, `"1000.50"`)
/// into tiyin without using floating point. Returns `null` for anything that is
/// not a plain non-negative decimal with at most two fractional digits.
int? parseSomToTiyin(String value) {
  final m = RegExp(r'^(\d{1,15})(?:\.(\d{1,2})0*)?$').firstMatch(value.trim());
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(2, '0');
  return whole * 100 + int.parse(frac);
}
