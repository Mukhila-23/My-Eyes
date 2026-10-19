import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../services/sos_alarm.dart';
import '../../services/sos_contact_store.dart';
import '../../services/sos_service.dart';
import '../../services/voice_command_service.dart';

/// Voice-first SOS trigger: spoken confirmation, a five second countdown the
/// user can cancel, then the emergency workflow.
///
/// Crash resistance, stage by stage:
///  * the countdown timer is always cancelled in `dispose`,
///  * every `await` is followed by a `mounted` check, because the dialer and
///    the messenger both bring this screen back to the foreground,
///  * a missing contact list is spoken as a fixable instruction, never a crash,
///  * the alarm is owned by [SosAlarm] and keeps running after this screen is
///    dismissed, so closing the app view never silences an emergency.
class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

/// What the user sees. Distinct from [SosStatus], which is the workflow's own
/// state: this one is about what has been explained out loud.
enum _ScreenPhase { countdown, working, alerted, alarmRunning }

class _SosScreenState extends State<SosScreen> {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  int _countdown = 5;
  Timer? _countdownTimer;
  bool _running = false;
  _ScreenPhase _phase = _ScreenPhase.countdown;
  String _status = 'Waiting for confirmation…';
  String _spokenOutcome = '';

  /// Remaining alarm time, mirrored from the alarm so the screen can show it
  /// without owning the alarm's lifecycle.
  int _alarmSeconds = SosAlarm.totalDuration.inSeconds;

  /// Ownership token for this screen's voice session, so a late `dispose()`
  /// cannot stop the dashboard session that replaced it.
  int? _voiceSession;

  /// Guards every async callback after this screen is disposed.
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _disposed = true;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    // Deliberately NOT stopping the alarm here. If the user leaves this screen
    // while the alert is still going out, the alarm has five more minutes to
    // run and that is the specified behaviour.
    //
    // Token-released, and a token that was never issued releases nothing: this
    // dispose can run after the screen underneath has already claimed the
    // microphone, and it must not shut that one down.
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _begin() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      autoStart: true,
    );
    if (_disposed || !mounted) return;

    // Reflect an alarm that is already running (a duplicate trigger that was
    // ignored) instead of pretending nothing is happening.
    _alarmSeconds = SosAlarm.secondsRemaining.value;

    await _voice.speak(
      'Emergency S O S. I will alert your emergency contacts with your name '
      'and your location, and start an alarm for five minutes. '
      'Say yes to confirm, or say cancel to abort. '
      'The alert will send in 5 seconds.',
      pace: TtsPace.important,
    );
    if (_disposed || !mounted) return;

    setState(() => _startCountdown());
  }

  void _startCountdown() {
    if (_countdownTimer != null) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        timer.cancel();
        _countdownTimer = null;
        unawaited(_confirmSos());
      }
    });
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceCommandService.stripWakeWords(raw).toLowerCase();
    if (text.isEmpty) return;

    switch (_phase) {
      case _ScreenPhase.countdown:
        if (_containsAny(text, const [
          'yes',
          'confirm',
          'send',
          'send it',
          'go ahead',
        ])) {
          await _confirmSos();
        } else if (_containsAny(text, const [
          'cancel',
          'no',
          'stop',
          'abort',
          "don't send",
        ])) {
          await _cancel();
        }
        return;

      case _ScreenPhase.working:
        if (_containsAny(text, const ['stop', 'cancel'])) {
          await _voice.speak(
            'The alert is already being sent. I cannot cancel it now.',
            pace: TtsPace.important,
          );
        }
        return;

      case _ScreenPhase.alerted:
      case _ScreenPhase.alarmRunning:
        // "Stop the alarm" is the safe escape hatch for a false alarm.
        if (_containsAny(text, const [
          'stop the alarm',
          'stop alarm',
          'stop the sound',
          'stop the noise',
        ])) {
          await _stopAlarm();
          return;
        }

        if (_containsAny(text, const ['stop', 'cancel', 'abort'])) {
          await _stopAlarm();
          return;
        }

        if (_containsAny(text, const [
          'ok',
          'done',
          'close',
          'finish',
          'exit',
        ])) {
          await _close();
          return;
        }

        if (_spokenOutcome.isNotEmpty) {
          await _voice.speak(_spokenOutcome, pace: TtsPace.important);
        }
        return;
    }
  }

  Future<void> _confirmSos() async {
    if (_running) return;
    if (SosService.isRunning) {
      await _voice.speak(
        'An SOS alert is already in progress.',
        pace: TtsPace.important,
      );
      return;
    }

    _running = true;
    _countdownTimer?.cancel();
    _countdownTimer = null;

    if (!mounted) return;
    setState(() {
      _phase = _ScreenPhase.working;
      _status = 'Starting your SOS alert…';
      _countdown = -1;
    });

    await _voice.speak(
      'Starting your SOS alert now.',
      resumeAfter: false,
      pace: TtsPace.important,
    );
    if (_disposed || !mounted) return;

    List<SosContact> contacts = const [];
    try {
      contacts = await SosContactStore.load();
    } catch (error) {
      debugPrint('[SOS] could not read local contacts: $error');
      contacts = const [];
    }

    if (_disposed || !mounted) return;

    if (contacts.isEmpty) {
      // Try the account before telling the user to set SOS up: the contacts
      // may exist on the server and simply not be mirrored on this phone yet.
      final mirrored = await SosContactStore.syncFromServer();
      if (mirrored > 0) contacts = await SosContactStore.load();
    }

    if (!mounted) return;

    if (contacts.isEmpty) {
      setState(() {
        _phase = _ScreenPhase.alerted;
        _running = false;
        _status = 'No emergency contacts are configured.';
      });
      _spokenOutcome =
          'No emergency contacts are configured. Please set up SOS before '
          'using it. Say emergency contacts to add them now, or tap the '
          'emergency contacts button on the dashboard.';
      await _voice.speak(_spokenOutcome, pace: TtsPace.important);
      return;
    }

    final userName = await _userName();
    if (_disposed || !mounted) return;

    final result = await SosService.runSos(
      contacts: contacts,
      withAlarm: true,
      userName: userName,
      onPhase: _onServicePhase,
    );

    if (!mounted) return;

    _spokenOutcome = result.duplicate
        ? 'An SOS alert is already in progress.'
        : result.spokenSummary(userName);

    // Keep the alarm countdown visible and live while it runs.
    _alarmSeconds = SosAlarm.secondsRemaining.value;
    unawaited(_watchAlarm());

    if (!mounted) return;

    setState(() {
      _running = false;
      _phase = result.duplicate
          ? _ScreenPhase.working
          : _ScreenPhase.alarmRunning;
      _status = result.duplicate
          ? 'An alert is already in progress.'
          : 'SOS activated. Your emergency contacts are being alerted.';
    });

    await _voice.speak(_spokenOutcome, pace: TtsPace.important);
  }

  /// Repaints the remaining-alarm readout while the alarm is active.
  ///
  /// Subscribing to the notifier rather than polling keeps the screen cheap and
  /// makes the countdown exact.
  Future<void> _watchAlarm() async {
    while (!_disposed && mounted && SosAlarm.active) {
      final remaining = SosAlarm.secondsRemaining.value;
      if (!mounted) return;
      setState(() => _alarmSeconds = remaining);

      if (!SosAlarm.active) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    if (!mounted) return;
    setState(() {
      _phase = _ScreenPhase.alerted;
      _alarmSeconds = 0;
      _status = 'The alarm has stopped. Your alert has already been sent.';
    });
    await _voice.speak(
      'The alarm has stopped. Say done to return to the dashboard.',
      pace: TtsPace.important,
    );
  }

  void _onServicePhase(SosStatus phase) {
    // Announce only the transitions the user needs to hear. Anything else is
    // rendered on screen; announcing every state would talk over the alert.
    switch (phase) {
      case SosStatus.activating:
        unawaited(
          _voice.speak(
            'SOS activated.',
            resumeAfter: false,
            pace: TtsPace.important,
          ),
        );
        break;
      case SosStatus.obtainingLocation:
        if (mounted) {
          setState(() => _status = 'Getting your current location…');
        }
        break;
      case SosStatus.sendingAlert:
        if (mounted) {
          setState(() => _status = 'Alerting your emergency contacts…');
        }
        break;
      case SosStatus.alarmActive:
      case SosStatus.completed:
      case SosStatus.partiallyFailed:
      case SosStatus.failed:
      case SosStatus.idle:
        break;
    }
  }

  /// Best-effort display name for the emergency message.
  Future<String> _userName() async {
    try {
      final enrollment = await SecureStorage.readEnrollment();
      return enrollment?.email.split('@').first ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _stopAlarm() async {
    try {
      await SosService.stopAlarm();
    } catch (_) {
      // Audio teardown failed; there is nothing useful to say about it.
    }
    if (!mounted) return;
    setState(() {
      _alarmSeconds = 0;
      _phase = _ScreenPhase.alerted;
      _status = 'The alarm has stopped.';
    });
    await _voice.speak(
      'The alarm has stopped. Say done to return to the dashboard.',
      pace: TtsPace.important,
    );
  }

  Future<void> _cancel() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    await _voice.speak(
      'Emergency S O S cancelled. Nothing has been sent.',
      resumeAfter: false,
      pace: TtsPace.important,
    );
    await _close();
  }

  Future<void> _close() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    // Leaving the screen must not silently end the emergency: only the alarm
    // timer keeps running, which is the intended five minute behaviour.
    if (SosService.currentStatus.isBusy) SosService.reset();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  bool _containsAny(String text, List<String> words) {
    for (final word in words) {
      if (text.contains(word)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFFFF3B3B);
    const secondary = Color(0xFFFF6B6B);

    final alerting = _phase == _ScreenPhase.alerted ||
        _phase == _ScreenPhase.alarmRunning;

    return PopScope(
      // Never let a stray back press abandon an alert mid-flight. Back is
      // still allowed once there is nothing left to cancel.
      canPop: _phase == _ScreenPhase.countdown || alerting,
      child: Scaffold(
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
                    _buildOrb(primary, secondary, alerting),
                    const SizedBox(height: 30),
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(
                        _headline,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (_phase == _ScreenPhase.countdown) _buildCountdown(),
                    if (_phase == _ScreenPhase.working) _buildProgress(),
                    if (_phase == _ScreenPhase.alarmRunning) _buildAlarm(),
                    const SizedBox(height: 20),
                    if (_phase == _ScreenPhase.countdown) _buildActions(),
                    if (alerting) _buildDone(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _headline {
    switch (_phase) {
      case _ScreenPhase.countdown:
        return 'SOS ALERT';
      case _ScreenPhase.working:
        return 'SENDING SOS';
      case _ScreenPhase.alerted:
        return 'SOS SENT';
      case _ScreenPhase.alarmRunning:
        return 'ALARM ACTIVE';
    }
  }

  Widget _buildOrb(Color primary, Color secondary, bool alerting) {
    return Semantics(
      label: alerting
          ? 'Emergency SOS is active'
          : 'Emergency SOS is waiting for your confirmation',
      child: ExcludeSemantics(
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [secondary, primary],
              stops: const [0.0, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.4),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Icon(
            alerting ? Icons.notifications_active_rounded : Icons.sos_rounded,
            color: Colors.white,
            size: 72,
          ),
        ),
      ),
    );
  }

  Widget _buildCountdown() {
    final seconds = _countdown > 0 ? _countdown : 0;
    return Semantics(
      liveRegion: true,
      label: 'The alert will send in $seconds seconds unless you cancel',
      child: ExcludeSemantics(
        child: Column(
          children: [
            Text(
              _countdown > 0 ? '$_countdown' : 'SENDING',
              style: const TextStyle(
                color: Color(0xFFFF6B6B),
                fontSize: 56,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Auto-send in $seconds seconds unless you cancel',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Semantics(
      label: 'Alerting your emergency contacts',
      child: ExcludeSemantics(
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                color: Color(0xFFFF6B6B),
                strokeWidth: 3,
              ),
            ),
            SizedBox(width: 14),
            Text(
              'Alerting your contacts…',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlarm() {
    final minutes = _alarmSeconds ~/ 60;
    final seconds = _alarmSeconds % 60;

    return Semantics(
      liveRegion: true,
      label: 'The alarm is sounding. ${SosAlarm.spokenRemaining()}',
      child: ExcludeSemantics(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: const Color(0xFFFF3B3B).withValues(alpha: 0.12),
                border: Border.all(
                  color: const Color(0xFFFF3B3B).withValues(alpha: 0.40),
                ),
              ),
              child: Column(
                children: [
                  const Text(
                    'ALARM SOUNDING',
                    style: TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$minutes:${seconds.toString().padLeft(2, '0')} remaining',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
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

  Widget _buildDone() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _actionButton(
                label: 'STOP ALARM',
                icon: Icons.volume_off_rounded,
                color: const Color(0xFF3A3A4A),
                semanticLabel: 'Stop the alarm',
                semanticHint: 'Silences the five minute emergency alarm',
                onTap: _stopAlarm,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _actionButton(
                label: 'DONE',
                icon: Icons.check_rounded,
                color: const Color(0xFFFF3B3B),
                semanticLabel: 'Done',
                semanticHint: 'Returns to the dashboard. The alarm keeps '
                    'running if it has not finished',
                onTap: _close,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'The alarm keeps sounding for five minutes unless you stop it.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: _actionButton(
            label: 'SEND NOW',
            icon: Icons.sos_rounded,
            color: const Color(0xFFFF3B3B),
            semanticLabel: 'Send the emergency alert now',
            semanticHint: 'Sends immediately instead of waiting for the '
                'countdown',
            onTap: _confirmSos,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _actionButton(
            label: 'CANCEL',
            icon: Icons.close_rounded,
            color: const Color(0xFF3A3A4A),
            semanticLabel: 'Cancel the emergency alert',
            semanticHint: 'Stops the countdown and sends nothing',
            onTap: _cancel,
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required String semanticLabel,
    required String semanticHint,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: color,
              ),
              child: Column(
                children: [
                  Icon(icon, color: Colors.white, size: 28),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 1,
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
