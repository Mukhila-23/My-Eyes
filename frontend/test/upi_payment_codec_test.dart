import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/upi_payment_codec.dart';
import 'package:frontend/services/upi_qr_parser.dart';

void main() {
  group('UpiQrParser', () {
    test('accepts a valid static UPI payment URI', () {
      final details = UpiQrParser.parse(
        'upi://pay?pa=merchant%40upi&pn=ABC%20Store&cu=INR',
      );

      expect(details, isNotNull);
      expect(details!.payeeVpa, 'merchant@upi');
      expect(details.displayName, 'ABC Store');
      expect(details.amount, isNull);
    });

    test('rejects a bare VPA and malformed fixed amount', () {
      expect(UpiQrParser.parse('merchant@upi'), isNull);
      expect(
        UpiQrParser.parse('upi://pay?pa=merchant%40upi&am=zero&cu=INR'),
        isNull,
      );
      expect(
        UpiQrParser.parse('upi://pay?pa=merchant%40upi&am=100&cu=USD'),
        isNull,
      );
    });
  });

  group('UPI payment-link preservation', () {
    test('keeps static QR merchant parameters when adding an amount', () {
      const scanned =
          'upi://pay?pa=merchant%40upi&pn=ABC%20Store&mc=5411&mode=02&'
          'purpose=00&orgid=123456&mam=10&tr=MERCHANT-ORDER-42&'
          'url=https%3A%2F%2Fmerchant.example%2Freceipt&cu=INR';

      final uri = Uri.parse(
        buildPaymentUriFromStaticQr(scannedUri: scanned, amount: 500),
      );

      expect(uri.queryParameters['pa'], 'merchant@upi');
      expect(uri.queryParameters['am'], '500.00');
      expect(uri.queryParameters['mc'], '5411');
      expect(uri.queryParameters['mode'], '02');
      expect(uri.queryParameters['purpose'], '00');
      expect(uri.queryParameters['orgid'], '123456');
      expect(uri.queryParameters['mam'], '10');
      expect(uri.queryParameters['tr'], 'MERCHANT-ORDER-42');
      expect(uri.queryParameters['url'], 'https://merchant.example/receipt');
    });
  });

  group('parsePaymentStatus', () {
    test('reports pending separately from unknown', () {
      expect(
        parsePaymentStatus(response: 'Status=PENDING'),
        UpiLaunchStatus.pending,
      );
    });

    test('does not treat a return without a response as cancellation or success', () {
      expect(
        parsePaymentStatus(resultCode: 0, response: null),
        UpiLaunchStatus.unknown,
      );
    });
  });
}
