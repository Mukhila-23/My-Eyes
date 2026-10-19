import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/vision_mode.dart';
import '../../services/history_service.dart';
import '../../services/voice_command_service.dart';
import '../../services/voice_guide.dart';
import 'module_history_screen.dart';

/// "Which module's history do you want?" - reached from the dashboard.
///
/// The dashboard must NOT silently open a mixed history: the requirement is
/// that "history" inside a module means that module. From the dashboard the
/// user has not chosen a module yet, so this screen makes them choose one.
///
/// It is intentionally not a generic combined list. Each row opens the same
/// [ModuleHistoryScreen] the module's own History button opens, so there is
/// one history implementation, not two.
class HistoryPickerScreen extends StatefulWidget {
  const HistoryPickerScreen({super.key});

  @override
  State<HistoryPickerScreen> createState() => _HistoryPickerScreenState();
}

class _HistoryPickerScreenState extends State<HistoryPickerScreen> {
  final VoiceGuide _voice = VoiceGuide.instance;

  Map<String, int> _counts = const {};
  bool _loading = true;
  int? _voiceSession;
  bool _disposed = false;

  VoiceCommandService get _voiceService => VoiceCommandService.instance;

  /// Only vision modules keep results, so only they can be listed here.
  static const List<VisionMode> _modes = VisionMode.values;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _disposed = true;
    _voice.stop();
    _voiceService.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _begin() async {
    await _voice.speak(
      'Which history would you like? Say the module name, for example read '
      'text, or say go back to return to the dashboard.',
    );
    if (_disposed || !mounted) return;

    _voiceSession = await _voiceService.startSession(
      onCommand: _handleCommand,
    );
    if (_disposed || !mounted) return;

    await _loadCounts();
  }

  Future<void> _loadCounts() async {
    // A failure here is cosmetic: counts are an extra hint, and the module can
    // still be opened (and will report its own empty/failed state properly).
    final counts = await HistoryService.fetchScanCounts();
    if (_disposed || !mounted) return;
    setState(() {
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _handleCommand(String raw) async {
    final transcript = VoiceCommandService.stripWakeWords(raw).toLowerCase();
    if (transcript.isEmpty) return;

    if (VoiceCommandService.isBackCommand(transcript)) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    if (VoiceCommandService.isRepeatCommand(transcript)) {
      await _voice.repeat();
      return;
    }

    final mode = _matchMode(transcript);
    if (mode == null) {
      await _voice.speak(
        'I did not match that to a module. Say read text, medicine '
        'detection, product detection, currency detection, scene detection or '
        'object detection.',
      );
      return;
    }

    await _open(mode);
  }

  /// Maps a spoken phrase onto a module, using the same words the command
  /// router uses so "currency detection" and "check the currency note" both
  /// land on the same module.
  VisionMode? _matchMode(String transcript) {
    VisionMode? best;
    var bestScore = 0;

    for (final mode in _modes) {
      final title = mode.title.toLowerCase();
      final words = title
          .split(' ')
          .where((word) => word.length > 2)
          .toList(growable: false);

      var score = 0;
      if (transcript.contains(title)) score += 10;
      for (final word in words) {
        if (transcript.contains(word)) score += 3;
      }

      // Extra spoken aliases that are not part of the title.
      switch (mode) {
        case VisionMode.currency:
          if (transcript.contains('money') ||
              transcript.contains('note') ||
              transcript.contains('cash') ||
              transcript.contains('rupee')) {
            score += 3;
          }
          break;
        case VisionMode.objectFinder:
        case VisionMode.scanObject:
          if (transcript.contains('object')) score += 3;
          break;
        case VisionMode.readText:
          if (transcript.contains('ocr') ||
              transcript.contains('document') ||
              transcript.contains('text')) {
            score += 2;
          }
          break;
        case VisionMode.medicine:
          if (transcript.contains('tablet') ||
              transcript.contains('pill') ||
              transcript.contains('drug')) {
            score += 3;
          }
          break;
        case VisionMode.product:
          if (transcript.contains('food') ||
              transcript.contains('ingredient') ||
              transcript.contains('packaged')) {
            score += 3;
          }
          break;
        case VisionMode.scene:
          if (transcript.contains('surrounding') ||
              transcript.contains('scene') ||
              transcript.contains('environment')) {
            score += 3;
          }
          break;
      }

      if (score > bestScore) {
        bestScore = score;
        best = mode;
      }
    }

    return best;
  }

  Future<void> _open(VisionMode mode) async {
    await _voice.speak('Opening your ${mode.historyLabel}.');
    if (!mounted) return;

    // The picker stops owning the microphone so the history screen can own it
    // cleanly and speak its own summary without overlapping.
    await _voiceService.releaseSession(_voiceSession);
    _voiceSession = null;

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModuleHistoryScreen(
          mode: mode,
          companion: _voiceService.appliedCompanion,
        ),
      ),
    );

    if (_disposed || !mounted) return;
    await _voice.speak('Back to the history list.');
  }

  int _countFor(VisionMode mode) {
    final scanType = mode.scanType;
    if (scanType == null) return 0;
    return _counts[scanType.toUpperCase()] ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                itemCount: _modes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final mode = _modes[index];
                  return _buildRow(mode, index + 1);
                },
              ),
            ),
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
          Semantics(
            button: true,
            label: 'Go back to the dashboard',
            hint: 'Closes the history list',
            child: ExcludeSemantics(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).pop(),
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
                    'Your History',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _loading
                        ? 'Loading saved results'
                        : 'Choose a module to hear its results',
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

  Widget _buildRow(VisionMode mode, int ordinal) {
    final count = _countFor(mode);

    return Semantics(
      button: true,
      label: count == 0
          ? '$ordinal. ${mode.historyLabel}. No saved results yet.'
          : '$ordinal. ${mode.historyLabel}. $count saved '
              '${count == 1 ? "result" : "results"}.',
      hint: 'Opens ${mode.historyLabel}',
      onTap: () => _open(mode),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Colors.white.withValues(alpha: 0.045),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.history_rounded,
                  color: AppTheme.primaryLight,
                  size: 21,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.historyLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      count == 0
                          ? 'No saved results yet'
                          : '$count saved ${count == 1 ? "result" : "results"}',
                      style: TextStyle(
                        color: count == 0
                            ? Colors.white.withValues(alpha: 0.40)
                            : AppTheme.accent.withValues(alpha: 0.9),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
