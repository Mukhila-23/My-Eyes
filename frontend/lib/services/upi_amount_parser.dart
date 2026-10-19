/// Pure-Dart parsing of spoken/heard amounts into a payable INR value.
///
/// Accepts forms like `500`, `500 rupees`, `₹250`, `250.50`,
/// `five hundred`, `one thousand rupees`, `two thousand five hundred fifty`.
/// Rejects zero, negative, unclear or unreasonable values by returning null.
library;

class UpiAmountParser {
  UpiAmountParser._();

  /// Upper bound considered reasonable for a single UPI payment. Values above
  /// this are rejected rather than paid.
  static const double maxAmount = 999999.99;

  static const Map<String, int> _units = {
    'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6,
    'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
    'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16,
    'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'twenty': 20,
    'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60, 'seventy': 70,
    'eighty': 80, 'ninety': 90,
  };

  static const Map<String, int> _scales = {
    'hundred': 100,
    'thousand': 1000,
    'lakh': 100000,
    'crore': 10000000,
  };

  static const Set<String> _noiseTokens = {
    'rupees', 'rupee', 'rs', 'inr', 'only', 'and', 'paise', 'exactly',
  };

  /// Attempts to parse [input] into a positive, valid amount.
  ///
  /// Returns the amount in rupees (rounded to 2 decimals) or null when the
  /// input cannot be understood or is unsafe to pay.
  static double? parse(String? input) {
    if (input == null) return null;
    var text = input.trim().toLowerCase();

    // Currency markers before numeric input, e.g. "₹250" or "rs 250".
    text = text.replaceAll(RegExp(r'[₹$]'), ' ');

    // Direct numeric path: strip currency words leaving digits/decimals.
    final stripped = _stripNoiseWords(text);
    final cleanDigits = stripped.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleanDigits.isNotEmpty) {
      final onlyNumeric = RegExp(r'^[0-9]+(\.[0-9]{1,2})?$').hasMatch(cleanDigits);
      if (onlyNumeric) {
        final direct = double.tryParse(cleanDigits);
        if (direct != null) return _validated(direct);
      }
    }

    // Word-number path.
    final words = _tokenize(text);
    if (words.isEmpty) return null;
    final wordValue = _parseWords(words);
    if (wordValue != null) return _validated(wordValue);
    return null;
  }

  static double? _validated(double raw) {
    if (raw.isNaN || raw.isInfinite) return null;
    if (raw <= 0) return null;
    if (raw > maxAmount) return null;
    return double.parse(raw.toStringAsFixed(2));
  }

  /// Drops noise/currency words so `500 rupees` reduces to `500`.
  static String _stripNoiseWords(String text) {
    final tokens = text.split(RegExp(r'\s+')).toList();
    tokens.retainWhere((t) => !_noiseTokens.contains(t));
    return tokens.join(' ');
  }

  static List<String> _tokenize(String text) {
    final tokens = <String>[];
    for (final raw in text.split(RegExp(r'[\s,\-]+'))) {
      if (raw.isEmpty) continue;
      // "500rupees" adjacent forms are already covered by the numeric path;
      // here we keep any token that is a known word or a digit string.
      if (_noiseTokens.contains(raw)) continue;
      if (_units.containsKey(raw) || _scales.containsKey(raw)) {
        tokens.add(raw);
      } else if (raw == 'point' || raw == 'dot') {
        tokens.add(raw);
      } else if (RegExp(r'^[0-9]+$').hasMatch(raw)) {
        tokens.add(raw);
      } else {
        return const [];
      }
    }
    return tokens;
  }

  /// Classic English numeric-word parser with optional `point` decimals.
  static double? _parseWords(List<String> tokens) {
    var total = 0.0;
    var segment = 0.0;
    var sawValue = false;
    var decimal = '';
    var inDecimal = false;

    for (final token in tokens) {
      if (inDecimal) {
        // Accept digits or unit words ("five point three" -> .3).
        if (RegExp(r'^[0-9]+$').hasMatch(token)) {
          decimal += token;
        } else {
          final unit = _units[token];
          if (unit != null && unit < 10) {
            decimal += '$unit';
          } else {
            return null;
          }
        }
        continue;
      }
      if (token == 'point' || token == 'dot') {
        if (!sawValue) return null;
        inDecimal = true;
        continue;
      }
      final unit = _units[token];
      if (unit != null) {
        segment += unit;
        sawValue = true;
        continue;
      }
      final scale = _scales[token];
      if (scale != null) {
        if (segment == 0) segment = 1;
        if (scale == 100) {
          segment *= 100;
        } else {
          segment *= scale;
          total += segment;
          segment = 0;
        }
        sawValue = true;
        continue;
      }
      final digits = int.tryParse(token);
      if (digits != null) {
        segment += digits;
        sawValue = true;
        continue;
      }
      return null;
    }

    if (!sawValue) return null;
    total += segment;

    if (inDecimal) {
      if (decimal.isEmpty && !tokens.contains('zero')) return null;
      // Keep at most two decimal digits.
      while (decimal.length > 2) {
        decimal = decimal.substring(0, decimal.length - 1);
      }
      final dec = double.tryParse('0.$decimal');
      if (dec == null) return null;
      total += dec;
    }
    return total;
  }
}