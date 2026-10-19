import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Why an interactive Google account selection attempt ended.
enum AccountPickOutcome {
  picked,
  cancelled,
  interrupted,
  configurationError,
  unavailable,
}

/// The account selected in Google's own sign-in UI.
class PickedAccount {
  const PickedAccount({
    this.email,
    this.idToken,
    this.type,
    this.outcome = AccountPickOutcome.cancelled,
    this.message,
  });

  const PickedAccount.picked(String this.email, String this.idToken)
      : type = 'com.google',
        outcome = AccountPickOutcome.picked,
        message = null;

  const PickedAccount.cancelled()
      : email = null,
        idToken = null,
        type = null,
        outcome = AccountPickOutcome.cancelled,
        message = null;

  final String? email;
  final String? idToken;
  final String? type;
  final AccountPickOutcome outcome;
  final String? message;
}

/// Opens Google's authenticated account chooser.
///
/// This deliberately does not use Android's deprecated AccountManager picker.
/// The latter can open the device's "Add account" screen, which is unrelated
/// to signing in to My Eyes and is the source of the email/phone dead end.
/// Google Sign-In owns the account UI and returns only after the user picks an
/// account (or explicitly dismisses it).
class DeviceAccountService {
  DeviceAccountService._();

  /// Configure this with the *Web application* OAuth client ID from the same
  /// Google Cloud project that contains the Android OAuth client. It is kept
  /// out of source control and supplied at build/run time, for example:
  /// `--dart-define=GOOGLE_WEB_CLIENT_ID=123...apps.googleusercontent.com`.
  static const _serverClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const <String>['email'],
    serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
  );

  static bool _launching = false;
  static const Duration chooserTimeout = Duration(minutes: 5);

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _isEmail(String value) {
    final email = value.trim();
    final at = email.indexOf('@');
    return at > 0 &&
        at < email.length - 1 &&
        email.indexOf('.', at + 1) > at + 1;
  }

  /// Shows the same Google-owned account selection flow users see after
  /// pressing "Continue with Google" on a website.
  static Future<PickedAccount> pickAccount() async {
    if (!isSupported) {
      return const PickedAccount(
        outcome: AccountPickOutcome.unavailable,
        message: 'Google account selection is available on Android only.',
      );
    }
    if (_serverClientId.isEmpty) {
      return const PickedAccount(
        outcome: AccountPickOutcome.configurationError,
        message: 'GOOGLE_WEB_CLIENT_ID was not provided to Flutter.',
      );
    }
    if (_launching) {
      return const PickedAccount(
        outcome: AccountPickOutcome.interrupted,
        message: 'Google account selection is already open.',
      );
    }

    _launching = true;
    try {
      // Do not silently reuse the account selected on a previous attempt. This
      // signs out of My Eyes' Google session only; it never removes an account
      // from the phone and makes every long press show the chooser again.
      await _googleSignIn.signOut();
      final account = await _googleSignIn.signIn().timeout(chooserTimeout);
      if (account == null) return const PickedAccount.cancelled();
      if (!_isEmail(account.email)) {
        return const PickedAccount(
          outcome: AccountPickOutcome.unavailable,
          message: 'Google did not return a usable email address.',
        );
      }
      final authentication = await account.authentication;
      final token = authentication.idToken;
      if (token == null || token.isEmpty) {
        return const PickedAccount(
          outcome: AccountPickOutcome.configurationError,
          message: 'Google did not issue an ID token for this backend.',
        );
      }
      return PickedAccount.picked(account.email.trim().toLowerCase(), token);
    } on TimeoutException {
      return const PickedAccount(
        outcome: AccountPickOutcome.interrupted,
        message: 'Google account selection timed out.',
      );
    } on PlatformException catch (error) {
      // Google Play Services error 10 (DEVELOPER_ERROR) occurs after the user
      // has chosen an account when the Android OAuth client does not match this
      // APK's package name and signing SHA-1. This is a configuration problem,
      // never a cancellation, so expose it separately and keep the button live.
      final detail = '${error.code}: ${error.message ?? ''}';
      if (detail.contains('ApiException: 10') ||
          detail.contains('DEVELOPER_ERROR')) {
        debugPrint('[GOOGLE_SIGN_IN] OAuth Android client is not configured: '
            '$detail');
        return const PickedAccount(
          outcome: AccountPickOutcome.configurationError,
          message: 'Google OAuth Android client configuration does not match '
              'this app.',
        );
      }
      debugPrint('[GOOGLE_SIGN_IN] $detail');
      return PickedAccount(
        outcome: AccountPickOutcome.unavailable,
        message: detail,
      );
    } catch (error) {
      debugPrint('[GOOGLE_SIGN_IN] $error');
      return PickedAccount(
        outcome: AccountPickOutcome.unavailable,
        message: error.toString(),
      );
    } finally {
      _launching = false;
    }
  }

  @visibleForTesting
  static void debugReset() => _launching = false;
}
