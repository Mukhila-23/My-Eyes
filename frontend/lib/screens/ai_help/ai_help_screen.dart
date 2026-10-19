import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/ai_service.dart';
import '../../services/voice_command_service.dart';

/// Explicit UI states for AI Help so a blind user always knows what is
/// happening (reflected in the spoken status and on-screen label).
///
/// Transitions are controlled centrally by [_setPhase]:
///   listening  -> processing   (a question was captured)
///   processing -> speaking     (an answer came back)
///   speaking   -> listening    (TTS finished)
/// plus `-> idle` on exit. The microphone is never left in `processing`.
enum _AiPhase { idle, listening, processing, speaking }

/// AI HELP.
///
/// AI Help IS the Help module - this is the only Help screen. It is a
/// general-purpose AI assistant: normal questions ("What is 347 + 778?",
/// "Explain machine learning", "Tell me a joke") always go to the backend AI
/// endpoint, never to Scan Object / Read Text / Currency / Navigation. Those
/// modules keep their own separate routing via
/// [VoiceCommandRouter]; nothing here executes My Eyes commands.
///
/// Conversation flow (voice-first):
///   LISTENING -> PROCESSING -> SPEAKING -> LISTENING
///
/// Typed questions use the exact same backend endpoint as spoken ones.
///
/// In-screen control phrases: Repeat, Stop, Go back, New chat.
class AiHelpScreen extends StatefulWidget {
  /// Optional spoken question handed over from the central router so the
  /// assistant answers it immediately instead of re-listening from scratch.
  final String? initialQuestion;

  const AiHelpScreen({super.key, this.initialQuestion});

  @override
  State<AiHelpScreen> createState() => _AiHelpScreenState();
}

class _AiHelpScreenState extends State<AiHelpScreen> {
  final VoiceCommandService _voice = VoiceCommandService.instance;
  final TextEditingController _textController = TextEditingController();

  _AiPhase _phase = _AiPhase.idle;

  /// True once the screen is disposed, so in-flight work can bail out
  /// instead of touching the dashboard's microphone.
  bool _closed = false;

  /// Ownership token for this screen's voice session. Handing it back to
  /// `stopSession` means a late `dispose()` cannot kill the dashboard
  /// session that already replaced it.
  int? _voiceSession;

  /// The active backend conversation id (null until the first question).
  /// This is the ONLY place AI Help keeps context, so it can never leak into
  /// other My Eyes modules.
  int? _conversationId;

  /// Last AI answer, so "Repeat" can re-speak it.
  String _lastAnswer = '';

  /// Central guard: only one explicit AI request at a time. Also prevents the
  /// voice system from looping into repeated API calls without user input.
  bool _busy = false;

  /// Spoken history (user + assistant) for the on-screen transcript.
  final List<_AiTurn> _turns = [];

  /// Phrases that control this screen instead of being sent to the AI.
  static const Set<String> _exitPhrases = {
    'go back', 'back', 'close', 'cancel', 'exit', 'quit', 'go home',
    'go to home', 'go to dashboard', 'back to dashboard', 'back to home',
    'go to dashboard screen', 'exit ai', 'close ai', 'leave ai',
    'exit ai help', 'close ai help', 'leave ai help', 'exit help',
    'close help', 'leave help', 'stop ai help',
  };

  static const Set<String> _newChatPhrases = {
    'new chat', 'new conversation', 'new topic', 'start over',
    'start a new chat', 'start a new conversation', 'clear chat',
    'clear conversation', 'reset conversation', 'forget everything',
  };

  static const Set<String> _stopPhrases = {
    'stop', 'stop talking', 'stop speaking', 'be quiet', 'silence',
    'shut up', 'quiet',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _closed = true;
    _busy = false;
    // Cancel any AI request still in flight and release the microphone +
    // TTS so the dashboard can take them straight back over.
    AIService.cancelPending();
    _voice.releaseSession(_voiceSession);
    _textController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleSpoken,
      onHeard: (_) {},
      onListeningChanged: (listening) {
        if (_closed || !mounted) return;
        if (listening) _setPhase(_AiPhase.listening);
      },
      autoStart: true,
    );

    if (_closed || !mounted) return;

    // If the router handed us a spoken question, answer it immediately.
    final initial = widget.initialQuestion;
    if (initial != null && initial.trim().isNotEmpty) {
      await _askAi(initial.trim());
      return;
    }

    await _voice.speak('Help is ready. What would you like to ask?');
    if (_closed || !mounted) return;
    await _goListening();
  }

  // ============================================================
  // PHASE / MICROPHONE STATE MACHINE
  // ============================================================

  void _setPhase(_AiPhase phase) {
    if (_closed || !mounted) return;
    if (_phase == phase) return;
    setState(() => _phase = phase);
  }

  /// PROCESSING: mic off, recogniser cancelled, so the user cannot start a
  /// second request while this one is running.
  Future<void> _goProcessing() async {
    await _voice.setProcessing();
    _setPhase(_AiPhase.processing);
    await _voice.pauseMicrophone();
  }

  /// SPEAKING: TTS plays (it stops the mic itself) and we wait for it to
  /// finish before touching the microphone again.
  ///
  /// [remember] stores the text as the app-wide spoken response so "repeat"
  /// also works from the dashboard after this screen closes.
  Future<void> _goSpeaking(String text, {bool remember = false}) async {
    _setPhase(_AiPhase.speaking);
    await _voice.speak(
      text,
      resumeAfter: false,
      pace: remember ? TtsPace.moduleResult : TtsPace.normal,
      remember: remember,
    );
  }

  /// LISTENING: hand the microphone back so the next question can be heard.
  Future<void> _goListening() async {
    if (_closed || !mounted) return;
    _setPhase(_AiPhase.listening);
    // Short settle so the tail of the TTS audio cannot be picked up as the
    // user's next question.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_closed || !mounted) return;
    await _voice.resumeMicrophone();
  }

  // ============================================================
  // SPOKEN COMMAND HANDLING
  // ============================================================

  Future<void> _handleSpoken(String rawTranscript) async {
    final transcript = VoiceCommandService.stripWakeWords(rawTranscript);
    if (transcript.isEmpty || _closed) return;

    // A request is already running: ignore the new utterance instead of
    // firing a duplicate.
    if (_busy || AIService.isRequestInFlight) {
      debugPrint('[ROUTER] AI ignored "$transcript" (request in flight)');
      return;
    }

    final command = transcript.toLowerCase().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    debugPrint('[ROUTER] AI heard: $command');

    // ---- Control phrases are intercepted, never sent to the AI. ----
    if (_exitPhrases.contains(command)) {
      await _exit();
      return;
    }
    if (_newChatPhrases.contains(command)) {
      await _newConversation();
      return;
    }
    if (VoiceCommandService.isRepeatCommand(command)) {
      await _speakLastAnswer();
      return;
    }
    if (_stopPhrases.contains(command) ||
        VoiceCommandService.isStopCommand(command)) {
      await _voice.interrupt();
      await _goListening();
      return;
    }
    if (_isEntryPhrase(command)) {
      await _goSpeaking('I am here. What would you like to ask?');
      await _goListening();
      return;
    }

    // ---- Everything else is a real question for the AI. ----
    await _askAi(transcript);
  }

  // ============================================================
  // ASK THE AI  (single path for BOTH voice and typed questions)
  // ============================================================

  Future<void> _askAi(String question) async {
    if (_busy) return;

    _busy = true;
    _setPhase(_AiPhase.processing);
    if (mounted) setState(() => _turns.add(_AiTurn('user', question)));

    try {
      // Mic off + short "Thinking..." so the user knows we are working.
      await _goProcessing();
      await _voice.speak('Thinking.', resumeAfter: false);

      final result = await AIService.chat(
        question: question,
        conversationId: _conversationId,
      );

      if (_closed || !mounted) return;

      if (result.success) {
        _conversationId = result.conversationId;
        _lastAnswer = result.answer;
        debugPrint('[API] AI answer: ${result.answer}');
        setState(() => _turns.add(_AiTurn('ai', result.answer)));
        await _goSpeaking(result.answer, remember: true);
      } else {
        // A dropped duplicate carries no message: stay silent, just recover.
        if (result.error.isEmpty) {
          await _goListening();
          return;
        }
        debugPrint('[API] AI failed [${result.errorCode}]: ${result.error}');
        setState(() => _turns.add(_AiTurn('ai', result.error)));
        await _goSpeaking(result.error);
      }
    } catch (e) {
      // AIService.chat converts expected failures into result.success=false
      // with a spoken-friendly message, so reaching here means something
      // unexpected happened. The user must never be left in silence after
      // their question, so report it in the transcript and out loud.
      debugPrint('[API] AI unexpected failure: $e');
      const message =
          'Something went wrong reaching the AI assistant. Please try again.';
      if (_closed || !mounted) return;
      setState(() => _turns.add(_AiTurn('ai', message)));
      await _goSpeaking(message);
    } finally {
      _busy = false;
    }

    if (_closed || !mounted) return;
    await _goListening();
  }

  Future<void> _speakLastAnswer() async {
    final answer = _lastAnswer.isNotEmpty
        ? _lastAnswer
        : (_voice.lastSpokenResponse ?? '');
    if (_busy || answer.isEmpty) return;
    await _goSpeaking(answer, remember: true);
    await _goListening();
  }

  // ============================================================
  // NEW CONVERSATION  (clears the AI context)
  // ============================================================

  Future<void> _newConversation() async {
    if (_busy) return;

    final previous = _conversationId;
    _conversationId = null;
    _lastAnswer = '';
    if (mounted) setState(() => _turns.clear());

    if (previous != null) {
      await AIService.clear(conversationId: previous);
    }

    await _goSpeaking('New chat started. What would you like to ask?');
    await _goListening();
  }

  // ============================================================
  // EXIT
  // ============================================================

  Future<void> _exit() async {
    if (_closed) return;
    // Back must always work, even mid-request: abort the AI call, stop the
    // microphone and TTS, then hand control back to the dashboard (which
    // restarts its own voice session when this route pops).
    AIService.cancelPending();
    await _voice.stopSpeaking();
    await _voice.releaseSession(_voiceSession);
    _closed = true;

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ============================================================
  // TEXT FALLBACK  (same backend endpoint as voice)
  // ============================================================

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _busy) return;
    _textController.clear();
    await _askAi(text);
  }

  // ============================================================
  // MATCHERS (exact, low-collision - a real question must never be
  // swallowed as a control phrase)
  // ============================================================

  static bool _isEntryPhrase(String t) {
    const phrases = {
      'ai help', 'ai', 'open ai', 'ask ai', 'start ai help',
      'ask assistant', 'are you there', 'hello assistant',
    };
    return phrases.contains(t);
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: _turns.isEmpty ? _buildEmptyState() : _buildConversation(),
              ),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: _exit,
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
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [Color(0xFF6C63FF), Color(0xFF42D9FF)],
              ),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HELP',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  'General AI assistant',
                  style: TextStyle(
                    color: Color(0xFFA9B0C3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _statusChip(),
        ],
      ),
    );
  }

  Widget _statusChip() {
    final (label, color) = switch (_phase) {
      _AiPhase.idle => ('READY', const Color(0xFF6C63FF)),
      _AiPhase.listening => ('LISTENING', const Color(0xFF42D392)),
      _AiPhase.processing => ('THINKING', const Color(0xFF42D9FF)),
      _AiPhase.speaking => ('SPEAKING', const Color(0xFFFFB04D)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [BoxShadow(color: color, blurRadius: 8)],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              color: Color(0xFF6C63FF),
              size: 56,
            ),
            const SizedBox(height: 18),
            const Text(
              'Ask me anything.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Speak your question, or type it below.\n'
              'Say "Go back" to return to the dashboard.\n'
              'Say "New chat" to clear the chat.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFA9B0C3),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversation() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: _turns.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final turn = _turns[index];
        final isUser = turn.role == 'user';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: isUser
                  ? const Color(0xFF6C63FF).withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.07),
              ),
            ),
            child: Text(
              turn.text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // CONTROLS (visual+voice fallback)
  // ============================================================

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Type a question (optional)',
                    hintStyle: const TextStyle(color: Color(0xFF6A7182)),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.04),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _sendText(),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: _sendText,
                icon: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _controlButton(
                  icon: Icons.mic_rounded,
                  label: 'Listen',
                  onTap: _goListening,
                  accent: const Color(0xFF42D392),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _controlButton(
                  icon: Icons.stop_rounded,
                  label: 'Stop',
                  onTap: () async {
                    await _voice.interrupt();
                    await _goListening();
                  },
                  accent: const Color(0xFFFF647C),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _controlButton(
                  icon: Icons.refresh_rounded,
                  label: 'New chat',
                  onTap: _newConversation,
                  accent: const Color(0xFF42D9FF),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color accent,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: accent.withValues(alpha: 0.13),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: accent, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiTurn {
  const _AiTurn(this.role, this.text);
  final String role; // 'user' | 'ai'
  final String text;
}