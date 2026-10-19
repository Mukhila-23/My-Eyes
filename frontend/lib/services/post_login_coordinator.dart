import 'package:flutter/material.dart';

import '../core/storage/secure_storage.dart';
import '../screens/sos/sos_setup_screen.dart';
import 'auth_service.dart';
import 'companion.dart';
import 'emergency_service.dart';
import 'sos_contact_store.dart';
import 'voice_command_service.dart';
import 'voice_guide.dart';

/// The post-login gate that sits between authentication and the dashboard.
///
/// Order, exactly as specified:
///
///   login -> profile/companion -> check SOS configuration
///         -> configured: dashboard
///         -> not configured: guide through SOS setup, then explain
///            activation, then dashboard
///
/// What it deliberately does *not* do:
///  * never crash on a network failure. If the check cannot complete, the user
///    is told so truthfully and still reaches the dashboard with a way to retry
///    from there. Claiming "SOS is configured" without a successful read would
///    be the worst possible outcome for a safety feature,
///  * never re-run setup for a user who is already configured,
///  * never reset anything: no history, no contacts, no session.
class PostLoginCoordinator {
  PostLoginCoordinator._();

  /// Outcome of the SOS check, so the dashboard can speak an accurate greeting
  /// and offer the setup button.
  static SosReadiness _readiness = SosReadiness.unknown;

  static SosReadiness get readiness => _readiness;

  /// Runs the check and, when needed, the setup flow.
  ///
  /// Returns `true` when the user is safe to continue to the dashboard.
  static Future<bool> run(BuildContext context) async {
    final companion = await _resolveCompanion();

    // The check is a network round trip, so the screen that called this may be
    // gone by the time it returns. Pushing the setup wizard onto a disposed
    // context would throw instead of letting the user into the dashboard.
    if (!context.mounted) return true;

    _readiness = await _checkConfiguration(companion);

    if (!context.mounted) return true;

    switch (_readiness) {
      case SosReadiness.configured:
        // Nothing to do. Explicitly do NOT speak here: the dashboard owns the
        // greeting and starting two speakers at once overlaps them.
        return true;

      case SosReadiness.mirroring:
        // Configured on the account but not on this phone yet. Pull the
        // contacts down for the offline SOS path, then carry on without
        // bothering the user with setup.
        await SosContactStore.syncFromServer();
        _readiness = SosReadiness.configured;
        return true;

      case SosReadiness.notConfigured:
        return _runSetup(context, companion, mandatory: true);

      case SosReadiness.checkFailed:
        return true;

      case SosReadiness.unknown:
        return true;
    }
  }

  /// Called by the dashboard when the user asks to set SOS up from there.
  static Future<bool> runManualSetup(
    BuildContext context,
    CompanionProfile companion,
  ) =>
      _runSetup(context, companion, mandatory: false);

  static Future<bool> _runSetup(
    BuildContext context,
    CompanionProfile companion, {
    required bool mandatory,
  }) async {
    if (!context.mounted) return false;

    await VoiceGuide.instance.speak(
      mandatory
          ? notConfiguredSpoken
          : 'Let us set up your emergency contacts.',
      pace: TtsPace.important,
    );
    if (!context.mounted) return false;

    final navigator = Navigator.of(context);
    final completed = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => SosSetupScreen(
          companion: companion,
          isMandatory: mandatory,
        ),
      ),
    );

    if (!context.mounted) return false;

    if (completed == true) {
      _readiness = SosReadiness.configured;
      return true;
    }

    // Skipped or failed. Re-check so the dashboard states the real situation.
    _readiness = await _checkConfiguration(companion);
    return true;
  }

  /// Reads `GET /sos-events/status`.
  ///
  /// Distinguishes "not configured" from "could not check", because those need
  /// opposite responses.
  static Future<SosReadiness> _checkConfiguration(
    CompanionProfile companion,
  ) async {
    try {
      final configuration = await EmergencyService.fetchSosConfiguration();
      final voice = VoiceGuide.instance;

      if (!configuration.configured) {
        debugPrint('[LOGIN] SOS not configured for this account');
        return SosReadiness.notConfigured;
      }

      // Mirroring makes the configured contacts available to the offline SOS
      // path on this phone. A failure here is not a setup problem.
      await SosContactStore.syncFromServer();

      await voice.speak(
        'Your emergency SOS is set up with '
        '${configuration.contactCount} '
        '${configuration.contactCount == 1 ? "contact" : "contacts"}.',
      );

      return SosReadiness.configured;
    } on AuthException catch (error) {
      debugPrint('[LOGIN] SOS check failed: ${error.code} ${error.message}');
      return SosReadiness.checkFailed;
    } catch (error, stack) {
      debugPrint('[LOGIN] SOS check raised: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 6);
      return SosReadiness.checkFailed;
    }
  }

  /// Reads the companion the account is set to.
  ///
  /// Local secure storage is the fast path and is already refreshed by the
  /// biometric login, so this does not make a second network call.
  static Future<CompanionProfile> _resolveCompanion() async {
    try {
      final stored = await SecureStorage.readCompanion();
      return Companions.fromStored(
        name: stored.name,
        gender: stored.gender,
      );
    } catch (_) {
      return Companions.alex;
    }
  }

  /// Dashboard greeting suffix based on the real SOS state.
  static String dashboardSosNotice() {
    switch (_readiness) {
      case SosReadiness.notConfigured:
        return 'Your emergency SOS is not set up yet. Say set up S O S, or tap '
            'the emergency contacts button, and I will guide you through it.';
      case SosReadiness.checkFailed:
        return checkFailedSpoken;
      case SosReadiness.configured:
      case SosReadiness.mirroring:
      case SosReadiness.unknown:
        return '';
    }
  }

  /// Reset for tests and for a fresh login cycle.
  static void reset() => _readiness = SosReadiness.unknown;

  /// Spoken when the check itself failed. Separate from [notConfiguredSpoken]
  /// so the dashboard can repeat it without re-running setup, and so a network
  /// failure is never reported as "SOS is not configured".
  static const String checkFailedSpoken =
      "I couldn't check your emergency SOS setup right now. You can try again "
      'from the dashboard with the emergency contacts button.';

  /// Spoken when the account genuinely has no emergency contacts.
  static const String notConfiguredSpoken =
      "Your emergency SOS is not configured yet. For your safety, let's set it "
      'up now.';
}

/// What the login flow knows about the user's SOS configuration.
enum SosReadiness {
  /// No successful check has happened yet.
  unknown,

  /// The account has usable emergency contacts.
  configured,

  /// The account has contacts but this phone has not mirrored them yet.
  mirroring,

  /// The account genuinely has no contacts; setup should run.
  notConfigured,

  /// The check could not complete (offline, server down, no session).
  ///
  /// Distinct from [notConfigured] on purpose: we must never claim SOS is set
  /// up when we could not verify it, and never force setup because the network
  /// is down.
  checkFailed,
}
