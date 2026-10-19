/// Pure-Dart encoding/decoding for the UPI payment flow.
///
/// No Flutter/plugin imports here so the parsing and URI logic can run under
/// the Dart VM for fast unit checks. The concrete launches (native bridge,
/// native Android method-channel bridge live in [upi_payment_service.dart].
library;

/// The status of a completed UPI payment attempt, based on the response the
/// external UPI app returned. Only [success] is reported as success.
enum UpiLaunchStatus {
  success,
  failed,
  cancelled,
  pending,
  unknown,
}

/// Builds the canonical `upi://pay` URI used by every major UPI app
/// (Google Pay, PhonePe, Paytm, BHIM, Amazon Pay, ...). Only supported
/// parameters are emitted.
String buildPaymentUri({
  required String vpa,
  String? payeeName,
  required double amount,
  String? note,
  String? transactionRef,
  String? merchantCode,
}) {
  final params = <String, String>{
    'pa': vpa,
    'am': amount.toStringAsFixed(2),
    'cu': 'INR',
    'tn': (note == null || note.trim().isEmpty) ? 'Payment' : note.trim(),
  };
  final name = payeeName?.trim();
  if (name != null && name.isNotEmpty) params['pn'] = name;
  final txnRef = transactionRef ?? _newTransactionRef();
  if (txnRef.isNotEmpty) params['tr'] = txnRef;
  final mc = merchantCode?.trim();
  if (mc != null && mc.isNotEmpty) params['mc'] = mc;
  return Uri(scheme: 'upi', host: 'pay', queryParameters: params).toString();
}

/// Adds a user-entered amount to an otherwise static scanned UPI QR without
/// discarding the QR's other payment parameters.
///
/// Rebuilding every scan from only `pa`, `pn`, `am`, `cu`, `tn`, `tr` and `mc`
/// looked harmless, but it silently removed fields a merchant/PSP can require
/// (`mam`, `mode`, `purpose`, `orgid`, `url`, and provider-specific signed QR
/// metadata). Google Pay therefore received a *different* payment request than
/// the one it receives when it scans the same QR itself; it can reject that
/// altered request with misleading messages such as an amount-limit failure.
///
/// This helper is for an unsigned static QR only. Dynamic and signed QR values
/// are passed through byte-for-byte by the caller because changing even one
/// parameter can invalidate their merchant signature.
String buildPaymentUriFromStaticQr({
  required String scannedUri,
  required double amount,
}) {
  final source = Uri.tryParse(scannedUri);
  if (source == null || !source.isScheme('upi') || source.host != 'pay') {
    throw ArgumentError.value(scannedUri, 'scannedUri', 'Invalid UPI QR URI');
  }

  final params = Map<String, String>.from(source.queryParameters);
  params['am'] = amount.toStringAsFixed(2);
  params.putIfAbsent('cu', () => 'INR');

  // NPCI expects the scanning PSP to supply a reference for a static QR when
  // the QR itself has none. Keep a merchant-supplied reference exactly as it
  // was scanned; never replace it with a local one.
  if ((params['tr'] ?? '').trim().isEmpty) {
    params['tr'] = _newTransactionRef();
  }

  return Uri(
    scheme: source.scheme,
    host: source.host,
    queryParameters: params,
  ).toString();
}

String _newTransactionRef() =>
    'MYE${DateTime.now().millisecondsSinceEpoch}';

/// Maps the raw intent result to an honest [UpiLaunchStatus].
///
/// The NPCI-standard response is a string like
/// `upi://pay?txnid=..&status=success&Amount=..` or a plain word. Result
/// codes alone never produce [UpiLaunchStatus.success]; only an explicit
/// success response does.
UpiLaunchStatus parsePaymentStatus({
  bool? resultOk,
  int? resultCode,
  String? response,
}) {
  final resp = response?.trim().toLowerCase() ?? '';

  // Parse a possible response URI.
  if (resp.contains('status=')) {
    final statusMatch = RegExp(r'status=([^&]+)').firstMatch(resp);
    final value = statusMatch?.group(1)?.toLowerCase() ?? '';
    if (value.contains('success')) return UpiLaunchStatus.success;
    if (value.contains('fail')) return UpiLaunchStatus.failed;
    if (value.contains('cancel') ||
        value.contains('abort') ||
        value.contains('reject')) {
      return UpiLaunchStatus.cancelled;
    }
    if (value.contains('submitted') ||
        value.contains('pending') ||
        value.contains('initiated') ||
        value.contains('processing')) {
      return UpiLaunchStatus.pending;
    }
  }

  if (resp.isNotEmpty) {
    // Plain-word responses from some UPI apps.
    if (resp.startsWith('success') ||
        resp == 'approved' ||
        resp.contains('payment successful') ||
        resp.contains('txn successful')) {
      return UpiLaunchStatus.success;
    }
    if (resp.contains('fail') ||
        resp.contains('declined') ||
        resp == 'error') {
      return UpiLaunchStatus.failed;
    }
    if (resp.contains('cancel') ||
        resp.contains('abort') ||
        resp.contains('reject') ||
        resp.startsWith('#')) {
      return UpiLaunchStatus.cancelled;
    }
    if (resp == 'submitted' ||
        resp == 'pending' ||
        resp == 'initiated' ||
        resp == 'processing') {
      return UpiLaunchStatus.pending;
    }
  }

  // A result code without an explicit response is not proof of cancellation:
  // several UPI apps return RESULT_CANCELED when the user simply comes back
  // to the caller. Treat it as unknown, never as a payment success.
  return UpiLaunchStatus.unknown;
}

String spokenPaymentStatus(UpiLaunchStatus status) {
  switch (status) {
    case UpiLaunchStatus.success:
      return 'Your payment app reported that the payment was successful. '
          'Please check the app for confirmation.';
    case UpiLaunchStatus.failed:
      return 'Payment failed.';
    case UpiLaunchStatus.cancelled:
      return 'Payment cancelled.';
    case UpiLaunchStatus.pending:
      return 'The payment is still pending. Please check your UPI app or '
          'bank before trying again.';
    case UpiLaunchStatus.unknown:
      return 'I could not confirm the payment status. Please check your '
          'payment app.';
  }
}
