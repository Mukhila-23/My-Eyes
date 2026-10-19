import '../storage/secure_storage.dart';

/// How far through the first-run setup the user got.
///
/// The flow is strictly:
/// `welcome -> account -> chooser -> confirm -> companion -> instructions ->
/// dashboard`.
///
/// Every stage writes its flag the moment it is genuinely complete (not when it
/// is merely displayed), so closing the app mid-setup resumes at the next real
/// step instead of restarting from the beginning.
class OnboardingProgress {
  const OnboardingProgress({
    this.welcomeCompleted = false,
    this.accountSelected = false,
    this.email,
    this.companionSelected = false,
    this.companionId,
    this.instructionsCompleted = false,
  });

  /// The spoken welcome has played and account creation was reached.
  final bool welcomeCompleted;

  /// An email from the Android account chooser was confirmed by the user.
  final bool accountSelected;

  /// The confirmed email address. Never guessed or typed by the user.
  final String? email;

  final bool companionSelected;

  /// `alex` / `maya`.
  final String? companionId;

  final bool instructionsCompleted;

  bool get hasEmail => (email ?? '').isNotEmpty;

  bool get hasCompanion => (companionId ?? '').isNotEmpty;

  /// True once the account exists on the backend and the dashboard may open.
  bool get onboardingCompleted =>
      welcomeCompleted &&
      accountSelected &&
      hasEmail &&
      companionSelected &&
      hasCompanion &&
      instructionsCompleted;

  OnboardingProgress copyWith({
    bool? welcomeCompleted,
    bool? accountSelected,
    String? email,
    bool? companionSelected,
    String? companionId,
    bool? instructionsCompleted,
  }) {
    return OnboardingProgress(
      welcomeCompleted: welcomeCompleted ?? this.welcomeCompleted,
      accountSelected: accountSelected ?? this.accountSelected,
      email: email ?? this.email,
      companionSelected: companionSelected ?? this.companionSelected,
      companionId: companionId ?? this.companionId,
      instructionsCompleted: instructionsCompleted ?? this.instructionsCompleted,
    );
  }
}

/// Reads and writes [OnboardingProgress].
///
/// Backed by [SecureStorage], i.e. `EncryptedSharedPreferences`, so the chosen
/// email never lands in plain `SharedPreferences`. `SecureStorage.clear()` on
/// logout wipes these keys together with the enrollment, which is what makes
/// "log out" return a user to the first-run flow.
class OnboardingProgressStore {
  const OnboardingProgressStore._();

  static Future<OnboardingProgress> read() async {
    try {
      final flags = await SecureStorage.readOnboardingFlags();
      return OnboardingProgress(
        welcomeCompleted: flags.$1,
        accountSelected: flags.$2,
        email: flags.$3,
        companionSelected: flags.$4,
        companionId: flags.$5,
        instructionsCompleted: flags.$6,
      );
    } catch (_) {
      // Storage unreadable: treat the app as brand new rather than trapping
      // the user on a blank screen.
      return const OnboardingProgress();
    }
  }

  static Future<void> save(OnboardingProgress progress) =>
      SecureStorage.writeOnboardingFlags(
        welcomeCompleted: progress.welcomeCompleted,
        accountSelected: progress.accountSelected,
        email: progress.email,
        companionSelected: progress.companionSelected,
        companionId: progress.companionId,
        instructionsCompleted: progress.instructionsCompleted,
      );
}