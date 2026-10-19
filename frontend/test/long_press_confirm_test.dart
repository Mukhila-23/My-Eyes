import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/long_press_confirm.dart';

const _hold = Duration(milliseconds: 200);

Widget _control({
  required VoidCallback onConfirmed,
  VoidCallback? onHoldStart,
  VoidCallback? onHoldCancelled,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          height: 240,
          child: LongPressConfirm(
            fill: true,
            label: 'HOLD TO CONTINUE',
            semanticLabel: 'Continue. Press and hold.',
            holdDuration: _hold,
            onConfirmed: onConfirmed,
            onHoldStart: onHoldStart,
            onHoldCancelled: onHoldCancelled,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('LongPressConfirm', () {
    testWidgets(
      'every hold confirms, not just the first one',
      (tester) async {
        var confirmed = 0;
        var started = 0;

        await tester.pumpWidget(_control(
          onConfirmed: () => confirmed++,
          onHoldStart: () => started++,
        ));

        // Three holds in a row with nothing in between: no reset() call, no
        // busy-flag change, no rebuild. The completion latch used to be cleared
        // only by those external signals, so every press after the first one
        // filled the progress bar and said "Opening Google account selection"
        // and then never fired. Deriving the latch from the touch-down is what
        // makes this pass.
        for (var attempt = 1; attempt <= 3; attempt++) {
          final gesture = await tester.startGesture(
            tester.getCenter(find.byType(LongPressConfirm)),
          );

          // Announced exactly once, on touch-down, for this press only.
          expect(started, attempt, reason: 'press $attempt was not announced');

          // Two pumps, not one. An AnimationController's ticker records its
          // start time on the FIRST frame it ticks, so a single
          // pump(holdDuration) advances the clock but delivers elapsed == 0 to
          // the animation. A real finger generates dozens of frames; the test
          // has to as well. Pumping once to start the ticker and again to carry
          // it past the hold duration is what actually completes the hold.
          await tester.pump();
          await tester.pump(_hold + const Duration(milliseconds: 50));

          expect(confirmed, attempt, reason: 'press $attempt did not confirm');
          expect(
            started,
            attempt,
            reason: 'press $attempt was announced more than once',
          );

          await gesture.up();
          await tester.pump();
        }
      },
    );

    testWidgets(
      'a hold released early is explained and does not confirm',
      (tester) async {
        var confirmed = 0;
        var cancelled = 0;

        await tester.pumpWidget(_control(
          onConfirmed: () => confirmed++,
          onHoldCancelled: () => cancelled++,
        ));

        final aborted = await tester.startGesture(
          tester.getCenter(find.byType(LongPressConfirm)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await aborted.up();
        await tester.pump();

        expect(cancelled, 1);
        expect(confirmed, 0);

        // Still armed: an abandoned hold must not cost the user the control.
        final completed = await tester.startGesture(
          tester.getCenter(find.byType(LongPressConfirm)),
        );
        await tester.pump();
        await tester.pump(_hold + const Duration(milliseconds: 50));
        await completed.up();
        await tester.pump();

        expect(confirmed, 1);
      },
    );

    testWidgets('a busy control ignores touches entirely', (tester) async {
      var confirmed = 0;
      var started = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 240,
                child: LongPressConfirm(
                  fill: true,
                  busy: true,
                  label: 'HOLD TO CONTINUE',
                  semanticLabel: 'Continue. Press and hold.',
                  holdDuration: _hold,
                  onConfirmed: () => confirmed++,
                  onHoldStart: () => started++,
                ),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LongPressConfirm)),
      );
      await tester.pump(_hold + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump();

      expect(started, 0);
      expect(confirmed, 0);
    });
  });
}
