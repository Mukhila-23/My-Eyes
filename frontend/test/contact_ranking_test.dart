import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/call_frequency_service.dart';
import 'package:frontend/services/contact_directory.dart';
import 'package:frontend/services/contact_matcher.dart';

/// Fixed call history, so these tests describe the *decision* rather than
/// whatever the tester's phone happens to contain.
CallFrequencyResult history(List<(String, int, int)> rows) {
  final now = DateTime.now();
  return CallFrequencyResult(
    available: true,
    entries: [
      for (final (number, count, daysAgo) in rows)
        CallFrequency(
          number: number,
          count: count,
          lastCall: now.subtract(Duration(days: daysAgo)),
        ),
    ],
  );
}

DeviceContact contact(String name, String phone) =>
    DeviceContact(name: name, phone: phone);

void main() {
  group('CallFrequencyService.sameNumber', () {
    test('matches an identical number', () {
      expect(CallFrequencyService.sameNumber('9876543210', '9876543210'), isTrue);
    });

    test('matches across a country-code prefix', () {
      // The same person appears as a local number in the contact list and an
      // international one in the call log, depending on who dialled.
      expect(
        CallFrequencyService.sameNumber('919876543210', '9876543210'),
        isTrue,
      );
      expect(
        CallFrequencyService.sameNumber('9876543210', '919876543210'),
        isTrue,
      );
    });

    test('matches across a leading zero', () {
      expect(
        CallFrequencyService.sameNumber('09876543210', '9876543210'),
        isTrue,
      );
    });

    test('does not merge two different people', () {
      expect(
        CallFrequencyService.sameNumber('9876543210', '9876543211'),
        isFalse,
      );
      expect(CallFrequencyService.sameNumber('', '9876543210'), isFalse);
      expect(CallFrequencyService.sameNumber('123', '1234567'), isFalse);
    });
  });

  group('ContactDirectory.rank', () {
    final contacts = [
      contact('Zoya Khan', '9000000001'),
      contact('Arun Kumar', '9000000002'),
      contact('Maya Patel', '9000000003'),
      contact('Bhavna Shah', '9000000004'),
    ];

    test('puts the most called contact first', () {
      final ranked = ContactDirectory.rank(
        contacts,
        history([
          ('9000000002', 42, 3),
          ('9000000003', 12, 30),
          ('9000000004', 2, 1),
        ]),
      );

      expect(ranked.first.name, 'Arun Kumar');
      expect(ranked[1].name, 'Maya Patel');
      expect(ranked[2].name, 'Bhavna Shah');
    });

    test('carries the call count onto the contact', () {
      final ranked = ContactDirectory.rank(
        contacts,
        history([('9000000002', 42, 3)]),
      );

      final arun = ranked.firstWhere((c) => c.name == 'Arun Kumar');
      expect(arun.callCount, 42);
      expect(arun.hasCallHistory, isTrue);
      expect(arun.spokenCallCount, 'called 42 times');
    });

    test('breaks a frequency tie by who was called most recently', () {
      final ranked = ContactDirectory.rank(
        contacts,
        history([
          ('9000000002', 10, 200), // 10 calls, long ago
          ('9000000003', 10, 1), // 10 calls, yesterday
        ]),
      );

      expect(ranked[0].name, 'Maya Patel');
      expect(ranked[1].name, 'Arun Kumar');
    });

    test('never-called contacts fall to the end, alphabetically', () {
      // Order must be stable even with no signal at all, so a user who pages
      // this far still gets a predictable list.
      final ranked = ContactDirectory.rank(
        contacts,
        const CallFrequencyResult.unavailable(),
      );

      expect(ranked.map((c) => c.name).toList(), [
        'Arun Kumar',
        'Bhavna Shah',
        'Maya Patel',
        'Zoya Khan',
      ]);
      expect(ranked.every((c) => !c.hasCallHistory), isTrue);
    });

    test('matches a call-log number to a differently formatted contact', () {
      final ranked = ContactDirectory.rank(
        [contact('Arun Kumar', '9876543210')],
        history([('919876543210', 30, 2)]),
      );

      expect(ranked.single.callCount, 30);
      expect(ranked.single.hasCallHistory, isTrue);
    });

    test('keeps a contact with no match in the call log', () {
      final ranked = ContactDirectory.rank(
        [contact('Stranger', '9000000009')],
        history([('9876543210', 30, 2)]),
      );

      expect(ranked.single.callCount, 0);
      expect(ranked.single.hasCallHistory, isFalse);
      expect(ranked.single.spokenCallCount, 'never called on this phone');
    });

    test('the index agrees with a full scan on a large, messy phone book', () {
      // The index is only allowed to be faster, never to decide differently.
      // So it is checked against the original "compare against every entry"
      // rule over a 500-contact list and a 1200-number call log - the
      // situation the emergency setup screen actually runs in, where the naive
      // version was hundreds of thousands of string comparisons before the
      // first suggestion could be spoken.
      String localNumber(int i) => '${3000000000 + i * 7919}';

      final many = <DeviceContact>[
        for (var j = 0; j < 500; j++)
          DeviceContact(name: 'Contact $j', phone: '91${localNumber(j)}'),
      ];

      final entries = <CallFrequency>[
        for (var i = 0; i < 1200; i++)
          CallFrequency(
            // Three formats for the same person: international, leading zero,
            // and exactly as the contact list stores it.
            number: switch (i % 3) {
              0 => '91${'91${localNumber(i)}'}',
              1 => '0${'91${localNumber(i)}'}',
              _ => '91${localNumber(i)}',
            },
            count: 1200 - i,
            lastCall: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          ),
      ];

      final indexed = ContactDirectory.rank(
        many,
        CallFrequencyResult(entries: entries, available: true),
      );

      final scanned = <String, int>{};
      for (final entry in entries) {
        for (final contact in many) {
          if (CallFrequencyService.sameNumber(contact.phone, entry.number)) {
            scanned.putIfAbsent(contact.phone, () => entry.count);
          }
        }
      }

      for (final contact in indexed) {
        expect(
          contact.callCount,
          scanned[contact.phone] ?? 0,
          reason: 'index disagreed with a full scan for ${contact.name}',
        );
      }

      // Call count really is the ordering signal, not just an annotation.
      final counts = indexed.map((c) => c.callCount).toList();
      final descending = [...counts]..sort((a, b) => b.compareTo(a));
      expect(counts, orderedEquals(descending));
      expect(counts.first, greaterThan(0));
    });
  });

  group('DeviceContact - what the shortlist needs to say', () {
    test('reads out the last four digits for a quick check', () {
      const contact = DeviceContact(name: 'Arun Kumar', phone: '9876543210');

      expect(contact.tail, '3210');
      expect(contact.spokenTail, '3 2 1 0');
    });

    test('keeps a number shorter than the tail whole', () {
      const contact = DeviceContact(name: 'Emergency', phone: '112');

      expect(contact.tail, '112');
      expect(contact.spokenTail, '1 1 2');
    });

    test('reads a relationship out of the saved name', () {
      // No extra spoken question is needed for the account's required
      // relationship field, because contact lists usually already say it.
      expect(
        const DeviceContact(name: 'Asha Mom', phone: '9876543210')
            .relationshipGuess,
        'Mother',
      );
      expect(
        const DeviceContact(name: 'Ravi Grandfather', phone: '9876543210')
            .relationshipGuess,
        'Grandfather',
      );
      expect(
        const DeviceContact(name: 'Sunita didi', phone: '9876543210')
            .relationshipGuess,
        'Sister',
      );
    });

    test('never guesses a relationship from a fragment of a name', () {
      // "ma" inside "Mahesh" and "son" inside "Sonu" are the failures a plain
      // substring match would produce, and a wrong relationship is written
      // straight into the account.
      expect(
        const DeviceContact(name: 'Mahesh Sonu', phone: '9876543210')
            .relationshipGuess,
        'Emergency contact',
      );
      expect(
        const DeviceContact(name: 'Gaunt Avenue', phone: '9876543210')
            .relationshipGuess,
        'Emergency contact',
      );
    });

    test('falls back to a neutral label for an unknown name', () {
      expect(
        const DeviceContact(name: 'Billing Department', phone: '9876543210')
            .relationshipGuess,
        'Emergency contact',
      );
    });
  });

  group('ContactMatcher - the alternative command', () {
    test('recognises the ways a user asks for another suggestion', () {
      for (final phrase in [
        'alternative',
        'another option',
        'someone else',
        'somebody else',
        'next option',
        'different person',
        'go on',
      ]) {
        expect(ContactMatcher.isAlternative(phrase), isTrue,
            reason: 'expected "$phrase" to ask for another suggestion');
      }
    });

    test('does not mistake a name for a request for another suggestion', () {
      expect(ContactMatcher.isAlternative('alternative'), isTrue);
      expect(ContactMatcher.isAlternative('bhavna'), isFalse);
      expect(ContactMatcher.isAlternative('yes'), isFalse);
      expect(ContactMatcher.isAlternative('maya'), isFalse);
    });

    test('recognises "who do I call most"', () {
      expect(ContactMatcher.isWhoDoICall('who do i call most'), isTrue);
      expect(ContactMatcher.isWhoDoICall('who is my most called contact'),
          isTrue);
      expect(ContactMatcher.isWhoDoICall('who is arun'), isFalse);
    });
  });

  group('ContactMatcher - reaching all 500 contacts', () {
    // A realistic large list: the ranked head is what gets spoken, but a name
    // must find anybody in the whole thing without a single one being read out.
    final many = <DeviceContact>[
      const DeviceContact(
        name: 'Arun Kumar',
        phone: '9000000002',
        callCount: 42,
      ),
      const DeviceContact(
        name: 'Maya Patel',
        phone: '9000000003',
        callCount: 12,
      ),
      for (var i = 0; i < 500; i++)
        contact('Contact $i', '91${(8000000000 + i).toString()}'),
    ];

    test('finds a contact deep in the list by name', () {
      final match = ContactMatcher.resolve(
        'contact 317',
        contacts: many,
        pageOffset: 0,
        pageSize: ContactDirectory.shortlistSize,
      );

      expect(match?.phone, '918000000317');
    });

    test('a position only ever refers to the shortlist', () {
      // "2" must be the second *suggestion*, never the second of 500 - which is
      // what made reading the list pointless.
      expect(
        ContactMatcher.resolve('2',
            contacts: many, pageOffset: 0, pageSize: 5)?.name,
        'Maya Patel',
      );
      // Beyond the shortlist there is nothing to point at.
      expect(
        ContactMatcher.resolve('7',
            contacts: many, pageOffset: 0, pageSize: 5),
        isNull,
      );
    });

    test('resolves a number deep in the list', () {
      // Spoken from the real number, so the test cannot drift out of step with
      // the digit count.
      const target = '918000000317';
      const words = <String, String>{
        '0': 'zero',
        '1': 'one',
        '2': 'two',
        '3': 'three',
        '4': 'four',
        '5': 'five',
        '6': 'six',
        '7': 'seven',
        '8': 'eight',
        '9': 'nine',
      };
      final spoken = target
          .split('')
          .map((d) => words[d]!)
          .join(' ');

      final match = ContactMatcher.resolve(
        spoken,
        contacts: many,
        pageOffset: 0,
        pageSize: ContactDirectory.shortlistSize,
      );

      expect(match?.phone, target);
    });

    test('"contact N" is the Nth suggestion, not a name', () {
      // The word "contact" plus a small number is how a user refers to a row
      // they were shown, so it must not be read as part of a name.
      expect(
        ContactMatcher.resolve('contact 2',
            contacts: many, pageOffset: 0, pageSize: 5)?.name,
        'Maya Patel',
      );
      expect(
        ContactMatcher.resolve('contact 3',
            contacts: many, pageOffset: 0, pageSize: 5)?.name,
        'Contact 0',
      );
    });

    test('an ambiguous name is refused rather than guessed', () {
      // Attaching the wrong number to an emergency contact is the worst thing
      // this screen can do, so a name that fits several people must offer them
      // rather than silently picking the first.
      final similar = [
        contact('Arjun Rao', '9000000010'),
        contact('Arun Kumar', '9000000011'),
        contact('Arnold Silva', '9000000012'),
      ];

      expect(
        ContactMatcher.resolve('ar',
            contacts: similar, pageOffset: 0, pageSize: 5),
        isNull,
      );
      expect(
        ContactMatcher.resolve('arun',
            contacts: similar, pageOffset: 0, pageSize: 5)?.name,
        'Arun Kumar',
      );
      expect(
        ContactMatcher.resolve('arjun rao',
            contacts: similar, pageOffset: 0, pageSize: 5)?.name,
        'Arjun Rao',
      );
    });
  });
}
