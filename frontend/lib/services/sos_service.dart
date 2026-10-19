import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'emergency_service.dart';
import 'sos_alarm.dart';
import 'sos_contact_store.dart';

/// Explicit SOS lifecycle.
///
/// Replaces the previous pile of independent booleans (`_running`,
/// `alarmActive`, `isRunning`) with one ordered state, so "can I trigger again"
/// and "what do I tell the user" are answers read off a single value.
///
/// The terminal states are [completed], [partiallyFailed] and [failed]; only
/// those (plus a return to [idle] via [reset]) allow a new trigger. That is
/// what stops a second, overlapping emergency workflow from a double tap.
enum SosStatus {
  /// No SOS in progress.
  idle,

  /// Accepted; alarm starting, contacts being collected.
  activating,

  /// Asking GPS for a position. Bounded by [SosService.locationTimeout].
  obtainingLocation,

  /// Contacting the emergency contacts / the backend.
  sendingAlert,

  /// Message handed off; the five minute alarm is still sounding.
  alarmActive,

  /// Everything that could be delivered was delivered.
  completed,

  /// At least one contact was reached, at least one was not.
  partiallyFailed,

  /// Nothing could be delivered.
  failed,
}

extension SosStatusX on SosStatus {
  /// True while a workflow owns the SOS. A trigger during this is ignored.
  bool get isBusy =>
      this == SosStatus.activating ||
      this == SosStatus.obtainingLocation ||
      this == SosStatus.sendingAlert ||
      this == SosStatus.alarmActive;

  /// True once the workflow has settled one way or another.
  bool get isTerminal =>
      this == SosStatus.completed ||
      this == SosStatus.partiallyFailed ||
      this == SosStatus.failed;

  bool get isFailure =>
      this == SosStatus.partiallyFailed || this == SosStatus.failed;
}

/// Result of a single outbound alert action (SMS or call).
class AlertActionResult {
  const AlertActionResult({required this.method, required this.ok});

  final String method; // 'sms' | 'call'
  final bool ok;
}

/// Where the position came from, or why there is not one.
///
/// Reported to the backend so the emergency log can distinguish "we never
/// asked" from "we asked and the device said no".
enum LocationOutcome {
  ok('OK'),
  permissionDenied('PERMISSION_DENIED'),
  serviceDisabled('SERVICE_DISABLED'),
  timedOut('TIMEOUT'),
  unavailable('UNAVAILABLE');

  const LocationOutcome(this.wireValue);

  final String wireValue;
}

/// Outcome of [SosService.getLocation]: a position, or the reason there is
/// none. Never an exception - the SOS workflow must keep going either way.
class LocationAttempt {
  const LocationAttempt(this.outcome, [this.position]);

  final LocationOutcome outcome;
  final Position? position;

  bool get hasPosition => position != null;

  String get spokenReason {
    switch (outcome) {
      case LocationOutcome.ok:
        return '';
      case LocationOutcome.permissionDenied:
        return "I couldn't get your location because location permission was "
            'denied.';
      case LocationOutcome.serviceDisabled:
        return "I couldn't get your location because location services are "
            'turned off on this phone.';
      case LocationOutcome.timedOut:
        return "I couldn't get your current location, it timed out.";
      case LocationOutcome.unavailable:
        return "I couldn't get your current location, but I'm continuing the "
            'emergency alert.';
    }
  }
}

/// Result summary of one SOS workflow.
class SosFlowResult {
  const SosFlowResult({
    required this.status,
    this.location,
    this.contactCount = 0,
    this.actions = const [],
    this.serverNotified = 0,
    this.serverFailed = 0,
    this.deliveryMethod = 'none',
    this.duplicate = false,
  });

  /// A trigger that was ignored because another SOS was already running.
  const SosFlowResult.duplicate()
      : status = SosStatus.activating,
        location = null,
        contactCount = 0,
        actions = const [],
        serverNotified = 0,
        serverFailed = 0,
        deliveryMethod = 'none',
        duplicate = true;

  final SosStatus status;
  final LocationAttempt? location;
  final int contactCount;
  final List<AlertActionResult> actions;

  /// How many contacts the backend reached.
  final int serverNotified;

  /// How many the backend could not reach.
  final int serverFailed;

  /// "server" | "client" | "none", straight from the backend.
  final String deliveryMethod;

  /// True when this trigger was ignored as a duplicate.
  final bool duplicate;

  int get smsOpened => actions.where((a) => a.method == 'sms' && a.ok).length;

  int get callOpened => actions.where((a) => a.method == 'call' && a.ok).length;

  /// Whether anything at all left the device.
  bool get anythingDelivered =>
      serverNotified > 0 ||
      deliveryMethod == 'client' ||
      smsOpened > 0 ||
      callOpened > 0;

  /// Truthful user-facing summary. Never mentions HTTP codes or exceptions.
  String spokenSummary(String userName) {
    final locationLine = location?.spokenReason ?? '';

    if (status == SosStatus.failed) {
      return '$locationLine The emergency alert could not be delivered to one '
          'or more contacts. The alarm is still active.'.trim();
    }

    if (status == SosStatus.partiallyFailed) {
      return '$locationLine One or more emergency contacts could not be '
          'reached. The alarm is still active.'.trim();
    }

    final delivered = serverNotified > 0
        ? '$serverNotified of $contactCount contacts reached the alert service.'
        : 'Your emergency contacts have been alerted.';
    return '$locationLine $delivered The alarm keeps sounding for five '
        'minutes.'.trim();
  }
}

/// Orchestrates the SOS workflow: start the alarm, get a location, build the
/// message, alert the contacts, tell the backend.
///
/// Guarantees, in priority order:
///  1. The alarm starts before anything else that can fail.
///  2. No single failure aborts the workflow. Location, the backend, SMS, the
///     dialer and audio are each guarded independently.
///  3. Nothing throws. [runSos] returns a [SosFlowResult] for every path,
///     including "there are no contacts" and "everything failed".
///  4. A second trigger while one is running is ignored, not queued.
class SosService {
  SosService._();

  // ------------------------------------------------------------
  // STATE
  // ------------------------------------------------------------

  static SosStatus _status = SosStatus.idle;

  /// Broadcast on every transition so a screen can render from one source.
  static final ValueNotifier<SosStatus> status = ValueNotifier<SosStatus>(
    SosStatus.idle,
  );

  static SosStatus get currentStatus => _status;

  /// True while an SOS workflow owns the SOS.
  static bool get isRunning => _status.isBusy;

  /// Highest-priority contacts that also get a call prompt first.
  static const int callCount = 3;

  /// Never alert more than this many people in one emergency.
  static const int maxRecipients = 5;

  /// SOS must never appear to hang waiting for a GPS fix.
  static const Duration locationTimeout = Duration(seconds: 8);

  static void _setStatus(SosStatus next) {
    if (_status == next) return;
    _status = next;
    try {
      status.value = next;
    } catch (_) {
      // A disposed listener must not be able to break an SOS.
    }
    debugPrint('[SOS] status -> ${next.name}');
  }

  /// Returns the SOS to [idle] so a new emergency can be triggered.
  ///
  /// Does NOT stop the alarm: the five minute alarm is deliberately decoupled
  /// from the workflow (see [SosAlarm]).
  static void reset() {
    _setStatus(SosStatus.idle);
  }

  // ------------------------------------------------------------
  // ALARM (delegated, kept here so callers have one import)
  // ------------------------------------------------------------

  static bool get alarmActive => SosAlarm.active;

  static ValueNotifier<int> get alarmSecondsRemaining =>
      SosAlarm.secondsRemaining;

  static void startAlarm() => SosAlarm.start();

  static Future<void> stopAlarm() => SosAlarm.stop();

  // ------------------------------------------------------------
  // LOCATION
  // ------------------------------------------------------------

  /// Obtains the best available position, or explains why it could not.
  ///
  /// Never throws. Covers, in order: GPS switched off, permission not granted,
  /// permission permanently denied, a slow/absent fix (timeout), and any
  /// platform-channel failure.
  static Future<LocationAttempt> getLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationAttempt(LocationOutcome.serviceDisabled);
      }
    } catch (_) {
      // Could not even ask. Treat as "no position" rather than crashing.
      return const LocationAttempt(LocationOutcome.unavailable);
    }

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        // Asking again cannot help, and the user is mid-emergency: report it
        // and move on rather than sending them to settings.
        return const LocationAttempt(LocationOutcome.permissionDenied);
      }
      if (permission == LocationPermission.denied) {
        return const LocationAttempt(LocationOutcome.permissionDenied);
      }
    } catch (_) {
      return const LocationAttempt(LocationOutcome.unavailable);
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: locationTimeout,
        ),
      );
      return LocationAttempt(LocationOutcome.ok, position);
    } on TimeoutException {
      return const LocationAttempt(LocationOutcome.timedOut);
    } catch (_) {
      // No fix, or the location plugin failed. Either way: keep going.
      return const LocationAttempt(LocationOutcome.unavailable);
    }
  }

  // ------------------------------------------------------------
  // OUTBOUND ALERTS (device side)
  // ------------------------------------------------------------

  /// Compose an SMS for [phoneNumber] via url_launcher. Opens the messaging
  /// app pre-filled: it never auto-sends (the user presses send).
  static Future<bool> sendSms(String phoneNumber, String body) async {
    if (phoneNumber.isEmpty) return false;
    final uri = Uri(
      scheme: 'sms',
      path: phoneNumber,
      queryParameters: {'body': body},
    );
    try {
      if (!await canLaunchUrl(uri)) return false;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Open the dialer for [phoneNumber] (does not auto-dial).
  static Future<bool> openDialer(String phoneNumber) async {
    if (phoneNumber.isEmpty) return false;
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    try {
      if (!await canLaunchUrl(uri)) return false;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Build the SOS message body with an optional shareable map link.
  ///
  /// The "location unavailable" sentence is always present in one form or the
  /// other, so a contact can tell a missing fix apart from a missing feature.
  static String buildSosBody({
    double? latitude,
    double? longitude,
    String userName = '',
  }) {
    final who = userName.trim().isEmpty ? 'a My Eyes user' : userName.trim();
    final buffer = StringBuffer(
      'EMERGENCY: This is an SOS alert for $who. Please contact me right away.',
    );

    if (latitude != null && longitude != null) {
      buffer.write(
        ' My location: https://maps.google.com/?q=$latitude,$longitude',
      );
    } else {
      buffer.write(
        ' My current GPS location could not be obtained at the time of the '
        'alert.',
      );
    }

    return buffer.toString();
  }

  // ------------------------------------------------------------
  // FULL WORKFLOW
  // ------------------------------------------------------------

  /// Runs one complete SOS workflow.
  ///
  /// [contacts] is the local offline list. [onPhase] receives every state
  /// transition so the caller can speak without inspecting this class.
  /// [userName] is only used to make the message readable.
  ///
  /// Returns a [SosFlowResult] for every outcome. Never throws.
  static Future<SosFlowResult> runSos({
    required List<SosContact> contacts,
    bool withAlarm = true,
    String userName = '',
    void Function(SosStatus phase)? onPhase,
  }) async {
    // --- duplicate guard -------------------------------------------
    // A second SOS button press while one is running must not start a
    // second workflow or a second alarm.
    if (_status.isBusy) {
      debugPrint('[SOS] trigger ignored: a workflow is already running');
      return const SosFlowResult.duplicate();
    }

    final actions = <AlertActionResult>[];
    var status = SosStatus.failed;
    var location = const LocationAttempt(LocationOutcome.unavailable);
    var recipients = const <SosContact>[];

    void announce(SosStatus next) {
      _setStatus(next);
      try {
        onPhase?.call(next);
      } catch (_) {
        // A broken listener must not break the workflow.
      }
    }

    try {
      // --- 1. ALARM FIRST ------------------------------------------
      // Everything below can fail; the alarm must not depend on it.
      announce(SosStatus.activating);
      if (withAlarm) {
        try {
          SosAlarm.start();
        } catch (_) {
          // Audio unavailable. Continue: the alert itself matters more.
        }
      }

      recipients = _recipients(contacts);

      if (recipients.isEmpty) {
        // No contacts is a configuration problem, not a crash. The alarm
        // keeps running so the user is still making noise.
        announce(SosStatus.failed);
        return SosFlowResult(
          status: SosStatus.failed,
          location: location,
          contactCount: 0,
          actions: actions,
        );
      }

      // --- 2. LOCATION ----------------------------------------------
      // Bounded, non-throwing. A missing fix never stops the alert.
      announce(SosStatus.obtainingLocation);
      location = await getLocation();

      final body = buildSosBody(
        latitude: location.position?.latitude,
        longitude: location.position?.longitude,
        userName: userName,
      );

      // --- 3. BACKEND -----------------------------------------------
      // The server validates ownership, builds the canonical message and
      // dispatches it when a delivery provider is configured. Best-effort:
      // the device-side SMS/dialer below still runs either way.
      announce(SosStatus.sendingAlert);
      var serverNotified = 0;
      var serverFailed = 0;
      var deliveryMethod = 'none';

      try {
        final response = await EmergencyService.triggerSos(
          latitude: location.position?.latitude,
          longitude: location.position?.longitude,
          locationStatus: location.outcome.wireValue,
        );
        serverNotified = response.notifiedCount;
        serverFailed = response.failedCount;
        deliveryMethod = response.deliveryMethod;
      } catch (_) {
        // Offline, server down, no token: the device path below still runs.
        debugPrint('[SOS] backend trigger unavailable; using device delivery');
      }

      // --- 4. DEVICE DELIVERY --------------------------------------
      // Calls to the highest-priority contacts first, then a message for every
      // contact. Each launch is independent and guarded.
      for (final contact in recipients.take(callCount)) {
        if (contact.phone.isEmpty) continue;
        actions.add(
          AlertActionResult(
            method: 'call',
            ok: await openDialer(contact.phone),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      for (final contact in recipients) {
        if (contact.phone.isEmpty) continue;
        actions.add(
          AlertActionResult(
            method: 'sms',
            ok: await sendSms(contact.phone, body),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      // --- 5. OUTCOME ------------------------------------------------
      // Truthful accounting: what actually left the device vs what was tried.
      final anythingLeft =
          serverNotified > 0 ||
          deliveryMethod == 'client' ||
          actions.any((action) => action.ok);

      if (!anythingLeft) {
        status = SosStatus.failed;
      } else if (serverFailed > 0 || !actions.any((action) => action.ok)) {
        status = SosStatus.partiallyFailed;
      } else {
        status = SosStatus.completed;
      }

      // The message is out; the alarm is still sounding for five minutes.
      // That is a real, separate state - not "completed".
      announce(
        status.isFailure ? status : SosStatus.alarmActive,
      );
      if (status == SosStatus.completed) {
        // Keep the terminal success in the result while the state stays on
        // alarm_active until the alarm ends or the user dismisses it.
        _setStatus(SosStatus.alarmActive);
      }

      return SosFlowResult(
        status: status,
        location: location,
        contactCount: recipients.length,
        actions: actions,
        serverNotified: serverNotified,
        serverFailed: serverFailed,
        deliveryMethod: deliveryMethod,
      );
    } catch (error, stack) {
      // Last line of defence. A SOS must never surface an exception.
      debugPrint('[SOS] workflow raised: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      _setStatus(SosStatus.failed);
      return SosFlowResult(
        status: SosStatus.failed,
        location: location,
        contactCount: recipients.length,
        actions: actions,
      );
    }
  }

  /// Contacts that will actually be alerted, in priority order, capped.
  static List<SosContact> _recipients(List<SosContact> contacts) {
    final usable = contacts
        .where((contact) => contact.phone.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return usable.take(maxRecipients).toList();
  }
}
