import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/onboarding/onboarding_progress.dart';
import '../../core/theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../services/companion.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';
import '../../widgets/long_press_confirm.dart';
import '../dashboard/dashboard_screen.dart';

/// Stage 4 of the first-run flow: how My Eyes works, then the dashboard.
///
/// One short spoken instruction at a time - never a wall of text. Navigation is
/// gesture based:
///   * swipe left  -> next instruction
///   * swipe right -> previous instruction
///   * long press  -> finish the instructions and open the dashboard
///
/// The final "instruction" is the terms summary, and holding on the last one is
/// the explicit acceptance, so `terms_accepted` is a deliberate act rather than
/// a default. On the last step the spoken guidance changes to
/// "You have completed the introduction" / "Press and hold to enter the My Eyes
/// dashboard".
class InstructionScreen extends StatefulWidget {
  const InstructionScreen({
    super.key,
    required this.email,
    required this.companionId,
    required this.googleIdToken,
  });

  final String email;
  final String companionId;
  final String googleIdToken;

  @override
  State<InstructionScreen> createState() => _InstructionScreenState();
}

class _InstructionScreenState extends State<InstructionScreen> {
  final VoiceGuide _voice = VoiceGuide.instance;

  late final CompanionProfile _companion =
      Companions.byId(widget.companionId);

  late final List<_Step> _steps = _buildSteps(_companion);

  /// The companion the backend actually holds for this account.
  ///
  /// Null until [AuthService.useOrCreateAccount] answers. When the chosen email
  /// already had a My Eyes account the server keeps the companion that account
  /// was created with, and that is the voice the dashboard must use - the one
  /// picked during onboarding this run only applies to an account this run
  /// actually created.
  String? _sessionCompanionId;

  /// Whether this run created the account, as opposed to opening one that
  /// already existed. Only a freshly created account may adopt the companion
  /// chosen on this run; an existing one must keep what it had.
  bool _sessionCreated = false;

  final PageController _pageController = PageController();

  int _index = 0;
  bool _started = false;
  bool _busy = false;
  bool _finishing = false;

  _Step get _current => _steps[_index];
  bool get _isLast => _index == _steps.length - 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _pageController.dispose();
    _voice.stop();
    super.dispose();
  }

  static List<_Step> _buildSteps(CompanionProfile companion) => [
        const _Step(
          title: 'Voice and touch',
          spoken:
              'My Eyes is controlled mainly using your voice and simple touch '
              'gestures.',
          visual: Icons.record_voice_over_rounded,
        ),
        const _Step(
          title: 'Speak naturally',
          spoken:
              'Speak naturally to your companion whenever you need help.',
          visual: Icons.mic_rounded,
        ),
        const _Step(
          title: 'Guided features',
          spoken:
              'The assistant will guide you through the available features.',
          visual: Icons.explore_rounded,
        ),
        const _Step(
          title: 'Camera and tools',
          spoken:
              'You can use the camera and other tools through voice-guided '
              'interactions.',
          visual: Icons.camera_alt_rounded,
        ),
        const _Step(
          title: 'Ask for help',
          spoken: 'If you are unsure what to do, ask your companion for help.',
          visual: Icons.help_outline_rounded,
        ),
        _Step(
          title: 'Terms',
          spoken: 'Before we begin, one last thing. '
              'My Eyes stores your email on this device and uses the camera, '
              'microphone and location only when you ask it to. '
              'Your data is never sold, and emergency features also depend on '
              'your phone signal.',
          visual: Icons.gavel_rounded,
          isTerms: true,
        ),
      ];

  // ============================================================
  // OPENING
  // ============================================================

  Future<void> _run() async {
    if (_started || !mounted) return;
    _started = true;

    // The companion's voice must already be applied so every instruction here
    // is spoken by the voice the user just chose.
    _voice.configureCompanion(_companion);

    await _voice.speak(
      'Before we begin, I will explain how to use My Eyes.',
      remember: true,
    );
    if (!mounted) return;

    await _voice.speak(
      'Swipe to hear the next instruction. '
      'Swipe the other way to hear it again.',
      remember: false,
    );
    if (!mounted) return;

    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    if (!mounted) return;

    // Each step is its own utterance, so the user can process it before the
    // next one starts.
    await _voice.speak(_current.spoken, remember: true);
    if (!mounted) return;

    if (!_isLast) {
      await _voice.speak(
        'Instruction ${_index + 1} of ${_steps.length}. '
        'Swipe to hear the next instruction.',
        remember: false,
      );
      return;
    }

    await _voice.speak(
      'You have completed the introduction.',
      pace: TtsPace.important,
      remember: false,
    );
    if (!mounted) return;

    await _voice.speak(
      'Press and hold to enter the My Eyes dashboard.',
      pace: TtsPace.important,
      remember: false,
    );
  }

  // ============================================================
  // NAVIGATION
  // ============================================================

  Future<void> _next() async {
    if (_busy || _finishing || !mounted) return;

    if (_isLast) {
      await _voice.speak(
        'This is the last instruction. '
        'Press and hold to enter the My Eyes dashboard.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    await _moveTo(_index + 1);
  }

  Future<void> _previous() async {
    if (_busy || _finishing || !mounted) return;

    if (_index == 0) {
      await _voice.speak(
        'This is the first instruction. '
        'Swipe forward to hear the next one.',
        remember: false,
      );
      return;
    }

    await _moveTo(_index - 1);
  }

  Future<void> _moveTo(int index) async {
    setState(() => _index = index);
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    await _speakCurrent();
  }

  // ============================================================
  // FINISH -> REGISTER -> DASHBOARD
  // ============================================================

  Future<void> _finish() async {
    if (_busy || _finishing || !mounted) return;
    setState(() => _finishing = true);

    await _voice.stopSpeakingOnly();
    if (!mounted) return;

    // Only the last step can finish: the long press on an earlier step simply
    // moves forward, so the instructions cannot be skipped by accident.
    if (!_isLast) {
      setState(() => _finishing = false);
      await _voice.speak(
        'There are more instructions left. '
        'Swipe to hear the next one, or press and hold on the last instruction '
        'to finish.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    setState(() => _busy = true);

    await _voice.speak('Please wait. I am preparing your account.',
        remember: false);
    if (!mounted) return;

    final biometric = await BiometricService.authenticate();
    if (!mounted) return;

    if (!biometric.authenticated) {
      setState(() {
        _busy = false;
        _finishing = false;
      });
      await _voice.speak(
        'Your fingerprint was not read, so your account was not created. '
        'Press and hold again to try once more.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    try {
      // One entry point for "use this email": it links an account that already
      // exists and creates one otherwise, and on every success it writes the
      // device credential. Registering directly here is what produced the dead
      // end - an `EMAIL_EXISTS` answer was treated as success, so onboarding
      // finished without ever enrolling this phone, and the next launch had no
      // biometric login to use.
      final session = await AuthService.useOrCreateAccount(
        email: widget.email,
        googleIdToken: widget.googleIdToken,
        companion: _companion.id,
        termsAccepted: true,
      );

      // An account that was already set up carries its own companion, so the
      // dashboard speaks in the voice that account was created with rather than
      // the one chosen on this run.
      _sessionCompanionId = session.companion;
      _sessionCreated = session.created;
    } on AuthException catch (error) {
      setState(() {
        _busy = false;
        _finishing = false;
      });

      if (error.isTermsRejected) {
        await _voice.speak(
          'The terms must be accepted before an account is created. '
          'Nothing was created. Press and hold again to try once more.',
          pace: TtsPace.important,
          remember: false,
        );
        return;
      }

      if (error.isLinkedElsewhere) {
        await _voice.speak(
          'That account is already set up on a different phone. '
          'Please use that phone, or choose another account here. '
          'Nothing was changed on this phone.',
          pace: TtsPace.important,
          remember: false,
        );
        return;
      }

      await _voice.speak(
        'I could not set up your account. ${error.message} '
        'Nothing was created. Press and hold again to try once more.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    } catch (_) {
      setState(() {
        _busy = false;
        _finishing = false;
      });
      await _voice.speak(
        'Something went wrong while creating your account. '
        'Nothing was created. '
        'Please check that the My Eyes server is running, '
        'then press and hold again.',
        pace: TtsPace.important,
        remember: false,
      );
      return;
    }

    if (!mounted) return;
    await _completeSetup();
  }

  /// Records the finished state and hands over to the dashboard with the closing
  /// announcement spoken in the companion's voice.
  ///
  /// Only reached once [AuthService.useOrCreateAccount] has succeeded, so the
  /// device credential always exists by the time the dashboard opens.
  Future<void> _completeSetup() async {
    final companionId = _sessionCompanionId ?? _companion.id;
    final companion = Companions.byId(companionId);

    final progress = await OnboardingProgressStore.read();
    await OnboardingProgressStore.save(
      progress.copyWith(
        welcomeCompleted: true,
        accountSelected: true,
        email: widget.email,
        companionSelected: true,
        companionId: companion.id,
        instructionsCompleted: true,
      ),
    );

    // Keep the account profile in step with the device copy - but only for an
    // account this run created. An account opened from an earlier setup keeps
    // the companion it was created with.
    if (_sessionCreated) {
      await AuthService.saveCompanionProfile(companion.id);
    }

    if (!mounted) return;

    await _voice.speak('Setup is complete.', pace: TtsPace.important,
        remember: false);
    if (!mounted) return;

    await _voice.speak('Welcome to My Eyes.', remember: false);
    if (!mounted) return;

    await _voice.speak('${companion.name} is ready to help you.',
        remember: false);
    if (!mounted) return;

    await _voice.speak(
      'You are now on the My Eyes dashboard.',
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
  }

  void _backToCompanion() {
    if (_busy || _finishing) return;
    _voice.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final accent = _companion.isMale
        ? const Color(0xFF149EFF)
        : const Color(0xFFFF5FA2);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Semantics(
                header: true,
                child: Text(
                  _isLast
                      ? 'Before we begin'
                      : 'How to use My Eyes',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _steps.length,
                onPageChanged: (index) {
                  setState(() => _index = index);
                  unawaited(_speakCurrent());
                },
                itemBuilder: (context, index) => _StepView(
                  step: _steps[index],
                  accent: accent,
                  position: index + 1,
                  total: _steps.length,
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
              child: Semantics(
                liveRegion: true,
                label: 'Instruction ${_index + 1} of ${_steps.length}. '
                    '${_current.spoken}',
                child: Text(
                  'Instruction ${_index + 1} of ${_steps.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Full-width swipe panels: previous / next instruction. Neither is
            // the only way forward - the long press finishes.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                children: [
                  Expanded(
                    child: _SwipePanel(
                      label: 'PREVIOUS',
                      semanticLabel: 'Previous instruction',
                      icon: Icons.chevron_left_rounded,
                      onTap: _previous,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SwipePanel(
                      label: 'NEXT',
                      semanticLabel: 'Next instruction',
                      icon: Icons.chevron_right_rounded,
                      onTap: _next,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: LongPressConfirm(
                label: _isLast
                    ? 'PRESS AND HOLD\nTO ENTER THE DASHBOARD'
                    : 'PRESS AND HOLD\nTO GO TO THE LAST INSTRUCTION',
                semanticLabel: _isLast
                    ? 'Enter the My Eyes dashboard. Press and hold.'
                    : 'Go to the last instruction. Press and hold.',
                semanticHint: _isLast
                    ? 'Press and hold for one second to finish setup and open '
                        'the dashboard.'
                    : 'Press and hold for one second to jump to the last '
                        'instruction.',
                accent: accent,
                busy: _busy,
                icon: _isLast
                    ? Icons.dashboard_rounded
                    : Icons.skip_next_rounded,
                onHoldStart: () => _voice.speakImportant('Hold...'),
                onHoldCancelled: () => _voice.speak(
                  'The button was released too early. '
                  'Press and hold again.',
                  pace: TtsPace.important,
                ),
                onConfirmed: _finish,
              ),
            ),

            const SizedBox(height: 10),

            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _busy || _finishing
                            ? null
                            : () => _voice.speak(
                                  _current.spoken,
                                  remember: true,
                                ),
                        icon: const Icon(Icons.volume_up_rounded),
                        label: const Text('REPEAT'),
                        style: _outlineStyle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _busy || _finishing
                            ? null
                            : _backToCompanion,
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('BACK'),
                        style: _outlineStyle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle get _outlineStyle => OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      );
}

class _Step {
  const _Step({
    required this.title,
    required this.spoken,
    required this.visual,
    this.isTerms = false,
  });

  final String title;
  final String spoken;
  final IconData visual;

  /// The terms step doubles as the acceptance gesture.
  final bool isTerms;
}

class _StepView extends StatelessWidget {
  const _StepView({
    required this.step,
    required this.accent,
    required this.position,
    required this.total,
  });

  final _Step step;
  final Color accent;
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      child: Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: accent.withValues(alpha: 0.45), width: 1.5),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: 0.16),
              Colors.white.withValues(alpha: 0.03),
            ],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.16),
                border: Border.all(color: accent.withValues(alpha: 0.5), width: 2),
              ),
              child: Icon(step.visual, color: accent, size: 50),
            ),
            const SizedBox(height: 26),
            Text(
              step.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 27,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              step.spoken,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textPrimary.withValues(alpha: 0.9),
                fontSize: 19,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              '$position of $total',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipePanel extends StatelessWidget {
  const _SwipePanel({
    required this.label,
    required this.semanticLabel,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: 'Double tap to $label'.toLowerCase(),
      excludeSemantics: true,
      child: SizedBox(
        height: 68,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 30),
          label: Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ),
    );
  }
}
