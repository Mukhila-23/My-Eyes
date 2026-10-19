import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/module_catalog.dart';
import '../../core/module_router.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/vision_mode.dart';
import '../../services/app_instructions.dart';
import '../../services/companion.dart';
import '../../services/post_login_coordinator.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_command_router.dart';
import '../../core/theme/app_theme.dart';
import '../companion/change_companion_screen.dart';
import '../history/history_picker_screen.dart';
import '../history/module_history_screen.dart';
import '../sos/sos_screen.dart';
import '../sos/sos_contacts_screen.dart';
import '../sos/sos_setup_screen.dart';
import '../ai_help/ai_help_screen.dart';
import '../navigation/navigation_screen.dart';
import '../onboarding/welcome_screen.dart';
import '../payment/payment_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String companionName;
  final String companionGender;

  /// The resolved profile for [companionName]/[companionGender].
  ///
  /// Passed in so the instructions system can address the user by the actual
  /// companion's name and personality instead of re-deriving it (and possibly
  /// guessing wrong) from the two display strings.
  final CompanionProfile? companionProfile;

  const DashboardScreen({
    super.key,
    this.companionName = 'MAYA',
    this.companionGender = 'female',
    this.companionProfile,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _backgroundController;
  late AnimationController _orbController;
  late AnimationController _pulseController;

  bool _isListening = false;
  String _lastHeard = '';
  VoiceState _voiceState = VoiceState.idle;

  /// True while the eye icon is playing the full guide.
  ///
  /// Purely visual: it brightens the one eye so a sighted tester can see the
  /// tap registered. It is deliberately not used to gate the tap, because a
  /// guard that swallows taps is exactly the "nothing happened" bug.
  bool _instructionsPlaying = false;

  final VoiceCommandService _voice = VoiceCommandService.instance;

  /// Token for the dashboard's own voice session. Every screen that starts a
  /// session keeps the token it was handed so its late `dispose()` cannot
  /// tear down the session that replaced it.
  int? _voiceSession;

  // Camera-or-file source selection. When a module is chosen we ask the
  // user "Would you like to use the camera or choose a file?" and keep the
  // dashboard listening for the answer before opening the module.
  VisionMode? _pendingSourceMode;
  String? _pendingSourceTarget;
  bool _awaitingSource = false;
  bool _awaitingFinderTarget = false;

  /// The module whose "camera or file?" question is currently on screen, or
  /// null when no question is outstanding.
  ///
  /// Drives the visible Camera / Choose a file buttons. Non-null means the
  /// dashboard is waiting for a source; it is cleared by [_clearPendingSource],
  /// by a spoken answer, and by leaving the dashboard.
  VisionMode? _sourceChoiceMode;

  // ============================================================
  // COMPANION THEME
  // ============================================================

  Color get _primaryColor =>
      widget.companionGender.toLowerCase() == 'male'
          ? const Color(0xFF149EFF)
          : const Color(0xFFFF5FA2);

  Color get _secondaryColor =>
      widget.companionGender.toLowerCase() == 'male'
          ? const Color(0xFF5267FF)
          : const Color(0xFF9B5CFF);

  Color get _accentColor =>
      widget.companionGender.toLowerCase() == 'male'
          ? const Color(0xFF39D9FF)
          : const Color(0xFFFF8CC4);

  IconData get _companionIcon =>
      widget.companionGender.toLowerCase() == 'male'
          ? Icons.person_rounded
          : Icons.face_3_rounded;

  /// The active companion as a profile, resolved once per build.
  ///
  /// Falls back to deriving it from the two display strings when a caller does
  /// not supply a profile, so no existing navigation path breaks.
  CompanionProfile get _companion {
    return widget.companionProfile ??
        Companions.fromStored(
          name: widget.companionName,
          gender: widget.companionGender,
        );
  }

  /// Spoken, full dashboard guide. Built on demand from the catalog so a new
  /// module is explained without editing this file.
  String _instructionsScript() =>
      AppInstructions.dashboardInstructions(
        companion: _companion,
        sosConfigured: PostLoginCoordinator.readiness ==
            SosReadiness.configured,
      );

  String get _sosInstructionsScript => AppInstructions.sosInstructions(
        companionName: _companion.name,
        configured: PostLoginCoordinator.readiness == SosReadiness.configured,
      );

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startVoiceAssistant();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      _voice.resumeAfterLifecycle();
    } else if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.inactive ||
        lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.detached) {
      _voice.pauseForLifecycle();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundController.dispose();
    _orbController.dispose();
    _pulseController.dispose();

    _voice.releaseSession(_voiceSession);

    super.dispose();
  }

  // ============================================================
  // VOICE ASSISTANT
  // ============================================================

  /// Opens the dashboard: SPEAK FIRST, then open the microphone.
  ///
  /// The order is deliberate and is what a blind user needs. The recognizer
  /// must never be listening while the companion is talking, or it picks up
  /// its own speech and executes a command nobody gave. So:
  ///
  ///   1. take the voice session WITHOUT auto-starting the recognizer,
  ///   2. speak the greeting with the microphone shut,
  ///   3. only then open the microphone, so the very next thing the user does
  ///      is speak and be heard.
  ///
  /// Previously the session was started with autoStart before the greeting, so
  /// the mic opened, the TTS then cut it, and the recognizer restarted against
  /// a closing audio pipeline - a start/stop churn that left the microphone
  /// unreliable to turn on.
  Future<void> _startVoiceAssistant() async {
    // Ensure the shared TTS uses the selected companion's voice (Alex/Maya)
    // for every spoken message in this session.
    _voice.configureCompanion(
      name: widget.companionName,
      gender: widget.companionGender,
    );

    // Claim ownership of the session first, but do not open the microphone:
    // this reserves the handler so nothing else can steal it mid-greeting.
    await _ensureVoiceSession(force: true);
    if (!mounted) return;

    await _voice.speak(
      '${widget.companionName} here. Your dashboard is ready. '
      'I can read text, identify objects, medicine, products and currency, '
      'describe your surroundings, navigate, scan payments, and help in an '
      'emergency. For example, say read this text, find my phone, describe '
      'my surroundings, or navigate to the railway station. You can also ask '
      'a general question naturally. If it is not an app command, I will ask '
      'Gemini for help. Say help at any time to hear command examples.',
      resumeAfter: false,
    );
    if (!mounted) return;

    await _openMicrophone();
  }

  /// (Re-)registers the dashboard's command handlers and stores the session
  /// token they belong to.
  ///
  /// [VoiceCommandService.startSession] *replaces* the handlers of whichever
  /// screen started last, and [VoiceCommandService.stopSession] clears them
  /// entirely. So the moment a module opens - or pops - the dashboard's
  /// handlers are gone. Opening the microphone again after that produced a live
  /// recognizer with nowhere to deliver what it heard: the dashboard kept
  /// claiming to be listening, and every command was dropped.
  ///
  /// Calling this before *every* microphone open - on entry and after every
  /// module round trip - is what makes "the mic is on" actually mean "I can hear
  /// you and I know what to do with it". It is a no-op when the dashboard is
  /// still the rightful owner, so it is cheap to call unconditionally.
  Future<void> _ensureVoiceSession({bool force = false}) async {
    if (!mounted) return;

    final ownsSession =
        _voiceSession == _voice.session && _voice.hasSessionOwner;
    if (ownsSession && !force) return;

    debugPrint('[VOICE] dashboard claims voice session '
        '(previous #$_voiceSession, engine #${_voice.session})');

    _voiceSession = await _voice.startSession(
      onCommand: _handleVoiceCommand,
      onHeard: (transcript) {
        if (!mounted) return;
        setState(() => _lastHeard = transcript);
      },
      onListeningChanged: (listening) {
        if (!mounted) return;
        setState(() => _isListening = listening);
      },
      onStateChanged: (state) {
        if (!mounted) return;
        setState(() => _voiceState = state);
      },
      autoStart: false,
    );
  }

  /// Opens the microphone and reports honestly if it would not turn on.
  ///
  /// A silent microphone is the worst possible failure for this app: the UI
  /// still looks ready and every spoken command is ignored. So the recognizer
  /// is verified here and the user is told out loud what went wrong, rather
  /// than discovering it by talking to an app that is not listening.
  ///
  /// Three things happen here, and all are required:
  ///   1. re-register the handlers, in case a module took the session,
  ///   2. check [VoiceCommandService.recognizerAvailable], not `isListening` -
  ///      `isListening` reports the *intent* to listen and is still true after
  ///      initialization failed, which is why the honest error message below
  ///      used to be unreachable and the microphone used to fail in silence,
  ///   3. only interrupt the user for a failure waiting is genuinely unable to
  ///      fix. A microphone that is briefly between restarts is the watchdog's
  ///      job; announcing it as broken made the app contradict itself while it
  ///      was in fact hearing the user perfectly well.
  Future<void> _openMicrophone() async {
    await _ensureVoiceSession();
    if (!mounted) return;

    await _voice.resumeMicrophone();
    if (!mounted) return;

    if (_voice.recognizerAvailable) return;

    final error = _voice.lastRecognizerError;
    debugPrint('[VOICE] microphone did not open: $error');
    await _voice.speak(
      'I could not open the microphone, so I cannot hear commands right now. '
      'Please check that My Eyes has microphone permission in your phone '
      'settings. You can still use the buttons on the screen.',
      resumeAfter: false,
      pace: TtsPace.important,
    );
  }

  /// Same as [_openMicrophone], but only announces success when the microphone
  /// really opened. Announcing "I'm listening" after a failure message would
  /// leave a blind user with two contradictory statements and no way to tell
  /// which to believe.
  Future<void> _openMicrophoneAndConfirm() async {
    await _openMicrophone();
    if (!mounted) return;
    if (!_voice.recognizerHealthy) return;
    await _voice.speak("I'm listening. Say a command such as scan object.");
  }

  Future<void> _handleVoiceCommand(String rawTranscript) async {
    final transcript = VoiceCommandService.stripWakeWords(rawTranscript);
    if (transcript.isEmpty) return;

    if (!mounted) return;
    setState(() => _lastHeard = transcript);

    // While we are waiting for a "camera or file?" answer, route the spoken
    // answer directly instead of re-classifying it as a module command.
    if (_awaitingFinderTarget) {
      await _handleFinderTarget(transcript);
      return;
    }

    if (_awaitingSource) {
      await _handleSourceAnswer(transcript);
      return;
    }

    debugPrint('[ROUTER] dashboard received: $transcript');

    final routed = VoiceCommandRouter.route(transcript);
    debugPrint(
      '[ROUTER] intent=${routed.intent.name} '
      'confidence=${routed.confidence.name} target=${routed.target}',
    );

    switch (routed.intent) {
      // ----------------------------------------------------------
      // SAFETY-CRITICAL: SOS requires explicit confirmation (in the SOS
      // screen). It is never auto-triggered here.
      // ----------------------------------------------------------
      case VoiceIntent.sos:
        await _launchSos();
        return;

      case VoiceIntent.emergencyContacts:
        await _launchEmergencyContacts();
        return;

      // ----------------------------------------------------------
      // UPI QR PAYMENT (voice-first; see PaymentScreen)
      // ----------------------------------------------------------
      case VoiceIntent.payment:
        await _openPayment();
        return;

      // ----------------------------------------------------------
      // STOP LISTENING
      // ----------------------------------------------------------
      case VoiceIntent.stop:
        await _voice.pauseMicrophone();
        await _voice.speak(
          'I stopped listening. Tap the microphone when you need me again.',
          resumeAfter: false,
        );
        return;

      // ----------------------------------------------------------
      // HELP
      // ----------------------------------------------------------
      case VoiceIntent.help:
        await _speakCommandGuide();
        return;

      // ----------------------------------------------------------
      // FULL SPOKEN INSTRUCTIONS (the eye icon's content)
      // ----------------------------------------------------------
      case VoiceIntent.instructions:
        await _playInstructions();
        return;

      case VoiceIntent.sosInstructions:
        await _playSosInstructions();
        return;

      // ----------------------------------------------------------
      // CHANGE COMPANION
      // ----------------------------------------------------------
      case VoiceIntent.changeCompanion:
        await _openChangeCompanion();
        return;

      // ----------------------------------------------------------
      // REPEAT LAST ANSWER
      // ----------------------------------------------------------
      case VoiceIntent.repeat:
        final previous = _voice.lastSpokenResponse;
        if (previous == null || previous.isEmpty) {
          await _voice.speak('I have nothing to repeat yet.');
        } else {
          await _voice.speak(previous, pace: TtsPace.moduleResult);
        }
        return;

      // ----------------------------------------------------------
      // GO BACK
      // ----------------------------------------------------------
      case VoiceIntent.goBack:
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        return;

      // ----------------------------------------------------------
      // NAVIGATION
      // ----------------------------------------------------------
      case VoiceIntent.navigation:
        await _openNavigation(routed.raw);
        return;

      case VoiceIntent.aiHelp:
        await _openHelp(routed.target);
        return;

      // ----------------------------------------------------------
      // HISTORY
      //
      // From the dashboard there is no "current module", so:
      //   "currency history" -> open Currency Detection history directly
      //   "history"          -> ask which module
      // Inside a module the module itself intercepts the command and opens
      // only its own history.
      // ----------------------------------------------------------
      case VoiceIntent.history:
        final named = routed.historyModule;
        if (named != null) {
          await _openModuleHistory(named);
        } else {
          await _openHistoryPicker();
        }
        return;

      // ----------------------------------------------------------
      // VISION MODULES
      // ----------------------------------------------------------
      case VoiceIntent.readText:
      case VoiceIntent.medicine:
      case VoiceIntent.currency:
      case VoiceIntent.product:
      case VoiceIntent.object:
      case VoiceIntent.scene:
        debugPrint('[MODULE] open ${routed.intent.name}');
        // A target makes this an Object Finder request ("find my bottle"),
        // whereas a plain "what is this" remains object identification.
        final mode = routed.intent == VoiceIntent.object &&
                routed.target != null && routed.target!.isNotEmpty
            ? VisionMode.objectFinder
            : VoiceCommandRouter.visionModeFor(routed.intent);
        if (mode == null) {
          await _speakUnknown(transcript);
          return;
        }
        final target = routed.intent == VoiceIntent.object ? routed.target : null;
        if (mode == VisionMode.objectFinder) {
          await _executeModule(mode, target: target);
        } else {
          await _askCameraOrFile(mode, target: target);
        }
        return;

      // ----------------------------------------------------------
      // UNKNOWN COMMAND
      // ----------------------------------------------------------
      case VoiceIntent.unknown:
        await _askGeminiForUnprocessedSpeech(transcript);
        return;
    }
  }

  /// Short command guide for the common "help" / "what can I say" request.
  ///
  /// This is intentionally brief enough to remember.  The user can still say
  /// "instructions" for the longer accessible walkthrough, or "ask AI" for
  /// an open-ended Gemini conversation.
  Future<void> _speakCommandGuide() async {
    await _voice.speak(
      'Try commands such as: read this text; identify this medicine; '
      'what is this object; describe my surroundings; find my phone; '
      'navigate to home; scan payment; or send SOS. For any general question, '
      'say ask AI, then speak naturally. If I cannot match what you say to an '
      'app command, I will automatically ask Gemini for help.',
      remember: true,
      pace: TtsPace.moduleResult,
    );
  }

  /// A sentence the deterministic command router cannot process is not thrown
  /// away. Hand it to the existing authenticated AI Help flow, whose backend
  /// asks Gemini while keeping the API key off the device.
  Future<void> _askGeminiForUnprocessedSpeech(String transcript) async {
    final question = transcript.trim();
    if (question.isEmpty) {
      await _speakUnknown(transcript);
      return;
    }
    await _openHelp(question);
  }

  Future<void> _speakUnknown(String transcript) async {
    await _voice.speak(
      'I did not catch that. ${VoiceCommandRouter.unknownHint}',
    );
  }

  // ============================================================
  // CAMERA OR FILE SOURCE SELECTION
  // ============================================================

  /// After a vision module is chosen - by tapping its card or by saying its
  /// name - ask whether to use the camera or a file, then keep listening for
  /// the answer. The dashboard stays visible and the microphone stays active
  /// for the reply.
  ///
  /// While the question is outstanding, [_buildSourceChoice] renders the same
  /// two options as real buttons, so a user who cannot get the wording
  /// recognised is never stuck.
  Future<void> _askCameraOrFile(VisionMode mode, {String? target}) async {
    _pendingSourceMode = mode;
    _pendingSourceTarget = target;
    _awaitingSource = true;

    final spokenName = VoiceCommandService.spokenName(mode);
    debugPrint('[MODULE] ask source: $spokenName');

    if (mounted) {
      setState(() => _sourceChoiceMode = mode);
    }

    // speak(resumeAfter: true) pauses the mic while talking, then resumes
    // listening so the user's "camera" / "file" answer is captured next.
    await _voice.speak(
      'Opening $spokenName. Would you like to use the camera, '
      'or choose a file?',
    );
  }

  /// Handles the answer to the "camera or file?" prompt.
  Future<void> _handleSourceAnswer(String transcript) async {
    final mode = _pendingSourceMode;
    final target = _pendingSourceTarget;
    if (mode == null) {
      _clearPendingSource();
      return;
    }

    // "Close" / "Cancel" / "Go back" during the prompt -> abort gracefully.
    if (VoiceCommandService.isBackCommand(transcript)) {
      debugPrint('[ROUTER] source answer: cancel');
      _clearPendingSource();
      await _voice.speak('Cancelled. Returning to the dashboard.');
      await _voice.resumeMicrophone();
      return;
    }

    // Camera.
    if (VoiceCommandRouter.isCameraSource(transcript)) {
      debugPrint('[ROUTER] source answer: camera');
      _clearPendingSource();
      await _executeModule(mode, target: target);
      return;
    }

    // File (system picker).
    if (VoiceCommandRouter.isFileSource(transcript)) {
      debugPrint('[ROUTER] source answer: file');
      _clearPendingSource();
      await _executeModule(mode, target: target, startFromFile: true);
      return;
    }

    // Not camera / file / cancel -> ask again, keep listening.
    await _voice.speak('Please say camera, or say choose a file.');
  }

  /// Runs a touch answer to the "camera or file?" prompt.
  ///
  /// Deliberately reuses the same branches as the spoken answer so a tap and a
  /// voice command can never diverge: one path opened the camera and the other
  /// opened the picker.
  Future<void> _chooseSourceByTouch(bool useCamera) async {
    final mode = _pendingSourceMode;
    final target = _pendingSourceTarget;
    if (mode == null || !_awaitingSource) return;

    debugPrint('[MODULE] source answer (touch): '
        '${useCamera ? "camera" : "file"}');

    _clearPendingSource();

    if (useCamera) {
      await _executeModule(mode, target: target);
    } else {
      await _executeModule(mode, target: target, startFromFile: true);
    }
  }

  void _clearPendingSource() {
    _pendingSourceMode = null;
    _pendingSourceTarget = null;
    _awaitingSource = false;
    if (mounted) {
      setState(() => _sourceChoiceMode = null);
    }
  }

  /// Object Finder needs a target before it can safely start the camera.
  /// Voice requests normally already include it; the touch card uses this.
Future<void> _askFinderTarget() async {
    _awaitingFinderTarget = true;
    await _voice.speak('What object should I find?');
  }

  Future<void> _handleFinderTarget(String transcript) async {
    if (VoiceCommandService.isBackCommand(transcript)) {
      _awaitingFinderTarget = false;
      await _voice.speak('Object Finder cancelled. Returning to the dashboard.');
      return;
    }

    final routed = VoiceCommandRouter.route(transcript);
    var target = routed.intent == VoiceIntent.object ? routed.target : null;

    // The user usually answers the prompt with the bare object name
    // ("phone"), which matches no command on its own. Treat the spoken words
    // as the target instead of asking again.
    if (target == null || target.isEmpty) {
      final candidate = VoiceCommandService.stripWakeWords(transcript).trim();
      final isCommand = routed.intent != VoiceIntent.unknown ||
          VoiceCommandService.isStopCommand(candidate);
      if (!isCommand && candidate.isNotEmpty && candidate.length < 40) {
        target = candidate.toLowerCase();
      }
    }

    if (target == null || target.isEmpty) {
      await _voice.speak('Please say the object name, for example, find my bottle.');
      return;
    }

    _awaitingFinderTarget = false;
    await _executeModule(VisionMode.objectFinder, target: target);
  }

  Future<void> _executeModule(
    VisionMode mode, {
    String? target,
    bool startFromFile = false,
  }) async {
    final spokenName = VoiceCommandService.spokenName(mode);
    debugPrint('[MODULE] open $spokenName file=$startFromFile target=$target');

    var announcement = startFromFile
        ? 'Opening $spokenName. Choose an image from your files.'
        : 'Opening $spokenName.';

    if (target != null && target.isNotEmpty) {
      announcement =
          'Searching for your $target.';
    }

    // Cut the microphone before announcing so the recognizer cannot pick up
    // the announcement and re-trigger the same module.
    await _voice.setProcessing();
    if (!mounted) return;

    await _voice.speak(announcement, resumeAfter: false);
    if (!mounted) return;

    // Keep the dashboard mic off while the module owns the voice.
    await _voice.pauseMicrophone();
    if (!mounted) return;

    await ModuleRouter.openMode(
      context,
      mode,
      autoStart: !startFromFile,
      startFromFile: startFromFile,
      target: target,
    ).then((_) {
      if (!mounted) return;
      _restartDashboardVoice();
    });
  }

  /// Called right after a module pops back. Reopens the microphone
  /// immediately so the next voice command just works.
  ///
  /// Speaks first, then opens the microphone - never the other way round, or
  /// the recognizer hears its own announcement.
  ///
  /// [_openMicrophone] re-registers the dashboard's handlers before it opens
  /// the recognizer. That step is the whole point: the module that just popped
  /// owned the session and its `dispose()` cleared the handlers, so without it
  /// the dashboard came back with a live microphone that discarded everything
  /// it heard.
  Future<void> _restartDashboardVoice() async {
    debugPrint('[MODULE] dashboard: module closed, resuming voice');
    if (mounted) setState(() => _lastHeard = '');

    // Keep this short: every second here is a second before the user can
    // speak their next command.
    await _voice.speak('Listening.', resumeAfter: false);
    if (!mounted) return;

    await _openMicrophone();
  }

  void _toggleListening() {
    if (_voice.isListening) {
      _voice.pauseMicrophone().then((_) {
        if (!mounted) return;
        _voice.speak(
          'I stopped listening. Tap the microphone when you need me again.',
          resumeAfter: false,
        );
      });
    } else {
      // Same path as every other wake-up, so a manual tap also repairs a lost
      // handler registration instead of reopening a microphone that ignores
      // the user.
      _openMicrophoneAndConfirm();
    }
  }

  // ============================================================
  // SOS / EMERGENCY
  // ============================================================

  Future<void> _openSos() async {
    await _pushOwningScreen(
      'Opening emergency SOS. Say yes to confirm, or cancel to abort.',
      const SosScreen(),
      pace: TtsPace.important,
    );
  }

  Future<void> _launchSos() async {
    if (_voice.isListening) {
      await _openSos();
      return;
    }
    await _voice.speak(
      'Opening emergency SOS.',
      resumeAfter: false,
      pace: TtsPace.important,
    );
    await _openSos();
  }

  Future<void> _launchEmergencyContacts() async {
    await _pushOwningScreen(
      'Opening your emergency contacts.',
      const SosContactsScreen(),
      pace: TtsPace.important,
    );
  }

  // ============================================================
  // SOS SETUP
  // ============================================================

  /// Voice-guided setup for a user who has no emergency contacts yet.
  Future<void> _openSosSetup() async {
    final voice = _voice;

    // Release the microphone: the setup screen runs its own wizard session and
    // two live recognizers would fight over the same audio stream.
    await voice.pauseMicrophone();
    if (!mounted) return;

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SosSetupScreen(
          companion: _companion,
          isMandatory: false,
        ),
      ),
    );

    if (!mounted) return;

    if (saved == true) {
      PostLoginCoordinator.reset();
      await _restartDashboardVoice();
      return;
    }

    await _restartDashboardVoice();
  }

  // ============================================================
  // INSTRUCTIONS (eye icon)
  // ============================================================

  /// Plays the full dashboard guide.
  ///
  /// Steps, in order, because each one depends on the previous:
  ///  1. cut the microphone so the announcement is not heard as a command,
  ///  2. stop anything already speaking (a leftover callout would be talking
  ///     over the guide),
  ///  3. speak the whole script at the slower pace a blind user needs,
  ///  4. restore the microphone and say how to replay it.
  ///
  /// The guide is delivered through [VoiceCommandService.speakLong] rather than
  /// a single [VoiceCommandService.speak]. The script is several thousand
  /// characters, which is far past what Android's speech engine reliably
  /// delivers in one utterance: it would start, hit the single-call timeout and
  /// be cut off mid-sentence, so tapping the eye produced a truncated guide
  /// followed by silence. Chunked delivery fixes that without changing the
  /// script.
  Future<void> _playInstructions() async {
    debugPrint('[INSTRUCTIONS] playing the dashboard guide');

    // Tapping the eye must always be heard as a deliberate action, even if a
    // guide is already running from a previous tap.
    await _voice.setProcessing();
    await _voice.stopSpeaking();
    if (!mounted) return;

    setState(() => _instructionsPlaying = true);

    await _voice.speakLong(
      _instructionsScript(),
      resumeAfter: false,
      pace: TtsPace.moduleResult,
    );
    if (!mounted) return;

    setState(() => _instructionsPlaying = false);

    await _voice.resumeMicrophone();
    if (!mounted) return;

    await _voice.speak(
      AppInstructions.instructionsShortNotice(_companion),
    );
  }

  /// Plays only the SOS guide.
  Future<void> _playSosInstructions() async {
    debugPrint('[INSTRUCTIONS] playing the SOS guide');

    await _voice.setProcessing();
    await _voice.stopSpeaking();
    if (!mounted) return;

    await _voice.speak(_sosInstructionsScript, resumeAfter: false);
    if (!mounted) return;

    await _voice.resumeMicrophone();
  }

  // ============================================================
  // CHANGE COMPANION
  // ============================================================

  Future<void> _openChangeCompanion() async {
    await _voice.setProcessing();
    if (!mounted) return;

    await _voice.speak(
      'You are currently using ${_companion.name}. '
      'Would you like to switch companion?',
      resumeAfter: false,
      pace: TtsPace.important,
    );
    await _voice.pauseMicrophone();
    if (!mounted) return;

    final result = await Navigator.of(context).push<CompanionChange>(
      MaterialPageRoute(
        builder: (_) => ChangeCompanionScreen(current: _companion),
      ),
    );

    if (!mounted) return;

    // The screen already confirmed and persisted the switch. Reflect the new
    // companion so the dashboard re-themes and every later message is spoken by
    // the new voice without a reload.
    if (result != null) {
      setState(() {});
      _voice.configureCompanionProfile(result.companion);
    }

    await _restartDashboardVoice();
  }

  // ============================================================
  // HISTORY
  // ============================================================

  Future<void> _openModuleHistory(VisionMode mode) async {
    await _voice.setProcessing();
    await _voice.speak(
      'Opening your ${mode.historyLabel}.',
      resumeAfter: false,
    );
    await _voice.pauseMicrophone();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModuleHistoryScreen(
          mode: mode,
          companion: _companion,
        ),
      ),
    );

    if (!mounted) return;
    await _restartDashboardVoice();
  }

  Future<void> _openHistoryPicker() async {
    await _voice.setProcessing();
    await _voice.pauseMicrophone();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HistoryPickerScreen()),
    );

    if (!mounted) return;
    await _restartDashboardVoice();
  }

  Future<void> _logout() async {
    await _voice.speak(
      'Logging out will remove this device\'s secure session. '
      'Tap Confirm to continue, or Cancel.',
      resumeAfter: false,
    );
    await _voice.pauseMicrophone();
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.background,
        title: const Text(
          'Log out of My Eyes?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Your secure login will be removed from this device. '
          'You can set it up again next time.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('CONFIRM',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    // Securely clear the on-device session so the next launch shows the
    // account setup/login flow again.
    await SecureStorage.clear();
    if (!mounted) return;

    await _voice.speak('You have been logged out.');
    if (!mounted) return;

    // Real global teardown: nobody else will ever own the microphone again.
    _voice.stopAll();
    // SecureStorage.clear() above also wiped the onboarding flags, so the
    // splash-equivalent restart genuinely replays the first-run flow.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  // ============================================================
  // UPI QR PAYMENT
  // ============================================================

/// Opens a screen that owns the microphone itself, then resumes dashboard
  /// listening when it pops.
  ///
  /// The screen's own `dispose()` runs after this `push` future resolves, so
  /// the module's token-guarded `stopSession` runs against an already newer
  /// dashboard session and is ignored. Previously it killed the freshly
  /// restarted microphone and forced the user to tap the button again.
  Future<void> _pushOwningScreen(
    String announcement,
    Widget screen, {
    TtsPace pace = TtsPace.normal,
  }) async {
    await _voice.setProcessing();
    await _voice.speak(announcement, resumeAfter: false, pace: pace);
    await _voice.pauseMicrophone();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );

    if (!mounted) return;
    _restartDashboardVoice();
  }

  Future<void> _openPayment() async {
    await _pushOwningScreen(
      'Opening payment scanner.',
      const PaymentScreen(),
      pace: TtsPace.important,
    );
  }

  // ============================================================
  // HELP (implemented by the existing AI assistant)
  // ============================================================

  Future<void> _openHelp([String? question]) async {
    await _pushOwningScreen(
      question == null || question.trim().isEmpty
          ? 'Opening AI Help. You can ask any question naturally.'
          : 'I will ask Gemini for help with that.',
      AiHelpScreen(initialQuestion: question),
    );
  }

  // ============================================================
  // NAVIGATION
  // ============================================================

  Future<void> _openNavigation(String phrase) async {
    await _pushOwningScreen(
      'Opening navigation.',
      NavigationScreen(initialCommand: phrase),
    );
  }

  // ============================================================
  // OPEN MODULE
  // ============================================================

  Future<void> _openModule(ModuleItem module) async {
    // Object Finder is the one module that needs a target before the camera
    // can open, so it asks instead of opening.
    if (module.visionMode == VisionMode.objectFinder) {
      await _askFinderTarget();
      return;
    }

    final mode = module.visionMode;
    if (mode == null) {
      debugPrint('[MODULE] ${module.title} has no vision mode; ignoring');
      return;
    }

    // Same source question as the voice path. Tapping the card used to skip
    // it and open the camera immediately, which meant a module card tap
    // behaved differently from saying the module's name - and a user who
    // wanted a saved file could not get one without backing out of a camera
    // that had already taken over the screen.
    await _askCameraOrFile(mode);
  }

  // ============================================================
  // HELP
  // ============================================================

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: AnimatedBuilder(
        animation: _backgroundController,
        builder: (context, child) {
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _DashboardBackgroundPainter(
                    progress: _backgroundController.value,
                    primary: _primaryColor,
                    secondary: _secondaryColor,
                  ),
                ),
              ),

              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        24,
                        18,
                        24,
                        30,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 1150,
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              _buildTopBar(),

                              // The "camera or file?" answer, as real buttons,
                              // shown only while that question is outstanding.
                              // Announced as a live region so a screen reader
                              // reads the options the moment they appear.
                              if (_sourceChoiceMode != null) ...[
                                const SizedBox(height: 18),
                                _buildSourceChoice(_sourceChoiceMode!),
                              ],

                              const SizedBox(height: 30),

                              _buildWelcome(),

                              const SizedBox(height: 25),

                              _buildVoiceAssistant(),

                              const SizedBox(height: 16),

                              _buildSectionTitle(),

                              const SizedBox(height: 18),

                              _buildModules(constraints),

                              const SizedBox(height: 32),

                              _buildAiHelpCard(),

                              const SizedBox(height: 16),

                              _buildNavigationCard(),

                              const SizedBox(height: 28),

                              _buildVoiceHint(),

                              const SizedBox(height: 22),

                              _buildFooter(),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // TOP BAR
  // ============================================================

  Widget _buildTopBar() {
    // The bar holds a 52px eye, the wordmark, the companion chip and five
    // round controls. That is far more than a phone-width Row can hold, which
    // is what produced the "RIGHT OVERFLOWED BY 334 PX" banner and pushed the
    // companion chip off the right edge of the screen entirely.
    //
    // Two layouts, chosen by available width: a single scrollable row on a
    // phone (nothing is ever clipped or pushed out of reach), and the full row
    // with the wordmark on its own line on a tablet.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;

        final actions = <Widget>[
          _companionChip(),
          const SizedBox(width: 10),
          _sosTopButton(),
          const SizedBox(width: 10),
          _smallTopButton(
            icon: Icons.contacts_rounded,
            onTap: _launchEmergencyContacts,
            semanticLabel: 'Emergency contacts',
            semanticHint: 'View, add or change the people your emergency alert '
                'will contact',
          ),
          const SizedBox(width: 10),
          _smallTopButton(
            icon: Icons.auto_awesome_rounded,
            onTap: _openHelp,
            semanticLabel: 'AI Help',
            semanticHint: 'Ask a spoken question to the assistant',
          ),
          const SizedBox(width: 10),
          _smallTopButton(
            icon: Icons.navigation_rounded,
            onTap: () => _openNavigation(''),
            semanticLabel: 'Smart Navigation',
            semanticHint: 'Find nearby places and get spoken directions',
          ),
          const SizedBox(width: 10),
          _smallTopButton(
            icon: Icons.logout_rounded,
            onTap: _logout,
            semanticLabel: 'Log out',
            semanticHint: 'Removes this device secure session and returns to '
                'the welcome screen',
          ),
        ];

        if (compact) {
          // The eye is pinned in the top-left corner and never scrolls away.
          return Row(
            children: [
              _instructionsButton(),
              const SizedBox(width: 12),
              const _Wordmark(showTagline: false),
              const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actions,
                  ),
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            _instructionsButton(),
            const SizedBox(width: 12),
            const _Wordmark(),
            const Spacer(),
            ...actions,
          ],
        );
      },
    );
  }

  /// CHANGE COMPANION - tapping the companion chip opens the switcher.
  ///
  /// The chip itself is the button, so the common action lives where the
  /// current companion is already displayed. It carries no trailing icon: the
  /// chevron/swap glyph that used to sit on it read as a separate control and
  /// gave no useful information.
  Widget _companionChip() {
    return Semantics(
      button: true,
      label: 'Change companion. You are currently using '
          '${_companion.name}.',
      hint: 'Opens the companion switcher to switch between Alex and Maya',
      onTap: _openChangeCompanion,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: _openChangeCompanion,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.045),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _primaryColor.withValues(alpha: 0.20),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          _primaryColor,
                          _secondaryColor,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryColor.withValues(alpha: 0.30),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Icon(
                      _companionIcon,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),

                  const SizedBox(width: 9),

                  Text(
                    _companion.name.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
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

  /// The eye icon: the app's only eye, and the Instructions control.
  ///
  /// Deliberately the first element in the top bar so it is literally in the
  /// top-left corner, and given the same 52px target as the SOS button so it
  /// is easy to hit without sight.
  ///
  /// It replaces the old logo circle, which used the same icon. Two identical
  /// eyes on screen meant a blind-ish tester could not tell which one spoke,
  /// and only this one did. There is now exactly one.
  Widget _instructionsButton() {
    return Semantics(
      button: true,
      label: 'Instructions',
      hint: 'Plays the full My Eyes guide out loud, including what every '
          'module does and how to use it',
      onTap: _playInstructions,
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'Hear the instructions',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: _playInstructions,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _secondaryColor,
                      _primaryColor,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryColor.withValues(
                        alpha: _instructionsPlaying ? 0.85 : 0.40,
                      ),
                      blurRadius: _instructionsPlaying ? 30 : 18,
                      spreadRadius: _instructionsPlaying ? 2 : 0,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.visibility_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sosTopButton() {
    final sosColor = const Color(0xFFFF3B3B);
    return Semantics(
      button: true,
      label: 'Emergency SOS',
      hint: 'Opens the emergency alert. You will be asked to confirm before '
          'anything is sent',
      onTap: _openSos,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: _openSos,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [Color(0xFFFF6B6B), Color(0xFFFF3B3B)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: sosColor.withValues(alpha: 0.55),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(
                Icons.sos_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _smallTopButton({
    required IconData icon,
    required VoidCallback onTap,
    required String semanticLabel,
    required String semanticHint,
  }) {
    // Every top-bar control gets a real semantic label and hint. These are the
    // only routes to SOS, contacts, help, navigation and logout for a user who
    // cannot see the icons.
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Tooltip(
          message: semanticLabel,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: onTap,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.045),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Icon(
                  icon,
                  color: Colors.white.withValues(alpha: 0.75),
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // CAMERA OR FILE CHOICE (touch)
  // ============================================================

  /// The visible answer to the spoken "camera or file?" question.
  ///
  /// Shown directly under the top bar for the whole time the question is
  /// outstanding, so a tap works immediately and does not have to wait for the
  /// microphone to recognise anything.
  Widget _buildSourceChoice(VisionMode mode) {
    final spokenName = VoiceCommandService.spokenName(mode);

    return Semantics(
      liveRegion: true,
      label: '$spokenName. Choose a source: use the camera, or choose a file.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: _primaryColor.withValues(alpha: 0.10),
          border: Border.all(
            color: _primaryColor.withValues(alpha: 0.40),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'How would you like to $spokenName?',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: _sourceChoiceButton(
                    icon: Icons.photo_camera_rounded,
                    label: 'USE CAMERA',
                    semanticLabel: 'Use the camera',
                    semanticHint: 'Opens the camera for $spokenName',
                    onTap: () => _chooseSourceByTouch(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _sourceChoiceButton(
                    icon: Icons.insert_drive_file_rounded,
                    label: 'CHOOSE FILE',
                    semanticLabel: 'Choose a file',
                    semanticHint: 'Opens the file picker to pick an image '
                        'for $spokenName',
                    onTap: () => _chooseSourceByTouch(false),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Text(
              'You can also say camera, or say choose a file.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChoiceButton({
    required IconData icon,
    required String label,
    required String semanticLabel,
    required String semanticHint,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _primaryColor,
                    _secondaryColor,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 26),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 0.8,
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

  // ============================================================
  // WELCOME
  // ============================================================

  Widget _buildWelcome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Good to see you.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),

        const SizedBox(height: 5),

        const Text(
          'What can I help you see?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 31,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 7),

        Text(
          'Everything you need, controlled by your voice.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.58),
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // VOICE ASSISTANT
  // ============================================================

  Widget _buildVoiceAssistant() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _orbController,
        _pulseController,
      ]),
      builder: (context, child) {
        final breathing =
            math.sin(_orbController.value * math.pi) * 4;

        final pulse =
            math.sin(_pulseController.value * math.pi) * 5;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 20,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                _primaryColor.withValues(alpha: 0.15),
                _secondaryColor.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0.035),
              ],
            ),
            border: Border.all(
              color: _isListening
                  ? _primaryColor.withValues(alpha: 0.65)
                  : Colors.white.withValues(alpha: 0.08),
            ),
            boxShadow: [
              if (_isListening)
                BoxShadow(
                  color: _primaryColor.withValues(alpha: 0.22),
                  blurRadius: 35,
                  spreadRadius: 2,
                ),
            ],
          ),
          child: Row(
            children: [
              // VOICE ORB
              Transform.translate(
                offset: Offset(
                  0,
                  -breathing - pulse / 4,
                ),
                child: GestureDetector(
                  onTap: _toggleListening,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          _accentColor,
                          _primaryColor,
                          _secondaryColor,
                        ],
                        stops: const [
                          0.0,
                          0.45,
                          1.0,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _primaryColor.withValues(
                            alpha: _isListening ? 0.55 : 0.25,
                          ),
                          blurRadius:
                              _isListening ? 35 : 22,
                          spreadRadius:
                              _isListening ? 6 : 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      _isListening
                          ? Icons.graphic_eq_rounded
                          : Icons.mic_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 20),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF5DFFB0),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF5DFFB0)
                                    .withValues(alpha: 0.6),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(width: 8),

                        Text(
                          _isListening
                              ? 'LISTENING'
                              : 'VOICE ASSISTANT',
                          style: TextStyle(
                            color: _isListening
                                ? const Color(0xFF65FFB1)
                                : Colors.white
                                    .withValues(alpha: 0.55),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    Text(
                      _isListening
                          ? (_lastHeard.isEmpty
                              ? "I'm listening..."
                              : '"$_lastHeard"')
                          : _voiceState == VoiceState.processing
                              ? 'Working on that...'
                              : _voiceState == VoiceState.speaking
                                  ? 'Speaking...'
                                  : "I'm ready whenever you need me.",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    const SizedBox(height: 5),

                    Text(
                      _isListening
                          ? 'Say a command such as "Scan object"'
                          : 'Say "Hey My Eyes" or tap the microphone.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.48),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 16),

              // MICROPHONE CONTROL
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _toggleListening,
                  borderRadius: BorderRadius.circular(18),
                  child: AnimatedContainer(
                    duration:
                        const Duration(milliseconds: 300),
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: _isListening
                          ? _primaryColor
                          : Colors.white.withValues(
                              alpha: 0.06,
                            ),
                      border: Border.all(
                        color: _isListening
                            ? _accentColor
                            : Colors.white.withValues(
                                alpha: 0.10,
                              ),
                      ),
                    ),
                    child: Icon(
                      _isListening
                          ? Icons.stop_rounded
                          : Icons.mic_none_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // SECTION TITLE
  // ============================================================

  Widget _buildSectionTitle() {
    return Row(
      children: [
        const Text(
          'VISION TOOLS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          child: Container(
            height: 1,
            color: Colors.white.withValues(alpha: 0.07),
          ),
        ),

        const SizedBox(width: 12),

        Text(
          'VOICE CONTROLLED',
          style: TextStyle(
            color: _primaryColor.withValues(alpha: 0.95),
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // MODULE GRID
  // ============================================================

  Widget _buildModules(BoxConstraints constraints) {
    final width = constraints.maxWidth;

    int crossAxisCount;

    if (width >= 1000) {
      crossAxisCount = 4;
    } else if (width >= 650) {
      crossAxisCount = 3;
    } else {
      crossAxisCount = 2;
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _modules.length,
      gridDelegate:
          SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.28,
      ),
      itemBuilder: (context, index) {
        return _buildModuleCard(_modules[index]);
      },
    );
  }

  Widget _buildModuleCard(ModuleItem module) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => module.isPayment
            ? _openPayment()
            : _openModule(module),
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                module.primary.withValues(alpha: 0.13),
                Colors.white.withValues(alpha: 0.035),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.075),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // MODULE ICON
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(16),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            module.primary,
                            module.secondary,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: module.primary.withValues(
                              alpha: 0.20,
                            ),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                      child: Icon(
                        module.icon,
                        color: Colors.white,
                        size: 25,
                      ),
                    ),

                    const Spacer(),

                    // HISTORY INDICATOR
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(
                          alpha: 0.05,
                        ),
                      ),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white.withValues(
                          alpha: 0.45,
                        ),
                        size: 16,
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                Text(
                  module.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  module.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(
                      alpha: 0.45,
                    ),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // HELP CARD
  // ============================================================

  Widget _buildAiHelpCard() {
    final aiStart = const Color(0xFF6C63FF);
    final aiEnd = const Color(0xFF42D9FF);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openHelp,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                aiStart.withValues(alpha: 0.22),
                aiEnd.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.035),
              ],
            ),
            border: Border.all(
              color: aiStart.withValues(alpha: 0.35),
            ),
            boxShadow: [
              BoxShadow(
                color: aiStart.withValues(alpha: 0.18),
                blurRadius: 28,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6C63FF), Color(0xFF42D9FF)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: aiStart.withValues(alpha: 0.35),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'HELP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Ask any question, I will read the answer aloud',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // NAVIGATION CARD
  // ============================================================

  Widget _buildNavigationCard() {
    final navStart = const Color(0xFF42D392);
    final navEnd = const Color(0xFF42D9FF);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openNavigation(''),
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                navStart.withValues(alpha: 0.22),
                navEnd.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.035),
              ],
            ),
            border: Border.all(
              color: navStart.withValues(alpha: 0.35),
            ),
            boxShadow: [
              BoxShadow(
                color: navStart.withValues(alpha: 0.18),
                blurRadius: 28,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient:
                        const LinearGradient(colors: [Color(0xFF42D392), Color(0xFF42D9FF)]),
                    boxShadow: [
                      BoxShadow(
                        color: navStart.withValues(alpha: 0.35),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NAVIGATION',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Voice-guided directions to anywhere',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // VOICE HINT
  // ============================================================

  Widget _buildVoiceHint() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 15,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primaryColor.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.tips_and_updates_rounded,
              color: _accentColor,
              size: 19,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Text(
              'Try saying  "Read this text"  •  '
              '"Find my phone"  •  '
              '"Describe my surroundings"',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.52),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // FOOTER
  // ============================================================

  Widget _buildFooter() {
    final notConfigured =
        PostLoginCoordinator.readiness == SosReadiness.notConfigured;

    return Column(
      children: [
        // The safety nudge is a visible control, not just a spoken line: a user
        // who did not hear it (or skipped the setup) still has a one-tap route
        // to finish configuring SOS.
        if (notConfigured) ...[
          _safetySetupCard(),
          const SizedBox(height: 18),
        ],

        Semantics(
          button: true,
          label: 'Repeat the My Eyes instructions',
          hint: 'Plays the full guide out loud again',
          onTap: _playInstructions,
          child: ExcludeSemantics(
            child: TextButton.icon(
              onPressed: _playInstructions,
              icon: const Icon(
                Icons.visibility_rounded,
                size: 18,
                color: Colors.white54,
              ),
              label: const Text(
                'REPEAT INSTRUCTIONS',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        Center(
          child: Text(
            'MY EYES  •  PERSONAL VISION ASSISTANT',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.20),
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  /// Dashboard card shown while SOS has no emergency contacts.
  Widget _safetySetupCard() {
    return Semantics(
      button: true,
      label: 'Set up your emergency SOS. Your emergency contacts are not '
          'configured yet.',
      hint: 'Opens a voice guided setup for your emergency contacts',
      onTap: _openSosSetup,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _openSosSetup,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xFFFF3B3B).withValues(alpha: 0.10),
                border: Border.all(
                  color: const Color(0xFFFF3B3B).withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.shield_moon_rounded,
                    color: Color(0xFFFF6B6B),
                    size: 26,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Set Up Emergency SOS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add the people to alert. Say set up S O S, or tap '
                          'here.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.60),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.4),
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

// ================================================================
// MODULE DATA
// ================================================================

/// "MY EYES" plus its tagline.
///
/// Extracted so the compact and wide top-bar layouts share one definition and
/// cannot drift apart. On a phone the tagline is dropped: it is ~180px wide
/// next to the 52px eye, which left too little room for the action controls to
/// be reachable without a lot of scrolling.
class _Wordmark extends StatelessWidget {
  const _Wordmark({this.showTagline = true});

  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'MY EYES',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: 4,
          ),
        ),
        if (showTagline)
          Text(
            'SEE THE WORLD THROUGH SOUND',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 8,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
      ],
    );
  }
}

// Dashboard cards. Titles are the [VisionMode] titles, so a module's name is
// identical on its card, inside the scanner, and in its history screen. The
// spoken purpose of each of these lives in ModuleCatalog, which is what the
// eye-icon instructions read.
const List<ModuleItem> _modules = [
  ModuleItem(
    title: 'Scan Object',
    subtitle: 'Identify objects around you',
    icon: Icons.center_focus_strong_rounded,
    primary: Color(0xFF149EFF),
    secondary: Color(0xFF5267FF),
  ),
  ModuleItem(
    title: 'Read Text',
    subtitle: 'Read printed text aloud',
    icon: Icons.document_scanner_rounded,
    primary: Color(0xFF39D9FF),
    secondary: Color(0xFF397CFF),
  ),
  ModuleItem(
    title: 'Medicine Detection',
    subtitle: 'Read medicine information',
    icon: Icons.medication_rounded,
    primary: Color(0xFF55D6A5),
    secondary: Color(0xFF319CFF),
  ),
  ModuleItem(
    title: 'Product Detection',
    subtitle: 'Read packaged food details',
    icon: Icons.inventory_2_rounded,
    primary: Color(0xFFFFA94D),
    secondary: Color(0xFFFF5F8F),
  ),
  ModuleItem(
    title: 'Currency Detection',
    subtitle: 'Recognize currency notes',
    icon: Icons.currency_rupee_rounded,
    primary: Color(0xFF5EE7A5),
    secondary: Color(0xFF3BB5FF),
  ),
  ModuleItem(
    title: 'Scan Payment',
    subtitle: 'Pay a UPI QR code',
    icon: Icons.qr_code_2_rounded,
    primary: Color(0xFF2ADE88),
    secondary: Color(0xFF149EFF),
    isPayment: true,
  ),
  ModuleItem(
    title: 'Scene Detection',
    subtitle: 'Understand your surroundings',
    icon: Icons.landscape_rounded,
    primary: Color(0xFFB56CFF),
    secondary: Color(0xFF6674FF),
  ),
  ModuleItem(
    title: 'Object Detection',
    subtitle: 'Locate a specific object',
    icon: Icons.radar_rounded,
    primary: Color(0xFFFF5FA2),
    secondary: Color(0xFF9B5CFF),
  ),
];

class ModuleItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color primary;
  final Color secondary;

  /// When true the card opens the dedicated payment flow instead of the
  /// scanner module.
  final bool isPayment;

  const ModuleItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.primary,
    required this.secondary,
    this.isPayment = false,
  });

  /// The vision mode this card opens, or null for a non-scanner module such as
  /// Scan Payment.
  ///
  /// Resolved through [ModuleCatalog] rather than a duplicated title switch so
  /// a renamed module cannot leave a card pointing at nothing.
  VisionMode? get visionMode => ModuleCatalog.forTitle(title)?.mode;
}


// ================================================================
// DASHBOARD BACKGROUND
// ================================================================

class _DashboardBackgroundPainter
    extends CustomPainter {
  final double progress;
  final Color primary;
  final Color secondary;

  _DashboardBackgroundPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint();

    final x = size.width *
        (0.5 +
            math.sin(
                  progress * math.pi * 2,
                ) *
                0.25);

    final y = size.height *
        (0.25 +
            math.cos(
                  progress * math.pi * 2,
                ) *
                0.12);

    paint.shader = RadialGradient(
      center: Alignment(
        (x / size.width) * 2 - 1,
        (y / size.height) * 2 - 1,
      ),
      radius: 1.1,
      colors: [
        primary.withValues(alpha: 0.12),
        secondary.withValues(alpha: 0.055),
        Colors.transparent,
      ],
    ).createShader(
      Rect.fromLTWH(
        0,
        0,
        size.width,
        size.height,
      ),
    );

    canvas.drawRect(
      Rect.fromLTWH(
        0,
        0,
        size.width,
        size.height,
      ),
      paint,
    );

    final particlePaint = Paint()
      ..color = primary.withValues(alpha: 0.08);

    for (int i = 0; i < 30; i++) {
      final px = (i * 127.0) % size.width;

      final py =
          ((i * 91.0) +
                  progress * size.height) %
              size.height;

      canvas.drawCircle(
        Offset(px, py),
        0.8 + (i % 3) * 0.4,
        particlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant _DashboardBackgroundPainter oldDelegate,
  ) {
    return oldDelegate.progress != progress ||
        oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary;
  }
}
