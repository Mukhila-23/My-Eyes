/// Pure-Dart parsing/validation for UPI payment QR codes.
///
/// This service only parses and validates a scanned value; it never performs
/// payment and it never touches UPI PINs, biometrics, or bank credentials.
/// Those remain entirely inside the external UPI app.
library;

/// A validated UPI payment target decoded from a QR code (or spoken/entered
/// manually). Mirrors the fields of the standard `upi://pay` URI.
class UpiPaymentDetails {
  const UpiPaymentDetails({
    required this.payeeVpa,
    this.payeeName,
    this.amount,
    this.currency,
    this.transactionRef,
    this.merchantCode,
    this.note,
    required this.raw,
  });

  /// The payee address (VPA), e.g. `merchant@upi`.
  final String payeeVpa;

  /// The payee display name from `pn`, when provided.
  final String? payeeName;

  /// Amount embedded in a dynamic QR (`am`). Null for static QRs.
  final double? amount;

  /// Payment currency (`cu`). Usually `INR`.
  final String? currency;

  /// Transaction reference (`tr` or `txnid`) when provided by the merchant.
  final String? transactionRef;

  /// Optional merchant category code (`mc`).
  final String? merchantCode;

  /// Transaction note (`tn`) when provided.
  final String? note;

  /// The normalized raw string that produced this object.
  final String raw;

  /// Whether a usable amount is embedded in the QR.
  bool get hasAmount => amount != null && amount! > 0;

  /// Whether this is a dynamic QR (amount fixed by the merchant).
  bool get isDynamic => hasAmount;

  /// Human-readable name used in spoken announcements.
  String get displayName {
    final n = payeeName?.trim();
    return (n != null && n.isNotEmpty) ? n : payeeVpa;
  }
}

class UpiQrParser {
  UpiQrParser._();

  static const double _maxAmount = 999999.99;
  static final RegExp _upiUri = RegExp(r'upi://pay\S*', caseSensitive: false);
  static final RegExp _vpa = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-_]*@[A-Za-z0-9.\-_]+$');

  /// Validates a scanned string and returns the payment details, or null when
  /// the input is not a recognized UPI payment code.
  static UpiPaymentDetails? parse(String? input) {
    if (input == null) return null;
    final text = input.trim();
    if (text.isEmpty) return null;

    final uriMatch = _upiUri.firstMatch(text);
    if (uriMatch == null) return null;
    final uriRaw = uriMatch.group(0)!;

    final uri = Uri.tryParse(uriRaw);
    if (uri == null) return null;
    if (!uri.isScheme('upi') || uri.host.toLowerCase() != 'pay') return null;

    final params = uri.queryParameters;
    final vpa = params['pa']?.trim();
    if (vpa == null || vpa.isEmpty || !_vpa.hasMatch(vpa)) return null;

    double? amount;
    final am = params['am']?.trim();
    if (am != null && am.isNotEmpty) {
      final parsed = double.tryParse(am);
      if (parsed == null ||
          parsed <= 0 ||
          parsed > _maxAmount ||
          !parsed.isFinite) {
        return null;
      }
      amount = parsed;
    }

    final txnRef = (params['tr'] ?? params['txnid'])?.trim();
    final name = params['pn']?.trim();
    final currency = params['cu']?.trim();
    if (currency != null &&
        currency.isNotEmpty &&
        currency.toUpperCase() != 'INR') {
      return null;
    }

    return UpiPaymentDetails(
      payeeVpa: vpa,
      payeeName: (name != null && name.isNotEmpty) ? name : null,
      amount: amount,
      currency: (currency != null && currency.isNotEmpty) ? currency : null,
      transactionRef: (txnRef != null && txnRef.isNotEmpty) ? txnRef : null,
      merchantCode: params['mc']?.trim(),
      note: params['tn']?.trim(),
      raw: uriRaw,
    );
  }

}
