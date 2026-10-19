import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/companion.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';

/// Result of a companion switch, handed back to the dashboard so it can
/// re-theme itself and re-apply the new voice without a reload.
class CompanionChange {
  const CompanionChange(this.companion);

  final CompanionProfile companion;
}

/// "Change Companion" - switch between Alex and Maya.
///
/// Voice-first:
///   "change companion"  -> "You are currently using Alex. Would you like to
///                          switch to Maya?"
///   "yes" / "switch"    -> "Changing your companion to Maya." then the switch
///   "no" / "cancel"      -> back to the dashboard, unchanged
///   "alex" / "maya"      -> picks that companion directly, still confirming
///
/// Persistence: the change is written to the account (`PUT /profile/companion`)
/// and only mirrored into secure local storage once the server has confirmed
/// it. A failed switch therefore leaves the app and the account in agreement
/// and the user is told plainly that nothing changed.
///
/// Nothing else is touched: no logout, no account recreation, no module
/// history, no SOS configuration, no preferences.
class ChangeCompanionScreen extends StatefulWidget {
  const ChangeCompanionScreen({super.key, required this.current});

  /// The companion in use when this screen opened.
  final CompanionProfile current;

  @override
  State<ChangeCompanionScreen> createState() => _ChangeCompanionScreenState();
}

enum _Phase { choosing, confirming, switching, done, failed }

class _ChangeCompanionScreenState extends State<ChangeCompanionScreen> {
  final VoiceGuide _voice = VoiceGuide.instance;

  _Phase _phase = _Phase.choosing;
  int? _voiceSession;
  bool _disposed = false;
  bool _busy = false;

  VoiceCommandService get _voiceService => VoiceCommandService.instance;

  /// The companion the app is currently speaking as.
  CompanionProfile get _active => widget.current;

  /// The only other companion offered.
  late final CompanionProfile _other =
      _active.id == Companions.alex.id ? Companions.maya : Companions.alex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _disposed = true;
    _busy = false;
    _voice.stop();
    _voiceService.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _begin() async {
    await _voice.speak(
      'You are currently using ${_active.name}. '
      'Would you like to switch to ${_other.name}? '
      'Say yes to switch, no to stay with ${_active.name}, or say go back.',
      pace: TtsPace.important,
    );
    if (_disposed || !mounted) return;
    if (!mounted) return;

    setState(() => _phase = _Phase.confirming);
    _voiceSession = await _voiceService.startSession(
      onCommand: _handleCommand,
    );
  }

  Future<void> _handleCommand(String raw) async {
    if (_busy) return;

    final transcript = VoiceCommandService.stripWakeWords(raw).toLowerCase();
    if (transcript.isEmpty) return;

    if (VoiceCommandService.isBackCommand(transcript)) {
      await _close();
      return;
    }

    if (VoiceCommandService.isStopCommand(transcript)) {
      await _voice.speak('Switching companion stopped.');
      await _close();
      return;
    }

    // Naming a companion picks it directly. "maya" alone must reach the
    // switch, not be treated as an unrecognised word.
    final named = _companionNamed(transcript);
    if (named != null && named.id != _active.id) {
      await _switchTo(named);
      return;
    }

    if (_isYes(transcript)) {
      await _switchTo(_other);
      return;
    }

    if (_isNo(transcript) || transcript.contains('keep')) {
      await _voice.speak(
        'Okay. ${_active.name} is still your companion.',
        pace: TtsPace.important,
      );
      await _close();
      return;
    }

    await _voice.speak(
      'I did not catch that. Say yes to switch to ${_other.name}, no to keep '
      '${_active.name}, or say go back.',
    );
  }

  CompanionProfile? _companionNamed(String transcript) {
    for (final candidate in Companions.all) {
      if (transcript.contains(candidate.name.toLowerCase())) return candidate;
    }
    return null;
  }

  bool _isYes(String transcript) =>
      transcript.contains('yes') ||
      transcript.contains('yeah') ||
      transcript.contains('yep') ||
      transcript.contains('switch') ||
      transcript.contains('change') ||
      transcript.contains('do it');

  bool _isNo(String transcript) =>
      transcript.trim() == 'no' ||
      transcript.startsWith('no ') ||
      transcript.contains('nope') ||
      transcript.contains('nah');

  /// The touch path: tap the other companion's card.
  Future<void> _switchTo(CompanionProfile target) async {
    if (_busy) return;
    if (target.id == _active.id) {
      await _voice.speak(
        'You are already using ${_active.name}.',
        pace: TtsPace.important,
      );
      return;
    }

    _busy = true;
    if (!mounted) return;
    setState(() => _phase = _Phase.switching);

    // Stop the microphone first: the switch itself must not be able to pick up
    // its own confirmation and start a second switch.
    await _voiceService.releaseSession(_voiceSession);
    _voiceSession = null;

    await _voice.speak(
      'Changing your companion to ${target.name}.',
      pace: TtsPace.important,
    );
    if (_disposed || !mounted) return;

    CompanionProfile confirmed;
    try {
      confirmed = await AuthService.changeCompanion(target.id);
    } on AuthException catch (error) {
      if (_disposed || !mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _busy = false;
      });
      await _voice.speakImportant(
        '${error.message} You are still using ${_active.name}.',
      );
      unawaited(_reopenVoiceForRetry());
      return;
    } catch (error, stack) {
      debugPrint('[COMPANION] switch failed: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 6);
      if (_disposed || !mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _busy = false;
      });
      await _voice.speakImportant(
        "I couldn't change your companion right now. Please try again. "
        'You are still using ${_active.name}.',
      );
      unawaited(_reopenVoiceForRetry());
      return;
    }

    // Mirror the server's answer into local storage and re-apply the voice so
    // the very next sentence is already spoken by the new companion.
    await SecureStorage.saveCompanion(
      name: confirmed.name,
      gender: confirmed.isMale ? 'male' : 'female',
    );
    if (_disposed || !mounted) return;

    // Configure on the shared TTS service (not on VoiceGuide, which only
    // forwards speech calls) so the new pitch/voice applies to every later
    // announcement in this session, including the greeting below.
    _voiceService.configureCompanionProfile(confirmed);

    setState(() {
      _phase = _Phase.done;
      _busy = false;
    });

    // Greet in the new voice. This is the proof the switch took effect.
    await _voice.speak(
      'Your companion has been changed to ${confirmed.name}. '
      '${confirmed.tagline} I am ready to help you.',
      pace: TtsPace.important,
    );
  }

  /// After a failed switch, keep the microphone alive so the user can retry
  /// with "yes" instead of hunting for a button.
  Future<void> _reopenVoiceForRetry() async {
    if (_disposed || !mounted) return;
    _voiceSession = await _voiceService.startSession(
      onCommand: _handleCommand,
    );
  }

  Future<void> _close() async {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final switching = _phase == _Phase.switching;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
                child: Column(
                  children: [
                    _buildCurrent(),
                    const SizedBox(height: 26),
                    _buildOptions(switching),
                    const SizedBox(height: 24),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Go back to the dashboard',
            hint: 'Keeps your current companion',
            child: ExcludeSemantics(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _close,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.white.withValues(alpha: 0.05),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Semantics(
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Change Companion',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Currently ${_active.name}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrent() {
    return Semantics(
      label: '${_active.name} is your current companion. '
          '${_active.tagline}',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              colors: [
                _colorFor(_active).withValues(alpha: 0.28),
                _colorFor(_active).withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(
              color: _colorFor(_active).withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              _avatar(_active, size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _active.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _active.tagline,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'YOUR COMPANION NOW',
                      style: TextStyle(
                        color: _colorFor(_active),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptions(bool switching) {
    final failed = _phase == _Phase.failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'AVAILABLE COMPANION',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          enabled: !switching,
          label: 'Switch to ${_other.name}. ${_other.tagline}',
          hint: switching
              ? 'Please wait, the switch is in progress'
              : 'Changes your companion and saves it to your account',
          onTap: switching ? null : () => _switchTo(_other),
          child: ExcludeSemantics(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: switching ? null : () => _switchTo(_other),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: Colors.white.withValues(alpha: 0.045),
                    border: Border.all(
                      color: failed
                          ? AppTheme.error.withValues(alpha: 0.45)
                          : _colorFor(_other).withValues(alpha: 0.30),
                      width: failed ? 1.4 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      _avatar(_other, size: 56),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _other.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _other.tagline,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (switching)
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppTheme.accent,
                            ),
                          ),
                        )
                      else
                        Icon(
                          Icons.swap_horiz_rounded,
                          color: _colorFor(_other),
                          size: 26,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        if (_phase == _Phase.done)
          Semantics(
            liveRegion: true,
            child: Text(
              'Your companion has been changed to ${_active == widget.current ? _other.name : _active.name}.',
              style: const TextStyle(
                color: AppTheme.success,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        else
          Text(
            'Your choice is saved to your account, so ${_active == widget.current ? _other.name : _active.name} will '
            'speak to you the next time you sign in.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: OutlinedButton.icon(
            onPressed: _close,
            icon: const Icon(Icons.check_rounded),
            label: const Text('DONE'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatar(CompanionProfile companion, {required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            _colorFor(companion),
            _colorFor(companion).withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Icon(
        companion.isMale ? Icons.person_rounded : Icons.face_3_rounded,
        color: Colors.white,
        size: size * 0.55,
      ),
    );
  }

  static Color _colorFor(CompanionProfile companion) =>
      companion.isMale ? const Color(0xFF149EFF) : const Color(0xFFFF5FA2);
}
