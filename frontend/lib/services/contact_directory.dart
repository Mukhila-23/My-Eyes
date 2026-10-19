import 'package:contacts_service_plus/contacts_service_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'call_frequency_service.dart';

/// One contact the user can choose, reduced to what a voice-driven flow needs.
class DeviceContact {
  const DeviceContact({
    required this.name,
    required this.phone,
    this.callCount = 0,
    this.lastCalledAt,
  });

  final String name;

  /// Digits only. Formatting is added back when the number is spoken.
  final String phone;

  /// How often this number appears in the device call log. Zero when call
  /// history is unavailable or this person has never been called.
  final int callCount;

  /// When this number was last called, or null if never.
  final DateTime? lastCalledAt;

  /// True when the ranking signal actually came from call history.
  bool get hasCallHistory => callCount > 0;

  String get initial => name.isEmpty ? '?' : name[0].toUpperCase();

  /// The phone number spoken digit by digit.
  ///
  /// Reading "9876543210" as one word is unintelligible and easy to mishear.
  /// Saying each digit separately lets the user confirm the exact number they
  /// are about to trust with an emergency call.
  String get spokenPhone => phone.split('').join(' ');

  /// The whole contact as announced to the user.
  String get spoken => '$name, $spokenPhone';

  /// The last four digits, or the whole number when it is shorter than that.
  ///
  /// Enough to catch "that is not her number" without a ten-digit reading on
  /// every suggestion, which is what made the old shortlist slow to follow. The
  /// full number is still available on demand.
  String get tail =>
      phone.length <= 4 ? phone : phone.substring(phone.length - 4);

  /// [tail], spoken one digit at a time.
  String get spokenTail => tail.split('').join(' ');

  /// "called 42 times" / "called once", for the shortlist announcement.
  ///
  /// Speaking the frequency is what makes a suggestion checkable. A user cannot
  /// verify a guess, but they know immediately when the app has the wrong
  /// person, or has merged two people into one entry.
  String get spokenCallCount {
    if (!hasCallHistory) return 'never called on this phone';
    return callCount == 1 ? 'called once' : 'called $callCount times';
  }

  /// A relationship label derived from the saved name.
  ///
  /// The account requires a relationship, and asking for one is a whole extra
  /// question in a flow that must stay short and purely spoken. Nearly every
  /// contact list already carries the relationship inside the name ("Asha -
  /// Mother", "Mum"), so it is read from there; anything unrecognised becomes a
  /// neutral label rather than a wrong guess.
  String get relationshipGuess {
    final lower = name.toLowerCase();

    // Word boundaries, never `contains`. "ma" inside "Mahesh" and "son" inside
    // "Sonu" would otherwise label half a contact list as somebody's mother or
    // child, and a wrong relationship is written into the account.
    const known = <String, String>{
      'mom': 'Mother',
      'mum': 'Mother',
      'mummy': 'Mother',
      'mother': 'Mother',
      'amma': 'Mother',
      'dad': 'Father',
      'papa': 'Father',
      'father': 'Father',
      'appa': 'Father',
      'abba': 'Father',
      'bhai': 'Brother',
      'brother': 'Brother',
      'didi': 'Sister',
      'didhi': 'Sister',
      'sister': 'Sister',
      'wife': 'Wife',
      'husband': 'Husband',
      'son': 'Son',
      'daughter': 'Daughter',
      'grandmother': 'Grandmother',
      'grandma': 'Grandmother',
      'grandfather': 'Grandfather',
      'grandpa': 'Grandfather',
      'uncle': 'Uncle',
      'aunt': 'Aunt',
      'friend': 'Friend',
      'doctor': 'Doctor',
      'dr': 'Doctor',
    };

    // Longest key first, so "grandmother" is tested before "mother".
    final keys = known.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      if (lower.contains(RegExp('\\b${RegExp.escape(key)}\\b'))) {
        return known[key]!;
      }
    }
    return defaultRelationship;
  }

  /// Neutral relationship used when the name carries no clue.
  static const String defaultRelationship = 'Emergency contact';

  @override
  bool operator ==(Object other) =>
      other is DeviceContact && other.phone == phone && other.name == name;

  @override
  int get hashCode => Object.hash(name, phone);
}

/// Outcome of loading the device contact list.
class ContactDirectoryResult {
  const ContactDirectoryResult({
    required this.contacts,
    required this.permissionGranted,
    this.callHistoryAvailable = false,
    this.loadFailed = false,
  });

  const ContactDirectoryResult.denied()
      : contacts = const [],
        permissionGranted = false,
        callHistoryAvailable = false,
        loadFailed = false;

  final List<DeviceContact> contacts;

  /// False when the user declined contacts access, so the caller can explain
  /// how to enable it instead of saying "no contacts found".
  final bool permissionGranted;

  /// True when [contacts] was ordered using real call history.
  final bool callHistoryAvailable;

  /// True when the contacts plugin itself failed.
  final bool loadFailed;

  bool get isEmpty => contacts.isEmpty;

  /// Why the list could not be shown, or null when it can.
  String? get problem {
    if (contacts.isNotEmpty) return null;
    if (!permissionGranted) {
      return 'Contacts permission is needed to choose an emergency contact. '
          'Enable contacts access for My Eyes in your phone settings, then '
          'try again.';
    }
    if (loadFailed) {
      return 'I could not read your contacts. Please try again.';
    }
    return 'No contacts with a phone number were found on this phone.';
  }
}

/// Reads the device contact list and orders it by who the user actually calls.
///
/// The ordering is the whole feature. A phone can hold 100 to 500 contacts, and
/// reading them out is not a selection interface - it is a chore, and it is
/// impossible for someone who cannot see the list or remember the order. So the
/// app does the ranking itself and offers the shortlist: most called first,
/// ties broken by most recent.
///
/// The user never loses control. They confirm the top suggestion, say
/// "alternative" to hear the next candidate, or name anyone directly, which
/// searches the full list without reading it.
///
/// Declining call-log access is not a failure: the list falls back to recency
/// and to the contacts the user does call, and name search still reaches
/// everybody.
class ContactDirectory {
  ContactDirectory._();

  static final ContactDirectory instance = ContactDirectory._();

  /// How many contacts the voice picker speaks at the start.
  ///
  /// Five is the number of emergency contacts the app stores, so the first
  /// screen is exactly the decision the user is being asked to make - and
  /// nobody has to page further for the common case.
  static const int shortlistSize = 5;

  /// Loads every device contact that has a phone number, ranked by call
  /// frequency.
  ///
  /// Requests contacts permission if needed. Never throws: a failure is
  /// reported as [ContactDirectoryResult] so the caller can speak the reason
  /// instead of crashing.
  Future<ContactDirectoryResult> load({
    bool requestPermission = true,
    bool requestCallHistory = true,
  }) async {
    try {
      var status = await ph.Permission.contacts.status;
      if (!status.isGranted) {
        if (!requestPermission) {
          return const ContactDirectoryResult.denied();
        }
        status = await ph.Permission.contacts.request();
        if (!status.isGranted) {
          return const ContactDirectoryResult.denied();
        }
      }

      final raw = await ContactsService.getContacts(withThumbnails: false);
      final contacts = flatten(raw);

      if (contacts.isEmpty) {
        return ContactDirectoryResult(
          contacts: const [],
          permissionGranted: true,
          loadFailed: true,
        );
      }

      if (!requestCallHistory) {
        return ContactDirectoryResult(
          contacts: rank(contacts, const CallFrequencyResult.unavailable()),
          permissionGranted: true,
        );
      }

      final history = await CallFrequencyService.instance.load();
      return ContactDirectoryResult(
        contacts: rank(contacts, history),
        permissionGranted: true,
        callHistoryAvailable: history.available,
      );
    } catch (_) {
      // Never let a contacts failure crash a blind user's emergency setup.
      return const ContactDirectoryResult(
        contacts: [],
        permissionGranted: true,
        loadFailed: true,
      );
    }
  }

  /// Collapses the platform shape into one entry per phone number.
  static List<DeviceContact> flatten(List<Contact> raw) {
    final byNumber = <String, DeviceContact>{};

    for (final contact in raw) {
      final display = (contact.displayName ?? '').trim();
      final name = display.isNotEmpty
          ? display
          : '${contact.givenName ?? ''} ${contact.familyName ?? ''}'.trim();
      if (name.isEmpty) continue;

      for (final phone in contact.phones ?? const <Item>[]) {
        final digits = normalizePhone(phone.value);
        if (digits.isEmpty) continue;
        // The first contact to claim a number keeps it.
        byNumber.putIfAbsent(
          digits,
          () => DeviceContact(name: name, phone: digits),
        );
      }
    }

    return byNumber.values.toList();
  }

  /// Orders contacts by how often and how recently they are called.
  ///
  /// Call count dominates; recency only separates two numbers that were called
  /// equally often, because "called 200 times two years ago" is a weaker signal
  /// than "called 12 times last week" but not a weaker signal than "called 200
  /// times last month".
  ///
  /// The tail is alphabetical so a user who says "next" past the ranked part
  /// still gets a stable, predictable order rather than whatever the provider
  /// happened to return.
  static List<DeviceContact> rank(
    List<DeviceContact> contacts,
    CallFrequencyResult history,
  ) {
    final index = CallLogIndex(history.entries);

    final scored = contacts
        .map((contact) => index.attachTo(contact))
        .toList(growable: true);

    scored.sort((a, b) {
      // Called people first, most called before least.
      if (a.callCount != b.callCount) return b.callCount.compareTo(a.callCount);

      // Same frequency: the more recent one wins.
      final aTime = a.lastCalledAt?.millisecondsSinceEpoch ?? 0;
      final bTime = b.lastCalledAt?.millisecondsSinceEpoch ?? 0;
      if (aTime != bTime) return bTime.compareTo(aTime);

      // Never called, or no call history: alphabetical, so the order is stable
      // and a user who reaches this far can still find someone by paging.
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return scored;
  }

  /// The top [count] contacts of an already ranked list.
  ///
  /// Five is the number of emergency contacts the app stores, so the shortlist
  /// is exactly the decision the user is being asked to make, and nobody has to
  /// page further for the common case.
  static List<DeviceContact> shortlist(
    List<DeviceContact> ranked, {
    int count = shortlistSize,
  }) =>
      ranked.take(count).toList(growable: false);

  /// Strips everything a phone number cannot legally contain.
  static String normalizePhone(String? raw) {
    if (raw == null) return '';
    final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    // Drop a leading "+" so the same number saved with and without the
    // international prefix is recognised as one contact, not two.
    final trimmed = digits.startsWith('+') ? digits.substring(1) : digits;
    return trimmed;
  }
}

/// Number-keyed view of the call log, so ranking 500 contacts costs one hash
/// lookup each instead of a scan of the whole history per contact.
///
/// This matters because the naive version was O(contacts x history entries).
/// With 500 contacts and a heavy user's call log that is hundreds of thousands
/// of string comparisons on the critical path of emergency setup - the one
/// screen that must never look like it is hanging.
///
/// The buckets hold *candidates*, not answers: every hit is still confirmed
/// with [CallFrequencyService.sameNumber], so indexing can only make the lookup
/// faster. It cannot change which contact a number belongs to.
class CallLogIndex {
  CallLogIndex(List<CallFrequency> entries) {
    for (final entry in entries) {
      final digits = entry.number;
      if (digits.isEmpty) continue;
      (_exact[digits] ??= <CallFrequency>[]).add(entry);
      (_byTail[_tail(digits, 10)] ??= <CallFrequency>[]).add(entry);
      (_byTail[_tail(digits, 7)] ??= <CallFrequency>[]).add(entry);
    }
  }

  /// Full stored digits. The common case: the contact list and the call log
  /// hold the same number in the same format.
  final Map<String, List<CallFrequency>> _exact = {};

  /// Last 10 and last 7 digits, for one person stored with a different country
  /// code or a leading zero.
  final Map<String, List<CallFrequency>> _byTail = {};

  static String _tail(String digits, int length) =>
      digits.length <= length ? digits : digits.substring(digits.length - length);

  /// Returns [contact] with its call statistics attached, or unchanged when the
  /// call log says nothing about it.
  DeviceContact attachTo(DeviceContact contact) {
    final match = lookup(contact.phone);
    if (match == null) return contact;

    return DeviceContact(
      name: contact.name,
      phone: contact.phone,
      callCount: match.count,
      lastCalledAt: match.lastCall,
    );
  }

  /// The call statistics for [phone], or null when there are none.
  CallFrequency? lookup(String phone) {
    if (phone.isEmpty) return null;

    final candidates = [
      _exact[phone],
      _byTail[_tail(phone, 10)],
      _byTail[_tail(phone, 7)],
    ];

    for (final bucket in candidates) {
      if (bucket == null) continue;
      for (final entry in bucket) {
        if (CallFrequencyService.sameNumber(phone, entry.number)) return entry;
      }
    }
    return null;
  }
}
