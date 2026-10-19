import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'screens/splash/splash_screen.dart';
import 'widgets/swipe_to_exit.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// My Eyes - Vision Beyond Sight.
///
/// Startup rules that matter for a blind user:
///
///  * `WidgetsFlutterBinding.ensureInitialized()` runs before anything else so
///    plugin channels are ready. Getting this wrong is what produces a red
///    error screen on the very first frame.
///  * All top-level async work is wrapped in [runZonedGuarded] and routed
///    through [FlutterError.onError] / `PlatformDispatcher.onError`. Any error
///    is logged in full, but it never renders an error widget to the user -
///    the app would show a blank or a red panel and a blind user has no way to
///    read or dismiss it.
///  * [MyEyesApp] itself is rendered synchronously, so there is always a real
///    dark themed screen on the display from the first frame.
void main() {
  // Must be first: registers the platform channels used by TTS, storage,
  // biometrics and the account chooser.
  WidgetsFlutterBinding.ensureInitialized();

  runZonedGuarded<Future<void>>(
    () async {
      _installErrorHandlers();
      runApp(const MyEyesApp());
    },
    (error, stack) {
      // Logged, never shown. A blind user cannot read an error panel, and an
      // unhandled async error reaching the zone would otherwise paint the
      // red Flutter error screen over the splash.
      debugPrint('[STARTUP] uncaught async error: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 12);
    },
  );
}

/// Routes framework errors to the log instead of the red error widget.
void _installErrorHandlers() {
  final previousOnError = FlutterError.onError;

  FlutterError.onError = (details) {
    debugPrint('[FLUTTER] ${details.exceptionAsString()}');
    final library = details.library;
    if (library != null) {
      debugPrint('[FLUTTER] while ${details.context} in $library');
    }
    // Keep platform-reported errors flowing to the default reporter so nothing
    // is lost, but never present them to the user.
    previousOnError?.call(details);
  };

  // Errors that escape the framework entirely (plugin channels, TTS, async
  // gaps). Without this, Android reports them and Flutter paints the red
  // screen.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[PLATFORM] uncaught platform error: $error');
    debugPrintStack(stackTrace: stack, maxFrames: 12);
    // Returning true marks the error as handled, which is what stops the red
    // error screen from being drawn.
    return true;
  };
}

class MyEyesApp extends StatelessWidget {
  const MyEyesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My Eyes',
      navigatorKey: _navigatorKey,

      debugShowCheckedModeBanner: false,

      theme: AppTheme.darkTheme,

      // Built synchronously so the very first frame is the dark My Eyes
      // splash, never an empty white window.
      builder: (_, child) => SwipeToExit(
        navigatorKey: _navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const SplashScreen(),
    );
  }
}
