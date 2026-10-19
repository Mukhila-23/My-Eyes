/// Payment engine for the voice-based UPI QR flow.
///
/// Responsibilities:
///  * Detect whether any installed UPI app can handle a `upi://pay` request
///    (Android 11+ requires a matching `<queries>` entry in AndroidManifest).
///  * Launch the external UPI app through the native `my_eyes/upi` channel
///    (startActivityForResult) so the REAL transaction response is read back
///    and reported honestly via [parsePaymentStatus].
///
/// Pure encoding/status logic (URI builder, response decoder) lives in the
/// dependency-free [upi_payment_codec.dart] and is re-exported here for callers.
///
/// This service does NOT collect, store, or process UPI PINs and does NOT
/// perform biometric or bank verification; that stays inside the UPI app.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'upi_payment_codec.dart';

export 'upi_payment_codec.dart';

class UpiLaunchException implements Exception {
  const UpiLaunchException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'UpiLaunchException($code): $message';
}

/// An installed application that declares support for `upi://pay`.
  ///
  /// The label and package are supplied by Android's package manager. They are
  /// used only to pick the payment app; no payment credentials are read or
  /// retained by My Eyes.
  class UpiApp {
    const UpiApp({
      required this.label,
      required this.packageName,
      this.isPreferred = false,
    });

    final String label;
    final String packageName;

    /// True for the app My Eyes supports ([UpiPaymentService.preferredPackage]),
    /// which is launched directly instead of being asked for.
    final bool isPreferred;
  }

class UpiPaymentService {
  UpiPaymentService._();

  static const MethodChannel _channel = MethodChannel('my_eyes/upi');

  /// The payment app My Eyes supports.
  ///
  /// Google Pay. It performs its own fingerprint / face-unlock verification,
  /// so the biometric step is real and My Eyes never sees a UPI PIN.
  ///
  /// Pinned rather than chosen: a system chooser asks the user to pick an icon
  /// out of a list, which is the one part of the flow a blind user cannot do
  /// reliably. Keeping one supported app makes the launch deterministic.
  static const String preferredPackage =
      'com.google.android.apps.nbu.paisa.user';

  /// Friendly name spoken while the payment app is opening.
  static const String preferredAppName = 'Google Pay';

  /// The package My Eyes launches, mirroring the Android-side pin.
  ///
  /// Falls back to [preferredPackage] if the native bridge cannot answer, so a
  /// platform hiccup never turns into "no payment app found".
  static Future<String> resolveTargetPackage() async {
    if (kIsWeb) return preferredPackage;
    try {
      final value =
          await _channel.invokeMethod<String>('preferredPackage');
      final packageName = value?.trim() ?? '';
      return packageName.isEmpty ? preferredPackage : packageName;
    } on PlatformException {
      return preferredPackage;
    } on MissingPluginException {
      return preferredPackage;
    }
  }

  /// Returns every installed application that can handle a `upi://pay`
  /// request, with the supported app first.
  static Future<List<UpiApp>> availableApps(Uri paymentUri) async {
    if (kIsWeb) return const [];
    try {
      final apps = await _channel.invokeListMethod<dynamic>(
        'availableApps',
        {'uri': paymentUri.toString()},
      );
      if (apps == null) return const [];

      final seenPackages = <String>{};
      final result = <UpiApp>[];
      for (final value in apps) {
        if (value is! Map) continue;
        final label = value['label']?.toString().trim() ?? '';
        final packageName = value['package']?.toString().trim() ?? '';
        if (label.isEmpty ||
            packageName.isEmpty ||
            !seenPackages.add(packageName)) {
          continue;
        }
        result.add(
          UpiApp(
            label: label,
            packageName: packageName,
            isPreferred: value['preferred']?.toString().toLowerCase() == 'true',
          ),
        );
      }

      // Supported app first: callers that take the head of this list open it.
      result.sort((a, b) {
        if (a.isPreferred != b.isPreferred) return a.isPreferred ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      return result;
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// True when at least one installed app can handle a `upi://pay` request.
  static Future<bool> hasUpiApp(Uri paymentUri) async {
    return (await availableApps(paymentUri)).isNotEmpty;
  }

  /// Launches [uri] in the selected external UPI app and returns its reported
  /// status.
  ///
  /// [packageName] is passed straight through to the native bridge, which pins
  /// the intent to the exact handler activity it resolved. The result is the
  /// real transaction response; success is never assumed.
  static Future<UpiLaunchStatus> launchPayment(
    Uri uri, {
    required String packageName,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'launchPayment',
        {
          'uri': uri.toString(),
          'package': packageName,
        },
      );
      return parsePaymentStatus(
        resultOk: result?['resultOk'] as bool?,
        resultCode: result?['resultCode'] as int?,
        response: result?['response'] as String?,
      );
    } on PlatformException catch (error) {
      throw UpiLaunchException(
        error.code,
        error.message ?? 'Unable to open the payment app.',
      );
    } on MissingPluginException {
      throw const UpiLaunchException(
        'unsupported_platform',
        'UPI payments are available only through the Android app.',
      );
    }
  }
}
