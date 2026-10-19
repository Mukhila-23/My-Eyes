import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  SecureStorage._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _emailKey = 'auth_email';
  static const _deviceIdKey = 'auth_device_id';
  static const _deviceSecretKey = 'auth_device_secret';
  static const _tokenKey = 'auth_token';
  static const _companionNameKey = 'companion_name';
  static const _companionGenderKey = 'companion_gender';
  static const _sosContactsKey = 'sos_contacts_v1';

  /// Randomness for the device identity. `Random.secure` is required: this
  /// secret is what the server checks a biometric login against.
  static final Random _random = Random.secure();

  // First-run onboarding progress. Kept in the same encrypted store as the
  // enrollment: the chosen email is personal data and must never fall back to
  // plain SharedPreferences just because it is not a credential.
  static const _obWelcomeKey = 'onboarding_welcome';
  static const _obAccountKey = 'onboarding_account';
  static const _obEmailKey = 'onboarding_email';
  static const _obCompanionKey = 'onboarding_companion';
  static const _obCompanionIdKey = 'onboarding_companion_id';
  static const _obInstructionsKey = 'onboarding_instructions';

  /// The stable identity of THIS installation.
  ///
  /// A phone is one device, so this must be created once and then reused for
  /// the lifetime of the install. It used to be generated fresh on every
  /// register/link call, which is what made "choose an account" unusable: the
  /// server pairs an account to the device that first claimed it and refuses a
  /// *different* device id with `ACCOUNT_LINKED_ELSEWHERE`. So re-picking an
  /// account that already had a My Eyes account - on the same phone, from the
  /// same chooser - was rejected as "connected to another phone" and the flow
  /// dead-ended.
  ///
  /// Reusing the existing `auth_device_id` / `auth_device_secret` values also
  /// repairs installs that already enrolled: the id the server knows keeps
  /// being presented, so linking becomes idempotent instead of a conflict.
  static Future<DeviceIdentity> deviceIdentity() async {
    final storedId = await _storage.read(key: _deviceIdKey);
    final storedSecret = await _storage.read(key: _deviceSecretKey);

    if (storedId != null &&
        storedId.isNotEmpty &&
        storedSecret != null &&
        storedSecret.isNotEmpty) {
      return DeviceIdentity(storedId, storedSecret);
    }

    // Only one of the two can exist if a previous write was interrupted; treat
    // that as no identity at all rather than pairing a stale id with a new
    // secret.
    final identity = DeviceIdentity(_randomUrlSafeValue(16), _randomUrlSafeValue(32));
    await _storage.write(key: _deviceIdKey, value: identity.deviceId);
    await _storage.write(key: _deviceSecretKey, value: identity.deviceSecret);
    return identity;
  }

  static String _randomUrlSafeValue(int bytes) {
    return base64UrlEncode(
      List<int>.generate(bytes, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
  }

  static Future<void> saveEnrollment({
    required String email,
    required String deviceId,
    required String deviceSecret,
    required String accessToken,
  }) async {
    await _storage.write(key: _emailKey, value: email);
    await _storage.write(key: _deviceIdKey, value: deviceId);
    await _storage.write(key: _deviceSecretKey, value: deviceSecret);
    await _storage.write(key: _tokenKey, value: accessToken);
  }

  static Future<StoredEnrollment?> readEnrollment() async {
    final email = await _storage.read(key: _emailKey);
    final deviceId = await _storage.read(key: _deviceIdKey);
    final deviceSecret = await _storage.read(key: _deviceSecretKey);
    if (email == null || deviceId == null || deviceSecret == null) return null;
    return StoredEnrollment(email, deviceId, deviceSecret);
  }

  static Future<void> saveAccessToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  static Future<String?> readAccessToken() => _storage.read(key: _tokenKey);

  static Future<void> clear() => _storage.deleteAll();

  static Future<void> saveCompanion({
    required String name,
    required String gender,
  }) async {
    await _storage.write(key: _companionNameKey, value: name);
    await _storage.write(key: _companionGenderKey, value: gender);
  }

  static Future<StoredCompanion> readCompanion() async => StoredCompanion(
        await _storage.read(key: _companionNameKey) ?? 'ALEX',
        await _storage.read(key: _companionGenderKey) ?? 'male',
      );

  static Future<void> saveSosContacts(String json) =>
      _storage.write(key: _sosContactsKey, value: json);

  static Future<String?> readSosContacts() =>
      _storage.read(key: _sosContactsKey);

  /// Returns
  /// `(welcomeCompleted, accountSelected, email, companionSelected,
  ///   companionId, instructionsCompleted)`.
  static Future<(bool, bool, String?, bool, String?, bool)>
      readOnboardingFlags() async {
    final values = await Future.wait([
      _storage.read(key: _obWelcomeKey),
      _storage.read(key: _obAccountKey),
      _storage.read(key: _obEmailKey),
      _storage.read(key: _obCompanionKey),
      _storage.read(key: _obCompanionIdKey),
      _storage.read(key: _obInstructionsKey),
    ]);

    final email = values[2];
    final companionId = values[4];

    return (
      values[0] == 'true',
      values[1] == 'true',
      // An "account selected" flag without an address is meaningless, so the
      // address is the source of truth.
      email != null && email.isNotEmpty ? email : null,
      values[3] == 'true',
      companionId != null && companionId.isNotEmpty ? companionId : null,
      values[5] == 'true',
    );
  }

  /// Written after each stage completes, so the next launch resumes at the
  /// right step. Each flag is written independently: a partial write can never
  /// claim a later stage is done.
  static Future<void> writeOnboardingFlags({
    required bool welcomeCompleted,
    required bool accountSelected,
    required String? email,
    required bool companionSelected,
    required String? companionId,
    required bool instructionsCompleted,
  }) async {
    await _storage.write(
      key: _obWelcomeKey,
      value: welcomeCompleted ? 'true' : 'false',
    );
    await _storage.write(
      key: _obAccountKey,
      value: accountSelected ? 'true' : 'false',
    );
    await _storage.write(key: _obEmailKey, value: email);
    await _storage.write(
      key: _obCompanionKey,
      value: companionSelected ? 'true' : 'false',
    );
    await _storage.write(key: _obCompanionIdKey, value: companionId);
    await _storage.write(
      key: _obInstructionsKey,
      value: instructionsCompleted ? 'true' : 'false',
    );
  }
}

class StoredEnrollment {
  const StoredEnrollment(this.email, this.deviceId, this.deviceSecret);

  final String email;
  final String deviceId;
  final String deviceSecret;
}

/// This phone's persistent identity, independent of which account is currently
/// enrolled on it. Created once and reused forever.
class DeviceIdentity {
  const DeviceIdentity(this.deviceId, this.deviceSecret);

  final String deviceId;
  final String deviceSecret;
}

class StoredCompanion {
  const StoredCompanion(this.name, this.gender);
  final String name;
  final String gender;
}