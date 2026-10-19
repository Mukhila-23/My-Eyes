import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/onboarding/onboarding_progress.dart';
import '../../core/theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../services/companion.dart';
import '../../services/device_account_service.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';
import '../../widgets/long_press_confirm.dart';
import '../dashboard/dashboard_screen.dart';
import 'companion_selection_screen.dart';
import 'instruction_screen.dart';

/// Explicit states of the account-creation stage.
///
/// Every path through this screen - success, cancel, back, error, exception -
/// ends in [idle]. That is what makes the second long press behave exactly like
/// the first one: there is no flag anywhere that survives the attempt.
enum AccountStage {
  /// Nothing in flight. The long press is armed.
  idle,

  /// A finger is down and the hold is filling.
  longPress,

  /// The native account chooser is on screen. This is the only state in which
  /// an Android BACK press is expected, and it always returns to [idle].
  chooserOpen,

  /// The email is confirmed and the account is being registered.
  registering,
}

/// Stage 2 of the first-run flow: create the account.
///
/// The whole screen is one giant long-press target covering roughly half the
/// usable area, centred, because the user cannot see a small button and must
/// be able to find it by touch in the middle of the display.
///
/// Interaction contract:
///   * the instructions are spoken automatically when the screen opens,
///   * touching down says "Opening the list of accounts" once, so the user
///     knows the app noticed - it is never repeated while the finger is down,
///   * releasing early says exactly why nothing happened,
///   * completing the hold opens Google's authenticated account chooser - the
///     same flow a "Continue with Google" button shows,
///   * the chosen address is read back and confirmed out loud - the app never
///     advances silently,
///   * an address that already has a My Eyes account opens it rather than
///     creating a second one,
///   * a cancelled, backed-out, or failed result returns the screen to
///     [AccountStage.idle] with a short spoken explanation and a working button.
class AccountCreationScreen extends StatefulWidget {
  const AccountCreationScreen({super.key});

  @override
  State<AccountCreationScreen> createState() => _AccountCreationScreenState();
}

class _AccountCreationScreenState extends State<AccountCreationScreen> {
  final VoiceGuide _voice = VoiceGuide.instance;

  /// Used to deterministically re-arm the long press after any attempt, so the
  /// next press is identical to the first one. See [LongPressConfirmState.reset].
  final GlobalKey<LongPressConfirmState> _holdKey =
      GlobalKey<LongPressConfirmState>();

  String? _email;
  String? _googleIdToken;
  AccountStage _stage = AccountStage.idle;

  /// Guards against a second long press launching a second chooser while the
  /// first is still opening. Always cleared in [finally].
  bool _launching = false;

  bool _announced = false;
  bool _cancelled = false;

  bool get _busy =>
      _stage == AccountStage.chooserOpen ||
      _stage == AccountStage.registering;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _announce());
  }

  @override
  void dispose() {
    _voice.stop();
    super.dispose();
  }

  // ============================================================
  // STATE MACHINE TRANSITIONS
  // ============================================================

  void _enter(AccountStage stage) {
    if (!mounted) return;
    setState(() => _stage = stage);
  }

  /// The single place that returns to IDLE. Everything that can end an attempt
  /// - success, cancel, error, exception - funnels through here so no path can
  /// leave the screen locked.
  void _returnToIdle() {
    if (!mounted) return;
    setState(() => _stage = AccountStage.idle);
    // Re-arm the button. Without this the first hold would be consumed for the
    // lifetime of the State and every later press would be silently ignored.
    _holdKey.currentState?.reset();
  }

  // ============================================================
  // OPENING INSTRUCTIONS
  // ============================================================

  Future<void> _announce() async {
    if (_announced || !mounted) return;
    _announced = true;

    // Resume point: if an email was already confirmed, do not ask for it again.
    final progress = await OnboardingProgressStore.read();
    if (!mounted) return;
    if (progress.hasEmail) {
      setState(() => _email = progress.email);
      await _voice.speak(
        'Account creation is ready. '
        'Your account $progress.email is already selected. '
        'Place your finger in the middle of the screen and press and hold the '
        'large button.',
        remember: true,
      );
      return;
    }

    await _voice.speak('Welcome to My Eyes.', remember: true);
    if (!mounted) return;

    await _voice.speak('Account creation is ready.', remember: false);
    if (!mounted) return;

    await _voice.speak(
      'To create your account, place your finger in the middle of the screen '
      'and press and hold the large button.',
      remember: false,
    );
    if (!mounted) return;

    await _voice.speak('Keep holding until I tell you to release.',
        remember: false);
  }

  // ============================================================
  // LONG-PRESS FEEDBACK
  // ============================================================

  /// Fired on touch-down, before the hold completes.
  ///
  /// Announced exactly once per press. The finger stays down for the whole
  /// duration, so re-speaking here would produce the same sentence over and
  /// over while the user is holding.
  Future<void> _onHoldStart() async {
    if (_launching || _cancelled) return;
    await _voice.stopSpeakingOnly();
    if (!mounted) return;
    await _voice.speakImportant('Opening the list of accounts.');
  }

  Future<void> _onHoldCancelled() async {
    if (_launching || _cancelled) return;
    await _voice.speak(
      'The button was released too early. '
      'Place your finger in the middle and press and hold again.',
      pace: TtsPace.important,
      remember: false,
    );
  }

  // ============================================================
  // ACCOUNT CHOOSER
  // ============================================================

  Future<void> _beginAccountCreation() async {
    // A second press while an attempt is in flight must not open a second
    // chooser. This is the "long press twice rapidly" case.
    if (_launching || !mounted) return;
    _launching = true;

    try {
      // Nothing to do when an email is already confirmed: this is the resume
      // path and the user is confirming, not choosing.
      if (_email != null && _email!.isNotEmpty) {
        // A Google ID token is intentionally memory-only. If an interrupted
        // onboarding resume has only an old email, make the user choose again
        // so FastAPI receives a fresh, verifiable Google identity.
        if (_googleIdToken == null || _googleIdToken!.isEmpty) {
          setState(() => _email = null);
        } else {
          await _voice.stopSpeakingOnly();
          if (!mounted) return;
          await _confirmEmail(_email!, _googleIdToken!);
          return;
        }
      }

      // Do not await a spoken lead-in here. In the recorded failure, the screen
      // entered its disabled "PLEASE WAIT" state and remained there while TTS
      // was finishing, so Google's account sheet had not even been requested.
      // The native request must be the next operation after the long press.
      _enter(AccountStage.chooserOpen);
      final picked = await DeviceAccountService.pickAccount();
      if (!mounted) return;

      switch (picked.outcome) {
        case AccountPickOutcome.picked:
          final email = picked.email!;
          final googleIdToken = picked.idToken!;
          setState(() {
            _email = email;
            _googleIdToken = googleIdToken;
          });
          await _confirmEmail(email, googleIdToken);
          return;

        case AccountPickOutcome.cancelled:
        case AccountPickOutcome.interrupted:
          // BACK or cancel in the chooser. Same handling either way: a short
          // spoken note and straight back to a working button.
          await _handleCancelled();
          return;

        case AccountPickOutcome.configurationError:
          await _returnToIdleAndSpeak(
            'Google rejected this app configuration after account selection. '
            'The My Eyes developer must register this app package and signing '
            'certificate in Google Cloud. Nothing was created. You can try '
            'again once that setup is complete.',
          );
          return;

        case AccountPickOutcome.unavailable:
          await _returnToIdleAndSpeak(
            'Google sign in could not be opened. Nothing was created and '
            'nothing was saved. Please check the Google sign-in setup, then '
            'press and hold the large button to try again.',
          );
          return;
      }
    } on AuthException catch (error) {
      // Unexpected, but must never leave the button locked.
      await _returnToIdleAndSpeak(
        'I could not finish choosing an account. ${error.message} '
        'Nothing was created. Press and hold the large button to try again.',
      );
    } catch (error) {
      debugPrint('[ACCOUNT] chooser failed: $error');
      await _returnToIdleAndSpeak(
        'Something went wrong while opening the account chooser. '
        'Nothing was created. '
        'Press and hold the large button to try again.',
      );
    } finally {
      // Deterministic cleanup: no matter how this method exits, the launch lock
      // is released. Together with [_returnToIdle] this guarantees the next
      // long press is accepted.
      _launching = false;
      if (mounted && _stage == AccountStage.chooserOpen) {
        _returnToIdle();
      }
    }
  }

  /// Returns to IDLE first, then speaks. The order matters: the button is usable
  /// again before the (slower) speech begins, so the user can act immediately
  /// even if TTS is slow to start.
  Future<void> _returnToIdleAndSpeak(String message) async {
    _returnToIdle();
    await _voice.speak(message, pace: TtsPace.important, remember: false);
  }

  Future<void> _handleCancelled() async {
    _returnToIdle();
    await _voice.speak(
      'Account selection cancelled. '
      'You can try again by pressing and holding the button.',
      pace: TtsPace.important,
      remember: false,
    );
  }

  // ============================================================
  // CONFIRMATION
  // ============================================================

  Future<void> _confirmEmail(String email, String googleIdToken) async {
    // Confirmed by voice, never by a text field: a blind user is never asked to
    // spell or type an address, so a mis-picked account is the only failure mode
    // and it is undone by picking again.
    await _voice.speak('You selected $email.',
        pace: TtsPace.important, remember: true);
    if (!mounted) return;

    await _continueAfterAccount(email, googleIdToken);
  }

  Future<void> _continueAfterAccount(String email, String googleIdToken) async {
    _enter(AccountStage.registering);

    // The account that already exists is opened, never re-created. A null status
    // means the server could not be asked - that is "unknown", not "new", and
    // it must not be treated as permission to create a duplicate.
    final status = await AuthService.accountStatusOrNull(email, googleIdToken);
    if (!mounted) return;

    if (status?.exists == true) {
      await _loadExistingAccount(email, googleIdToken);
      return;
    }

    if (status == null) {
      await _voice.speak(
        'I could not check whether this account already exists, '
        'so I will not create a second one. '
        'Please check that the My Eyes server is running, '
        'then press and hold the large button to try again.',
        pace: TtsPace.important,
        remember: false,
      );
      _returnToIdle();
      return;
    }

    final companionId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CompanionSelectionScreen()),
    );
    if (!mounted) return;

    if (companionId == null || companionId.isEmpty) {
      // The user backed out of companion selection. Return to IDLE so the
      // button works again if they want to pick a different account.
      _returnToIdle();
      await _voice.speak(
        'Companion choice cancelled. Your account was not created yet. '
        'Place your finger in the middle of the screen and press and hold the '
        'large button to choose a companion again.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InstructionScreen(
          email: email,
          companionId: companionId,
          googleIdToken: googleIdToken,
        ),
      ),
    );
    if (!mounted) return;

    if (done != true) {
      _returnToIdle();
      await _voice.speak(
        'Setup was not completed. Your account was not created. '
        'Press and hold the large button to continue.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }
    // The instruction screen registered the account and replaced this route.
  }

  /// Existing account on this email: verify the owner with a biometric check
  /// and open the dashboard instead of creating a duplicate.
  Future<void> _loadExistingAccount(String email, String googleIdToken) async {
    await _voice.speak(
      'This account is already set up for My Eyes. '
      'Please place your finger on the sensor to open it.',
      pace: TtsPace.important,
      remember: false,
    );
    if (!mounted) return;

    final biometric = await BiometricService.authenticate();
    if (!mounted) return;

    if (!biometric.authenticated) {
      _returnToIdle();
      await _voice.speak(
        'I could not verify that it is you, so nothing was changed. '
        'Place your finger on the sensor and try again, '
        'or press and hold the large button to choose another account.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    try {
      final session = await AuthService.linkExistingAccount(
        email: email,
        googleIdToken: googleIdToken,
      );
      if (!mounted) return;

      final companion = Companions.byId(session.companion);

      final progress = await OnboardingProgressStore.read();
      await OnboardingProgressStore.save(
        progress.copyWith(
          welcomeCompleted: true,
          accountSelected: true,
          email: email,
          companionSelected: true,
          companionId: companion.id,
          instructionsCompleted: true,
        ),
      );
      if (!mounted) return;

      await _voice.speak(
        'Welcome back. Your account is ready and ${companion.name} will speak '
        'for you. Opening your dashboard.',
        remember: false,
      );
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            companionName: companion.name,
            companionGender: companion.isMale ? 'male' : 'female',
          ),
        ),
      );
    } on AuthException catch (error) {
      if (error.isLinkedElsewhere) {
        // The only genuinely blocked case: this exact account is paired to a
        // different phone. Say what to do instead of only what went wrong, so
        // the user has a way forward from where they are.
        await _returnToIdleAndSpeak(
          'That account is already set up on a different phone. '
          'Please use that phone instead, or press and hold the large button '
          'to choose another account. Nothing was changed here.',
        );
        return;
      }
      if (error.isAccountMissing) {
        // The status check said the account exists but the server no longer has
        // it, so continue as a new account rather than dead-ending.
        await _voice.speak(
          'That account is no longer on the server, so I will set it up again. '
          'Please wait.',
          pace: TtsPace.important,
          remember: false,
        );
        if (!mounted) return;
        await _continueAfterAccount(email, googleIdToken);
        return;
      }
      await _returnToIdleAndSpeak(
        'I could not open that account. ${error.message} '
        'Nothing was changed. Press and hold the large button to try again.',
      );
    } catch (error) {
      debugPrint('[ACCOUNT] link existing failed: $error');
      await _returnToIdleAndSpeak(
        'Something went wrong while opening that account. '
        'Nothing was changed. Press and hold the large button to try again.',
      );
    }
  }

  // ============================================================
  // CANCEL
  // ============================================================

  Future<void> _cancelFlow() async {
    if (_cancelled || !mounted) return;
    setState(() => _cancelled = true);

    await _voice.stopSpeakingOnly();
    if (!mounted) return;

    await _voice.speak(
      'Account creation cancelled. Nothing was created and nothing was saved.',
      pace: TtsPace.important,
      remember: false,
    );
  }

  Future<void> _retry() async {
    if (_busy || !mounted) return;
    setState(() {
      _cancelled = false;
      _email = null;
    });
    _holdKey.currentState?.reset();
    await _announce();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (_cancelled) return _buildCancelled();

    final email = _email;
    final hasAccount = email != null && email.isNotEmpty;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            children: [
              Semantics(
                header: true,
                child: const Text(
                  'Create your account',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                label: hasAccount
                    ? 'You selected $email. Press and hold the large button to '
                        'continue.'
                    : 'To create your account, place your finger in the middle '
                        'of the screen and press and hold the large button. '
                        'Keep holding until I tell you to release.',
                child: Text(
                  hasAccount
                      ? 'You selected $email.\nPress and hold to continue.'
                      : 'Place your finger in the middle of the screen and '
                          'press and hold.\nKeep holding until I tell you to '
                          'release.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 17,
                    height: 1.45,
                  ),
                ),
              ),

              // Roughly half the usable screen, dead centre, so it can be found
              // by touch alone.
              const SizedBox(height: 22),
              Expanded(
                flex: 5,
                child: Center(
                  child: Semantics(
                    container: true,
                    label: 'Large centre button. Create account. '
                        'Press and hold.',
                    child: LongPressConfirm(
                      key: _holdKey,
                      fill: true,
                      busy: _busy,
                      onHoldStart: _onHoldStart,
                      onHoldCancelled: _onHoldCancelled,
                      label: hasAccount
                          ? 'HOLD TO\nCONTINUE'
                          : 'PRESS AND HOLD\nTO CREATE YOUR ACCOUNT',
                      semanticLabel: hasAccount
                          ? 'Continue with the selected account $email. '
                              'Press and hold.'
                          : 'Create account. Press and hold.',
                      semanticHint: hasAccount
                          ? 'Press and hold for one second to continue with '
                              '$email. A tap does nothing.'
                          : 'Press and hold for one second to open Google '
                              'account selection. A tap does nothing.',
                      icon: hasAccount
                          ? Icons.arrow_forward_rounded
                          : Icons.person_add_alt_1_rounded,
                      onConfirmed: _beginAccountCreation,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Secondary actions stay full width and large; nothing here is the
              // only way forward.
              SizedBox(
                width: double.infinity,
                height: 60,
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _voice.speak(
                            hasAccount
                                ? 'You selected $email. '
                                    'Place your finger in the middle of the '
                                    'screen and press and hold the large button '
                                    'to continue, or say choose another account '
                                    'to pick a different one.'
                                : 'To create your account, place your finger in '
                                    'the middle of the screen and press and hold '
                                    'the large button. Keep holding until I tell '
                                    'you to release.',
                            remember: true,
                          ),
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('REPEAT THE INSTRUCTIONS'),
                  style: _outlineStyle,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _cancelFlow,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('CANCEL SAFELY'),
                  style: _outlineStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCancelled() {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                label: 'Nothing was created. No account was created and no '
                    'information was saved.',
                child: const Column(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 76,
                      color: AppTheme.accent,
                    ),
                    SizedBox(height: 22),
                    Text(
                      'Nothing was created',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No account was created and no information was saved.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: LongPressConfirm(
                    key: _holdKey,
                    fill: true,
                    label: 'START OVER',
                    semanticLabel: 'Start over. Press and hold.',
                    semanticHint:
                        'Press and hold for one second to start account '
                        'creation again.',
                    icon: Icons.restart_alt_rounded,
                    onHoldStart: () => _voice.speakImportant('Hold...'),
                    onHoldCancelled: () => _voice.speak(
                      'The button was released too early. Press and hold again.',
                      pace: TtsPace.important,
                    ),
                    onConfirmed: _retry,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle get _outlineStyle => OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      );
}
