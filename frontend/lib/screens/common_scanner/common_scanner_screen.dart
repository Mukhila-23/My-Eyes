import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import '../../services/app_instructions.dart';
import '../../services/vision_service.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/module_catalog.dart';
import '../../core/theme/app_theme.dart';
import '../../core/vision_mode.dart';
import '../history/module_history_screen.dart';

class CommonScannerScreen extends StatefulWidget {
  final VisionMode mode;

  /// When true (voice-command entry) the camera opens automatically
  /// so a blind user does not need to find the button.
  final bool autoStart;

  /// When true the gallery/file picker opens instead of the camera
  /// (voice command: "choose file").
  final bool startFromFile;

  /// Target object for Object Finder, e.g. "phone" from
  /// "find my phone".
  final String? target;

  /// Optional image bytes from a previously chosen file (voice file flow).
  /// When provided, the module opens with this file and processes it
  /// directly instead of triggering the camera or picker on load.
  final Uint8List? initialImageBytes;

  const CommonScannerScreen({
    super.key,
    required this.mode,
    this.autoStart = false,
    this.startFromFile = false,
    this.target,
    this.initialImageBytes,
  });

  @override
  State<CommonScannerScreen> createState() => _CommonScannerScreenState();
}

class _CommonScannerScreenState extends State<CommonScannerScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _voice = VoiceCommandService.instance;

Uint8List? _selectedImageBytes;
  // This is the only image that can be sent to the API.  Both input paths
  // replace it; processing never opens the camera or reads a previous image.
  String _activeImageSource = 'unknown';
  String _activeImageName = 'image.jpg';
  bool _isProcessing = false;

  // True while the auto-start countdown is still pending (the module opened
  // with autoStart and "capturing in 3 seconds" is still being spoken).
  // Disarmed the moment the user makes an explicit input choice so a stale
  // auto-start can never open the camera after a file has been selected and
  // overwrite the chosen image with a new capture.
  bool _autoCameraArmed = false;

  // Ownership token for this module's own voice session, so a late dispose()
  // cannot stop the session that replaced it.
  int? _voiceSession;

  // Guards every async callback: the camera screen, the file picker and the
  // history screen all dispose this State while work is in flight.
  bool _disposed = false;

  // ============================================================
  // MODULE COLORS
  // ============================================================

  Color get _primaryColor {
    switch (widget.mode) {
      case VisionMode.scanObject:
        return const Color(0xFF149EFF);

      case VisionMode.readText:
        return const Color(0xFF39D9FF);

      case VisionMode.medicine:
        return const Color(0xFF55D6A5);

      case VisionMode.product:
        return const Color(0xFFFFA94D);

      case VisionMode.currency:
        return const Color(0xFF5EE7A5);

      case VisionMode.scene:
        return const Color(0xFFB56CFF);

      case VisionMode.objectFinder:
        return const Color(0xFFFF5FA2);
    }
  }

  Color get _secondaryColor {
    switch (widget.mode) {
      case VisionMode.scanObject:
        return const Color(0xFF5267FF);

      case VisionMode.readText:
        return const Color(0xFF397CFF);

      case VisionMode.medicine:
        return const Color(0xFF319CFF);

      case VisionMode.product:
        return const Color(0xFFFF5F8F);

      case VisionMode.currency:
        return const Color(0xFF3BB5FF);

      case VisionMode.scene:
        return const Color(0xFF6674FF);

      case VisionMode.objectFinder:
        return const Color(0xFF9B5CFF);
    }
  }

  // ============================================================
  // MODULE TITLE
  // ============================================================

  /// Titles come from [VisionMode] so the module's name is identical on the
  /// dashboard card, in this header, and in the history screen title.
  String get _moduleTitle => widget.mode.title;

  // ============================================================
  // MODULE DESCRIPTION
  // ============================================================

  String get _moduleDescription => widget.mode.description;

  // ============================================================
  // FILE SUPPORT
  // Every module accepts an image input (camera or file).
  // ============================================================

  bool get _supportsFile => true;

  // ============================================================
  // MODULE ICON
  // ============================================================

  IconData get _moduleIcon {
    switch (widget.mode) {
      case VisionMode.scanObject:
        return Icons.center_focus_strong_rounded;

      case VisionMode.readText:
        return Icons.document_scanner_rounded;

      case VisionMode.medicine:
        return Icons.medication_rounded;

      case VisionMode.product:
        return Icons.inventory_2_rounded;

      case VisionMode.currency:
        return Icons.currency_rupee_rounded;

      case VisionMode.scene:
        return Icons.landscape_rounded;

      case VisionMode.objectFinder:
        return Icons.radar_rounded;
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  void initState() {
    super.initState();

    // A module spends its life handing the microphone to *other* apps: the
    // system camera, the file picker, a permission dialog. Each of those makes
    // this screen inactive, which parks the voice engine in the background.
    // Without these callbacks nothing ever replayed that parked resume, so
    // coming back from the camera left the module deaf - the user was told
    // "say history" and the app never heard it.
    WidgetsBinding.instance.addObserver(this);

    if (widget.initialImageBytes != null) {
      _selectedImageBytes = widget.initialImageBytes;
      _activeImageSource = 'file';
      _activeImageName = 'selected-image.jpg';
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Own a voice session from the moment the module opens. That is what
      // makes "history" work HERE, while this module is the active screen:
      // the dashboard session is replaced, not shared.
      unawaited(_beginModuleVoice());

      if (widget.initialImageBytes != null) {
        _processImage();
      } else if (widget.startFromFile) {
        _runFileFlow();
      } else if (widget.autoStart) {
        _runCameraFlow();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (_disposed) return;
    if (lifecycleState == AppLifecycleState.resumed) {
      unawaited(_voice.resumeAfterLifecycle());
    } else if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.inactive ||
        lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.detached) {
      unawaited(_voice.pauseForLifecycle());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Guards every async callback below: the camera screen and the history
    // screen both cause this State to be disposed mid-flight.
    _disposed = true;

    // This module DOES own a session now (so "history" can be spoken here), so
    // it must stop it. Token-guarded, so a dispose that lands after the
    // dashboard already restarted its own session is ignored rather than
    // killing the live microphone.
    //
    // `dispose()` runs after this route's future resolved, i.e. after the
    // dashboard underneath has already claimed the engine and started
    // listening. Releasing through the token - rather than pausing and
    // stopping the microphone unconditionally afterwards - is what stops this
    // module silencing the screen that replaced it on its way out.
    _voice.releaseSession(_voiceSession);

    super.dispose();
  }

  // ============================================================
  // MODULE VOICE SESSION
  // ============================================================

  /// Starts this module's voice session and announces what is available here.
  ///
  /// The opening line names the module, explains what it is for, and mentions
  /// the History button, so a user who arrived by voice is never dropped into
  /// an unexplained screen.
  Future<void> _beginModuleVoice() async {
    if (_disposed || !mounted) return;

    _voiceSession = await _voice.startSession(
      onCommand: _handleModuleCommand,
      autoStart: false,
    );
    if (_disposed || !mounted) return;

    debugPrint('[MODULE] $_moduleTitle owns voice session #$_voiceSession');

    await _voice.speak(_moduleOpeningSpoken, resumeAfter: false);
    if (_disposed || !mounted) return;

    // Listen so "history" and "go back" work straight away.
    await _voice.resumeMicrophone();
  }

  /// Name + purpose + what to say next.
  String get _moduleOpeningSpoken {
    final purpose = ModuleCatalog.forMode(widget.mode)?.purpose;
    final buffer = StringBuffer();

    buffer.write('$_moduleTitle is open. ');
    if (purpose != null && purpose.isNotEmpty) {
      buffer.write('$purpose ');
    }

    if (widget.mode.hasHistory) {
      buffer.write(AppInstructions.moduleHistoryHint(widget.mode));
    } else {
      buffer.write('Say help for more about this module.');
    }

    return buffer.toString();
  }

  /// Handles a spoken command while this module is the active screen.
  ///
  /// The important behaviour: "history" (or "show history", "open history")
  /// opens THIS module's history and nothing else. It is deliberately
  /// intercepted here rather than routed through the global router, because the
  /// router has no idea which module is on screen and a generic history screen
  /// would mix every module's results together.
  Future<void> _handleModuleCommand(String raw) async {
    if (_disposed || !mounted) return;
    final transcript = VoiceCommandService.stripWakeWords(raw).toLowerCase();
    if (transcript.isEmpty) return;

    if (VoiceCommandService.isBackCommand(transcript)) {
      await _voice.speak(
        'Closing $_moduleTitle.',
        resumeAfter: false,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    if (VoiceCommandService.isRepeatCommand(transcript)) {
      await _voice.speak(
        _voice.lastSpokenResponse ??
            '$_moduleTitle. ${ModuleCatalog.forMode(widget.mode)?.purpose ?? ''}',
        pace: TtsPace.moduleResult,
      );
      return;
    }

    if (VoiceCommandService.isHelpCommand(transcript)) {
      _showHelp();
      return;
    }

    if (_isHistoryRequest(transcript)) {
      await _openOwnHistory();
      return;
    }

    if (VoiceCommandService.isCaptureCommand(transcript)) {
      await _scanWithCamera();
      return;
    }

    if (VoiceCommandService.isFileCommand(transcript)) {
      await _chooseFile();
      return;
    }

    await _voice.speak(
      'In $_moduleTitle you can say history to open '
      '${widget.mode.historyLabel}, help to hear about this module, or go '
      'back to return to the dashboard.',
    );
  }

  /// True for every phrasing that means "open this module's history".
  static bool _isHistoryRequest(String transcript) =>
      transcript.contains('history') || transcript.contains('past result');

  /// Opens [Mode]'s own history screen and returns here afterwards.
  Future<void> _openOwnHistory() async {
    if (_disposed || !mounted) return;

    await _voice.setProcessing();
    await _voice.speak(
      'Opening your ${widget.mode.historyLabel}.',
      resumeAfter: false,
    );
    await _voice.pauseMicrophone();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModuleHistoryScreen(
          mode: widget.mode,
          companion: _voice.appliedCompanion,
        ),
      ),
    );

    if (_disposed || !mounted) return;

    // Returning to the module: resume listening so "history" still works.
    _voiceSession = await _voice.startSession(
      onCommand: _handleModuleCommand,
      autoStart: false,
    );
    if (_disposed || !mounted) return;

    await _voice.speak(
      'Back in $_moduleTitle.',
      resumeAfter: false,
    );
    await _voice.resumeMicrophone();
  }

  // ============================================================
  // VOICE FLOW
  //
  // The module is a single voice round-trip:
  // instruction -> capture -> answer spoken -> back to dashboard.
  // The dashboard owns the microphone the whole time, which keeps
  // speech recognition reliable after the system camera closes.
  // ============================================================

  /// Voice-entry point: explain what to do, then open the camera.
  Future<void> _runCameraFlow() async {
    _autoCameraArmed = true;

    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || !_autoCameraArmed) return;

    final target = widget.target;

    if (target != null && target.isNotEmpty) {
      await _voice.speak(
        'Object Finder is ready. Hold the camera and turn around slowly.',
        resumeAfter: false,
      );
    } else {
      await _voice.speak(
        '$_moduleTitle is ready. Camera ready. Capturing in 3 seconds. '
        '3. 2. 1.',
        resumeAfter: false,
      );
    }

    // The user may have tapped "Choose a File" / "Scan with Camera" while the
    // countdown was being spoken.  Those handlers disarm this flow, so the
    // camera must not open afterwards and hijack the chosen input.
    if (!mounted || !_autoCameraArmed) return;
    await _scanWithCamera();
  }

  /// "Choose file" entry point for Read Text.
  Future<void> _runFileFlow() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    await _voice.speak(
      '$_moduleTitle is open. Choose an image.',
      resumeAfter: false,
    );

    if (!mounted) return;
    await _chooseFile();
  }

  /// Speaks the final answer, remembers it for "repeat", and returns
  /// to the dashboard so the next voice command is handled at once.
  ///
  /// When the result was actually stored server-side, the answer is followed
  /// by the command that shows it in the module's history. Without this the
  /// user hears the answer and is then immediately returned to the dashboard
  /// with no way to know the scan was saved or how to revisit it.
  Future<void> _finishWithMessage(
    String message, {
    bool goBack = true,
    bool savedToHistory = false,
  }) async {
    if (!mounted) return;

    _showMessage(message);

    // Module output (OCR text, labels, amounts) is spoken in the slower,
    // clearer tier and stored as the shared response for "repeat".
    await _voice.speak(
      message,
      resumeAfter: false,
      pace: TtsPace.moduleResult,
      remember: true,
    );

    if (!mounted) return;

    // Only claim it is in the history when the request actually succeeded:
    // telling a user to look for a result that was never stored is worse than
    // saying nothing.
    if (savedToHistory && widget.mode.hasHistory) {
      await _voice.speak(
        AppInstructions.historyAfterResultSpoken(widget.mode),
        resumeAfter: false,
      );
    }

    if (!mounted || !goBack) return;

    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: _Background(
              primary: _primaryColor,
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                _buildHeader(),

                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      22,
                      10,
                      22,
                      30,
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 10),

                        _buildModuleHeader(),

                        const SizedBox(height: 28),

                        if (_selectedImageBytes != null)
                          _buildImagePreview()
                        else
                          _buildScannerIllustration(),

                        const SizedBox(height: 28),

                        if (_isProcessing)
                          _buildProcessing()
                        else
                          _buildInputOptions(),

                        const SizedBox(height: 24),

                        _buildVoiceHint(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // HEADER
  // ============================================================

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        20,
        14,
        20,
        8,
      ),
      child: Row(
        children: [
          _roundButton(
            icon: Icons.arrow_back_rounded,
            semanticLabel: 'Go back to the dashboard',
            semanticHint: 'Closes $_moduleTitle',
            onTap: () {
              Navigator.of(context).pop();
            },
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                _moduleTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),

          // HISTORY - present on every module that stores results. Opens only
          // this module's results, never a mixed list.
          if (widget.mode.hasHistory) ...[
            _historyButton(),
            const SizedBox(width: 10),
          ],

          _roundButton(
            icon: Icons.help_outline_rounded,
            semanticLabel: 'Help for $_moduleTitle',
            semanticHint: 'Explains what this module does',
            onTap: _showHelp,
          ),
        ],
      ),
    );
  }

  /// The module's History button.
  Widget _historyButton() {
    return Semantics(
      button: true,
      label: 'History for $_moduleTitle',
      hint: 'Opens your ${widget.mode.historyLabel}, showing the date, time '
          'and result of each scan',
      onTap: _openOwnHistory,
      child: ExcludeSemantics(
        child: Tooltip(
          message: widget.mode.historyLabel,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openOwnHistory,
              borderRadius: BorderRadius.circular(15),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  color: _primaryColor.withValues(alpha: 0.12),
                  border: Border.all(
                    color: _primaryColor.withValues(alpha: 0.30),
                  ),
                ),
                child: Icon(
                  Icons.history_rounded,
                  color: _primaryColor,
                  size: 21,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    String? semanticLabel,
    String? semanticHint,
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
            onTap: onTap,
            borderRadius: BorderRadius.circular(15),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.05),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Icon(
                icon,
                color: Colors.white.withValues(alpha: 0.85),
                size: 21,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // MODULE HEADER
  // ============================================================

  Widget _buildModuleHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
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
                color: _primaryColor.withValues(
                  alpha: 0.28,
                ),
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            _moduleIcon,
            color: Colors.white,
            size: 34,
          ),
        ),

        const SizedBox(height: 18),

        Text(
          _moduleTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 27,
            fontWeight: FontWeight.w800,
          ),
        ),

        const SizedBox(height: 7),

        Text(
          _moduleDescription,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.52),
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // SCANNER ILLUSTRATION
  // ============================================================

  Widget _buildScannerIllustration() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        maxWidth: 520,
      ),
      height: 260,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: Colors.white.withValues(alpha: 0.025),
        border: Border.all(
          color: _primaryColor.withValues(alpha: 0.20),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primaryColor.withValues(alpha: 0.06),
              border: Border.all(
                color: _primaryColor.withValues(alpha: 0.16),
              ),
            ),
          ),

          Container(
            width: 125,
            height: 125,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  _primaryColor.withValues(alpha: 0.30),
                  _secondaryColor.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
              ),
            ),
            child: Icon(
              Icons.camera_alt_rounded,
              color: Colors.white.withValues(alpha: 0.85),
              size: 55,
            ),
          ),

          Positioned(
            top: 20,
            left: 20,
            child: _corner(
              top: true,
              left: true,
            ),
          ),

          Positioned(
            top: 20,
            right: 20,
            child: _corner(
              top: true,
              left: false,
            ),
          ),

          Positioned(
            bottom: 20,
            left: 20,
            child: _corner(
              top: false,
              left: true,
            ),
          ),

          Positioned(
            bottom: 20,
            right: 20,
            child: _corner(
              top: false,
              left: false,
            ),
          ),

          Positioned(
            bottom: 18,
            child: Text(
              'READY TO SCAN',
              style: TextStyle(
                color: _primaryColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _corner({
    required bool top,
    required bool left,
  }) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        border: Border(
          top: top
              ? BorderSide(
                  color: _primaryColor.withValues(alpha: 0.8),
                  width: 3,
                )
              : BorderSide.none,
          bottom: !top
              ? BorderSide(
                  color: _primaryColor.withValues(alpha: 0.8),
                  width: 3,
                )
              : BorderSide.none,
          left: left
              ? BorderSide(
                  color: _primaryColor.withValues(alpha: 0.8),
                  width: 3,
                )
              : BorderSide.none,
          right: !left
              ? BorderSide(
                  color: _primaryColor.withValues(alpha: 0.8),
                  width: 3,
                )
              : BorderSide.none,
        ),
      ),
    );
  }

  // ============================================================
  // INPUT OPTIONS
  // ============================================================

  Widget _buildInputOptions() {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 520,
      ),
      child: Column(
        children: [
          _buildInputButton(
            icon: Icons.camera_alt_rounded,
            title: 'Scan with Camera',
            subtitle: 'Use your camera to capture an image',
            onTap: _scanWithCamera,
            primary: true,
          ),

          // ------------------------------------------------------
          // FILE UPLOAD (ALL MODULES)
          // ------------------------------------------------------

          if (_supportsFile) ...[
            const SizedBox(height: 13),

            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                  ),
                  child: Text(
                    'OR',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.28),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),

                Expanded(
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 13),

            _buildInputButton(
              icon: Icons.upload_file_rounded,
              title: 'Choose a File',
              subtitle: 'Select an image from your device',
              onTap: _chooseFile,
              primary: false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool primary,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: primary
                ? LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      _primaryColor.withValues(alpha: 0.25),
                      _secondaryColor.withValues(alpha: 0.13),
                    ],
                  )
                : null,
            color: primary
                ? null
                : Colors.white.withValues(alpha: 0.035),
            border: Border.all(
              color: primary
                  ? _primaryColor.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  gradient: LinearGradient(
                    colors: [
                      _primaryColor,
                      _secondaryColor,
                    ],
                  ),
                ),
                child: Icon(
                  icon,
                  color: Colors.white,
                  size: 25,
                ),
              ),

              const SizedBox(width: 15),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white.withValues(alpha: 0.35),
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // CAMERA
  // ============================================================

  Future<void> _scanWithCamera() async {
    // Explicit user choice: cancel any still-pending auto-start camera so a
    // duplicate (auto-capture) camera screen never opens on top of this one.
    _autoCameraArmed = false;

    // Camera access takes over the microphone.
    await _voice.pauseMicrophone();
    if (!mounted) return;

    debugPrint('[CAMERA] opening auto-capture camera for $_moduleTitle');

    try {
      final bytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _AutoCaptureCameraScreen(title: _moduleTitle),
        ),
      );

      if (bytes == null) {
        debugPrint('[CAMERA] cancelled (no image)');
        await _finishWithMessage(
          'Scan cancelled. Going back to the dashboard.',
        );
        return;
      }

      debugPrint('[CAMERA] image captured (${bytes.length} bytes)');

      if (!mounted) return;

      setState(() {
        _selectedImageBytes = bytes;
        _activeImageSource = 'camera';
        _activeImageName = 'camera-capture.jpg';
      });

      await _processImage();
    } catch (e) {
      debugPrint('[CAMERA] error: $e');
      await _finishWithMessage(
        'The camera could not be opened. Please check camera permission.',
      );
    }
  }

  // ============================================================
  // FILE PICKER
  // ============================================================

  Future<void> _chooseFile() async {
    if (!_supportsFile) {
      return;
    }

    // The user chose the file input: disarm the pending auto-start camera so
    // it never opens after the picker closes and processes a new capture
    // instead of the file that was just selected.
    _autoCameraArmed = false;

    await _voice.pauseMicrophone();

    final pickedFile = await _pickSystemFile();
    if (pickedFile == null) {
      if (!mounted) return;
      await _finishWithMessage(
        'No file was selected. Going back to the dashboard.',
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _selectedImageBytes = pickedFile.bytes!;
      _activeImageSource = 'file';
      _activeImageName = pickedFile.fileName ?? 'selected-image.jpg';
    });

    await _processImage();
  }

  /// Opens the Android system file picker (Storage Access Framework) and
  /// returns validated, decodable image bytes — or null if the user
  /// cancelled / the file is invalid. Never scans the filesystem.
  Future<PickedFileResult?> _pickSystemFile() async {
    final label = VoiceCommandService.spokenName(widget.mode);

    try {
      final result = await VoiceFilePicker.instance.pickImageForName(label);
      if (!result.picked || result.bytes == null) {
        return null;
      }

      final bytes = result.bytes!;

      // Verify the chosen file is actually a decodable image (format +
      // accessibility check) before handing it to the vision module.
      try {
        final decoded = await decodeImageFromList(bytes);
        decoded.dispose();
      } catch (_) {
        await _voice.speak(
          "This file type isn't supported. Please choose an image.",
          resumeAfter: false,
        );
        return null;
      }

      return result;
    } catch (_) {
      await _voice.speak(
        "I couldn't open that file. Please choose another file.",
        resumeAfter: false,
      );
      return null;
    }
  }

  // ============================================================
  // PROCESS IMAGE
  // ============================================================

  String get _processingAnnouncement {
    switch (widget.mode) {
      case VisionMode.readText:
        return 'Reading text. Please wait.';
      case VisionMode.currency:
        return 'Identifying currency. Please wait.';
      default:
        return 'Processing image.';
    }
  }

Future<void> _processImage() async {
    if (_selectedImageBytes == null || _isProcessing) {
      return;
    }

    debugPrint('[MODULE] scan input: mode=${widget.mode.name} '
        'source=$_activeImageSource name=$_activeImageName '
        'bytes=${_selectedImageBytes!.length}');

    setState(() {
      _isProcessing = true;
    });

    // Close the microphone for the whole backend round trip so the
    // recognizer cannot hear the announcement or the answer.
    await _voice.setProcessing();
    await _voice.speak(_processingAnnouncement, resumeAfter: false);

    debugPrint('[API] vision request started: ${widget.mode.name}');

    String message;
    var saved = false;
    try {
      final result = await VisionService.processImage(
        mode: widget.mode,
        imageBytes: _selectedImageBytes!,
        fileName: _activeImageName,
        target: widget.target,
      );

      message = result.message;
      saved = result.success;

      debugPrint('[API] vision result: '
          'success=${result.success} message=${result.message}');
    } catch (e) {
      debugPrint('[API] vision request failed: $e');
      message = 'Unable to process the image. Please try again.';
    }

    // Clear the busy state before the answer is spoken.  Speaking takes several
    // seconds, and the screen used to keep showing "Processing image..."
    // (with _isProcessing still true) for that whole time, so a finished
    // request could display the spinner together with its own error message.
    // `_finishWithMessage` then speaks, shows the answer and returns to the
    // dashboard, so this ordering guarantees the indicator is never visible
    // once the operation has an outcome.
    if (mounted && _isProcessing) {
      setState(() {
        _isProcessing = false;
      });
    }

    debugPrint('[MODULE] scan finished: ${widget.mode.name}');

if (!mounted) return;

    await _finishWithMessage(message, savedToHistory: saved);
  }

  // ============================================================
  // PROCESSING
  // ============================================================

  Widget _buildProcessing() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        maxWidth: 520,
      ),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withValues(alpha: 0.035),
        border: Border.all(
          color: _primaryColor.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: _primaryColor,
            ),
          ),

          const SizedBox(width: 15),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Processing image...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  'Please wait while My Eyes analyzes it.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // VOICE HINT
  // ============================================================

  Widget _buildVoiceHint() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        maxWidth: 520,
      ),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.025),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _primaryColor.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.record_voice_over_rounded,
              color: _primaryColor,
              size: 20,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Text(
              _voiceInstruction,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.50),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _voiceInstruction {
    switch (widget.mode) {
      case VisionMode.scanObject:
        return 'Say "Scan object" to start the camera.';

      case VisionMode.readText:
        return 'Say "Read text" to scan, or "Read this file" to choose an image.';

      case VisionMode.medicine:
        return 'Say "Scan medicine" to identify the medicine.';

      case VisionMode.product:
        return 'Say "Scan product" to read product details.';

      case VisionMode.currency:
        return 'Say "Read currency" to identify the currency note.';

      case VisionMode.scene:
        return 'Say "Describe surroundings" to analyze the scene.';

      case VisionMode.objectFinder:
        return 'Say "Find my object" to start searching with the camera.';
    }
  }

  // ============================================================
  // HELP
  // ============================================================

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF171A2A),
          title: const Text(
            'Voice Control',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: Text(
            _voiceInstruction,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(
                'OK',
                style: TextStyle(
                  color: _primaryColor,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF20243A),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ============================================================
  // IMAGE PREVIEW
  // ============================================================

  Widget _buildImagePreview() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        maxWidth: 520,
      ),
      height: 300,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: _primaryColor.withValues(alpha: 0.25),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            _selectedImageBytes!,
            fit: BoxFit.cover,
          ),

          Positioned(
            top: 14,
            right: 14,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _selectedImageBytes = null;
                  });
                },
                borderRadius: BorderRadius.circular(14),
                child: const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            left: 14,
            bottom: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.60),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: _primaryColor,
                    size: 16,
                  ),

                  const SizedBox(width: 6),

                  const Text(
                    'IMAGE SELECTED',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
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
}

// ================================================================
// BACKGROUND
// ================================================================

class _Background extends StatelessWidget {
  final Color primary;

  const _Background({
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BackgroundPainter(
        primary: primary,
      ),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  final Color primary;

  const _BackgroundPainter({
    required this.primary,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.5),
        radius: 1.1,
        colors: [
          primary.withValues(alpha: 0.12),
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
  }

  @override
  bool shouldRepaint(
    covariant _BackgroundPainter oldDelegate,
  ) {
    return oldDelegate.primary != primary;
  }
}

/// A live camera for voice-initiated scans.  Unlike the system image-picker
/// camera, it does not require the user to find a shutter button.
class _AutoCaptureCameraScreen extends StatefulWidget {
  const _AutoCaptureCameraScreen({required this.title});

  final String title;

  @override
  State<_AutoCaptureCameraScreen> createState() =>
      _AutoCaptureCameraScreenState();
}

class _AutoCaptureCameraScreenState extends State<_AutoCaptureCameraScreen> {
  CameraController? _controller;
  Timer? _captureTimer;
  String? _error;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera is available');
      final controller = CameraController(
        cameras.first,
        // The previous "medium" preset produced 720x480 photos, which is too
        // few pixels for the small print on documents and currency notes:
        // OCR could not read the denomination.  "high" (720x1280) doubles the
        // detail while staying cheap enough for an instant capture.
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      debugPrint('[CAMERA] initialized');
      debugPrint('[CAMERA] auto capture started (7 seconds)');
      _captureTimer = Timer(const Duration(seconds: 7), _capture);
    } catch (error) {
      debugPrint('[CAMERA] initialization failed: $error');
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_capturing || controller == null || !controller.value.isInitialized) {
      return;
    }
    _capturing = true;
    try {
      final image = await controller.takePicture();
      final bytes = await image.readAsBytes();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (error) {
      debugPrint('[CAMERA] capture failed: $error');
      if (mounted) setState(() => _error = 'Unable to capture the image.');
    } finally {
      _capturing = false;
    }
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      body: _error != null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'I could not access the camera. Please try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
            )
          : controller == null || !controller.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Semantics(
                  label: 'Live camera preview. Capturing automatically.',
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(controller),
                      const Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            'Hold the phone steady. Capturing automatically…',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 17),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
