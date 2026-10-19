import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../core/storage/secure_storage.dart';
import '../core/vision_mode.dart';
import 'companion.dart';
import 'tts_script_chunker.dart' as tts;

/// Explicit states for the continuous voice interaction loop.
///
/// The normal happy path is:
/// `idle -> listening -> commandDetected -> processing -> speaking ->
/// ready -> listening`.
///
/// Screens read this so a blind user always hears "what is happening", and
/// the engine itself uses it to guarantee the microphone is never left open
/// while a command is being executed.
enum VoiceState {
  /// Nothing is happening; the engine is idle between screens.
  idle,

  /// The recognizer is capturing speech.
  listening,

  /// A final transcript arrived and the microphone has already been cut.
  commandDetected,

  /// A command is executing (camera open, API call, navigation, ...).
  processing,

  /// A response is being spoken. The microphone is guaranteed closed.
  speaking,

  /// Spoken output finished; the microphone is about to reopen.
  ready,

  /// Listening is intentionally stopped (user asked, screen popped, ...).
  paused,

  /// Recognizer, permission or API level failure.
  error,

  /// The owning screen released the session.
  stopped,
}

/// Speech speed tiers.
///
/// [normal] is everyday conversation, [moduleResult] is the slower, clearer
/// delivery needed for OCR text, object labels and currency amounts, and
/// [important] is the slowest tier reserved for safety-critical messages.
enum TtsPace {
  normal,
  moduleResult,
  important,
}

/// Speech rate for each tier. Blind users need OCR output and emergency
/// instructions spoken noticeably slower than casual chat.
extension TtsPaceSettings on TtsPace {
  double get rate {
    switch (this) {
      case TtsPace.normal:
        return 0.45;
      case TtsPace.moduleResult:
        return 0.36;
      case TtsPace.important:
        return 0.32;
    }
  }
}

/// Voice-first command engine for My Eyes.
///
/// A single shared instance drives every screen so that only one
/// microphone session exists at a time. Each screen registers its
/// own handlers through [startSession], keeps the returned session token,
/// and releases it with [stopSession]. Passing the token makes teardown
/// safe: a widget that is disposed late (its `Navigator` future has already
/// resolved and the next screen has already started listening) can no longer
/// tear down the newer session. This was the root cause of "the microphone
/// is dead until I tap the button again" after a module round trip.
class VoiceCommandService {
  VoiceCommandService._();

  static final VoiceCommandService instance = VoiceCommandService._();

  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _ttsReady = false;
  bool _speechReady = false;
  bool _speechUnavailableReported = false;
  bool _micPermissionChecked = false;

  bool _shouldListen = false;
  bool _listening = false;
  bool _speaking = false;
  int _failureCount = 0;
  int _session = 0;

  VoiceState _state = VoiceState.idle;

  /// Serializes microphone start/stop operations so overlapping
  /// `listen()` / `cancel()` calls never corrupt the Android recognizer
  /// (the root cause of the microphone "going deaf" after a module round
  /// trip: concurrent recognizer operations racing).
  bool _micBusy = false;

  /// Incremented whenever the microphone is stopped or restarted. Stale
  /// recognizer callbacks from a superseded listen are then ignored.
  int _listenGeneration = 0;

  /// Set while the app is backgrounded so the engine pauses and gracefully
  /// resumes without spin-loops.
  bool _inBackground = false;

  /// A resume was requested while backgrounded (permission dialog, system
  /// camera, ...). Replayed by [resumeAfterLifecycle] so the microphone is
  /// never left dead because the foreground handler arrived too early.
  bool _pendingResume = false;

  /// Health timer that guarantees the microphone is genuinely ON whenever a
  /// session owns it and the engine believes it should be listening.
  ///
  /// Everything else in this class is event driven: something has to call
  /// [resumeMicrophone] for the recognizer to run. A single missed event - a
  /// widget disposed late, a handler that threw, a recognizer error while the
  /// app was backgrounded, a lifecycle callback that arrived before its screen
  /// mounted - leaves `_shouldListen == false` and nothing ever calls it again.
  /// For a blind user that is an app that still *looks* ready while silently
  /// ignoring every spoken command, which is the single worst failure this app
  /// can have.
  ///
  /// The watchdog closes that hole. While a session is registered, the engine
  /// is not busy, and the session *intends* to listen, it verifies the
  /// recognizer is really capturing and reopens it if not.
  Timer? _watchdog;

  /// Set once the engine has told the user out loud that it cannot hear them.
  /// Prevents a broken recognizer from repeating the same apology every two
  /// seconds; cleared the moment listening works again.
  bool _micDeadAnnounced = false;

  /// Session that last asked to stop listening.
  ///
  /// This exists because of Flutter's teardown order. A popped screen's
  /// `dispose()` runs *after* its route future has already resolved, which is
  /// after the screen underneath has started its own session. So the outgoing
  /// module's `pauseMicrophone()` used to shut the microphone of the dashboard
  /// that had just taken over: the dashboard showed "listening", its handler
  /// was registered, and nothing was ever heard again.
  ///
  /// Recording who asked means a pause belonging to a superseded session is
  /// recognised as stale and dropped instead of applied to the current owner.
  int? _pauseOwnerSession;

  /// Last transcript handed to the active handler, used to swallow the
  /// duplicate final results Android emits after `cancel()`.
  String _lastDispatched = '';
  DateTime _lastDispatchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Recognizer tuning. `pauseFor` is deliberately short so a finished
  /// command is dispatched without a long silence wait; the microphone is
  /// cut immediately on a final result, so `listenFor` is only an upper
  /// bound for a user who never speaks.
  static const Duration _listenFor = Duration(seconds: 12);
  static const Duration _pauseFor = Duration(seconds: 2);

  /// Settle time after cancelling the recognizer, before reopening it.
  /// Gives the audio pipeline and TTS time to release the microphone.
  static const Duration _micSettle = Duration(milliseconds: 280);

  /// A command repeated verbatim inside this window is treated as a
  /// recognizer duplicate, not a new request.
  static const Duration _duplicateWindow = Duration(seconds: 3);

  /// Companion voice state (Alex = male, Maya = female). Cached so the TTS
  /// voice is applied once and persists across login, module opens/closes
  /// and every listening restart.
  ///
  /// The authoritative live value is [appliedCompanion]; this mirror exists so
  /// the cache check is a cheap string comparison instead of re-reading secure
  /// storage on every TTS setup.
  // ignore: unused_field
  String _companionGender = 'male';
  bool _companionLoaded = false;

  /// The engine voice currently applied, kept so the companion picker can
  /// verify it really switched voices (and report honestly when the device has
  /// no identifiable voice of the requested gender) instead of assuming the
  /// companion name was enough.
  ResolvedVoice? _appliedVoice;

  /// Companion whose voice is currently applied. Previews set this to the
  /// companion being previewed, so switching companions mid-preview is safe.
  CompanionProfile _appliedCompanion = Companions.alex;

  /// Speed tier currently applied to the TTS engine.
  TtsPace _pace = TtsPace.normal;

  /// Shared handle to a single in-flight initialization, so concurrent
  /// callers never initialize the recognizer twice.
  Future<bool>? _initializing;

  /// Current explicit state of the voice engine.
  VoiceState get state => _state;

  /// Token identifying the session that currently owns the microphone.
  int get session => _session;

  /// The most recent spoken result, shared across every screen so "repeat",
  /// "say that again" and "repeat it" replay the same answer. Set through
  /// [speak] with `remember: true`.
  String? lastAnswer;

  /// Alias used by repeat flows that read the shared response.
  String? get lastSpokenResponse => lastAnswer;

  /// Called with a final transcript whenever the user finishes a phrase.
  FutureOr<void> Function(String transcript)? onCommand;

  /// Called with the live (partial) transcript while listening.
  void Function(String transcript)? onHeard;

  /// Called when the microphone state changes.
  void Function(bool listening)? onListeningChanged;

  /// Called whenever the explicit [state] changes.
  void Function(VoiceState state)? onStateChanged;

  bool get isListening => _listening || _shouldListen;

  bool get isSpeaking => _speaking;

  /// True while a screen owns the engine, i.e. it registered handlers through
  /// [startSession] and has not released them.
  ///
  /// [VoiceGuide] uses this to avoid tearing down a session it does not own -
  /// a pre-auth screen being disposed late must never blind the dashboard.
  bool get hasSessionOwner => onCommand != null;

  /// True when [sessionId] is the session that currently owns the engine.
  ///
  /// A screen's `dispose()` runs after its route future resolved, so by then a
  /// newer screen usually owns the microphone. Screens must check this before
  /// shutting it down on the way out, or they silence the screen that replaced
  /// them. See [_pauseOwnerSession] for the engine-side protection.
  bool ownsSession(int? sessionId) =>
      sessionId != null && sessionId == _session;

  /// True when the microphone is genuinely usable right now.
  ///
  /// Screens must check this rather than [isListening] before telling a user
  /// the microphone is on. [isListening] reports the *intent* to listen and is
  /// true even when initialization failed, so a dead microphone used to look
  /// healthy on screen and in the code.
  ///
  /// Requires [_listening] as well as a clean error state on purpose. Checking
  /// only the error string made the dashboard announce "I could not open the
  /// microphone" while the microphone was demonstrably recording: a single
  /// transient recognizer complaint (`error_no_match`, a timeout, an error
  /// while the app was briefly backgrounded) set the flag and nothing ever
  /// cleared it. For a blind user that is worse than no message at all - it
  /// contradicts what the app is actually doing.
  bool get recognizerHealthy =>
      _speechReady && _listening && _lastRecognizerError == null;

  /// True once speech recognition has been initialized successfully.
  ///
  /// This is the *actionable* health check. False means the app genuinely
  /// cannot hear anything and the user has to fix a permission or install a
  /// recognition service - a problem no amount of waiting will solve, so it is
  /// the only condition worth interrupting the user to report. A mic that is
  /// merely mid-restart is handled by the watchdog, and a mic that has failed
  /// persistently is reported by the engine itself, so neither needs to
  /// interrupt the user with a scary message.
  bool get recognizerAvailable => _speechReady;

  void _setState(VoiceState newState) {
    if (_state == newState) return;
    _state = newState;
    debugPrint('[VOICE] state -> ${newState.name}');
    onStateChanged?.call(newState);
  }

  /// True while the engine is in a state where the microphone must stay shut.
  bool get _micMustBeClosed =>
      _speaking ||
      _state == VoiceState.commandDetected ||
      _state == VoiceState.processing;

  // ============================================================
  // INITIALIZATION
  // ============================================================

  /// Applies the selected companion's TTS voice (Alex = male, Maya =
  /// female). Called automatically on first initialize, and exposed so
  /// callers (e.g. companion selection, dashboard) can switch it live.
  void configureCompanion({
    required String name,
    required String gender,
  }) {
    _configureCompanion(Companions.fromStored(name: name, gender: gender));
  }

  /// Applies [companion] as the active voice for every later utterance.
  void configureCompanionProfile(CompanionProfile companion) {
    _configureCompanion(companion);
  }

  /// Switches the engine voice and *waits* for it, so the next [speak] cannot
  /// start before the new voice is actually installed.
  Future<void> _configureCompanion(CompanionProfile companion) async {
    _appliedCompanion = companion;
    _companionGender = companion.isMale ? 'male' : 'female';
    _companionLoaded = true;
    await _applyCompanionVoice();
  }

  /// The companion whose voice is currently applied to the engine.
  CompanionProfile get appliedCompanion => _appliedCompanion;

  /// The engine voice that was actually selected, for verification/logging.
  ResolvedVoice? get appliedVoice => _appliedVoice;

  /// True when the engine voice is a recognised voice of the companion's
  /// gender. False on devices that only ship voices of the other gender; the
  /// companion pitch is applied in that case to compensate.
  bool get companionVoiceMatchesGender =>
      _appliedVoice?.matchesRequestedGender ?? false;

  Future<void> _loadCompanion() async {
    if (_companionLoaded) return;
    _companionLoaded = true;
    try {
      final companion = await SecureStorage.readCompanion();
      _companionGender = companion.gender;
      _appliedCompanion = Companions.fromStored(
        name: companion.name,
        gender: companion.gender,
      );
    } catch (_) {
      // Default to Alex if storage is unavailable.
    }
  }

  /// Selects and applies a matching English TTS voice + pitch for the
  /// selected companion. Uses the shared [CompanionVoicePicker] so the
  /// onboarding preview and every later message use the *same* voice.
  ///
  /// The speech *rate* is deliberately not touched here: it is applied per
  /// message from [TtsPace] so one slow module result cannot permanently
  /// slow down (or a chat message speed up) everything else.
  Future<void> _applyCompanionVoice() async {
    if (!_ttsReady) return;

    final companion = _appliedCompanion;

    try {
      await _tts.setLanguage('en-US');
      await _tts.setVolume(1.0);

      List<dynamic>? voices;
      try {
        final raw = await _tts.getVoices;
        if (raw is List) voices = raw;
      } catch (_) {
        voices = null;
      }

      final resolved = CompanionVoicePicker.pick(voices, companion.gender);

      if (resolved == null) {
        _appliedVoice = null;
        debugPrint(
          '[TTS] no ${companion.name} voice available; '
          'using the engine default voice',
        );
      } else {
        _appliedVoice = resolved;
        if (resolved.matchesRequestedGender) {
          debugPrint('[TTS] ${companion.name} voice -> $resolved');
        } else {
          debugPrint(
            '[TTS] ${companion.name} has no ${companion.gender.name} voice on '
            'this device; using $resolved and relying on pitch '
            '${companion.pitch}',
          );
        }
        try {
          await _tts.setVoice(<String, String>{
            'name': resolved.name,
            'locale': resolved.locale,
          });
        } catch (_) {}
      }

      await _tts.setPitch(companion.pitch);
    } catch (_) {
      // Never let a TTS voice failure break the flow for a blind user.
    }
  }

  /// Idempotent TTS engine setup. Kept separate from the recognizer setup so
  /// a permission prompt can speak without re-entering [initialize].
  Future<void> _ensureTts() async {
    if (_ttsReady) return;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(_pace.rate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    _ttsReady = true;

    await _loadCompanion();
    _applyCompanionVoice();
  }

  /// Check / request microphone permission. Returns true when granted.
  ///
  /// Does not repeatedly prompt: once denied (permanently) it reports the
  /// denial and the caller can route the user to Android settings via
  /// [openSettings].
  ///
  /// Pass `announce: false` to re-check silently. A silent check is what later
  /// attempts use, so a user who granted access in Settings and came back gets a
  /// working microphone instead of a permanent "permission denied".
  Future<bool> requestMicPermission({bool announce = true}) async {
    try {
      var status = await ph.Permission.microphone.status;
      if (status.isGranted) return true;

      if (status.isPermanentlyDenied) {
        if (announce) {
          await _speakDirect(
            'Microphone access is turned off for this app. '
            'You can enable it in your phone settings.',
            TtsPace.important,
          );
        }
        return false;
      }

      if (status.isDenied) {
        status = await ph.Permission.microphone.request();
        if (status.isGranted) return true;
      }

      if (announce) {
        await _speakDirect(
          'Microphone access is required for voice commands. '
          'You can enable it in your phone settings.',
          TtsPace.important,
        );
      }
      return false;
    } catch (_) {
      // Permission plugin unavailable; fall back to letting the speech
      // recognizer request it itself.
      return true;
    }
  }

  /// Silent permission re-check used on retry paths. Returns true when the
  /// permission is granted (or the plugin is unavailable, matching
  /// [requestMicPermission]'s fallback).
  Future<bool> _micGrantedNow() async {
    try {
      return (await ph.Permission.microphone.status).isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Opens the Android app settings so the user can grant a permission
  /// that was permanently denied.
  Future<void> openSettings() async {
    try {
      await ph.openAppSettings();
    } catch (_) {}
  }

  /// Prepares both TTS and speech recognition. Safe to call concurrently.
  Future<bool> initialize() async {
    await _ensureTts();

    final existing = _initializing;
    if (existing != null) return existing;

    final future = _initializeRecognizer();
    _initializing = future;
    try {
      return await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<bool> _initializeRecognizer() async {
    if (_speechReady) return true;

    // Ask for microphone permission clearly on first use. If denied, speak
    // once and stop - do not ping the user repeatedly.
    //
    // On every later attempt the permission is re-checked *silently*. That is
    // the difference between a recoverable and a permanently deaf app: a user
    // who grants the permission in Settings and returns must get a live
    // microphone, but must not be shown a second system dialog.
    var mic = true;
    if (!_micPermissionChecked) {
      _micPermissionChecked = true;
      mic = await requestMicPermission();
    } else {
      mic = await _micGrantedNow();
    }

    if (!mic) {
      _speechReady = false;
      _speechUnavailableReported = true;
      _lastRecognizerError = 'microphone permission denied';
      debugPrint('[VOICE] recognizer unavailable: microphone denied');
      return false;
    }

    try {
      _speechReady = await _speech.initialize(
        onError: _onRecognizerError,
        onStatus: _onRecognizerStatus,
        debugLogging: false,
      );
    } catch (error) {
      _speechReady = false;
      _lastRecognizerError = '$error';
      debugPrint('[VOICE] recognizer init failed: $error');
    }

    if (_speechReady) {
      _lastRecognizerError = null;
      // The recognizer is healthy again, so both "unavailable" notices are
      // stale. Without this reset, a single early failure permanently silenced
      // every later explanation on every later screen.
      _speechUnavailableReported = false;
      _micDeadAnnounced = false;
    } else if (_lastRecognizerError == null) {
      // initialize() returned false without throwing. This is the signature
      // of Android package visibility hiding the recognition service, which is
      // the single most common cause and produces no error message at all.
      _lastRecognizerError =
          'no speech recognition service is visible to the app';
      debugPrint(
        '[VOICE] no recognition service found. If the microphone never turns '
        'on, check that AndroidManifest.xml declares '
        '<action android:name="android.speech.RecognitionService" /> inside '
        '<queries>.',
      );
    }

    debugPrint('[VOICE] recognizer ready: $_speechReady');
    return _speechReady;
  }

  /// Why the recognizer failed, for diagnostics. Null when it is healthy.
  ///
  /// The previous behaviour was to log and move on, so a completely dead
  /// microphone looked identical to a quiet room. This is surfaced to the
  /// caller so it can speak the real reason instead of going silently.
  String? get lastRecognizerError => _lastRecognizerError;
  String? _lastRecognizerError;

  void _onRecognizerError(SpeechRecognitionError error) {
    debugPrint('[VOICE] recognizer error: ${error.errorMsg} (${error.permanent})');
    _lastRecognizerError = error.errorMsg;
    if (!_shouldListen) return;
    _listening = false;
    _notifyListening();
    _setState(VoiceState.error);
    if (_hasPendingPartial) {
      debugPrint('[VOICE] recognizer error after partial transcript; '
          'waiting for it to settle');
      return;
    }
    _scheduleRestart();
  }

  void _onRecognizerStatus(String status) {
    debugPrint('[VOICE] recognizer status: $status');
    if (status != 'notListening' && status != 'done') return;
    if (!_shouldListen) return;
    _listening = false;
    _notifyListening();

    // A valid partial is a command candidate, not a reason to throw the turn
    // away.  Let its debounce timer deliver it.  Restarting here increments
    // the listen generation before that timer runs, which was the exact path
    // that made recognised commands appear on screen but never reach their
    // module/router.
    if (_hasPendingPartial) {
      debugPrint('[VOICE] recognizer ended with partial transcript; '
          'waiting for it to settle');
      return;
    }
    _scheduleRestart();
  }

  // ============================================================
  // SPEAK (MICROPHONE IS ALWAYS CLOSED WHILE TALKING)
  // ============================================================

  /// Speaks [text] with the microphone guaranteed closed.
  ///
  /// [pace] selects the speed tier, [remember] stores the text as the shared
  /// response for later "repeat" commands, and [resumeAfter] reopens the
  /// microphone once speech finishes.
  Future<void> speak(
    String text, {
    bool resumeAfter = true,
    TtsPace pace = TtsPace.normal,
    bool remember = false,
  }) async {
    if (text.trim().isEmpty) return;

    final session = _session;

    // Set synchronously so pending restart timers stand down and any other
    // recognizer callback is ignored for the rest of this call.
    _speaking = true;
    _shouldListen = false;
    _setState(VoiceState.speaking);
    await _ensureTts();

    // A newer screen took over while we were initializing: drop this speech.
    if (session != _session) {
      _speaking = false;
      return;
    }

    await _applyPace(pace);

    try {
      await _tts.stop();
      await _tts.speak(text).timeout(_speakTimeout(text));
    } on TimeoutException {
      debugPrint('[TTS] speak timed out, cancelling ${text.length} chars');
      try {
        await _tts.stop();
      } catch (_) {}
    } catch (_) {
      // Never let a TTS failure break the flow for a blind user.
    }

    if (remember) lastAnswer = text;

    _speaking = false;

    if (session != _session || _inBackground) return;

    if (resumeAfter) {
      await resumeMicrophone();
    } else {
      _setState(VoiceState.paused);
    }
  }

  /// Upper bound for a single utterance. Without it a stuck TTS engine would
  /// leave the app permanently in SPEAKING with a shut microphone.
  Duration _speakTimeout(String text) {
    final seconds = 20 + (text.length / 10).ceil();
    return Duration(seconds: seconds.clamp(20, 90));
  }

  /// Maximum characters handed to the TTS engine in one call.
  ///
  /// Re-exported from the dependency-free chunker so callers and tests can
  /// reference the cap without importing the chunker separately.
  static const int maxSpeechChunkChars = tts.maxSpeechChunkChars;

  /// Splits [text] into TTS-sized utterances. See [tts.chunkForSpeech].
  static List<String> chunkForSpeech(String text, {int? maxChars}) =>
      maxChars == null
          ? tts.chunkForSpeech(text)
          : tts.chunkForSpeech(text, maxChars: maxChars);

  /// Speaks a long script as a sequence of short utterances.
  ///
  /// The dashboard guide is thousands of characters. Handing that to
  /// `flutter_tts` as one call is what broke the Instructions button: the
  /// engine began, then the single-utterance timeout in [speak] fired and
  /// stopped it partway, so tapping the eye produced a truncated guide and then
  /// silence. [chunkForSpeech] gives each part its own completion callback and
  /// its own timeout, so the whole script is delivered.
  ///
  /// The microphone stays closed for the entire run, and the same session /
  /// background guards as [speak] apply to every chunk, so a screen popped
  /// mid-guide stops talking immediately instead of reading on.
  Future<void> speakLong(
    String text, {
    TtsPace pace = TtsPace.normal,
    bool remember = false,
    bool resumeAfter = true,
  }) async {
    if (text.trim().isEmpty) return;

    final chunks = chunkForSpeech(text);

    // Already short enough: one clean utterance, no chunking overhead.
    if (chunks.length <= 1) {
      await speak(
        text,
        pace: pace,
        remember: remember,
        resumeAfter: resumeAfter,
      );
      return;
    }

    final session = _session;

    _speaking = true;
    _shouldListen = false;
    _setState(VoiceState.speaking);
    await _ensureTts();

    if (session != _session) {
      _speaking = false;
      return;
    }

    await _applyPace(pace);

    debugPrint('[TTS] long script: ${chunks.length} chunks, '
        '${text.length} chars');

    for (final chunk in chunks) {
      // A newer screen took over, the app went to the background, or something
      // else already reopened the microphone: stop talking rather than reading
      // a guide nobody is listening to.
      if (session != _session || _inBackground) break;
      if (_shouldListen) break;

      try {
        await _tts.stop();
        await _tts.speak(chunk).timeout(_speakTimeout(chunk));
      } on TimeoutException {
        debugPrint('[TTS] chunk timed out: ${chunk.length} chars');
        try {
          await _tts.stop();
        } catch (_) {}
      } catch (error) {
        debugPrint('[TTS] chunk failed: $error');
      }
    }

    if (remember) lastAnswer = text;

    _speaking = false;

    if (session != _session || _inBackground) return;

    if (resumeAfter) {
      await resumeMicrophone();
    } else {
      _setState(VoiceState.paused);
    }
  }

  Future<void> _applyPace(TtsPace pace) async {
    if (_pace == pace) return;
    _pace = pace;
    try {
      await _tts.setSpeechRate(pace.rate);
      debugPrint('[TTS] pace -> ${pace.name} (${pace.rate})');
    } catch (_) {}
  }

  /// Speaks without touching the recognizer or the session state machine.
  /// Used by the permission flow, which runs *inside* [initialize] and must
  /// therefore not call [speak] back.
  Future<void> _speakDirect(String text, TtsPace pace) async {
    await _ensureTts();
    _speaking = true;
    await _applyPace(pace);
    try {
      await _tts.stop();
      await _tts.speak(text).timeout(_speakTimeout(text));
    } catch (_) {}
    _speaking = false;
  }

  /// Stops any in-progress TTS without resuming the microphone.
  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _speaking = false;
    if (!_shouldListen && !_listening && !_micMustBeClosed) {
      _setState(VoiceState.paused);
    }
  }

  /// Interrupt speech immediately and return to listening. Used when the
  /// user says "stop" while a long response is being spoken.
  Future<void> interrupt() async {
    await stopSpeaking();
    final session = _session;
    if (_inBackground) {
      _pendingResume = true;
      return;
    }
    if (_shouldListen && session == _session) {
      await resumeMicrophone();
    }
  }

  /// Marks the engine as busy executing a command. The microphone is closed
  /// synchronously-ish (awaited by the caller) so it cannot pick up the
  /// screen's own announcements.
  Future<void> setProcessing() async {
    if (_inBackground) return;
    _pauseOwnerSession = _session;
    _shouldListen = false;
    _setState(VoiceState.processing);
    await _stopMicrophone();
  }

  // ============================================================
  // APP LIFECYCLE
  // ============================================================

  /// Pause voice recognition when the app goes to background / is hidden or
  /// the screen locks. Android restricts the microphone in the background, so
  /// we stop cleanly and remember to resume on return.
  Future<void> pauseForLifecycle() async {
    _inBackground = true;
    _pendingResume = false;
    await _stopMicrophone();
    await stopSpeaking();
    _setState(VoiceState.paused);
  }

  /// Resume the continuous voice loop when the app returns to the foreground.
  ///
  /// A permission dialog or the system camera can make the app briefly
  /// inactive in the middle of [startSession], which parks the resume in
  /// [_pendingResume]; replaying it here is what keeps the microphone alive
  /// on the very first run.
  Future<void> resumeAfterLifecycle() async {
    _inBackground = false;
    final session = _session;
    final wants = _pendingResume || _shouldListen;
    _pendingResume = false;
    if (wants && session == _session) {
      await resumeMicrophone();
    }
  }

  // ============================================================
  // SESSION MANAGEMENT (TOKEN OWNED)
  // ============================================================

  /// Registers handlers for the active screen and starts listening.
  ///
  /// Returns the session token the caller must hand back to [stopSession].
  Future<int> startSession({
    required FutureOr<void> Function(String transcript) onCommand,
    void Function(String transcript)? onHeard,
    void Function(bool listening)? onListeningChanged,
    void Function(VoiceState state)? onStateChanged,
    bool autoStart = true,
  }) async {
    final session = ++_session;
    this.onCommand = onCommand;
    this.onHeard = onHeard;
    this.onListeningChanged = onListeningChanged;
    this.onStateChanged = onStateChanged;
    _pendingResume = false;
    _failureCount = 0;
    _resetDuplicateGuard();
    _startWatchdog();
    debugPrint('[VOICE] startSession #$session');

    await stopSpeaking();

    if (!autoStart) return session;

    if (_inBackground) {
      _pendingResume = true;
      return session;
    }

    final ready = await initialize();
    if (!ready) {
      if (!_speechUnavailableReported) {
        _speechUnavailableReported = true;
        await speak(
          'Voice recognition is not available right now. '
          'You can still use the touch controls.',
          resumeAfter: false,
          pace: TtsPace.important,
        );
      }
      return session;
    }

    await resumeMicrophone();
    return session;
  }

  /// Stops listening and clears handlers.
  ///
  /// Pass the token returned by [startSession]. A stale token (this widget
  /// was disposed after its route future resolved and the next screen already
  /// started a session) is ignored, which is what previously left the
  /// dashboard microphone dead after returning from a module.
  /// Omit the token only for a genuine global teardown such as logout.
  Future<void> stopSession([int? sessionId]) async {
    if (sessionId != null && sessionId != _session) {
      debugPrint(
        '[VOICE] stopSession ignored: stale $sessionId, current $_session',
      );
      return;
    }
    _session++;
    onCommand = null;
    onHeard = null;
    onListeningChanged = null;
    onStateChanged = null;
    _stopWatchdog();

    _shouldListen = false;
    _pendingResume = false;
    _pauseOwnerSession = null;
    _resetDuplicateGuard();
    await _stopMicrophone();
    await stopSpeaking();
    _setState(VoiceState.stopped);
    debugPrint('[VOICE] stopSession -> session $_session');
  }

  /// Releases the engine on behalf of the screen that owns [sessionId].
  ///
  /// Safe with a token that was never issued. A widget can be disposed before
  /// its session is established - the post-frame callback that starts the
  /// session may not have run yet - and a null token must NOT be interpreted as
  /// a global teardown, or that screen silently silences whichever screen is
  /// currently listening.
  ///
  /// [stopSession] already stops the recognizer and any speech when it actually
  /// owns the session, so callers do not need a separate pause.
  Future<void> releaseSession(int? sessionId) async {
    if (sessionId == null) {
      debugPrint('[VOICE] release: no session was ever established');
      return;
    }
    await stopSession(sessionId);
  }

  /// Unconditionally tears down the microphone, whoever owns it. Only for
  /// real global teardown (logout, sign-out), never for a screen `dispose()`.
  Future<void> stopAll() => stopSession();

  // ============================================================
  // MICROPHONE CONTROL
  // ============================================================

  /// Takes the microphone lock, waiting for any in-flight operation to finish.
  ///
  /// The wait is bounded on purpose. The previous unbounded spin loop meant
  /// that any recognizer call which threw outside its own `try/finally` left
  /// `_micBusy` stuck `true` forever, after which `resumeMicrophone` and
  /// `_stopMicrophone` both spun indefinitely and the microphone was
  /// permanently shut with no recovery path. Breaking a stale lock is strictly
  /// better than hanging: the worst case is one extra recognizer restart.
  Future<void> _acquireMic({int maxWaitMs = 4000}) async {
    var waited = 0;
    while (_micBusy) {
      if (waited >= maxWaitMs) {
        debugPrint('[VOICE] microphone lock stuck after ${waited}ms; '
            'forcing release');
        _micBusy = false;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      waited += 20;
    }
    _micBusy = true;
  }

  /// Reopens the microphone and returns to the LISTENING state.
  Future<void> resumeMicrophone() async {
    if (_inBackground) {
      _pendingResume = true;
      debugPrint('[VOICE] resume deferred: app backgrounded');
      return;
    }

    if (!_shouldListen && !_listening) {
      _shouldListen = true;
      // This session is now actively listening, so any pause on record belongs
      // to an earlier owner and must not hold the microphone shut.
      _pauseOwnerSession = null;
    }

    if (_listening || _speaking) return;

    final ready = await initialize();
    if (!ready) return;

    // Serialize so only one mic operation runs at a time. This prevents
    // two concurrent `listen()`/`cancel()` calls from racing on the shared
    // SpeechToText recognizer, which is what left it dead after navigation.
    await _acquireMic();
    try {
      if (!_shouldListen || _speaking || _listening || _inBackground) return;

      final token = ++_listenGeneration;

      // Clear any stuck recognition session left by the system camera, TTS
      // or a previous listen. This is essential for reliable restarts.
      try {
        await _speech.cancel();
      } catch (_) {}

      // Give the audio pipeline a moment to settle and let TTS release the
      // microphone, otherwise the recogniser starts deaf.
      await Future<void>.delayed(_micSettle);

      // Superseded while settling (stop/restart happened)?
      if (token != _listenGeneration) return;
      if (!_shouldListen || _speaking || _listening || _inBackground) return;

      _failureCount = 0;
      _listening = true;
      _resetPartialTracking();
      // A recognizer that opens cleanly is working, whatever it complained
      // about on a previous attempt. Clearing here means a recovered
      // microphone stops reporting itself as broken.
      _lastRecognizerError = null;
      _micDeadAnnounced = false;
      _setState(VoiceState.ready);
      _setState(VoiceState.listening);
      _notifyListening();

      // Start listening WITHOUT awaiting the long-lived recognizer future.
      // Blocking on it caused re-entrant `listen()` calls via the
      // onStatus/onError callbacks. Completion / restart is driven by the
      // callbacks below through a controlled, guarded restart.
      _speech
          .listen(
            onResult: (result) {
              if (token != _listenGeneration) return;
              final words = result.recognizedWords.trim();
              if (words.isEmpty) return;

              // Hearing anything at all clears the error state. The recognizer
              // reporting `error_no_match` or a timeout once used to set
              // `_lastRecognizerError` permanently, so `recognizerHealthy`
              // stayed false for the rest of the process and the dashboard
              // told the user "I could not open the microphone" while the
              // microphone was demonstrably working - see screenshot: mic
              // listening and "choose file" heard, yet the error banner shown.
              _lastRecognizerError = null;
              _micDeadAnnounced = false;

              onHeard?.call(words);

              if (result.finalResult) {
                _onFinalResult(token, words);
                return;
              }

              // Act on a transcript that has stopped changing instead of
              // waiting for a `finalResult` that may never arrive.
              _trackPartial(token, words);
            },
            listenOptions: stt.SpeechListenOptions(
              listenFor: _listenFor,
              pauseFor: _pauseFor,
              partialResults: true,
              cancelOnError: true,
            ),
          )
          .then((_) {
            if (token != _listenGeneration) return;
            if (_hasPendingPartial) {
              debugPrint('[VOICE] recognizer completed with partial '
                  'transcript; waiting for it to settle');
              return;
            }
            _scheduleRestart();
          })
          .onError((_, _) {
            if (token != _listenGeneration) return;
            if (_hasPendingPartial) {
              debugPrint('[VOICE] recognizer closed with partial transcript; '
                  'waiting for it to settle');
              return;
            }
            _scheduleRestart();
          });
    } catch (e) {
      debugPrint('[VOICE] listen failed: $e');
      if (_listening) {
        _listening = false;
        _notifyListening();
      }
      _setState(VoiceState.error);
      _scheduleRestart();
    } finally {
      _micBusy = false;
    }
  }

  /// Temporarily pauses listening (e.g. camera, biometrics, speaking).
  ///
  /// Pass the token returned by [startSession] so a pause issued by a screen
  /// that has already been replaced is ignored. See [_pauseOwnerSession].
  Future<void> pauseMicrophone([int? sessionId]) async {
    final owner = sessionId ?? _session;
    if (owner != _session) {
      debugPrint('[VOICE] pauseMicrophone ignored: stale $owner, '
          'current $_session');
      return;
    }

    _pauseOwnerSession = owner;
    _shouldListen = false;
    await _stopMicrophone();
  }

  Future<void> _stopMicrophone() async {
    await _acquireMic();
    try {
      if (!_listening) {
        _maybeSettlePaused();
        return;
      }
      _listenGeneration++; // invalidate the in-flight listen's callbacks
      _listening = false;
      _resetPartialTracking();
      _notifyListening();
      try {
        await _speech.cancel();
      } catch (_) {}
      _maybeSettlePaused();
    } finally {
      _micBusy = false;
    }
  }

  // ============================================================
  // ONE-SHOT LISTENING (PRE-SESSION / ONBOARDING)
  // ============================================================

  /// Listens for a *single* short answer and returns it, then closes the
  /// microphone again.
  ///
  /// Used by the onboarding screens (account confirmation, "say select",
  /// terms) so they never keep a permanent recognizer running. It reuses the
  /// single shared recognizer and the same mic serialization as the continuous
  /// loop, so a one-shot prompt cannot race a continuous session and leave the
  /// microphone deaf. Returns null when nothing was heard, when recognition is
  /// unavailable, or when a newer call superseded this one.
  Future<String?> listenOnce({
    Duration listenFor = const Duration(seconds: 8),
    Duration settle = const Duration(milliseconds: 500),
    int attempts = 2,
  }) async {
    // Let TTS release the microphone before the recognizer opens.
    await Future<void>.delayed(settle);

    if (_inBackground) return null;

    for (var attempt = 0; attempt < attempts; attempt++) {
      final token = ++_listenGeneration;

      // A continuous session owns the microphone; never fight it.
      if (_shouldListen) return null;

      final ready = await initialize();
      if (!ready) {
        if (!_speechUnavailableReported) {
          _speechUnavailableReported = true;
          debugPrint('[VOICE] one-shot unavailable: recognizer not ready');
        }
        return null;
      }

      if (_inBackground) return null;

      // Serialize with the continuous loop so only one recognizer operation
      // runs at a time.
      await _acquireMic();

      String? heard;
      try {
        if (_speaking) return null;

        try {
          await _speech.cancel();
        } catch (_) {}

        await Future<void>.delayed(_micSettle);

        if (token != _listenGeneration || _inBackground) return null;

        _speech.listen(
          onResult: (result) {
            if (token != _listenGeneration) return;
            final words = result.recognizedWords.trim();
            if (words.isEmpty) return;
            heard = words;
            if (result.finalResult) {
              unawaited(_speech.stop());
            }
          },
          listenOptions: stt.SpeechListenOptions(
            listenFor: listenFor,
            pauseFor: const Duration(milliseconds: 600),
            partialResults: false,
            cancelOnError: true,
          ),
        );

        // Give the recognizer the whole window, then close it.
        await Future<void>.delayed(listenFor + const Duration(seconds: 1));
      } catch (_) {
        return null;
      } finally {
        _micBusy = false;
      }

      // Superseded (screen popped, another prompt started) -> drop.
      if (token != _listenGeneration) return null;

      try {
        await _speech.stop();
      } catch (_) {}

      final result = heard?.trim();
      if (result != null && result.isNotEmpty) {
        debugPrint('[VOICE] one-shot heard: $result');
        return result;
      }

      if (attempt + 1 < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }

    debugPrint('[VOICE] one-shot heard nothing');
    return null;
  }

  /// Speaks [text] using [companion]'s voice without changing the companion the
  /// app is configured for, unless [keepVoice] is set.
  ///
  /// This is what makes the picker trustworthy: the preview, the "selected"
  /// confirmation and every later screen message are produced by the *same*
  /// engine voice, so a user can hear the difference between Alex and Maya.
  Future<void> speakAs(
    CompanionProfile companion,
    String text, {
    TtsPace pace = TtsPace.normal,
    bool remember = false,
    bool keepVoice = false,
  }) async {
    if (text.trim().isEmpty) return;

    final previous = _appliedCompanion;
    await _configureCompanion(companion);
    await speak(text, resumeAfter: false, pace: pace, remember: remember);

    if (!keepVoice && previous.id != companion.id) {
      await _configureCompanion(previous);
    }
  }

  /// Drops into PAUSED only from the "nothing is happening" states, so a
  /// deliberate PROCESSING or COMMAND_DETECTED transition is not clobbered.
  void _maybeSettlePaused() {
    if (_speaking || _shouldListen || _inBackground) return;
    if (_state != VoiceState.listening &&
        _state != VoiceState.ready &&
        _state != VoiceState.idle) {
      return;
    }
    _setState(VoiceState.paused);
  }

  /// Consecutive failed reopen attempts before the engine gives up hammering
  /// the recognizer and says so out loud.
  ///
  /// The old limit was 25 with no user feedback, so a recognizer that failed
  /// repeatedly (lifecycle churn around the system camera is the usual cause)
  /// went permanently deaf while the UI kept claiming it was listening.
  static const int _maxRestartFailures = 8;

  void _scheduleRestart() {
    if (!_shouldListen || _speaking || _listening) return;

    // Nobody to restart for: a screen that never registered (or already
    // released) owns nothing, so reopening the microphone would just leave a
    // live recognizer with nowhere to deliver what it hears.
    if (onCommand == null) return;

    _failureCount++;
    if (_failureCount > _maxRestartFailures) {
      _announceMicDead();
      return;
    }

    // Gentle backoff. The first few retries fire almost immediately, which is
    // what recovers a transient recognizer hiccup; later ones wait longer so a
    // genuinely unavailable recognizer is not polled in a tight loop.
    final delayMs = (250 * _failureCount).clamp(300, 3000);
    Future<void>.delayed(Duration(milliseconds: delayMs), () {
      if (_shouldListen && !_speaking && !_listening) {
        unawaited(resumeMicrophone());
      }
    });
  }

  /// Tells the user, once, that the app has stopped hearing them and how to
  /// fix it. Silence here is what made the bug undebuggable: a blind user had
  /// no way to tell "the app is broken" from "the app is ignoring me".
  void _announceMicDead() {
    if (_micDeadAnnounced) return;
    _micDeadAnnounced = true;
    debugPrint('[VOICE] giving up on the recognizer after '
        '$_failureCount failed attempts: $_lastRecognizerError');
    unawaited(
      speak(
        'I am having trouble hearing you, so I have paused. '
        'Please check that My Eyes has microphone permission in your phone '
        'settings, then tap the microphone to wake me up.',
        resumeAfter: false,
        pace: TtsPace.important,
      ),
    );
  }

  // ============================================================
  // MICROPHONE WATCHDOG
  // ============================================================

  /// How often the engine verifies that it is genuinely listening.
  static const Duration _watchdogInterval = Duration(seconds: 2);

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_watchdogInterval, (_) => _runWatchdog());
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// Reopens the microphone whenever a session owns it, the engine intends to
  /// listen, and the recognizer is not actually capturing.
  ///
  /// That combination is precisely the state a user experiences as "the mic is
  /// not on". Every other recovery path in this class is event driven and needs
  /// somebody to call it; this one needs nothing.
  ///
  /// It deliberately does NOT reopen the microphone when `_shouldListen` is
  /// false, because that also covers a deliberate pause ("stop", mid-navigation,
  /// screen popped). Reopening there is exactly how a stray phrase would
  /// execute a command the user never gave.
  void _runWatchdog() {
    if (_inBackground) return;
    if (onCommand == null) return;
    if (_speaking || _micBusy) return;

    // A pause left behind by a screen that has already been replaced must not
    // keep the *current* owner deaf. This is the exact state a popped module
    // leaves behind: it calls pauseMicrophone() after the dashboard has already
    // claimed the engine and restarted listening.
    if (_pauseOwnerSession != null && _pauseOwnerSession != _session) {
      debugPrint('[VOICE] watchdog: discarding stale pause from session '
          '#$_pauseOwnerSession (current #$_session)');
      _pauseOwnerSession = null;
      _shouldListen = true;
    }

    // A deliberate pause by the current owner ("stop", mid-navigation) is
    // respected. Reopening here is exactly how a stray phrase would execute a
    // command the user never gave.
    if (!_shouldListen) return;
    if (_listening) return;

    debugPrint('[VOICE] watchdog: engine believed it was listening but the '
        'recognizer was idle; reopening');
    unawaited(resumeMicrophone());
  }

  // ============================================================
  // COMMAND DISPATCH
  // ============================================================

  /// A complete command arrived: cut the microphone *now* instead of waiting
  /// for `pauseFor` to expire, then hand the transcript to the active screen.
  void _onFinalResult(int token, String words) {
    if (token != _listenGeneration) return;

    _listening = false;
    _shouldListen = false;
    // Invalidate the in-flight listen so its trailing callbacks (and the
    // duplicate final result Android often sends after cancel) are dropped.
    _listenGeneration++;
    _resetPartialTracking();
    _notifyListening();
    _setState(VoiceState.commandDetected);
    debugPrint('[VOICE] command detected: $words');

    unawaited(_cancelRecognizer());
    unawaited(_dispatch(words));
  }

  /// Bare cancel used right after a final result. It deliberately does not
  /// take `_micBusy`: the following `listen()` is already gated by
  /// [_listenGeneration], and blocking here would delay the command handler.
  Future<void> _cancelRecognizer() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  void _resetDuplicateGuard() {
    _lastDispatched = '';
    _lastDispatchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _resetPartialTracking() {
    _partialSettleTimer?.cancel();
    _partialSettleTimer = null;
    _lastPartial = '';
    _partialListenToken = null;
  }

  /// How long a partial transcript must stop changing before it is treated as
  /// the user's finished command.
  ///
  /// Android decides `finalResult` itself, and it is conservative: on a noisy
  /// street, with an accented speaker, or right after a TTS utterance it often
  /// keeps re-sending growing partials and then just times out at `listenFor`.
  /// The user had clearly finished speaking - the dashboard even displayed
  /// "choose file" - but nothing was executed and the microphone stayed open
  /// for the full twelve seconds, re-listening to a room the user had left
  /// alone. That is the single most frustrating failure in a voice-only app,
  /// because the user has no visual cue that the app is still waiting.
  ///
  /// A partial that remains unchanged for this interval is treated as a
  /// finished command, even when Android does not send a final result.
  static const Duration _partialSettle = Duration(milliseconds: 1100);

  /// Last partial transcript seen in the current listen.
  String _lastPartial = '';

  /// The recognizer turn that owns [_lastPartial].  Android's status callback
  /// has no turn identifier, so this is also what lets the delayed settle
  /// callback prove that it still belongs to the live listen before it acts.
  int? _partialListenToken;

  /// A real timer is required here.  Recognition engines normally send one
  /// partial result, then emit `done`; they do *not* promise to send a second,
  /// identical partial.  Previously the settle check only ran when another
  /// result callback happened, which meant a visible/detected command was
  /// silently discarded and the next recognizer turn began listening again.
  Timer? _partialSettleTimer;

  bool get _hasPendingPartial =>
      _lastPartial.isNotEmpty && _partialListenToken == _listenGeneration;

  /// Dispatches [words] once the recognizer has stopped revising them.
  ///
  /// Guarded so it can only ever fire for the live listen ([token]), and only
  /// when the transcript genuinely stopped changing - a speaker mid-word
  /// produces new partials constantly, and dispatching one of those would
  /// execute a fragment ("choose") as if it were a command ("choose file").
  void _trackPartial(int token, String words) {
    if (_lastPartial == words && _partialListenToken == token) return;

    // A changed transcript means the recognizer is still working.  Reset a
    // real debounce timer rather than waiting for another callback: on Android
    // there may never be one after a perfectly usable partial transcript.
    _partialSettleTimer?.cancel();
    _lastPartial = words;
    _partialListenToken = token;
    _partialSettleTimer = Timer(_partialSettle, () {
      if (token != _listenGeneration ||
          _partialListenToken != token ||
          _lastPartial != words ||
          !_shouldListen) {
        return;
      }
      debugPrint('[VOICE] transcript settled without a finalResult: "$words" '
          '- dispatching now');
      _onFinalResult(token, words);
    });
  }

  bool _isDuplicate(String transcript) {
    if (_lastDispatched != transcript) return false;
    return DateTime.now().difference(_lastDispatchedAt) < _duplicateWindow;
  }

  void _recordDispatch(String transcript) {
    _lastDispatched = transcript;
    _lastDispatchedAt = DateTime.now();
  }

  Future<void> _dispatch(String rawTranscript) async {
    final handler = onCommand;
    if (handler == null) {
      // The recognizer is already shut by the time a command is dispatched
      // (see [_onFinalResult]). Returning here therefore did not just lose the
      // command, it left the microphone CLOSED: the screen still showed
      // "listening" because [_listening] had been cleared but the engine never
      // reopened, and from then on the app looked ready while ignoring every
      // spoken command until the user tapped the button.
      //
      // Reopen instead. The screen that owns the session will re-register its
      // handler via startSession, and the watchdog covers the window in between.
      debugPrint('[VOICE] command dropped: no active session handler');
      _shouldListen = true;
      await resumeMicrophone();
      return;
    }

    final transcript = stripWakeWords(rawTranscript).trim();
    if (transcript.isEmpty) {
      // Wake word with nothing after it - keep listening.
      _shouldListen = true;
      await resumeMicrophone();
      return;
    }

    // A command is already running; ignore the echo Android sends after the
    // recognizer is cancelled rather than executing it twice.
    if (_isDuplicate(transcript)) {
      debugPrint('[VOICE] duplicate ignored: $transcript');
      return;
    }
    _recordDispatch(transcript);

    final normalized = transcript.toLowerCase();
    debugPrint('[VOICE] dispatch: $normalized');

    try {
      await handler(normalized);
    } catch (e, st) {
      debugPrint('[VOICE] handler error for "$normalized": $e\n$st');
      _setState(VoiceState.error);
      // A crashed handler must not leave the user with a silent, dead
      // microphone: reopen it so the next command still works.
      _shouldListen = true;
      await resumeMicrophone();
    }
  }

  // ============================================================
  // COMMAND MATCHING HELPERS
  // ============================================================

  static String stripWakeWords(String text) {
    var value = text.toLowerCase();
    const wakeWords = [
      'hey my eyes',
      'ok my eyes',
      'okay my eyes',
      'hi my eyes',
      'hello my eyes',
      'hey myeyes',
      'my eyes',
    ];
    for (final word in wakeWords) {
      value = value.replaceAll(word, ' ');
    }
    return value.trim();
  }

  static bool isBackCommand(String text) {
    return _containsAny(text, const [
      'go back',
      'back to dashboard',
      'back to home',
      'dashboard',
      'main menu',
      'close this',
      'cancel this',
      'stop scanning',
      'exit',
    ]);
  }

  static bool isRepeatCommand(String text) {
    return _containsAny(text, const [
      'repeat',
      'say again',
      'say that again',
      "what did you say",
      'pardon',
    ]);
  }

  static bool isCaptureCommand(String text) {
    return _containsAny(text, const [
      'capture',
      'take photo',
      'take picture',
      'take a picture',
      'snap',
      'click photo',
      'scan now',
      'scan it',
      'scan this',
    ]);
  }

  static bool isFileCommand(String text) {
    return _containsAny(text, const [
      'choose file',
      'choose a file',
      'pick file',
      'upload file',
      'read this file',
      'from gallery',
      'from files',
    ]);
  }

  static bool isHelpCommand(String text) {
    return _containsAny(text, const [
      'help',
      'what can i say',
      'what can you do',
      'commands',
      'options',
      'instructions',
    ]);
  }

  static bool isStopCommand(String text) {
    return _containsAny(text, const [
      'stop listening',
      'stop the app',
      'be quiet',
      'silence',
    ]);
  }

  /// Maps a spoken phrase to a vision module. Returns null when the
  /// phrase does not match any module.
  static VisionMode? matchModule(String text) {
    if (_containsAny(text, const [
      'medicine',
      'tablet',
      'pill',
      'drug',
      'prescription',
    ])) {
      return VisionMode.medicine;
    }

    if (_containsAny(text, const [
      'product',
      'barcode item',
      'packaged food',
      'food label',
      'food details',
      'ingredients',
    ])) {
      return VisionMode.product;
    }

    if (_containsAny(text, const [
      'currency',
      'note detector',
      'bank note',
      'banknote',
      'money',
      'cash',
      'rupee',
      'rupees',
    ])) {
      return VisionMode.currency;
    }

    if (_containsAny(text, const [
      'find',
      'locate',
      'search for',
      'where is',
      "where's",
      'looking for',
    ])) {
      return VisionMode.objectFinder;
    }

    if (_containsAny(text, const [
      'describe',
      'surroundings',
      'scene',
      'around me',
      'where am i',
      'what do you see',
    ])) {
      return VisionMode.scene;
    }

    if (_containsAny(text, const [
      'read text',
      'read this',
      'read the text',
      'read page',
      'read document',
      'read paper',
      'read book',
      'scan text',
      'text reader',
      'document scanner',
    ])) {
      return VisionMode.readText;
    }

    if (_containsAny(text, const [
      'scan object',
      'identify object',
      'detect object',
      'what is this',
      "what's this",
      'object scan',
      'tell me what this is',
    ])) {
      return VisionMode.scanObject;
    }

    return null;
  }

  /// Extracts the object name from phrases like
  /// "find my phone", "locate the water bottle", "where is my keys".
  static String? extractTarget(String text) {
    final patterns = [
      RegExp(r'(?:find|locate|search for|looking for|where is|wheres)\s+(?:my |the |a |an )?(.+)$'),
      RegExp(r'find\s+(?:my |the |a |an )?(.+?)(?:\s+please|\s+now)$'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final target = match.group(1)?.trim();
        if (target != null &&
            target.isNotEmpty &&
            target.length < 40) {
          return target;
        }
      }
    }

    return null;
  }

  /// Friendly spoken names for each module.
  static String spokenName(VisionMode mode) {
    switch (mode) {
      case VisionMode.scanObject:
        return 'Scan Object';
      case VisionMode.readText:
        return 'Read Text';
      case VisionMode.medicine:
        return 'Medicine Reader';
      case VisionMode.product:
        return 'Product Reader';
      case VisionMode.currency:
        return 'Currency Detector';
      case VisionMode.scene:
        return 'Scene Describer';
      case VisionMode.objectFinder:
        return 'Object Finder';
    }
  }

  static const String commandHelpText =
      'You can say: Scan object. Read text. Medicine reader. '
      'Product reader. Currency detector. Describe my surroundings. '
      'Find my phone. Scan payment to pay a QR code. '
      'Or say help at any time.';

  // ============================================================
  // INTERNALS
  // ============================================================

  static bool _containsAny(String text, List<String> keywords) {
    for (final keyword in keywords) {
      if (text.contains(keyword)) return true;
    }
    return false;
  }

  void _notifyListening() {
    onListeningChanged?.call(_listening || _shouldListen);
  }
}
