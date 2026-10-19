import 'package:flutter/foundation.dart';

import 'companion.dart';
import 'voice_command_service.dart';

/// The single voice controller for every screen that runs before (or between)
/// authenticated sessions: splash -> account creation -> introduction ->
/// terms -> companion selection, plus the sign-in screens.
///
/// It is a thin, shared facade over [VoiceCommandService], which owns the one
/// TTS engine and the one recognizer for the whole app. Previously each screen
/// built its own `VoiceGuide` (its own `FlutterTts` + `SpeechToText`) and the
/// companion screen owned a *fourth* engine, so a companion voice chosen during
/// setup was not the voice used by the screens after it, and overlapping
/// engines competed for the microphone.
///
/// Nothing here keeps a permanent listener: the microphone is opened only for
/// the duration of a single prompt ([listenOnce]).
class VoiceGuide {
  VoiceGuide._();

  /// The one shared instance.
  static final VoiceGuide instance = VoiceGuide._();

  final VoiceCommandService _voice = VoiceCommandService.instance;

  /// Bumped by [stop] so a screen that was popped mid-sentence cannot speak
  /// (or open the microphone) after the next screen has taken over.
  int _generation = 0;

  /// Bumped on every new prompt so a superseded [listenOnce] result is ignored.
  int _prompt = 0;

  /// The last spoken line, so "repeat" works on the onboarding screens too.
  String? lastSpoken;

  /// Current generation token. Pass it to [speakIfCurrent] / [listenIfCurrent]
  /// so async work started by a screen that has since been disposed becomes a
  /// no-op instead of speaking over the next screen.
  int get generation => _generation;

  /// Speaks [text] and waits for it to finish. The microphone stays closed.
  Future<void> speak(
    String text, {
    TtsPace pace = TtsPace.normal,
    bool remember = true,
  }) async {
    if (text.trim().isEmpty) return;
    lastSpoken = text;
    await _voice.speak(
      text,
      resumeAfter: false,
      pace: pace,
      remember: remember,
    );
  }

  /// Speaks an instruction the user must not miss (errors, confirmations).
  Future<void> speakImportant(String text) =>
      speak(text, pace: TtsPace.important);

/// Speaks [text] in [companion]'s voice, used for the Alex/Maya previews so
  /// the user hears the real difference before choosing.
  Future<void> speakAs(
    CompanionProfile companion,
    String text, {
    TtsPace pace = TtsPace.normal,
    bool remember = true,
  }) async {
    if (text.trim().isEmpty) return;
    if (remember) lastSpoken = text;
    await _voice.speakAs(
      companion,
      text,
      remember: remember,
      pace: pace,
    );
  }

  /// Applies [companion] as the engine voice for every later utterance.
  ///
  /// Used so the confirmation after a choice is already spoken by the companion
  /// the user just picked, rather than the previous default.
  void configureCompanion(CompanionProfile companion) =>
      _voice.configureCompanionProfile(companion);

  /// Speaks [text] only if [token] is still the current generation.
  Future<void> speakIfCurrent(int token, String text) async {
    if (token != _generation) return;
    await speak(text);
  }

  /// Listens for one short answer and returns it, or null if nothing was
  /// heard / recognition is unavailable. The microphone closes again
  /// immediately afterwards.
  Future<String?> listenOnce() {
    _prompt++;
    return _voice.listenOnce();
  }

  /// Replays the most recent spoken line.
  Future<void> repeat() async {
    final text = lastSpoken;
    if (text == null || text.isEmpty) {
      await speak('There is nothing to repeat yet.');
      return;
    }
    await speak(text, remember: false);
  }

  /// Interrupts speech immediately without invalidating the current screen or
  /// cancelling an in-flight prompt. Used when switching companion previews so
  /// two voices never overlap.
  Future<void> stopSpeakingOnly() => _voice.stopSpeaking();

  /// Interrupts speech immediately and invalidates any pending prompt.
  ///
  /// This does NOT tear down a session owned by another screen. [VoiceGuide] is
  /// the pre-auth / between-sessions facade, but its `stop()` is called from
  /// `dispose()` on screens that can be popped while the dashboard is already
  /// running its own session. Calling the unconditional `stopAll()` here
  /// cleared the *dashboard's* command handler as well, which produced the worst
  /// possible failure for a blind user: the dashboard still showed "listening",
  /// the recognizer was live, and every command was silently dropped because it
  /// had nowhere to be delivered.
  ///
  /// When somebody does own the engine, only the speech is cut - the owner's
  /// session and microphone are left completely alone.
  Future<void> stop() async {
    _generation++;
    _prompt++;
    if (_voice.hasSessionOwner) {
      debugPrint('[VOICE] guide stop: a screen owns the session; '
          'leaving the microphone alone');
      await _voice.stopSpeaking();
      return;
    }
    await _voice.stopAll();
  }

  /// True when the engine is currently speaking.
  bool get isSpeaking => _voice.isSpeaking;

  /// The engine voice currently applied, for verification and logging.
  ResolvedVoice? get appliedVoice => _voice.appliedVoice;

  /// Whether the engine voice matches the active companion's gender.
  bool get companionVoiceMatchesGender => _voice.companionVoiceMatchesGender;

  @visibleForTesting
  int get promptGeneration => _prompt;
}
