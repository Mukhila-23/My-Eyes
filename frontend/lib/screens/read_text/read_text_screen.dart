import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';

class ReadTextScreen extends StatefulWidget {
  const ReadTextScreen({super.key});

  @override
  State<ReadTextScreen> createState() => _ReadTextScreenState();
}

class _ReadTextScreenState extends State<ReadTextScreen>
    with TickerProviderStateMixin {
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _imagePicker = ImagePicker();

  late AnimationController _backgroundController;
  late AnimationController _pulseController;

  File? _selectedFile;

  bool _isProcessing = false;
  bool _isSpeaking = false;

  String _extractedText = '';

  @override
  void initState() {
    super.initState();

    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _initializeTts();
  }

  Future<void> _initializeTts() async {
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);

    _tts.setStartHandler(() {
      if (!mounted) return;

      setState(() {
        _isSpeaking = true;
      });
    });

    _tts.setCompletionHandler(() {
      if (!mounted) return;

      setState(() {
        _isSpeaking = false;
      });
    });

    _tts.setCancelHandler(() {
      if (!mounted) return;

      setState(() {
        _isSpeaking = false;
      });
    });

    _tts.setErrorHandler((message) {
      debugPrint('TTS Error: $message');

      if (!mounted) return;

      setState(() {
        _isSpeaking = false;
      });
    });
  }

  @override
  void dispose() {
    _tts.stop();
    _backgroundController.dispose();
    _pulseController.dispose();

    super.dispose();
  }

  // ============================================================
  // UPLOAD FILE
  // ============================================================

  Future<void> _uploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg',
          'jpeg',
          'png',
          'pdf',
          'txt',
        ],
      );

      if (result == null) {
        return;
      }

      final path = result.files.single.path;

      if (path == null) {
        _showMessage('Unable to access the selected file.');
        return;
      }

      setState(() {
        _selectedFile = File(path);
        _extractedText = '';
      });

      _showMessage(
        'File selected: ${result.files.single.name}',
      );

      // OCR will be connected here.
      await _processFile();
    } catch (e) {
      debugPrint('File picker error: $e');
      _showMessage('Could not select the file.');
    }
  }

  // ============================================================
  // CAMERA
  // ============================================================

  Future<void> _openCamera() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      if (image == null) {
        return;
      }

      setState(() {
        _selectedFile = File(image.path);
        _extractedText = '';
      });

      _showMessage('Image captured successfully.');

      // OCR will be connected here.
      await _processFile();
    } catch (e) {
      debugPrint('Camera error: $e');

      _showMessage(
        'Camera could not be opened.',
      );
    }
  }

  // ============================================================
  // PROCESS FILE
  // ============================================================

  Future<void> _processFile() async {
    if (_selectedFile == null) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    /*
      ----------------------------------------------------------
      OCR WILL BE CONNECTED HERE
      ----------------------------------------------------------

      Later:

      Image/File
          ↓
      OCR
          ↓
      Extracted text
          ↓
      _extractedText
          ↓
      Text-to-speech

      For now we display sample text so that
      the complete UI can be tested.
    */

    await Future.delayed(
      const Duration(seconds: 2),
    );

    if (!mounted) return;

    setState(() {
      _isProcessing = false;

      _extractedText =
          'This is a preview of the extracted text. '
          'The OCR engine will read the selected image or '
          'document and display the detected text here.';
    });
  }

  // ============================================================
  // READ TEXT
  // ============================================================

  Future<void> _readTextAloud() async {
    if (_extractedText.trim().isEmpty) {
      _showMessage(
        'There is no text to read yet.',
      );
      return;
    }

    try {
      if (_isSpeaking) {
        await _tts.stop();

        setState(() {
          _isSpeaking = false;
        });

        return;
      }

      await _tts.speak(_extractedText);
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  // ============================================================
  // CLEAR
  // ============================================================

  Future<void> _clearResult() async {
    await _tts.stop();

    setState(() {
      _selectedFile = null;
      _extractedText = '';
      _isProcessing = false;
      _isSpeaking = false;
    });
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF252A45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

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
                  painter: _ReadTextBackgroundPainter(
                    progress: _backgroundController.value,
                  ),
                ),
              ),

              SafeArea(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    30,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 900,
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          _buildTopBar(),

                          const SizedBox(height: 28),

                          _buildHeading(),

                          const SizedBox(height: 25),

                          _buildVoiceHint(),

                          const SizedBox(height: 22),

                          _buildInputSection(),

                          const SizedBox(height: 22),

                          if (_isProcessing)
                            _buildProcessingCard(),

                          if (!_isProcessing &&
                              _extractedText.isNotEmpty)
                            _buildResultCard(),

                          const SizedBox(height: 25),

                          _buildBottomInfo(),
                        ],
                      ),
                    ),
                  ),
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
    return Row(
      children: [
        _roundButton(
          icon: Icons.arrow_back_rounded,
          onTap: () {
            Navigator.of(context).pop();
          },
        ),

        const SizedBox(width: 14),

        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              colors: [
                Color(0xFF39D9FF),
                Color(0xFF397CFF),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF39D9FF)
                    .withValues(alpha: 0.25),
                blurRadius: 25,
              ),
            ],
          ),
          child: const Icon(
            Icons.document_scanner_rounded,
            color: Colors.white,
            size: 25,
          ),
        ),

        const SizedBox(width: 13),

        const Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                'READ TEXT',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'TURN TEXT INTO SOUND',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.3,
                ),
              ),
            ],
          ),
        ),

        _roundButton(
          icon: Icons.history_rounded,
          onTap: _showHistoryMessage,
        ),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            color: Colors.white.withValues(alpha: 0.045),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: 0.8),
            size: 21,
          ),
        ),
      ),
    );
  }

  // ============================================================
  // HEADING
  // ============================================================

  Widget _buildHeading() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What would you like me to read?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          'Use your voice, camera or upload a file.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // VOICE HINT
  // ============================================================

  Widget _buildVoiceHint() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF5267FF)
                .withValues(alpha: 0.14),
            const Color(0xFF39D9FF)
                .withValues(alpha: 0.07),
          ],
        ),
        border: Border.all(
          color: const Color(0xFF6577FF)
              .withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final scale =
                  1 +
                  (_pulseController.value * 0.05);

              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF6577FF),
                        Color(0xFF39D9FF),
                      ],
                    ),
                  ),
                  child: const Icon(
                    Icons.mic_rounded,
                    color: Colors.white,
                    size: 23,
                  ),
                ),
              );
            },
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'VOICE COMMAND',
                  style: TextStyle(
                    color: Color(0xFF8D9AFF),
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),

                const SizedBox(height: 5),

                const Text(
                  '"Read this file"',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  'My Eyes will help you select and read it.',
                  style: TextStyle(
                    color: Colors.white
                        .withValues(alpha: 0.45),
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
  // INPUT SECTION
  // ============================================================

  Widget _buildInputSection() {
    return Row(
      children: [
        Expanded(
          child: _buildInputCard(
            icon: Icons.document_scanner_rounded,
            title: 'Scan Text',
            subtitle: 'Use camera',
            primary: const Color(0xFF39D9FF),
            secondary: const Color(0xFF397CFF),
            onTap: _openCamera,
          ),
        ),

        const SizedBox(width: 14),

        Expanded(
          child: _buildInputCard(
            icon: Icons.upload_file_rounded,
            title: 'Upload File',
            subtitle: 'Image, PDF or text',
            primary: const Color(0xFF8D6CFF),
            secondary: const Color(0xFF5267FF),
            onTap: _uploadFile,
          ),
        ),
      ],
    );
  }

  Widget _buildInputCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color primary,
    required Color secondary,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                primary.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.035),
              ],
            ),
            border: Border.all(
              color: primary.withValues(alpha: 0.22),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(18),
                  gradient: LinearGradient(
                    colors: [
                      primary,
                      secondary,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: primary.withValues(
                        alpha: 0.25,
                      ),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  color: Colors.white,
                  size: 28,
                ),
              ),

              const SizedBox(height: 18),

              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const SizedBox(height: 5),

              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white
                      .withValues(alpha: 0.45),
                  fontSize: 11,
                ),
              ),

              const SizedBox(height: 15),

              Row(
                children: [
                  Text(
                    'OPEN',
                    style: TextStyle(
                      color: primary,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),

                  const Spacer(),

                  Icon(
                    Icons.arrow_forward_rounded,
                    color: primary,
                    size: 18,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // PROCESSING
  // ============================================================

  Widget _buildProcessingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: Colors.white.withValues(alpha: 0.035),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Transform.scale(
                scale: 1 +
                    (_pulseController.value * 0.08),
                child: Container(
                  width: 75,
                  height: 75,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF39D9FF),
                        Color(0xFF397CFF),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF39D9FF)
                            .withValues(alpha: 0.30),
                        blurRadius: 30,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.document_scanner_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 22),

          const Text(
            'Reading your file...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            'Please wait while My Eyes processes the text.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white
                  .withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),

          const SizedBox(height: 20),

          const LinearProgressIndicator(
            minHeight: 3,
            backgroundColor: Color(0x22222222),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // RESULT
  // ============================================================

  Widget _buildResultCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF39D9FF)
                .withValues(alpha: 0.09),
            Colors.white.withValues(alpha: 0.035),
          ],
        ),
        border: Border.all(
          color: const Color(0xFF39D9FF)
              .withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(13),
                  color: const Color(0xFF39D9FF)
                      .withValues(alpha: 0.14),
                ),
                child: const Icon(
                  Icons.text_fields_rounded,
                  color: Color(0xFF6EE5FF),
                  size: 21,
                ),
              ),

              const SizedBox(width: 12),

              const Expanded(
                child: Text(
                  'EXTRACTED TEXT',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),

              IconButton(
                onPressed: _clearResult,
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white54,
                ),
              ),
            ],
          ),

          const SizedBox(height: 17),

          Container(
            width: double.infinity,
            constraints: const BoxConstraints(
              minHeight: 150,
              maxHeight: 350,
            ),
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Colors.black.withValues(
                alpha: 0.18,
              ),
            ),
            child: SingleChildScrollView(
              child: Text(
                _extractedText,
                style: TextStyle(
                  color: Colors.white
                      .withValues(alpha: 0.78),
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
            ),
          ),

          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _readTextAloud,
                    icon: Icon(
                      _isSpeaking
                          ? Icons.stop_rounded
                          : Icons.volume_up_rounded,
                    ),
                    label: Text(
                      _isSpeaking
                          ? 'STOP READING'
                          : 'READ ALOUD',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          const Color(0xFF397CFF),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape:
                          RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(17),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              SizedBox(
                height: 52,
                width: 52,
                child: OutlinedButton(
                  onPressed: _clearResult,
                  style:
                      OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white
                          .withValues(alpha: 0.10),
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(17),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(
                    Icons.refresh_rounded,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // BOTTOM INFO
  // ============================================================

  Widget _buildBottomInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.025),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.record_voice_over_rounded,
            color: Color(0xFF8B98FF),
            size: 20,
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Text(
              'Voice commands:  "Read this file"  •  '
              '"Scan this text"  •  "Read it aloud"',
              style: TextStyle(
                color: Colors.white
                    .withValues(alpha: 0.48),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // HISTORY
  // ============================================================

  void _showHistoryMessage() {
    _showMessage(
      'Read Text history will be connected here.',
    );
  }
}

// ================================================================
// BACKGROUND
// ================================================================

class _ReadTextBackgroundPainter
    extends CustomPainter {
  final double progress;

  _ReadTextBackgroundPainter({
    required this.progress,
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
        const Color(0xFF39D9FF)
            .withValues(alpha: 0.10),
        const Color(0xFF5267FF)
            .withValues(alpha: 0.04),
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
      ..color = Colors.white.withValues(
        alpha: 0.055,
      );

    for (int i = 0; i < 25; i++) {
      final px =
          (i * 127.0) % size.width;

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
    covariant _ReadTextBackgroundPainter
        oldDelegate,
  ) {
    return oldDelegate.progress != progress;
  }
}