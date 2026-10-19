import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_theme.dart';
import '../../services/upi_amount_parser.dart';
import '../../services/upi_payment_service.dart';
import '../../services/upi_qr_parser.dart';
import '../../services/voice_command_service.dart';

/// Voice-first UPI QR payment flow for My Eyes.
///
///  * Camera scans for a `upi://pay` QR code. TTS announces the receiver and,
///    for static QRs, asks the user to say the amount.
///  * After an explicit spoken/touch confirmation the standard Android UPI
///    intent is launched. The external UPI app performs bank verification,
///    biometric checks and UPI PIN handling — none of that is touched here.
///  * The real transaction response is read back and the ACTUAL status
///    (success / failed / cancelled / unknown) is spoken. Success is never
///    assumed.
///
/// The microphone is off while the camera is scanning and while the external
/// payment app is open; it is resumed only when the app must hear the user
/// (amount entry and confirmation).
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

enum _PayPhase {
  scanning,
  invalid,
  awaitingAmount,
  confirming,
  selectingApp,
  launching,
  result,
}

class _PaymentScreenState extends State<PaymentScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  late final MobileScannerController _scanner;
  Timer? _scanTimer;
  Timer? _closeTimer;

  _PayPhase _phase = _PayPhase.scanning;
  UpiPaymentDetails? _details;
  double? _amount;
  UpiLaunchStatus? _resultStatus;
  List<UpiApp> _availableApps = const [];
  Uri? _paymentUri;
  bool _noApp = false;
  String? _paymentError;
  bool _busy = false;
  bool _scannerErrorSpoken = false;

  final TextEditingController _amountCtrl = TextEditingController();
  String? _amountError;

  /// Ownership token for this screen's voice session, so a late `dispose()`
  /// cannot stop the dashboard session that replaced it.
  int? _voiceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanner = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      facing: CameraFacing.back,
      autoStart: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _closeTimer?.cancel();
    _scanner.dispose();
    _amountCtrl.dispose();
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The dashboard observer owns the app-wide lifecycle too, but the
      // payment route owns the active voice handler while it is displayed.
      // Do not revive the microphone before a UPI result has been received.
      if (_phase != _PayPhase.launching) {
        unawaited(_voice.resumeAfterLifecycle());
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_voice.pauseForLifecycle());
    }
  }

  Future<void> _begin() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      autoStart: false,
    );

    if (!mounted) return;
    setState(() => _phase = _PayPhase.scanning);

    // Payments are safety-critical: speak the slowest tier.
    await _voice.speak(
      'Payment scanner is open. Hold the QR code in front of the '
      'camera.',
      resumeAfter: false,
      pace: TtsPace.important,
    );

    await _startScanning();
  }

  Future<void> _startScanning() async {
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 60), () {
      if (!mounted || _phase != _PayPhase.scanning) return;
      unawaited(_onScanTimeout());
    });
    try {
      await _scanner.start();
    } catch (_) {
      // Error surfaces through the widget's errorBuilder.
    }
  }

  Future<void> _onScanTimeout() async {
    await _pauseScanner();
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.invalid;
      _noApp = false;
      _paymentError = null;
    });
    await _voice.speak(
      'I could not detect a QR code. Make sure the code is fully in the '
      'frame. Say try again to rescan, or say close to exit.',
      resumeAfter: true,
    );
    await _resumeForPaymentCommand();
  }

  Future<void> _pauseScanner() async {
    _scanTimer?.cancel();
    try {
      await _scanner.stop();
    } catch (_) {
      // Scanner may already be stopped; that is fine.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy || _phase != _PayPhase.scanning) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.trim().isNotEmpty) {
        unawaited(_onQr(raw.trim()));
        return;
      }
    }
  }

  Future<void> _onQr(String raw) async {
    _busy = true;
    await _pauseScanner();
    if (!mounted) return;

    final details = UpiQrParser.parse(raw);
    if (details == null) {
      setState(() {
        _phase = _PayPhase.invalid;
        _noApp = false;
      });
      await _voice.speak(
        'This does not look like a valid UPI payment QR code. Say try '
        'again to rescan, or say close to exit.',
        resumeAfter: true,
      );
      _busy = false;
      await _resumeForPaymentCommand();
      return;
    }

    setState(() => _details = details);
    await _voice.speak(
      'Payment QR detected. Payee: ${details.displayName}.',
      resumeAfter: false,
    );
    if (!mounted) return;

    if (details.hasAmount) {
      setState(() {
        _amount = details.amount;
        _phase = _PayPhase.confirming;
      });
      await _voice.speak(
        'You are about to pay ${_spokenAmount(details.amount!)} to '
        '${details.displayName}. Say confirm to continue, or say cancel.',
        resumeAfter: false,
      );
    } else {
      setState(() => _phase = _PayPhase.awaitingAmount);
      await _voice.speak(
        'Please say the amount you want to pay. For example, '
        'say five hundred rupees.',
        resumeAfter: false,
      );
    }
    _busy = false;
    await _resumeForPaymentCommand();
  }

  String _spokenAmount(double amt) {
    if (amt == amt.roundToDouble()) {
      return '${amt.toStringAsFixed(0)} rupees';
    }
    return '${amt.toStringAsFixed(2)} rupees';
  }

  String _displayAmount(double amt) {
    if (amt == amt.roundToDouble()) {
      return '₹${amt.toStringAsFixed(0)}';
    }
    return '₹${amt.toStringAsFixed(2)}';
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceCommandService.stripWakeWords(raw);

    switch (_phase) {
      case _PayPhase.invalid:
        if (_noApp) {
          if (_containsAny(text, const ['close', 'ok', 'done', 'finish', 'cancel', 'exit', 'back'])) {
            _close();
          }
        } else if (_containsAny(text, const ['try again', 'try scan again', 'rescan', 'scan again', 'again'])) {
          await _restartScanning();
        } else if (_containsAny(text, const ['close', 'cancel', 'exit', 'back'])) {
          _close();
        }
        break;

      case _PayPhase.awaitingAmount:
        final parsed = UpiAmountParser.parse(text);
        if (parsed != null) {
          setState(() {
            _amount = parsed;
            _amountError = null;
            _phase = _PayPhase.confirming;
          });
          await _voice.speak(
            'You are about to pay ${_spokenAmount(parsed)} to '
            '${_details!.displayName}. Say confirm to continue, or say '
            'cancel.',
            resumeAfter: false,
          );
          await _resumeForPaymentCommand();
        } else {
          await _voice.speak(
            'I could not understand the amount. Please say the amount '
            'again, for example, five hundred rupees.',
            resumeAfter: false,
          );
          await _resumeForPaymentCommand();
        }
        break;

      case _PayPhase.confirming:
        if (_containsAny(text, const ['confirm', 'yes', 'pay', 'proceed', 'go ahead', 'start'])) {
          await _launchPayment();
        } else if (_containsAny(text, const ['cancel', 'no', 'stop', 'abort', "don't pay"])) {
          await _cancelPayment();
        } else if (!(_details?.hasAmount ?? false) &&
            _containsAny(text, const ['change amount', 'change', 'different amount', 're enter'])) {
          setState(() => _phase = _PayPhase.awaitingAmount);
          await _voice.speak(
            'Please say the new amount.',
            resumeAfter: true,
          );
          await _resumeForPaymentCommand();
        }
        break;

      case _PayPhase.scanning:
        if (_containsAny(text, const ['close', 'cancel', 'exit', 'stop', 'back'])) {
          _close();
        }
        break;

      case _PayPhase.selectingApp:
        final app = _matchSelectedApp(text);
        if (app != null) {
          await _launchSelectedApp(app);
        } else if (_containsAny(text, const ['cancel', 'no', 'stop', 'back', 'exit'])) {
          await _cancelPayment();
        } else {
          await _voice.speak(
            'Please say one of these payment apps: ${_spokenAppNames()}.',
            resumeAfter: true,
          );
          await _resumeForPaymentCommand();
        }
        break;

      case _PayPhase.launching:
      case _PayPhase.result:
        break;
    }
  }

  Future<void> _restartScanning() async {
    if (_busy) return;
    setState(() {
      _phase = _PayPhase.scanning;
      _details = null;
      _amount = null;
      _resultStatus = null;
      _noApp = false;
      _availableApps = const [];
      _paymentUri = null;
      _amountError = null;
    });
    await _voice.speak(
      'Scanning again. Hold the QR code in front of the camera.',
      resumeAfter: false,
    );
    await _startScanning();
  }

  /// Reclaims the shared recognizer after a prompt that expects a spoken
  /// amount, confirmation, retry or app choice.  Calling this explicitly is
  /// more reliable than relying on the TTS helper's implicit resume: the
  /// camera and a just-finished utterance can both briefly own Android audio.
  /// The session check prevents a late payment callback from reviving its
  /// microphone after another screen has taken control.
  Future<void> _resumeForPaymentCommand() async {
    if (!mounted || !_voice.ownsSession(_voiceSession)) return;
    switch (_phase) {
      case _PayPhase.invalid:
      case _PayPhase.awaitingAmount:
      case _PayPhase.confirming:
      case _PayPhase.selectingApp:
        await _voice.resumeMicrophone();
        return;
      case _PayPhase.scanning:
      case _PayPhase.launching:
      case _PayPhase.result:
        return;
    }
  }

  /// Produces the exact UPI request handed to the payment app.
  ///
  /// A dynamic QR already contains its merchant-authorized amount and may be
  /// signed. Passing its original URI unchanged is essential: rebuilding it
  /// drops fields that Google Pay uses to verify merchant payment rules. For a
  /// normal static QR, only the user-confirmed amount and a missing local
  /// reference are added; every original QR parameter is retained.
  Uri _paymentUriFor(UpiPaymentDetails details, double amount) {
    final scanned = Uri.parse(details.raw);
    final isSigned = scanned.queryParameters.containsKey('sign');
    if (details.hasAmount || isSigned) return scanned;

    return Uri.parse(
      buildPaymentUriFromStaticQr(
        scannedUri: details.raw,
        amount: amount,
      ),
    );
  }

  Future<void> _launchPayment() async {
    if (_busy) return;
    final details = _details;
    final amount = _amount;
    if (details == null || amount == null) return;

    _busy = true;
    await _voice.pauseMicrophone();
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.launching;
      _amountError = null;
    });
    await _voice.speak(
      'Opening ${UpiPaymentService.preferredAppName}.',
      resumeAfter: false,
    );
    if (!mounted) return;

    try {
      final uri = _paymentUriFor(details, amount);

      // One supported app, launched directly.
      //
      // There used to be a system-style chooser on the main path. Two problems
      // for the users this app is built for: it asks the user to pick one icon
      // out of a list of near-identical payment icons, and a spoken app name is
      // the only non-visual way to answer it. My Eyes now targets a single
      // payment app, so the common case is a deterministic launch.
      //
      // The chooser is kept only as a fallback, for the case where the
      // supported app is not installed: silently opening a different app than
      // the one the flow promised would be worse than asking.
      final apps = await UpiPaymentService.availableApps(uri);
      if (!mounted) return;

      final preferredPackage = await UpiPaymentService.resolveTargetPackage();
      if (!mounted) return;

      final supported = apps.where((app) => app.packageName == preferredPackage);
      final exact = supported.isNotEmpty
          ? supported.first
          : apps.where((app) => app.isPreferred).firstOrNull;

      if (exact != null) {
        await _launchSelectedApp(exact, uri);
        return;
      }

      if (apps.isEmpty) {
        await _showNoApp();
        _busy = false;
        return;
      }

      if (apps.length == 1) {
        await _launchSelectedApp(apps.first, uri);
        return;
      }

      setState(() {
        _availableApps = apps;
        _paymentUri = uri;
        _phase = _PayPhase.selectingApp;
      });
      await _voice.speak(
        '${UpiPaymentService.preferredAppName} is not installed. '
        'I found ${_spokenAppNames()}. Say the payment app you want to use.',
        resumeAfter: true,
      );
      _busy = false;
      await _resumeForPaymentCommand();
    } catch (_) {
      await _showLaunchError();
      _busy = false;
    }
  }

  Future<void> _launchSelectedApp(UpiApp app, [Uri? preparedUri]) async {
    if (_busy && _phase != _PayPhase.launching) return;
    final details = _details;
    final amount = _amount;
    if (details == null || amount == null) return;

    _busy = true;
    await _voice.pauseMicrophone();
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.launching;
      _amountError = null;
    });
    await _voice.speak('Opening ${app.label}.', resumeAfter: false);

    UpiLaunchStatus status;
    try {
      final uri = preparedUri ?? _paymentUri ?? _paymentUriFor(details, amount);
      status = await UpiPaymentService.launchPayment(
        uri,
        packageName: app.packageName,
      );
    } on UpiLaunchException catch (e) {
      if (e.code == 'no_app') {
        await _showAppUnavailable(app.label);
        _busy = false;
        return;
      }
      await _showLaunchError();
      _busy = false;
      return;
    } catch (_) {
      await _showLaunchError();
      _busy = false;
      return;
    }

    if (!mounted) return;
    setState(() {
      _resultStatus = status;
      _phase = _PayPhase.result;
    });
    await _voice.speak(
      '${spokenPaymentStatus(status)} Returning to My Eyes.',
      resumeAfter: false,
    );
    _busy = false;

    // Auto-return to the dashboard so the microphone starts listening again.
    _closeTimer = Timer(const Duration(milliseconds: 3000), () {
      if (!mounted) return;
      _close();
    });
  }

  Future<void> _showLaunchError() async {
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.invalid;
      _noApp = false;
      _paymentError = 'Your payment app could not be opened.';
    });
    await _voice.speak(
      'Your payment app could not be opened. Say try again, or say close to exit.',
      resumeAfter: true,
    );
  }

  UpiApp? _matchSelectedApp(String text) {
    final normalized = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final app in _availableApps) {
      final name = app.label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (name.isNotEmpty && (normalized == name || normalized.contains(name))) {
        return app;
      }
    }
    return null;
  }

  String _spokenAppNames() {
    final names = _availableApps.map((app) => app.label).toList();
    if (names.length == 2) return '${names.first} and ${names.last}';
    if (names.length > 2) return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
    return names.isEmpty ? 'a UPI payment app' : names.single;
  }

  Future<void> _showNoApp() async {
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.invalid;
      _noApp = true;
      _paymentError = null;
    });
    await _voice.speak(
      'I could not find ${UpiPaymentService.preferredAppName} on this phone. '
      'My Eyes pays through ${UpiPaymentService.preferredAppName}, which '
      'verifies the payment with your fingerprint or face. Install it and '
      'complete its setup, then say try again. Say close when you are ready to '
      'go back.',
      resumeAfter: true,
    );
  }

  Future<void> _showAppUnavailable(String appName) async {
    if (!mounted) return;
    setState(() {
      _phase = _PayPhase.invalid;
      _noApp = false;
      _paymentError = '$appName is installed but cannot accept UPI payment links right now. '
          'Open $appName and complete its UPI or bank setup, then try again.';
    });
    await _voice.speak(
      '$appName is installed but cannot accept UPI payment links right now. '
      'Open $appName and complete its UPI or bank setup, then try again.',
      resumeAfter: true,
    );
  }

  Future<void> _cancelPayment() async {
    _closeTimer?.cancel();
    await _voice.pauseMicrophone();
    if (!mounted) return;
    await _voice.speak('Payment cancelled. Returning to My Eyes.', resumeAfter: false);
    _closeAfterDelay();
  }

  void _closeAfterDelay() {
    _closeTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      _close();
    });
  }

  Future<void> _submitManualAmount() async {
    if (_busy) return;
    final parsed = UpiAmountParser.parse(_amountCtrl.text);
    if (parsed == null) {
      setState(() => _amountError = 'Enter a valid amount, e.g. 500 or 500 rupees.');
      await _voice.speak(
        'That amount could not be read. Please enter a valid amount.',
        resumeAfter: true,
      );
      return;
    }
    setState(() {
      _amount = parsed;
      _amountError = null;
      _phase = _PayPhase.confirming;
    });
    await _voice.speak(
      'You are about to pay ${_spokenAmount(parsed)} to '
      '${_details!.displayName}. Say confirm to continue, or say cancel.',
      resumeAfter: true,
    );
    await _resumeForPaymentCommand();
  }

  void _close() {
    _scanTimer?.cancel();
    _closeTimer?.cancel();
    _voice.releaseSession(_voiceSession);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  bool _containsAny(String text, List<String> words) {
    for (final w in words) {
      if (text.contains(w)) return true;
    }
    return false;
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _PayPhase.launching,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: _phase == _PayPhase.scanning
              ? _buildScanner()
              : _buildPane(),
        ),
      ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: _scannerErrorBuilder,
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.75),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 20),
              _pill('QR PAYMENT'),
              const Spacer(),
              _scanFrame(),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: _paneButton(
                        label: 'CLOSE',
                        icon: Icons.close_rounded,
                        onTap: _close,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _scanFrame() {
    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white, width: 3),
        borderRadius: BorderRadius.circular(28),
        color: Colors.white.withValues(alpha: 0.06),
      ),
      child: const Icon(
        Icons.qr_code_2_rounded,
        color: Colors.white70,
        size: 90,
      ),
    );
  }

  Widget _scannerErrorBuilder(
    BuildContext context,
    MobileScannerException error,
  ) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = denied
        ? 'Camera permission is needed to scan a payment QR code. '
            'Allow camera access in Settings, then come back.'
        : 'The camera could not be started. Please try again.';
    if (!_scannerErrorSpoken) {
      _scannerErrorSpoken = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_voice.speak(message, resumeAfter: true));
      });
    }
    return Container(
      color: AppTheme.background,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_rounded, color: Colors.white70, size: 56),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 24),
          _paneButton(
            label: 'CLOSE',
            icon: Icons.close_rounded,
            onTap: _close,
          ),
        ],
      ),
    );
  }

  Widget _buildPane() {
    final details = _details;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(26),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _paneIcon(),
              const SizedBox(height: 24),
              Text(
                _paneTitle(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _paneStatus(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 30),
              ..._paneControls(details),
            ],
          ),
        ),
      ),
    );
  }

  Widget _paneIcon() {
    switch (_phase) {
      case _PayPhase.launching:
        return const SizedBox(
          width: 96,
          height: 96,
          child: CircularProgressIndicator(
            color: Color(0xFF2ADE88),
            strokeWidth: 5,
          ),
        );
      case _PayPhase.result:
        switch (_resultStatus) {
          case UpiLaunchStatus.success:
            return const _StatusIcon(
              icon: Icons.check_rounded,
              color: Color(0xFF2ADE88),
            );
          case UpiLaunchStatus.failed:
            return const _StatusIcon(
              icon: Icons.close_rounded,
              color: Color(0xFFFF5252),
            );
          default:
            return const _StatusIcon(
              icon: Icons.error_outline_rounded,
              color: Color(0xFFFFC24D),
            );
        }
      case _PayPhase.confirming:
        return const _StatusIcon(
          icon: Icons.payment_rounded,
          color: Color(0xFF2ADE88),
        );
      case _PayPhase.selectingApp:
        return const _StatusIcon(
          icon: Icons.account_balance_wallet_rounded,
          color: Color(0xFF39D9FF),
        );
      default:
        return const _StatusIcon(
          icon: Icons.qr_code_2_rounded,
          color: Color(0xFF39D9FF),
        );
    }
  }

  String _paneTitle() {
    switch (_phase) {
      case _PayPhase.invalid:
        return _noApp
            ? 'NO UPI APP'
            : _paymentError != null
                ? 'UPI APP UNAVAILABLE'
                : 'QR NOT RECOGNIZED';
      case _PayPhase.awaitingAmount:
        return 'ENTER AMOUNT';
      case _PayPhase.confirming:
        return 'CONFIRM PAYMENT';
      case _PayPhase.selectingApp:
        return 'CHOOSE PAYMENT APP';
      case _PayPhase.launching:
        return 'OPENING PAYMENT APP';
      case _PayPhase.result:
        switch (_resultStatus) {
          case UpiLaunchStatus.success:
            return 'PAYMENT SUCCESSFUL';
          case UpiLaunchStatus.failed:
            return 'PAYMENT FAILED';
          case UpiLaunchStatus.cancelled:
            return 'PAYMENT CANCELLED';
          case UpiLaunchStatus.pending:
            return 'PAYMENT PENDING';
          default:
            return 'STATUS UNKNOWN';
        }
      case _PayPhase.scanning:
        return '';
    }
  }

  String _paneStatus() {
    final details = _details;
    switch (_phase) {
      case _PayPhase.invalid:
        return _noApp
            ? 'No installed app can scan and pay this QR code. Install '
                'Google Pay, PhonePe, Paytm or another UPI app, then try '
                'again.'
            : _paymentError ?? 'The scanned code is not a valid UPI payment QR code.';
      case _PayPhase.awaitingAmount:
        return 'Say the amount, or type it below. '
            'Receiver: ${details?.displayName ?? ''}';
      case _PayPhase.confirming:
        final amt = _amount;
        return 'Pay ${amt != null ? _displayAmount(amt) : ''} to '
            '${details?.displayName ?? ''}?';
      case _PayPhase.selectingApp:
        return 'Say the name of the UPI app you want to use: '
            '${_spokenAppNames()}.';
      case _PayPhase.launching:
        return 'Your payment app will complete the payment. Please '
            'verify and confirm inside it.';
      case _PayPhase.result:
        return spokenPaymentStatus(
          _resultStatus ?? UpiLaunchStatus.unknown,
        );
      case _PayPhase.scanning:
        return '';
    }
  }

  List<Widget> _paneControls(UpiPaymentDetails? details) {
    final list = <Widget>[];

    if (_phase == _PayPhase.awaitingAmount) {
      list.add(
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white, fontSize: 18),
          decoration: InputDecoration(
            hintText: 'Enter amount, e.g. 500',
            hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
            ),
            errorText: _amountError,
            errorStyle: const TextStyle(color: Color(0xFFFF7B7B)),
            prefixIcon: const Icon(
              Icons.currency_rupee_rounded,
              color: Colors.white54,
            ),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.07),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );
      list.add(const SizedBox(height: 16));
      list.add(
        _paneButton(
          label: 'SET AMOUNT',
          icon: Icons.check_rounded,
          onTap: _submitManualAmount,
        ),
      );
      list.add(const SizedBox(height: 12));
    }

    if (_phase == _PayPhase.confirming) {
      list.add(
        _paneButton(
          label: 'CONFIRM & PAY',
          icon: Icons.payment_rounded,
          prominent: true,
          onTap: _launchPayment,
        ),
      );
      list.add(const SizedBox(height: 12));
      if (!(_details?.hasAmount ?? false)) {
        list.add(
          _paneButton(
            label: 'CHANGE AMOUNT',
            icon: Icons.edit_rounded,
            onTap: () {
              setState(() => _phase = _PayPhase.awaitingAmount);
            },
          ),
        );
        list.add(const SizedBox(height: 12));
      }
    }

    if (_phase == _PayPhase.selectingApp) {
      for (final app in _availableApps) {
        list.add(
          _paneButton(
            label: app.label.toUpperCase(),
            icon: Icons.account_balance_wallet_rounded,
            onTap: () => unawaited(_launchSelectedApp(app)),
          ),
        );
        list.add(const SizedBox(height: 12));
      }
    }

    if (_phase == _PayPhase.invalid && !_noApp) {
      list.add(
        _paneButton(
          label: 'TRY AGAIN',
          icon: Icons.refresh_rounded,
          prominent: true,
          onTap: _restartScanning,
        ),
      );
      list.add(const SizedBox(height: 12));
    }

    if (_phase == _PayPhase.result || _phase == _PayPhase.invalid) {
      list.add(
        _paneButton(
          label: 'DONE',
          icon: Icons.check_circle_rounded,
          onTap: _close,
        ),
      );
      list.add(const SizedBox(height: 12));
    }

    if (_phase == _PayPhase.awaitingAmount ||
        _phase == _PayPhase.confirming ||
        _phase == _PayPhase.selectingApp) {
      list.add(
        _paneButton(
          label: 'CANCEL',
          icon: Icons.close_rounded,
          onTap: () => unawaited(_cancelPayment()),
        ),
      );
    }

    return list;
  }

  Widget _paneButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool prominent = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: prominent
                  ? const Color(0xFF1FBE78)
                  : Colors.white.withValues(alpha: 0.08),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 2),
      ),
      child: Icon(icon, color: color, size: 52),
    );
  }
}
