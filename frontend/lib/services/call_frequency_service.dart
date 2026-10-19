import 'package:flutter/services.dart';

/// How often and how recently one number was called.
class CallFrequency {
  const CallFrequency({
    required this.number,
    required this.count,
    required this.lastCall,
  });

  final String number;
  final int count;
  final DateTime? lastCall;
}

/// Outcome of reading the call log.
class CallFrequencyResult {
  const CallFrequencyResult({
    required this.entries,
    required this.available,
    this.reason = '',
  });

  const CallFrequencyResult.unavailable([this.reason = ''])
      : entries = const [],
        available = false;

  /// Ranked most-called-first.
  final List<CallFrequency> entries;

  /// True when the numbers below are real call history.
  ///
  /// False means the shortlist cannot be ranked, and the caller must fall back
  /// to a name-based search rather than pretending to know who matters.
  final bool available;

  /// Spoken explanation when [available] is false.
  final String reason;

  bool get isEmpty => entries.isEmpty;

  /// Frequency per number, for O(1) lookup while ranking.
  Map<String, CallFrequency> get byNumber => {
        for (final entry in entries) entry.number: entry,
      };
}

/// Reads the device call log so the app can propose who matters.
///
/// The point is that a phone can hold 100 to 500 contacts. Asking a blind user
/// to page through them - four at a time, remembering the order - is not a
/// selection interface. The people who belong on an emergency list are almost
/// always the handful the user actually calls, so the app offers those first and
/// the user simply confirms, says "alternative", or names someone directly.
///
/// Nothing is ever sent anywhere: the numbers are read on the device, used to
/// order a list, and discarded.
class CallFrequencyService {
  CallFrequencyService._();

  static final CallFrequencyService instance = CallFrequencyService._();

  static const MethodChannel _channel = MethodChannel('my_eyes/call_log');

  /// Number of characters trimmed from the right when comparing an 11-digit
  /// local number against an international one.
  ///
  /// The same person can appear in the call log as `9876543210` and
  /// `919876543210` depending on which app dialled. Comparing the last 10 digits
  /// matches both without guessing the country code.
  static const int _nationalNumberLength = 10;

  /// Asks for call-log access if needed and returns the ranking.
  ///
  /// Never throws. Every failure mode - declined, unavailable on this Android
  /// version, a blocked query - comes back as an unavailable result carrying a
  /// spoken reason, so the caller can degrade instead of crashing mid-setup.
  Future<CallFrequencyResult> load() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'loadCallFrequency',
      );
      if (raw == null) {
        return const CallFrequencyResult.unavailable(
          'Call history is not available on this phone.',
        );
      }

      final status = raw['status'] as String? ?? 'failed';
      if (status != 'ok') {
        return CallFrequencyResult.unavailable(_reasonFor(status));
      }

      final rows = raw['entries'];
      if (rows is! List) {
        return const CallFrequencyResult.unavailable();
      }

      final entries = <CallFrequency>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final number = (row['number'] as String?) ?? '';
        if (number.isEmpty) continue;

        final millis = (row['lastCall'] as num?)?.toInt() ?? 0;
        entries.add(
          CallFrequency(
            number: number,
            count: (row['count'] as num?)?.toInt() ?? 0,
            lastCall: millis > 0
                ? DateTime.fromMillisecondsSinceEpoch(millis)
                : null,
          ),
        );
      }

      return CallFrequencyResult(entries: entries, available: true);
    } on MissingPluginException {
      // Older build of the app, or a platform without the bridge. Degrade
      // quietly; the contacts list still works.
      return const CallFrequencyResult.unavailable(
        'Call history is not available on this phone.',
      );
    } catch (_) {
      return const CallFrequencyResult.unavailable(
        'I could not read your call history.',
      );
    }
  }

  static String _reasonFor(String status) {
    switch (status) {
      case 'denied':
        return 'Call history access was declined, so I cannot rank your '
            'contacts. You can still choose anyone by name.';
      case 'no_activity':
        return 'Call history access needs to be enabled. You can still choose '
            'anyone by name.';
      default:
        return 'I could not read your call history, so I cannot rank your '
            'contacts. You can still choose anyone by name.';
    }
  }

  /// True when [contactNumber] and [loggedNumber] are the same person.
  ///
  /// Exact match first, then a suffix match, so an international prefix or a
  /// leading zero cannot split one person into two entries. Both directions are
  /// checked because the contact list is usually the longer form.
  static bool sameNumber(String contactNumber, String loggedNumber) {
    if (contactNumber.isEmpty || loggedNumber.isEmpty) return false;
    if (contactNumber == loggedNumber) return true;

    final short = contactNumber.length <= loggedNumber.length
        ? contactNumber
        : loggedNumber;
    final long = contactNumber.length <= loggedNumber.length
        ? loggedNumber
        : contactNumber;

    if (long.endsWith(short)) return true;

    // Compare the last 10 digits on their own, for the case where neither is a
    // suffix of the other (differing country codes of different lengths).
    if (short.length >= _nationalNumberLength) {
      return short.substring(short.length - _nationalNumberLength) ==
          long.substring(long.length - _nationalNumberLength);
    }
    return false;
  }
}
