import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/onboarding/onboarding_progress.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_gate_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../onboarding/account_creation_screen.dart';
import '../onboarding/companion_selection_screen.dart';
import '../onboarding/welcome_screen.dart';

/// App entry. Resolves *where* the user must resume, then hands over.
///
/// Resume rules, in order:
///  1. an account exists on the backend -> fingerprint-first [AuthGateScreen]
///  2. onboarding finished -> [DashboardScreen]
///  3. setup interrupted part-way -> the exact stage they reached
///  4. nothing done -> [WelcomeScreen]
///
/// The splash itself is deliberately short and silent. It is a routing decision,
/// not a greeting: speaking here would overlap the welcome message and would
/// delay the user behind an animation they cannot see the purpose of.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// `TickerProviderStateMixin`, not `SingleTickerProviderStateMixin`: this State
/// drives two controllers (the looping orb and the one-shot fade) and is also
/// the `vsync` for every `AnimatedBuilder` below. The single-ticker mixin
/// asserts as soon as the second controller is created, which is what threw the
/// red "multiple tickers were created" screen over the splash.
class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _orbController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  late final Animation<double> _orbAnimation = CurvedAnimation(
    parent: _orbController,
    curve: Curves.easeInOut,
  );

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  late final Animation<double> _fadeAnimation = CurvedAnimation(
    parent: _fadeController,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
  }

  @override
  void dispose() {
    _orbController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _route() async {
    // A failure while reading storage must never strand the user on a splash
    // that never resolves, and must never surface as a red error screen. The
    // worst case is that a first-time user sees the welcome again, which is
    // recoverable and correct; the error is logged for diagnosis.
    Widget next;
    try {
      final enrollment = await SecureStorage.readEnrollment();
      final progress = await OnboardingProgressStore.read();
      if (!mounted) return;

      if (enrollment != null) {
        // An account already exists on this device: unlock with a fingerprint.
        next = const AuthGateScreen();
      } else if (progress.onboardingCompleted) {
        // Setup finished but the enrollment was lost (e.g. the secure store
        // was cleared by the OS). Read the companion back rather than asking
        // again.
        final companion = await SecureStorage.readCompanion();
        next = DashboardScreen(
          companionName: companion.name,
          companionGender: companion.gender,
        );
      } else if (progress.instructionsCompleted &&
          progress.hasEmail &&
          progress.hasCompanion) {
        // A Google ID token is never stored on the device. Re-selecting the
        // account yields a fresh token for a secure server-side verification.
        next = const AccountCreationScreen();
      } else if (progress.companionSelected && progress.hasCompanion) {
        next = const CompanionSelectionScreen();
      } else {
        // Account and/or welcome incomplete: restart from the earliest stage
        // that is genuinely unfinished. The welcome is only replayed when it
        // never completed.
        next = progress.welcomeCompleted
            ? const AccountCreationScreen()
            : const WelcomeScreen();
      }
    } catch (error, stack) {
      debugPrint('[SPLASH] could not restore session state: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      if (!mounted) return;
      next = const WelcomeScreen();
    }

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _orbAnimation,
              builder: (context, child) => CustomPaint(
                painter: _GlowPainter(progress: _orbAnimation.value),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _orbAnimation,
                      builder: (context, child) => Transform.scale(
                        scale: 0.94 +
                            (math.sin(_orbAnimation.value * math.pi * 2) *
                                0.03),
                        child: child,
                      ),
                      child: _buildEye(),
                    ),
                    const SizedBox(height: 38),
                    const Text(
                      'MY EYES',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'See the world through sound',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 16,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 40),
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppTheme.accent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEye() {
    return Container(
      width: 150,
      height: 150,
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
          BoxShadow(
            color: AppTheme.accent.withValues(alpha: 0.12),
            blurRadius: 90,
            spreadRadius: 20,
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.visibility_rounded,
          size: 62,
          color: AppTheme.accent,
        ),
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment(
          math.sin(progress * math.pi * 2) * 0.5,
          math.cos(progress * math.pi * 2) * 0.5,
        ),
        radius: 1.2,
        colors: [
          AppTheme.primary.withValues(alpha: 0.12),
          AppTheme.accent.withValues(alpha: 0.04),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
