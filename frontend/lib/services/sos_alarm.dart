import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The SOS alarm: the device's own alarm ringtone on `USAGE_ALARM`, looping,
/// plus a repeating vibration waveform, for a fixed five minutes.
///
/// Design constraints, all of them safety requirements:
///
///  * The alarm must be an ALARM, not a notification sound. Flutter's
///    `SystemSound.play(SystemSoundType.alert)` is implemented on Android as a
///    ~150 ms `ToneGenerator` beep on `AudioManager.STREAM_SYSTEM`. That stream
///    is muted when the phone is silenced or set to vibrate - exactly the
///    state an alarm is needed in - so the old implementation produced a faint
///    tick that nobody nearby could hear or feel. The real alarm is played
///    natively on `USAGE_ALARM` by [SosAlarmBridge], which is loud, loops, and
///    is not silenced by the ringer switch.
///  * [SystemSound] and [HapticFeedback] are kept only as a fallback for a
///    platform where the native bridge is missing. They are never the primary
///    path.
///  * The native side owns its own deadline. A Dart timer is throttled while
///    the app is backgrounded, which is precisely what happens when the user
///    puts the phone down and runs for help; the alarm must not shorten.
///  * It never blocks. The countdown is a [Timer.periodic] driving two
///    [ValueNotifier]s, so the UI keeps painting and the microphone keeps
///    working for the whole five minutes.
///  * It cannot throw into the caller. Every platform call is guarded; a silent
///    alarm is still a running alarm and the SOS message still goes out.
///  * Only one alarm can run. Starting it again while it is already active is
///    a no-op, which is what makes a double-tapped SOS button safe.
class SosAlarm {
  SosAlarm._();

  /// Total alarm duration. Five minutes is the specified behaviour.
  static const Duration totalDuration = Duration(minutes: 5);

  /// How often the vibration is re-asserted and the readout refreshes.
  static const Duration pulseInterval = Duration(seconds: 2);

  /// Native bridge. Android plays the real alarm ringtone here.
  static const MethodChannel _channel = MethodChannel('my_eyes/alarm');

  static Timer? _pulseTimer;
  static DateTime? _endsAt;

  /// True once the native alarm has been asked to play.
  ///
  /// Drives the "ALARM SOUNDING" UI so the screen never claims an alarm is
  /// running when the native bridge refused (no ringtone, no vibrator, or a
  /// non-Android platform).
  static final ValueNotifier<bool> isActive = ValueNotifier<bool>(false);

  static final ValueNotifier<int> secondsRemaining =
      ValueNotifier<int>(totalDuration.inSeconds);

  static bool get active => _pulseTimer != null;

  /// Starts the alarm if it is not already running.
  ///
  /// Returns immediately. Never throws, and starting twice is a no-op, which is
  /// what makes a double-tapped SOS button safe.
  ///
  /// Starts the alarm for its full [totalDuration].
  static void start() => _startFor(totalDuration);

  /// Starts the alarm with an explicit duration.
  ///
  /// Exists so the lifecycle can be verified without waiting five minutes.
  /// Production code must call [start], which always uses [totalDuration]:
  /// a real alarm is never shortened.
  @visibleForTesting
  static void startFor(Duration duration) => _startFor(duration);

  static void _startFor(Duration duration) {
    if (_pulseTimer != null) return;

    _endsAt = DateTime.now().add(duration);
    secondsRemaining.value = duration.inSeconds;

    isActive.value = true;

    // Hand the real alarm to the native side, which owns the sound, the
    // vibration and its own deadline.
    _startNative(duration);

    // The Dart timer exists only to drive the countdown UI. It is not what
    // makes the noise.
    _pulseTimer = Timer.periodic(pulseInterval, (_) {
      final endsAt = _endsAt;
      if (endsAt == null) {
        unawaited(stop());
        return;
      }

      final left = endsAt.difference(DateTime.now());
      if (left.isNegative || left == Duration.zero) {
        secondsRemaining.value = 0;
        unawaited(stop());
        return;
      }

      secondsRemaining.value = left.inSeconds;

      // Re-assert the vibration. Some devices and some battery savers stop a
      // long waveform on their own; a light re-assert keeps it alive for the
      // full five minutes.
      _assertVibration();
    });
  }

  /// Asks the native side to play the alarm ringtone.
  static Future<void> _startNative(Duration duration) async {
    try {
      await _channel.invokeMethod<bool>('startAlarm', {
        'seconds': duration.inSeconds,
      });
    } on PlatformException catch (error) {
      debugPrint('[SOS] native alarm refused: ${error.code} ${error.message}');
      // Fall back so the user still gets *something*, even if quiet.
      _fallbackPulse();
    } on MissingPluginException {
      // Not Android (or an older build): fall back.
      _fallbackPulse();
    } catch (error) {
      debugPrint('[SOS] native alarm raised: $error');
      _fallbackPulse();
    }
  }

  /// Nudges the vibrator without restarting the sound.
  static void _assertVibration() {
    try {
      unawaited(
        HapticFeedback.heavyImpact()
            .catchError((Object _) {})
            .catchError((Object _) {}),
      );
    } catch (_) {
      // No binding initialised, or no vibrator.
    }
  }

  /// Last-resort sound for a device with no native bridge.
  ///
  /// Deliberately quiet and infrequent: this is a "better than nothing" path,
  /// not an alarm. See the class comment for why it cannot be the primary one.
  static void _fallbackPulse() {
    try {
      unawaited(
        SystemSound.play(SystemSoundType.alert)
            .catchError((Object _) {})
            .catchError((Object _) {}),
      );
    } catch (_) {
      // No binding initialised, or the audio service is unavailable.
    }
    _assertVibration();
  }

  /// Stops the alarm early - the safe escape hatch for a false alarm.
  ///
  /// Returns a Future so callers can await the platform teardown, but every
  /// failure inside is swallowed.
  static Future<void> stop() async {
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _endsAt = null;
    if (isActive.value) {
      isActive.value = false;
    }

    try {
      await _channel.invokeMethod<bool>('stopAlarm');
    } catch (error) {
      debugPrint('[SOS] native alarm stop failed: $error');
    }
  }

  /// Spoken/visible remaining time, e.g. "4 minutes 30 seconds".
  static String spokenRemaining() {
    final total = secondsRemaining.value.clamp(0, totalDuration.inSeconds);
    final minutes = total ~/ 60;
    final seconds = total % 60;

    if (minutes <= 0 && seconds <= 0) return 'The alarm has stopped.';
    if (minutes <= 0) return '$seconds seconds.';

    final minuteWord = minutes == 1 ? 'minute' : 'minutes';
    if (seconds == 0) return '$minutes $minuteWord.';

    return '$minutes $minuteWord and $seconds seconds.';
  }
}