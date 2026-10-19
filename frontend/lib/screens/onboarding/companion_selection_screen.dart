import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/onboarding/onboarding_progress.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../services/companion.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';
import '../../widgets/long_press_confirm.dart';

/// Stage 3 of the first-run flow: choose a companion.
///
/// Voice-first by construction. The user is told what is happening, hears the
/// focused companion introduced by name, hears a preview in that companion's
/// real engine voice, and only then is told how to move on.
///
/// Navigation is deliberately gesture-based:
///   * swipe (or the two full-width swipe panels, or "next"/"previous") moves
///     between companions,
///   * a plain tap only replays the preview - it can never select,
///   * a ~1.2 second long press selects the focused companion and confirms it
///     out loud.
///
/// Returns the chosen companion id (`alex` / `maya`), or null when cancelled.
class CompanionSelectionScreen extends StatefulWidget {
  const CompanionSelectionScreen({super.key});

  @override
  State<CompanionSelectionScreen> createState() =>
      _CompanionSelectionScreenState();
}

class _CompanionSelectionScreenState extends State<CompanionSelectionScreen>
    with SingleTickerProviderStateMixin {
  final VoiceGuide _voice = VoiceGuide.instance;

  final PageController _pageController = PageController();

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  int _index = 0;
  bool _started = false;
  bool _speaking = false;
  bool _saving = false;
  bool _explained = false;

  /// Invalidates a preview that is still speaking when the user swipes fast, so
  /// two voices can never overlap.
  int _previewToken = 0;

  static const List<CompanionProfile> _companions = Companions.all;

  CompanionProfile get _current => _companions[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _previewToken++;
    _pageController.dispose();
    _pulse.dispose();
    _voice.stop();
    super.dispose();
  }

  // ============================================================
  // OPENING
  // ============================================================

  Future<void> _run() async {
    if (_started || !mounted) return;
    _started = true;

    // Resume support: a companion chosen in a previous session is pre-focused
    // and announced first, so the user does not start over blindly.
    final progress = await OnboardingProgressStore.read();
    if (!mounted) return;
    final preselected = progress.hasCompanion
        ? _companions.indexWhere((c) => c.id == progress.companionId)
        : -1;
    if (preselected > 0) {
      _index = preselected;
      // Deferred: the PageView has no client until after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pageController.jumpToPage(preselected);
      });
    }

    await _voice.speak('Now choose your companion.', remember: true);
    if (!mounted) return;

    await _preview(_index);
    if (!mounted) return;

    // Instructions are spoken once, after the first preview, so the user knows
    // who they are listening to before being told how to move on.
    if (!_explained) {
      _explained = true;
      await _voice.speak(
        'To hear the next companion, swipe to the next option.',
        remember: false,
      );
      if (!mounted) return;

      await _voice.speak(
        'You can swipe to hear the next companion. '
        'When you find the companion you want, press and hold to select it. '
        'You can also say select ${_current.name}.',
        remember: false,
      );
      return;
    }

    await _voice.speak(
      'You can swipe to hear the next companion. '
      'When you find the companion you want, press and hold to select it.',
      remember: false,
    );
  }

  /// Speaks the preview for [index] in that companion's real engine voice.
  Future<void> _preview(int index) async {
    if (!mounted) return;

    final token = ++_previewToken;
    final companion = _companions[index];

    // Cancel anything still speaking before starting the next preview.
    await _voice.stopSpeakingOnly();
    if (!mounted || token != _previewToken) return;

    await _voice.speakAs(companion, _previewText(companion), remember: true);
    if (!mounted || token != _previewToken) return;

    // Verify what the engine actually switched to instead of trusting the
    // companion name.

    debugPrint(
      '[COMPANION] ${companion.name} -> voice ${_voice.appliedVoice}, '
      'matchesGender=${_voice.companionVoiceMatchesGender}',
    );

    if (token != _previewToken) return;
    if (mounted) setState(() => _speaking = false);
  }

  String _previewText(CompanionProfile companion) =>
      "This is ${companion.name}. "
      "Hello. I'm ${companion.name}, your My Eyes guide. "
      "${companion.tagline} "
      "I'll be here whenever you need me.";

  // ============================================================
  // NAVIGATION
  // ============================================================

  Future<void> _goTo(int index, {required bool animate}) async {
    if (!mounted) return;
    final target = index % _companions.length;

    final alreadyFocused = target == _index;

    setState(() {
      _index = target;
      _speaking = true;
    });

    // "This is <name>" is spoken in the target companion's own voice before its
    // preview, so a user who swipes always knows which one they landed on. When
    // it is already focused, the preview alone is enough.
    if (!alreadyFocused) {
      await _voice.speakAs(
        _companions[target],
        'This is ${_companions[target].name}.',
        remember: false,
      );
      if (!mounted) return;
    }

    // An animated move fires `onPageChanged`, which owns the preview. Only the
    // non-animated / not-attached cases need it triggered explicitly.
    final willAnimate = animate && _pageController.hasClients;

    if (willAnimate) {
      await _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      return;
    }

    await _preview(target);
  }

  Future<void> _next() =>
      _goTo(_index + 1, animate: true);

  Future<void> _previous() =>
      _goTo(_index - 1, animate: true);

  // ============================================================
  // SELECTION
  // ============================================================

  Future<void> _select() async {
    if (_saving || !mounted) return;
    setState(() => _saving = true);

    final companion = _current;

    await _voice.stopSpeakingOnly();
    if (!mounted) return;

    // Apply the voice immediately so the confirmation itself is already spoken
    // by the companion that was chosen.
    _voice.configureCompanion(companion);

    await SecureStorage.saveCompanion(
      name: companion.name,
      gender: companion.isMale ? 'male' : 'female',
    );

    final progress = await OnboardingProgressStore.read();
    await OnboardingProgressStore.save(
      progress.copyWith(companionSelected: true, companionId: companion.id),
    );
    if (!mounted) return;

    await _voice.speak(
      'You selected ${companion.name} as your companion.',
      pace: TtsPace.important,
      remember: true,
    );
    if (!mounted) return;

    await _voice.speak(
      '${companion.name} will guide you through My Eyes.',
      remember: false,
    );
    if (!mounted) return;

    Navigator.of(context).pop(companion.id);
  }

  void _cancel() {
    _voice.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final companion = _current;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            children: [
              Semantics(
                header: true,
                child: const Text(
                  'Now choose your companion',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                label: '${companion.name} is selected. '
                    'Swipe to hear the next companion. '
                    'Press and hold to select ${companion.name}.',
                child: Text(
                  'Swipe to hear the next companion.\n'
                  'Press and hold to select ${companion.name}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 14),

              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _companions.length,
                  onPageChanged: (index) {
                    setState(() {
                      _index = index;
                      _speaking = true;
                    });
                    unawaited(_preview(index));
                  },
                  itemBuilder: (context, index) => _CompanionCard(
                    companion: _companions[index],
                    selected: index == _index,
                    speaking: _speaking && index == _index,
                    pulse: _pulse,
                    // Tapping only replays the preview: it cannot change or
                    // confirm anything.
                    onReplay: () => _preview(index),
                  ),
                ),
              ),

              const SizedBox(height: 12),
              _buildDots(),
              const SizedBox(height: 12),

              // Full-width swipe panels instead of small arrow icons: the target
              // is the whole half of the row, not a 48px chevron.
              _buildSwipeRow(),
              const SizedBox(height: 12),

              LongPressConfirm(
                label: 'PRESS AND HOLD TO SELECT ${companion.name.toUpperCase()}',
                semanticLabel: 'Select ${companion.name}',
                semanticHint: 'Press and hold for one second to select '
                    '${companion.name}, or say select ${companion.name}. '
                    'A tap does nothing.',
                accent: _accentFor(companion),
                busy: _saving,
                onHoldStart: () => _voice.speakImportant('Hold...'),
                onHoldCancelled: () => _voice.speak(
                  'The button was released too early. '
                  'Press and hold again to select ${companion.name}.',
                  pace: TtsPace.important,
                ),
                onConfirmed: _select,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => _voice.speak(
                            'You can swipe to hear the next companion. '
                            'When you find the companion you want, '
                            'press and hold to select it.',
                            remember: true,
                          ),
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('REPEAT THE INSTRUCTIONS'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.22),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _cancel,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('CANCEL SAFELY'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.22),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _accentFor(CompanionProfile companion) =>
      companion.isMale ? const Color(0xFF149EFF) : const Color(0xFFFF5FA2);

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _companions.length; i++)
          Semantics(
            label: i == _index
                ? '${_companions[i].name}, selected'
                : _companions[i].name,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 5),
              width: i == _index ? 30 : 12,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: i == _index
                    ? _accentFor(_companions[i])
                    : Colors.white.withValues(alpha: 0.25),
              ),
            ),
          ),
      ],
    );
  }

  /// Two large panels acting as previous / next. They exist so the interaction
  /// is not swiping-only, but they are never the only way to select: the long
  /// press below is.
  Widget _buildSwipeRow() {
    return Row(
      children: [
        Expanded(
          child: _SwipePanel(
            label: 'PREVIOUS COMPANION',
            semanticLabel: 'Previous companion. ${_companions[
                    (_index - 1 + _companions.length) % _companions.length]
                .name}',
            icon: Icons.chevron_left_rounded,
            onTap: _previous,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SwipePanel(
            label: 'NEXT COMPANION',
            semanticLabel: 'Next companion. ${_companions[
                    (_index + 1) % _companions.length]
                .name}',
            icon: Icons.chevron_right_rounded,
            onTap: _next,
          ),
        ),
      ],
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
      hint: 'Double tap to hear this companion',
      excludeSemantics: true,
      child: SizedBox(
        height: 72,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 30),
          label: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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

class _CompanionCard extends StatelessWidget {
  const _CompanionCard({
    required this.companion,
    required this.selected,
    required this.speaking,
    required this.pulse,
    required this.onReplay,
  });

  final CompanionProfile companion;
  final bool selected;
  final bool speaking;
  final Animation<double> pulse;
  final VoidCallback onReplay;

  Color get _primary =>
      companion.isMale ? const Color(0xFF149EFF) : const Color(0xFFFF5FA2);
  Color get _secondary =>
      companion.isMale ? const Color(0xFF5267FF) : const Color(0xFF9B5CFF);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${companion.name} companion. '
          '${companion.isMale ? 'Male' : 'Female'} voice. '
          '${companion.tagline}',
      hint: 'Swipe to hear the next companion. '
          'Press and hold to select ${companion.name}.',
      child: GestureDetector(
        // Replay only - never selects.
        onTap: onReplay,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: selected
                  ? _primary.withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.08),
              width: selected ? 2 : 1,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _primary.withValues(alpha: selected ? 0.20 : 0.08),
                Colors.white.withValues(alpha: 0.03),
              ],
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: AnimatedBuilder(
                    animation: pulse,
                    builder: (context, child) {
                      final scale = speaking
                          ? 1.0 + (pulse.value * 0.04)
                          : 1.0 + (math.sin(pulse.value * math.pi) * 0.02);
                      return Transform.scale(scale: scale, child: child);
                    },
                    child: _Avatar(
                      companion: companion,
                      primary: _primary,
                      secondary: _secondary,
                      speaking: speaking,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                companion.name.toUpperCase(),
                style: TextStyle(
                  color: _primary,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                companion.isMale ? 'Male voice' : 'Female voice',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                companion.tagline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                speaking ? 'SPEAKING' : 'TAP TO HEAR AGAIN',
                style: TextStyle(
                  color: _secondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.companion,
    required this.primary,
    required this.secondary,
    required this.speaking,
  });

  final CompanionProfile companion;
  final Color primary;
  final Color secondary;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: primary.withValues(alpha: speaking ? 0.5 : 0.25),
          width: speaking ? 3 : 1.5,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primary, secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.35),
            blurRadius: 45,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Center(
        child: Text(
          companion.name.substring(0, 1),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 78,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}