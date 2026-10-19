import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../services/companion.dart';
import '../../services/post_login_coordinator.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';
import '../dashboard/dashboard_screen.dart';
import '../onboarding/welcome_screen.dart';

/// Secure, fingerprint-first startup screen for an already-registered device.
///
/// Flow:  welcome message -> Android biometric dialog (local_auth) ->
///   * success: best-effort token refresh, then open Dashboard. The Dashboard
///     initializes the companion TTS voice + microphone exactly once.
///   * failure: short retry message; up to 3 retries, then the OS device
///     credential (PIN/pattern/password) via local_auth.
///
/// When the fingerprint is genuinely not recognized *and* this device has no
/// My Eyes account, the user is offered the account-creation flow ("I don't
/// recognize this fingerprint. Would you like to create a new account?").
/// A device that already holds an enrollment is never pushed into registration:
/// an existing user must not be made to create a second account because their
/// finger was not read.
///
/// A failed or cancelled biometric otherwise keeps the user safely on this
/// screen with Try Again / Exit. Biometric + microphone are never run at the
/// same time here (no speech-recognition listener is started in this screen),
/// so there is no duplicate-listener or race condition.
class AuthGateScreen extends StatefulWidget {
  const AuthGateScreen({super.key});

  @override
  State<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends State<AuthGateScreen> {
  static const int maxRetries = 3;

  final _voice = VoiceGuide.instance;

  bool _busy = false; // guards against launching two dialogs at once.
  bool _exiting = false;
  bool _started = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _busy = false;
    _voice.stop();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_started || !mounted) return;
    _started = true;

    await _voice.speak('Welcome back. Please use your fingerprint.');
    if (!mounted) return;

    unawaited(_attemptBiometric());
  }

  Future<void> _attemptBiometric() async {
    if (_busy || !mounted) return;
    _busy = true;

    // Guard: if biometric isn't available, offer the device credential.
    if (!await BiometricService.canAuthenticate()) {
      _busy = false;
      await _fallbackToDeviceCredential();
      return;
    }

    final result = await BiometricService.authenticate();
    if (!mounted) return;
    _busy = false;

    if (result.authenticated) {
      await _onAuthenticated();
      return;
    }

    _attempts++;
    if (!mounted) return;

    if (_attempts >= maxRetries) {
      await _fallbackToDeviceCredential();
      return;
    }

    await _voice.speak('Fingerprint not recognized. Please try again.');
    if (!mounted) return;

    // Automatic retry after a short pause so a blind user does not have to
    // hunt for a button.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    unawaited(_attemptBiometric());
  }

  Future<void> _fallbackToDeviceCredential() async {
    if (_busy || !mounted) return;
    _busy = true;

    await _voice.speak('Please use your device unlock method.');
    if (!mounted) return;

    // Allow the OS to fall back to the device PIN/pattern/password. My Eyes
    // never reads or stores that credential; Android handles it natively.
    final result =
        await BiometricService.authenticate(allowDeviceFallback: true);
    if (!mounted) return;
    _busy = false;

    if (result.authenticated) {
      await _onAuthenticated();
      return;
    }

    // The fingerprint was not recognized. Only offer to create an account when
    // this device has none: an enrolled device is an existing user, and must
    // never be pushed through registration again.
    final enrollment = await SecureStorage.readEnrollment();
    if (!mounted) return;

    if (enrollment == null) {
      await _offerCreateAccount();
      return;
    }

    await _voice.speak('Authentication cancelled. You can try again or exit.');
    _resetForRetry();
  }

  /// Spoken offer for a genuinely new user on a device with no account.
  Future<void> _offerCreateAccount() async {
    await _voice.speak(
      'I don\'t recognize this fingerprint. '
      'Would you like to create a new account?',
      pace: TtsPace.important,
      remember: false,
    );
    if (!mounted) return;

    final answer = (await _voice.listenOnce() ?? '').toLowerCase();
    if (!mounted) return;

    if (_isYes(answer)) {
      _openRegister();
      return;
    }

    if (_isNo(answer)) {
      await _voice.speak('Okay. You can try again or exit.');
      _resetForRetry();
      return;
    }

    // Unclear answer: ask once more, never assume yes.
    await _voice.speak(
      'I did not hear a clear answer. '
      'Say yes to create a new account, or no to go back.',
      remember: false,
    );
    if (!mounted) return;

    final retry = (await _voice.listenOnce() ?? '').toLowerCase();
    if (!mounted) return;

    if (_isYes(retry)) {
      _openRegister();
      return;
    }

    await _voice.speak('Okay. You can try again or exit.');
    _resetForRetry();
  }

  bool _isYes(String text) =>
      text.contains('yes') || text.contains('yeah') || text.contains('yep');

  bool _isNo(String text) =>
      text.trim() == 'no' ||
      text.startsWith('no ') ||
      text.contains('nah') ||
      text.contains('nope');

  /// Sends a genuinely new user back to the start of the first-run flow. The
  /// welcome replays its greeting and hands over to account creation, so no
  /// stage is skipped even though the fingerprint check was reached first.
  void _openRegister() {
    if (!mounted) return;
    _voice.stop();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  Future<void> _onAuthenticated() async {
    // Authenticated: reset retry state on success (spec requirement).
    _attempts = 0;
    if (!mounted) return;

    // Best-effort token refresh against the backend. The on-device secure
    // session (enrollment + existing access token) is already the source of
    // truth at startup, so a transiently-unreachable server must not block
    // the authenticated user or force a re-login.
    try {
      await AuthService.loginWithEnrolledDevice();
    } catch (_) {
      // Keep the existing secure session; opening the dashboard is still safe.
    }

    if (!mounted) return;

    // Read the companion AFTER the refresh: loginWithEnrolledDevice writes the
    // server's stored preference back into secure storage, so this is the
    // account's choice rather than a stale local value.
    var companion = await SecureStorage.readCompanion();
    if (!mounted) return;

    await _voice.speak('Welcome back.');
    if (!mounted) return;

    _voice.stop();

    // Profile -> companion -> SOS check -> (setup) -> dashboard.
    // The coordinator owns that sequence so the splash path and any future
    // login entry point behave identically.
    final companionProfile = Companions.fromStored(
      name: companion.name,
      gender: companion.gender,
    );

    await PostLoginCoordinator.run(context);

    if (!mounted) return;

    // Re-read: the setup flow may have changed nothing about the companion, but
    // this keeps the dashboard's constructor honest about where its value came
    // from.
    companion = await SecureStorage.readCompanion();
    debugPrint(
      '[AUTH] opening dashboard as ${companion.name} (${companion.gender})',
    );

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          companionName: companion.name,
          companionGender: companion.gender,
          companionProfile: companionProfile,
        ),
      ),
    );
  }

  void _resetForRetry() {
    if (!mounted) return;
    setState(() => _attempts = 0);
  }

  void _tryAgain() {
    if (_busy || _exiting) return;
    _resetForRetry();
    unawaited(_attemptBiometric());
  }

  void _exit() {
    if (_exiting) return;
    _exiting = true;
    _voice.stop();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [
                          AppTheme.primaryLight,
                          AppTheme.primary,
                          Color(0xFF151A32),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.4),
                          blurRadius: 45,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.fingerprint_rounded,
                      color: Colors.white,
                      size: 60,
                    ),
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    'MY EYES',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Use your fingerprint or device unlock to continue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 34),
                  SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _tryAgain,
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: const Text('TRY AGAIN'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _exit,
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('EXIT'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}