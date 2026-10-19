import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/sos_alarm.dart';
import 'package:frontend/services/sos_service.dart';

void main() {
  tearDown(() async {
    // Every test must leave the alarm stopped, or the next one starts from a
    // running timer and the lifecycle assertions become meaningless.
    await SosAlarm.stop();
    SosService.reset();
  });

  group('SosAlarm - lifecycle', () {
    test('is idle before anything starts it', () {
      expect(SosAlarm.active, isFalse);
      expect(SosAlarm.isActive.value, isFalse);
    });

    test('starts active and counts down from its full duration', () {
      SosAlarm.start();

      expect(SosAlarm.active, isTrue);
      expect(SosAlarm.isActive.value, isTrue);
      expect(
        SosAlarm.secondsRemaining.value,
        SosAlarm.totalDuration.inSeconds,
      );
    });

    test('runs for five minutes by default', () {
      // The five-minute requirement, asserted rather than assumed.
      expect(SosAlarm.totalDuration, const Duration(minutes: 5));
      expect(SosAlarm.totalDuration.inSeconds, 300);
    });

    test('starting twice does not restart or double the alarm', () async {
      SosAlarm.start();
      final firstDeadline = SosAlarm.secondsRemaining.value;

      // Burn a little of the clock.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      SosAlarm.start();

      // A second start must not reset the countdown.
      expect(SosAlarm.secondsRemaining.value, lessThanOrEqualTo(firstDeadline));
      expect(SosAlarm.active, isTrue);

      await SosAlarm.stop();
    });

    test('stops automatically when its duration elapses', () async {
      // Short duration so the lifecycle can be verified without waiting 5 min.
      SosAlarm.startFor(const Duration(seconds: 1));

      expect(SosAlarm.active, isTrue);

      // Just past the deadline plus one pulse interval.
      await Future<void>.delayed(const Duration(milliseconds: 2400));

      expect(SosAlarm.active, isFalse);
      expect(SosAlarm.isActive.value, isFalse);
      expect(SosAlarm.secondsRemaining.value, 0);
    });

    test('counts down while running', () async {
      SosAlarm.startFor(const Duration(seconds: 8));

      await Future<void>.delayed(const Duration(milliseconds: 2300));

      expect(SosAlarm.secondsRemaining.value, lessThan(8));
      expect(SosAlarm.secondsRemaining.value, greaterThan(0));
    });

    test('can be stopped early for a false alarm', () async {
      SosAlarm.startFor(const Duration(seconds: 30));
      expect(SosAlarm.active, isTrue);

      await SosAlarm.stop();

      expect(SosAlarm.active, isFalse);
      expect(SosAlarm.isActive.value, isFalse);
    });

    test('stopping when already stopped is harmless', () async {
      await SosAlarm.stop();
      await SosAlarm.stop();

      expect(SosAlarm.active, isFalse);
    });

    test('does not block the caller', () {
      // The whole point of the timer-based design: start() returns
      // synchronously so the UI is never blocked for five minutes.
      final watch = Stopwatch()..start();
      SosAlarm.start();
      watch.stop();

      expect(watch.elapsedMilliseconds, lessThan(100));
    });
  });

  group('SosAlarm - spoken remaining time', () {
    test('announces the end of the alarm at zero', () {
      SosAlarm.secondsRemaining.value = 0;
      expect(SosAlarm.spokenRemaining(), 'The alarm has stopped.');
    });

    test('announces whole minutes without a seconds part', () {
      SosAlarm.secondsRemaining.value = 240;
      expect(SosAlarm.spokenRemaining(), '4 minutes.');
    });

    test('uses the singular for one minute', () {
      SosAlarm.secondsRemaining.value = 60;
      expect(SosAlarm.spokenRemaining(), '1 minute.');
    });

    test('announces minutes and seconds together', () {
      SosAlarm.secondsRemaining.value = 270;
      expect(SosAlarm.spokenRemaining(), '4 minutes and 30 seconds.');
    });

    test('announces seconds alone under a minute', () {
      SosAlarm.secondsRemaining.value = 25;
      expect(SosAlarm.spokenRemaining(), '25 seconds.');
    });
  });

  group('SosStatus - state machine', () {
    test('busy states block a second trigger', () {
      for (final status in <SosStatus>[
        SosStatus.activating,
        SosStatus.obtainingLocation,
        SosStatus.sendingAlert,
        SosStatus.alarmActive,
      ]) {
        expect(status.isBusy, isTrue, reason: '${status.name} should be busy');
      }
    });

    test('settled states no longer block a trigger', () {
      for (final status in <SosStatus>[
        SosStatus.idle,
        SosStatus.completed,
        SosStatus.partiallyFailed,
        SosStatus.failed,
      ]) {
        expect(
          status.isBusy,
          isFalse,
          reason: '${status.name} should not block a new SOS',
        );
      }
    });

    test('terminal states are exactly the three outcomes', () {
      expect(SosStatus.completed.isTerminal, isTrue);
      expect(SosStatus.partiallyFailed.isTerminal, isTrue);
      expect(SosStatus.failed.isTerminal, isTrue);

      expect(SosStatus.idle.isTerminal, isFalse);
      expect(SosStatus.activating.isTerminal, isFalse);
      expect(SosStatus.alarmActive.isTerminal, isFalse);
    });

    test('both non-success outcomes count as failures', () {
      expect(SosStatus.partiallyFailed.isFailure, isTrue);
      expect(SosStatus.failed.isFailure, isTrue);
      expect(SosStatus.completed.isFailure, isFalse);
      expect(SosStatus.alarmActive.isFailure, isFalse);
    });

    test('covers every stage of the required lifecycle', () {
      final names = SosStatus.values.map((s) => s.name).toSet();
      expect(
        names,
        containsAll(<String>[
          'idle',
          'activating',
          'obtainingLocation',
          'sendingAlert',
          'alarmActive',
          'completed',
          'partiallyFailed',
          'failed',
        ]),
      );
    });
  });

  group('SosService - status resets', () {
    test('starts idle', () {
      expect(SosService.currentStatus, SosStatus.idle);
      expect(SosService.isRunning, isFalse);
    });

    test('reset returns to idle so a new SOS is allowed', () {
      SosService.reset();
      expect(SosService.currentStatus, SosStatus.idle);
    });

    test('GPS timeout is bounded so SOS cannot appear to hang', () {
      expect(SosService.locationTimeout.inSeconds, lessThanOrEqualTo(10));
      expect(SosService.locationTimeout.inSeconds, greaterThan(0));
    });
  });

  group('LocationOutcome - honest reporting', () {
    test('every outcome has a backend wire value', () {
      expect(LocationOutcome.ok.wireValue, 'OK');
      expect(LocationOutcome.permissionDenied.wireValue, 'PERMISSION_DENIED');
      expect(LocationOutcome.serviceDisabled.wireValue, 'SERVICE_DISABLED');
      expect(LocationOutcome.timedOut.wireValue, 'TIMEOUT');
      expect(LocationOutcome.unavailable.wireValue, 'UNAVAILABLE');
    });

    test('a missing fix always produces an explanation', () {
      for (final outcome in LocationOutcome.values) {
        final attempt = LocationAttempt(outcome);
        if (outcome == LocationOutcome.ok) {
          expect(attempt.spokenReason, isEmpty);
        } else {
          expect(
            attempt.spokenReason,
            isNotEmpty,
            reason: '${outcome.name} must explain itself',
          );
        }
      }
    });

    test('the GPS failure message says the alert continues', () {
      expect(
        LocationAttempt(LocationOutcome.unavailable).spokenReason,
        contains('continuing the emergency alert'),
      );
    });
  });

  group('SosService - emergency message', () {
    test('includes the user name', () {
      final body = SosService.buildSosBody(
        userName: 'Radha',
        latitude: 12.97,
        longitude: 77.59,
      );

      expect(body, contains('Radha'));
      expect(body, contains('EMERGENCY'));
    });

    test('includes a shareable map link when a fix exists', () {
      final body = SosService.buildSosBody(latitude: 12.97, longitude: 77.59);

      expect(body, contains('maps.google.com'));
      expect(body, contains('12.97'));
      expect(body, contains('77.59'));
    });

    test('says the location is unavailable when there is no fix', () {
      final body = SosService.buildSosBody();

      expect(body, isNot(contains('maps.google.com')));
      expect(body, contains('could not be obtained'));
    });

    test('does not crash without a user name', () {
      final body = SosService.buildSosBody();

      expect(body, contains('a My Eyes user'));
    });
  });

  group('SosFlowResult - truthful summaries', () {
    test('a failure says the alarm is still active', () {
      final result = SosFlowResult(status: SosStatus.failed);
      expect(result.spokenSummary('Radha'), contains('alarm is still active'));
    });

    test('a partial failure says some contacts were not reached', () {
      final result = SosFlowResult(
        status: SosStatus.partiallyFailed,
        contactCount: 3,
        serverNotified: 1,
      );

      expect(result.spokenSummary('Radha'), contains('not be reached'));
      expect(result.spokenSummary('Radha'), contains('alarm is still active'));
    });

    test('a GPS failure is stated before the delivery outcome', () {
      final result = SosFlowResult(
        status: SosStatus.completed,
        contactCount: 2,
        serverNotified: 2,
        location: const LocationAttempt(LocationOutcome.permissionDenied),
      );

      final summary = result.spokenSummary('Radha');
      expect(summary, contains('permission was denied'));
      expect(summary.indexOf('permission'), lessThan(summary.indexOf('2 of 2')));
    });

    test('a success reports the delivery count and the five minute alarm', () {
      final result = SosFlowResult(
        status: SosStatus.completed,
        contactCount: 2,
        serverNotified: 2,
      );

      final summary = result.spokenSummary('Radha');
      expect(summary, contains('2 of 2 contacts'));
      expect(summary, contains('five minutes'));
    });

    test('the duplicate result is flagged and claims nothing was sent', () {
      const result = SosFlowResult.duplicate();

      expect(result.duplicate, isTrue);
      expect(result.contactCount, 0);
      expect(result.anythingDelivered, isFalse);
    });

    test('client delivery counts as an attempt, not a failure', () {
      // With no server-side provider the phone hands the message to the
      // messaging app; that is a delivery attempt, not a failure.
      final result = SosFlowResult(
        status: SosStatus.completed,
        contactCount: 2,
        deliveryMethod: 'client',
      );

      expect(result.anythingDelivered, isTrue);
      expect(result.status.isFailure, isFalse);
    });
  });
}
