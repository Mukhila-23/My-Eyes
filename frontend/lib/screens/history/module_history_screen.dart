import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/vision_mode.dart';
import '../../services/companion.dart';
import '../../services/history_service.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';

/// History for ONE vision module.
///
/// Opened by the History button in the module's top bar, by saying "history"
/// while that module is open, or from the dashboard's module picker. It only
/// ever shows [VisionMode]'s own backend scan type, so Read Text history can
/// never contain currency results.
///
/// Blind-user rules enforced here:
///  * the screen announces itself before loading,
///  * an empty history speaks "there is no history available ... yet" and shows
///    a plain explanation instead of a blank list,
///  * a load failure speaks a readable message and offers a Retry button,
///  * back navigation and the spoken command "go back" both work, and
///    re-opening after a back works because nothing is cached.
class ModuleHistoryScreen extends StatefulWidget {
  const ModuleHistoryScreen({
    super.key,
    required this.mode,
    this.companion,
    this.accentColor,
  });

  /// The module whose history this is. Everything shown is scoped to
  /// [VisionMode.scanType], so two modules can never show each other's results.
  final VisionMode mode;

  /// The companion the caller is currently using. Optional: the screen speaks
  /// with whatever voice is already configured, which is always the user's
  /// selected companion.
  final CompanionProfile? companion;

  final Color? accentColor;

  @override
  State<ModuleHistoryScreen> createState() => _ModuleHistoryScreenState();
}

enum _HistoryPhase { loading, ready, empty, failed }

class _ModuleHistoryScreenState extends State<ModuleHistoryScreen> {
  final VoiceGuide _voice = VoiceGuide.instance;

  _HistoryPhase _phase = _HistoryPhase.loading;
  List<HistoryEntry> _entries = const [];
  String _errorSpoken = '';

  /// Session token for the spoken commands this screen owns.
  int? _voiceSession;

  /// Guards against a late async callback touching a disposed State, which is
  /// exactly what happens when the user taps back while a fetch is in flight.
  bool _disposed = false;

  VoiceCommandService get _voiceService => VoiceCommandService.instance;

  VisionMode get _mode => widget.mode;

  Color get _accent => widget.accentColor ?? _defaultAccent;

  static const Color _defaultAccent = Color(0xFF6C63FF);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _disposed = true;
    _voice.stop();
    // Only release the session if it is still ours, and never let a token that
    // was never issued turn into a global teardown: this dispose can run after
    // the screen underneath has already claimed the microphone, and it must not
    // shut that one down.
    _voiceService.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _begin() async {
    await _voice.speak(
      'Opening your ${_mode.historyLabel}.',
      pace: TtsPace.normal,
    );
    if (_disposed || !mounted) return;

    await _startVoiceSession();
    if (_disposed || !mounted) return;

    await _load();
  }

  Future<void> _startVoiceSession() async {
    _voiceSession = await _voiceService.startSession(
      onCommand: _handleCommand,
      onStateChanged: (_) {},
    );
  }

  Future<void> _handleCommand(String raw) async {
    final transcript = VoiceCommandService.stripWakeWords(raw).toLowerCase();
    if (transcript.isEmpty) return;

    if (VoiceCommandService.isBackCommand(transcript)) {
      await _close();
      return;
    }

    if (VoiceCommandService.isRepeatCommand(transcript)) {
      await _voice.repeat();
      return;
    }

    if (VoiceCommandService.isHelpCommand(transcript)) {
      await _voice.speak(_helpSpoken());
      return;
    }

    // "Refresh" / "try again" is the spoken equivalent of the Retry button, so
    // a user who cannot find the button is never stuck.
    if (transcript.contains('refresh') ||
        transcript.contains('try again') ||
        transcript.contains('reload')) {
      await _reload();
      return;
    }

    if (_phase == _HistoryPhase.failed) {
      await _voice.speak(_errorSpoken);
      return;
    }

    await _voice.speak(_summarySpoken());
  }

  Future<void> _load() async {
    if (_disposed || !mounted) return;
    setState(() {
      _phase = _HistoryPhase.loading;
      _errorSpoken = '';
    });

    List<HistoryEntry> loaded;
    try {
      loaded = await HistoryService.fetchModuleHistory(_mode);
    } on HistoryException catch (error) {
      if (_disposed || !mounted) return;
      setState(() {
        _phase = _HistoryPhase.failed;
        _errorSpoken = error.spoken;
      });
      await _voice.speakImportant(error.spoken);
      return;
    } catch (error, stack) {
      debugPrint('[HISTORY] unexpected failure for ${_mode.title}: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 6);
      if (_disposed || !mounted) return;
      setState(() {
        _phase = _HistoryPhase.failed;
        _errorSpoken =
            "I couldn't load your history right now. Please try again.";
      });
      await _voice.speakImportant(_errorSpoken);
      return;
    }

    if (_disposed || !mounted) return;

    setState(() {
      _entries = loaded;
      _phase = loaded.isEmpty ? _HistoryPhase.empty : _HistoryPhase.ready;
    });

    await _voice.speak(_summarySpoken());
  }

  Future<void> _reload() async {
    await _voice.speak('Loading your ${_mode.historyLabel} again.');
    await _load();
  }

  String _summarySpoken() {
    switch (_phase) {
      case _HistoryPhase.loading:
        return 'Loading your ${_mode.historyLabel}.';
      case _HistoryPhase.empty:
        return _mode.historyEmptySpoken();
      case _HistoryPhase.failed:
        return _errorSpoken;
      case _HistoryPhase.ready:
        final count = _entries.length;
        final head = count == 1
            ? 'You have 1 result in your ${_mode.historyLabel}.'
            : 'You have $count results in your ${_mode.historyLabel}.';
        final newest = _entries.first.spokenSummary();
        return '$head The most recent is $newest.';
    }
  }

  String _helpSpoken() =>
      'This is your ${_mode.historyLabel}. It lists the date, the time and the '
      'result of each scan, newest first. Say refresh to load it again, say '
      'repeat to hear the summary again, or say go back to return to the '
      'module.';

  Future<void> _close() async {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          _roundButton(
            icon: Icons.arrow_back_rounded,
            semanticLabel: 'Go back',
            semanticHint: 'Returns to the module',
            onTap: _close,
          ),
          const SizedBox(width: 14),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _accent.withValues(alpha: 0.35)),
            ),
            child: Icon(
              Icons.history_rounded,
              color: _accent,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Semantics(
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _mode.historyLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _mode.resultLabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _roundButton(
            icon: Icons.refresh_rounded,
            semanticLabel: 'Refresh ${_mode.historyLabel}',
            semanticHint: 'Loads your results again from the server',
            onTap: _phase == _HistoryPhase.loading ? null : _reload,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _HistoryPhase.loading:
        return _buildLoading();
      case _HistoryPhase.empty:
        return _buildMessage(
          icon: Icons.inbox_rounded,
          title: 'No ${_mode.title} history yet',
          message:
              'There is no history available for ${_mode.title} yet. Results '
              'appear here as soon as you run your first ${_mode.title} scan.',
          primaryLabel: 'Try again',
          onPrimary: _reload,
        );
      case _HistoryPhase.failed:
        return _buildMessage(
          icon: Icons.cloud_off_rounded,
          title: "Couldn't load your history",
          message: _errorSpoken,
          primaryLabel: 'Try again',
          onPrimary: _reload,
        );
      case _HistoryPhase.ready:
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 30),
          itemCount: _entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) =>
              _buildCard(_entries[index], index),
        );
    }
  }

  Widget _buildLoading() {
    return Center(
      child: Semantics(
        label: 'Loading your ${_mode.historyLabel}',
        liveRegion: true,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Loading your ${_mode.historyLabel}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(HistoryEntry entry, int index) {
    final ordinal = index + 1;
    return Semantics(
      // One announcement per row, so a screen reader reads a whole result
      // instead of five disconnected fragments.
      label: 'Result $ordinal. ${entry.spokenTimestamp}. '
          '${entry.readableResult}',
      button: true,
      onTap: () => _speakEntry(entry, ordinal),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withValues(alpha: 0.045),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _resultIcon,
                  color: _accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _mode.resultLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.readableResult,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      entry.displayTimestamp,
                      style: TextStyle(
                        color: _accent.withValues(alpha: 0.9),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
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

  Future<void> _speakEntry(HistoryEntry entry, int ordinal) async {
    await _voice.speak(
      'Result $ordinal, ${entry.spokenTimestamp}. ${entry.readableResult}',
    );
  }

  IconData get _resultIcon {
    switch (_mode) {
      case VisionMode.readText:
        return Icons.notes_rounded;
      case VisionMode.medicine:
        return Icons.medication_rounded;
      case VisionMode.product:
        return Icons.inventory_2_rounded;
      case VisionMode.currency:
        return Icons.currency_rupee_rounded;
      case VisionMode.scene:
        return Icons.landscape_rounded;
      case VisionMode.scanObject:
      case VisionMode.objectFinder:
        return Icons.center_focus_strong_rounded;
    }
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _accent.withValues(alpha: 0.10),
                  border: Border.all(color: _accent.withValues(alpha: 0.25)),
                ),
                child: Icon(icon, size: 38, color: _accent.withValues(alpha: 0.8)),
              ),
              const SizedBox(height: 22),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Semantics(
                button: true,
                label: primaryLabel,
                hint: 'Loads your ${_mode.historyLabel} again',
                child: ExcludeSemantics(
                  child: ElevatedButton.icon(
                    onPressed: onPrimary,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(primaryLabel.toUpperCase()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
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

  Widget _roundButton({
    required IconData icon,
    required String semanticLabel,
    required String semanticHint,
    required VoidCallback? onTap,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
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
              child: Icon(
                icon,
                color: onTap == null
                    ? Colors.white.withValues(alpha: 0.3)
                    : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
