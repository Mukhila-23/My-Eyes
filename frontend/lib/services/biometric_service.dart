import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._();
  static final _auth = LocalAuthentication();

  /// True when the device supports the app's behavior and has at least one
  /// enrolled strong biometric (fingerprint/face/etc.). Used to decide how
  /// the startup screen should behave.
  static Future<bool> canAuthenticate() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.contains(BiometricType.fingerprint) ||
          enrolled.contains(BiometricType.strong) ||
          enrolled.contains(BiometricType.face) ||
          enrolled.contains(BiometricType.weak) ||
          enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Launches Android biometric authentication via [local_auth] within My
  /// Eyes. Android performs the verification; My Eyes only learns
  /// success/failure. Fingerprint data is never exposed to or sent to the
  /// backend.
  ///
  /// When [allowDeviceFallback] is true, [local_auth] also lets the system
  /// fall back to the device credential (PIN/pattern/password) that the user
  /// already set up on the phone. My Eyes never reads or stores that
  /// credential — it is handled natively by the operating system.
  static Future<BiometricResult> authenticate({
    bool allowDeviceFallback = false,
  }) async {
    final supported = await _auth.isDeviceSupported();
    final enrolled = await _auth.getAvailableBiometrics();
    final hasBiometrics = enrolled.isNotEmpty;
    if (!supported || !hasBiometrics) {
      return BiometricResult.failure(
        'Set up a fingerprint or another device unlock method in Android '
        'settings first.',
      );
    }

    try {
      final authenticated = await _auth.authenticate(
        localizedReason: 'Verify your fingerprint to access My Eyes',
        options: AuthenticationOptions(
          biometricOnly: !allowDeviceFallback,
          stickyAuth: true,
          sensitiveTransaction: true,
          useErrorDialogs: true,
        ),
      );
      return authenticated
          ? const BiometricResult.success()
          : const BiometricResult.failure('Biometric verification was cancelled.');
    } catch (_) {
      return const BiometricResult.failure(
        'Biometric verification is unavailable. Please try again.',
      );
    }
  }
}

class BiometricResult {
  const BiometricResult.success() : authenticated = true, message = null;
  const BiometricResult.failure(this.message) : authenticated = false;

  final bool authenticated;
  final String? message;
}
