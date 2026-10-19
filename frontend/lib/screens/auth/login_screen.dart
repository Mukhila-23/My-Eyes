import 'package:flutter/material.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_service.dart';
import '../../services/voice_guide.dart';
import '../dashboard/dashboard_screen.dart';
import '../onboarding/welcome_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _voice = VoiceGuide.instance;
  bool _loading = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 800), _startVoiceLogin);
  }

  Future<void> _startVoiceLogin() async {
    if (_started || !mounted) return;
    _started = true;
    await _voice.speak(
      'Welcome to My Eyes. Say login, then place your finger on the fingerprint sensor. '
      'If this is your first visit, say register.',
    );
    final command = (await _voice.listenOnce() ?? '').toLowerCase();
    if (!mounted) return;
    if (command.contains('register') || command.contains('create')) {
      _openRegister();
    } else if (command.contains('login') || command.contains('sign in')) {
      _login();
    } else {
      await _voice.speak('I did not hear a command. Please say login or register, or use the buttons on screen.');
    }
  }

  Future<void> _login() async {
    if (_loading) return;
    setState(() => _loading = true);
    await _voice.speak('Please place your finger on the fingerprint sensor now.');
    final result = await BiometricService.authenticate();
    if (!result.authenticated) {
      await _voice.speak('Login was not successful. I will take you to registration.');
      if (mounted) _openRegister();
      return;
    }
    try {
      await AuthService.loginWithEnrolledDevice();
      final companion = await SecureStorage.readCompanion();
      await _voice.speak('Login successful. Opening your dashboard.');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => DashboardScreen(
          companionName: companion.name,
          companionGender: companion.gender,
        ),
      ));
    } on AuthException catch (_) {
      await _voice.speak('Login was not successful. I will take you to registration.');
      if (mounted) _openRegister();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openRegister() {
    // Clear any partial onboarding state so the flow starts from the welcome.
    SecureStorage.clear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() { _voice.stop(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.background,
    body: SafeArea(child: Center(child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.fingerprint_rounded, size: 84, color: AppTheme.accent),
        const SizedBox(height: 24),
        const Text('Voice-guided sign in', style: TextStyle(color: AppTheme.textPrimary, fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        const Text('Say “login” or “register”. You can also use the buttons below.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 32),
        SizedBox(width: double.infinity, height: 58, child: ElevatedButton.icon(
          onPressed: _loading ? null : _login, icon: const Icon(Icons.fingerprint_rounded),
          label: Text(_loading ? 'VERIFYING...' : 'LOGIN WITH FINGERPRINT'),
        )),
        TextButton(onPressed: _loading ? null : _openRegister, child: const Text('REGISTER BY VOICE')),
      ]),
    ))),
  );
}
