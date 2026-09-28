// Foreign fares (CZK, PLN, CHF, HUF, …) converted to euros with the ECB reference rates (published daily).
import 'net.dart';

final _ecb = Uri.parse('https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml');

/// Approximate fallback if the ECB can't be reached (only used for display ordering, marked "≈").
const _fallback = {'CZK': 24.4, 'PLN': 4.3, 'CHF': 0.94, 'HUF': 367.0, 'DKK': 7.46, 'SEK': 11.3, 'NOK': 11.6, 'GBP': 0.85};

Map<String, double>? _rates;
DateTime? _fetched;

Future<Map<String, double>> _load() async {
  if (_rates != null && DateTime.now().difference(_fetched!).inHours < 12) return _rates!;
  try {
    final xml = await Net.instance.getText(_ecb, timeout: const Duration(seconds: 8));
    final rates = <String, double>{'EUR': 1};
    for (final m in RegExp(r"currency='([A-Z]{3})'\s+rate='([0-9.]+)'").allMatches(xml)) {
      rates[m.group(1)!] = double.parse(m.group(2)!);
    }
    if (rates.length > 5) {
      _rates = rates;
      _fetched = DateTime.now();
    }
  } catch (_) {
    // keep old rates / fallback
  }
  return _rates ?? {'EUR': 1, ..._fallback};
}

/// [amount] in [currency] → euros. Null for unknown currencies.
Future<double?> toEur(double amount, String currency) async {
  if (currency == 'EUR') return amount;
  final r = (await _load())[currency];
  return r == null ? null : (amount / r * 100).round() / 100;
}

String currencySymbol(String c) => switch (c) {
  'EUR' => '€',
  'CZK' => 'Kč',
  'PLN' => 'zł',
  'HUF' => 'Ft',
  'CHF' => 'CHF',
  'GBP' => '£',
  'DKK' || 'SEK' || 'NOK' => 'kr',
  _ => c,
};
