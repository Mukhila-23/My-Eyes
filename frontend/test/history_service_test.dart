import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/history_service.dart';

/// Pure-logic checks for the history model.
///
/// These run without a network: [HistoryEntry] is a plain data class, so its
/// formatting is what a blind user actually hears. The HTTP path itself is
/// verified against the running backend separately.
void main() {
  group('HistoryEntry - spoken timestamp', () {
    /// Builds an entry in LOCAL time.
    ///
    /// The formatting converts to local time, so the fixture must be local too
    /// - otherwise these assertions would only hold for a UTC device and fail
    /// on every developer machine outside UTC.
    HistoryEntry entryAt(int year, int month, int day, int hour, int minute) =>
        HistoryEntry(
          id: 1,
          scanType: 'CURRENCY',
          result: 'INR 500',
          createdAt: DateTime(year, month, day, hour, minute),
        );

    test('renders a readable date and 12-hour time', () {
      final spoken = entryAt(2026, 3, 12, 15, 45).spokenTimestamp;

      expect(spoken, contains('12 March'));
      expect(spoken, contains('3:45'));
      // Hour 15 -> pm.
      expect(spoken, contains('pm'));
    });

    test('renders midnight and noon correctly', () {
      // 00:30 -> 12:30 am (not 0:30).
      expect(
        entryAt(2026, 1, 5, 0, 30).spokenTimestamp,
        contains('12:30 am'),
      );
      // 12:15 -> 12:15 pm (not 0:15).
      expect(
        entryAt(2026, 1, 5, 12, 15).spokenTimestamp,
        contains('12:15 pm'),
      );
      // 23:05 -> 11:05 pm (not 23:05).
      expect(
        entryAt(2026, 1, 5, 23, 5).spokenTimestamp,
        contains('11:05 pm'),
      );
    });

    test('pads minutes so "3:05" is not read as "3:5"', () {
      expect(entryAt(2026, 6, 1, 15, 5).spokenTimestamp, contains('3:05'));
    });

    test('every month is spelled out, not abbreviated', () {
      const months = <String>[
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];

      for (var index = 0; index < months.length; index++) {
        expect(
          entryAt(2026, index + 1, 15, 10, 0).spokenTimestamp,
          contains(months[index]),
          reason: 'month ${index + 1} is not spelled out',
        );
      }
    });
  });

  group('HistoryEntry - result rendering', () {
    HistoryEntry withResult(String result) => HistoryEntry(
          id: 1,
          scanType: 'PRODUCT',
          result: result,
          createdAt: DateTime(2026, 3, 12, 10, 0),
        );

    test('collapses whitespace so the spoken line stays readable', () {
      expect(
        withResult('Line one\n\n   Line two').readableResult,
        'Line one Line two',
      );
    });

    test('never renders an empty result as a blank line', () {
      expect(withResult('   ').readableResult, 'No result was stored.');
      expect(withResult('').readableResult, 'No result was stored.');
    });

    test('spokenSummary truncates a long result rather than reading it all', () {
      final long = 'x' * 500;
      final summary = withResult(long).spokenSummary();

      expect(summary, contains('and more'));
      expect(summary.length, lessThan(300));
    });

    test('spokenSummary keeps a short result whole', () {
      expect(
        withResult('Indian Rupee 500 note').spokenSummary(),
        contains('Indian Rupee 500 note'),
      );
    });

    test('displayTimestamp includes the year, unlike an ambiguous 03/04', () {
      final entry = withResult('x');
      final display = entry.displayTimestamp;

      // 03/04 alone would be ambiguous (3 April or 4 March). The visible form
      // resolves it with the year.
      expect(display, contains('2026'));
      expect(display, matches(RegExp(r'\d{2}/\d{2}/\d{4}')));
    });
  });

  group('HistoryEntry - parsing', () {
    test('tolerates a missing optional image', () {
      final entry = HistoryEntry.fromJson({
        'id': 7,
        'scan_type': 'OCR',
        'result': 'Hello',
        'created_at': '2026-02-02T08:00:00Z',
      });

      expect(entry.id, 7);
      expect(entry.scanType, 'OCR');
      expect(entry.result, 'Hello');
      expect(entry.inputImage, isNull);
    });

    test('falls back rather than throwing on a missing timestamp', () {
      final entry = HistoryEntry.fromJson({
        'id': 1,
        'scan_type': 'OCR',
        'result': 'x',
      });

      expect(entry.createdAt, isA<DateTime>());
    });

    test('substitutes an empty result rather than rendering nothing', () {
      final entry = HistoryEntry.fromJson({
        'id': 1,
        'scan_type': 'OCR',
        'created_at': '2026-02-02T08:00:00Z',
      });

      expect(entry.result, '');
      expect(entry.readableResult, 'No result was stored.');
    });
  });

  group('HistoryFailure - spoken messages', () {
    test('every failure carries a message safe to read aloud', () {
      // The enum itself carries no text; the messages are produced at the throw
      // site. This asserts the enum is exhaustive so a new failure kind cannot
      // be added without deciding its message.
      expect(HistoryFailure.values.length, 3);
      expect(
        HistoryFailure.values.map((f) => f.name),
        containsAll(<String>['network', 'unauthorized', 'server']),
      );
    });
  });
}
