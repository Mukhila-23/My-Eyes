import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import 'api_error.dart';
import 'companion.dart';

/// Result of an account creation / link / login call.
class AccountSession {
  const AccountSession({
    required this.accessToken,
    required this.created,
    required this.fullName,
    required this.email,
    required this.companion,
  });

  final String accessToken;

  /// False when an existing account was loaded instead of a new one created.
  final bool created;
  final String fullName;
  final String email;

  /// Companion id (`alex` / `maya`) stored on the account.
  final String companion;
}

/// Whether an email already has a My Eyes account.
class AccountStatus {
  const AccountStatus({required this.exists, this.fullName, this.companion});

  final bool exists;
  final String? fullName;
  final String? companion;
}

class AuthService {
  AuthService._();

  // FastAPI is served on port 8000 (see BIOMETRIC_AUTH_SETUP.md:ip
  // `uvicorn app.main:app --host 0.0.0.0 --port 8000`). Omitting the
  // port caused the app to hit port 80 and receive wrong status codes.
  // Keep the phone and FastAPI server on the same Wi-Fi network.  This is
  // deliberately the only backend address in the app: every API service
  // builds its URI from [baseUrl].
  static const String host = '192.168.29.33';
  static const int port = 8000;
  static const String baseUrl = 'http://$host:$port';

  /// Creates a new account. [companion] is the voice chosen during onboarding
  /// and is stored on the profile so every later session uses it.
  ///
  /// The device id and secret are this installation's stable identity, never a
  /// fresh random pair: see [SecureStorage.deviceIdentity] for why that matters
  /// when the same phone re-uses an account that is already registered.
  static Future<AccountSession> register({
    required String email,
    required String googleIdToken,
    String? fullName,
    String companion = 'alex',
    bool termsAccepted = true,
  }) async {
    final identity = await SecureStorage.deviceIdentity();

    final body = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'google_id_token': googleIdToken,
      'device_id': identity.deviceId,
      'device_secret': identity.deviceSecret,
      'companion': companion,
      'terms_accepted': termsAccepted,
    };

    // Optional: the server derives a display name from the email when this is
    // null, so a blind user is never asked to spell or type their name.
    if (fullName != null && fullName.trim().isNotEmpty) {
      body['full_name'] = fullName.trim();
    }

    final session = _session(
      await _post('/auth/register', body),
      fallback: 'Unable to create the account.',
    );

    await _saveEnrollment(
      email: session.email,
      deviceId: identity.deviceId,
      deviceSecret: identity.deviceSecret,
      session: session,
    );

    return session;
  }

  /// Whether [email] already has an account, so onboarding can load it instead
  /// of creating a duplicate.
  static Future<AccountStatus> accountStatus(String email, String googleIdToken) async {
    final body = _decode(
      await _post('/auth/account/status', {
        'email': email.trim().toLowerCase(),
        'google_id_token': googleIdToken,
      }),
      fallback: 'Unable to check that account.',
    );

    return AccountStatus(
      exists: body['exists'] == true,
      fullName: body['full_name']?.toString(),
      companion: body['companion']?.toString(),
    );
  }

  /// Loads an existing account onto this device.
  ///
  /// This is the "pick the same account again" path, not a takeover: the
  /// server only accepts it after the device owner passed a biometric check,
  /// and it refuses an account already paired to a *different* device id. Because
  /// [SecureStorage.deviceIdentity] is stable per installation, re-picking an
  /// already-registered account on the same phone succeeds instead of being
  /// rejected as another device.
  static Future<AccountSession> linkExistingAccount({
    required String email,
    required String googleIdToken,
  }) async {
    final identity = await SecureStorage.deviceIdentity();

    final session = _session(
      await _post('/auth/account/link', {
        'email': email.trim().toLowerCase(),
        'google_id_token': googleIdToken,
        'device_id': identity.deviceId,
        'device_secret': identity.deviceSecret,
      }),
      fallback: 'Unable to open that account.',
    );

    await _saveEnrollment(
      email: session.email,
      deviceId: identity.deviceId,
      deviceSecret: identity.deviceSecret,
      session: session,
    );

    return session;
  }

  /// Whether [email] already has a My Eyes account, so onboarding can load it
  /// instead of creating a duplicate.
  ///
  /// Returns `null` when the status could not be read. Callers must treat that
  /// as "do not know", never as "does not exist": guessing is what made a
  /// reachable account look like a new one.
  static Future<AccountStatus?> accountStatusOrNull(String email, String googleIdToken) async {
    try {
      return await accountStatus(email, googleIdToken);
    } on AuthException catch (error) {
      debugPrint('[AUTH] account status check failed: ${error.code} '
          '${error.message}');
      return null;
    } catch (error) {
      debugPrint('[AUTH] account status check failed: $error');
      return null;
    }
  }

  /// Makes [email] the account this phone uses.
  ///
  /// The single entry point behind "choose an account and use it", used by both
  /// the account-creation stage and the final confirmation stage. It removes the
  /// race that produced the dead end the user reported: the status was checked
  /// at the start of onboarding, but the create happened two screens later, so an
  /// account created in between surfaced as `EMAIL_EXISTS` and the flow finished
  /// without ever creating a device credential - leaving the phone unable to
  /// sign in next launch.
  ///
  /// Guarantees, for every outcome:
  ///  * an account that did not exist is created and enrolled,
  ///  * an account that already existed is linked and enrolled, so it behaves
  ///    exactly like "Continue with Google" on a site you have used before,
  ///  * on success the device credential is always written, which is what makes
  ///    the next launch a biometric sign-in rather than a dead end.
  static Future<AccountSession> useOrCreateAccount({
    required String email,
    required String googleIdToken,
    required String companion,
    String? fullName,
    bool termsAccepted = true,
  }) async {
    final normalized = email.trim().toLowerCase();

    final status = await accountStatusOrNull(normalized, googleIdToken);

    if (status?.exists == true) {
      try {
        return await linkExistingAccount(email: normalized, googleIdToken: googleIdToken);
      } on AuthException catch (error) {
        // Only genuinely another device, or a server that cannot see the
        // account. Anything else would be reported as a plain failure and sent
        // back to the chooser, which is where the user can actually do
        // something about it.
        if (!error.isLinkedElsewhere && !error.isAccountMissing) rethrow;
        debugPrint('[AUTH] link failed for $normalized: ${error.code}');
      }
    }

    try {
      return await register(
        email: normalized,
        googleIdToken: googleIdToken,
        fullName: fullName ?? status?.fullName,
        companion: companion,
        termsAccepted: termsAccepted,
      );
    } on AuthException catch (error) {
      if (!error.isEmailTaken) rethrow;
      // The account appeared between the status check and the create. Link it
      // now so this phone ends up with a usable credential either way.
      return linkExistingAccount(email: normalized, googleIdToken: googleIdToken);
    }
  }

  static Future<void> loginWithEnrolledDevice() async {
    final enrollment = await SecureStorage.readEnrollment();

    if (enrollment == null) {
      throw const AuthException(
        'No biometric login is set up on this device.',
      );
    }

    final response = await _post(
      '/auth/biometric/login',
      {
        'email': enrollment.email,
        'device_id': enrollment.deviceId,
        'device_secret': enrollment.deviceSecret,
      },
    );

    final session = _session(
      response,
      fallback: 'Unable to sign in on this device.',
    );

    // The stored profile is the source of truth for the voice, so refresh it
    // on every login rather than trusting a value cached on the device.
    await SecureStorage.saveAccessToken(session.accessToken);
    await SecureStorage.saveCompanion(
      name: Companions.byId(session.companion).name,
      gender: Companions.byId(session.companion).gender == CompanionGender.male
          ? 'male'
          : 'female',
    );
  }

  /// Persists the companion chosen during onboarding to the account, so the
  /// same voice is restored on the next login on any device.
  static Future<void> saveCompanionProfile(String companionId) async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) return;

    try {
      await http
          .put(
            Uri.parse('$baseUrl/profile/update'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'companion': companionId}),
          )
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // The choice is already saved on the device; the profile sync is a
      // best-effort convenience and must never block the flow.
    }
  }

  /// Switches the account's companion and returns the companion the SERVER
  /// ended up storing.
  ///
  /// Uses the dedicated `PUT /profile/companion` endpoint rather than the
  /// general profile update, so a companion switch can never send - or blank -
  /// a name or phone number by accident.
  ///
  /// Throws [AuthException] when the switch cannot be confirmed. The caller is
  /// responsible for telling the user; this never changes local state on its
  /// own, so a failed switch leaves the app and the server in agreement.
  static Future<CompanionProfile> changeCompanion(
    String companionId,
  ) async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      throw const AuthException(
        'Your session has expired. Please sign in again.',
      );
    }

    final http.Response response;
    try {
      response = await http
          .put(
            Uri.parse('$baseUrl/profile/companion'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'companion': companionId}),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const AuthException(
        "The server did not respond. I couldn't change your companion right "
        'now. Please try again.',
      );
    } on SocketException {
      throw const AuthException(
        "I couldn't change your companion right now. Please try again.",
      );
    } on http.ClientException {
      throw const AuthException(
        "I couldn't change your companion right now. Please try again.",
      );
    }

    // `_decode` already guarantees a Map<String, dynamic>, substituting the
    // fallback for a non-JSON or empty body.
    final map = _decode(response, fallback: '{}');

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          map,
          fallback:
              "I couldn't change your companion right now. Please try again.",
        ),
        code: _errorCode(map),
      );
    }

    // Trust the server's answer, not the request: a normalised value must not
    // leave the phone speaking as a different companion than the account has.
    return Companions.byId(map['companion'] as String?);
  }

  static Future<void> _saveEnrollment({
    required String email,
    required String deviceId,
    required String deviceSecret,
    required AccountSession session,
  }) async {
    final companion = Companions.byId(session.companion);

    await SecureStorage.saveEnrollment(
      email: email,
      deviceId: deviceId,
      deviceSecret: deviceSecret,
      accessToken: session.accessToken,
    );
    await SecureStorage.saveCompanion(
      name: companion.name,
      gender: companion.isMale ? 'male' : 'female',
    );
  }

  static Future<http.Response> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AuthException(
        'The server did not respond. Please check that FastAPI is running.',
      );
    } on SocketException {
      throw const AuthException(
        'Cannot connect to the server. Check Wi-Fi, IP address, and FastAPI.',
      );
    } on http.ClientException {
      throw const AuthException(
        'Cannot connect to the server. Check Wi-Fi, IP address, and FastAPI.',
      );
    }
  }

  static Map<String, dynamic> _decode(
    http.Response response, {
    required String fallback,
  }) {
    dynamic body;
    try {
      body = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    } catch (_) {
      body = <String, dynamic>{};
    }

    final map = body is Map<String, dynamic> ? body : <String, dynamic>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body is Map<String, dynamic> ? body : null,
          fallback: fallback,
        ),
        code: _errorCode(map),
      );
    }

    return map;
  }

  /// Pulls the structured `error.code` so callers can branch on the cause
  /// instead of matching an English message.
  static String _errorCode(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      return error['code']?.toString() ?? '';
    }
    return '';
  }

  static AccountSession _session(
    http.Response response, {
    required String fallback,
  }) {
    final map = _decode(response, fallback: fallback);

    final token = map['access_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const AuthException('The server returned an invalid session.');
    }

    return AccountSession(
      accessToken: token,
      created: map['created'] != false,
      fullName: map['full_name']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      companion: Companions.byId(map['companion']?.toString()).id,
    );
  }
}

class AuthException implements Exception {
  const AuthException(this.message, {this.code = ''});

  final String message;

  /// Backend error code, e.g. `EMAIL_EXISTS`, `TERMS_NOT_ACCEPTED`.
  final String code;

  bool get isEmailTaken => code == 'EMAIL_EXISTS';
  bool get isTermsRejected => code == 'TERMS_NOT_ACCEPTED';
  bool get isLinkedElsewhere => code == 'ACCOUNT_LINKED_ELSEWHERE';
  bool get isAccountMissing => code == 'ACCOUNT_NOT_FOUND';

  @override
  String toString() => message;
}
