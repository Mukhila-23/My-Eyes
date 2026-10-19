import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/onboarding/onboarding_progress.dart';
import '../../core/theme/app_theme.dart';
import '../../services/voice_guide.dart';
import 'account_creation_screen.dart';

/// Stage 1 of the first-run flow.
///
/// The greeting plays the moment this screen appears and the screen advances
/// by itself - there is deliberately no "Next" button for a blind user to
/// hunt for, and no silent state change either: the handover is spoken.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  final VoiceGuide _voice = VoiceGuide.instance;

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  bool _navigated = false;

  @override
  void dispose() {
    _voice.stop();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // One frame of delay so the first utterance is not swallowed by the
    // splash screen's own teardown.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_navigated || !mounted) return;
    _navigated = true;

    // Short and calm. This is a greeting, not a paragraph.
    await _voice.speak(
      'Welcome to My Eyes, your vision beyond sight.',
      remember: true,
    );
    if (!mounted) return;

    await _voice.speak(
      'I will guide you through the setup using voice. '
      'You do not need to look at the screen.',
      remember: false,
    );
    if (!mounted) return;

    await _voice.speak('Let us begin.', remember: false);
    if (!mounted) return;

    await OnboardingProgressStore.save(
      (await OnboardingProgressStore.read()).copyWith(welcomeCompleted: true),
    );
    if (!mounted) return;

    // Automatic navigation: the user never has to press anything.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AccountCreationScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: FadeTransition(
            opacity: _fadeController,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Semantics(
                  header: true,
                  label: 'Welcome to My Eyes, your vision beyond sight.',
                  child: Column(
                    children: [
                      Container(
                        width: 148,
                        height: 148,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(
                            colors: [
                              AppTheme.primaryLight,
                              AppTheme.primary,
                              Color(0xFF151A32),
                            ],
                            stops: [0.0, 0.35, 1.0],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.35),
                              blurRadius: 55,
                              spreadRadius: 12,
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.visibility_rounded,
                            size: 66,
                            color: AppTheme.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                      Semantics(
                        label: 'My Eyes. I am guiding you through setup.',
                        child: const Text(
                          'MY EYES',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 40,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 7,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Vision beyond sight',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 18,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 44),
                      Semantics(
                        liveRegion: true,
                        label:
                            'I will guide you through the setup using voice. '
                            'You do not need to look at the screen.',
                        child: const Text(
                          'Setting up…',
                          style: TextStyle(
                            color: AppTheme.accent,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}