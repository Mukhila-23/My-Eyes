import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/contact_directory.dart';
import 'package:frontend/services/contact_matcher.dart';

/// Fixed contact list, so these tests describe a *spoken* decision rather than
/// whatever happens to be in the tester's phone.
const List<DeviceContact> _contacts = [
  DeviceContact(name: 'Arun Kumar', phone: '9876543210'),
  DeviceContact(name: 'Aruna Iyer', phone: '9812345678'),
  DeviceContact(name: 'Ashwin Rao', phone: '9900112233'),
  DeviceContact(name: 'Bhavna Shah', phone: '9123456780'),
];

DeviceContact? resolve(String phrase, {int offset = 0, int pageSize = 4}) =>
    ContactMatcher.resolve(
      phrase,
      contacts: _contacts,
      pageOffset: offset,
      pageSize: pageSize,
    );

void main() {
  group('DeviceContact', () {
    test('speaks the phone number digit by digit', () {
      // Reading a number as one word is unintelligible and easy to mishear.
      // Digit by digit is the only way a user can confirm the exact number
      // that an ambulance will call.
      expect(
        _contacts.first.spokenPhone,
        '9 8 7 6 5 4 3 2 1 0',
      );
    });

    test('keeps a zero in the number', () {
      const withZero = DeviceContact(name: 'Test', phone: '9000112233');
      expect(withZero.spokenPhone, '9 0 0 0 1 1 2 2 3 3');
    });

    test('normalises away formatting and the country prefix', () {
      expect(ContactDirectory.normalizePhone('+91 98765-43210'), '919876543210');
      expect(ContactDirectory.normalizePhone('(020) 7946 0958'), '02079460958');
      expect(ContactDirectory.normalizePhone(null), '');
      expect(ContactDirectory.normalizePhone('n/a'), '');
    });
  });

  group('ContactMatcher - choosing by name', () {
    test('resolves an exact name', () {
      expect(resolve('arun kumar')?.name, 'Arun Kumar');
    });

    test('resolves a unique prefix', () {
      expect(resolve('bhavna')?.name, 'Bhavna Shah');
    });

    test('ignores punctuation the recognizer adds', () {
      expect(resolve('arun kumar.')?.name, 'Arun Kumar');
    });

    test('resolves a single-word name inside a sentence', () {
      expect(resolve('i want bhavna')?.name, 'Bhavna Shah');
    });

    test('returns null when a prefix is ambiguous rather than guessing', () {
      // "arun" matches both Arun Kumar and Aruna Iyer. Choosing one silently
      // means an emergency call goes to a stranger, so both answers must be
      // offered instead.
      expect(resolve('arun'), isNull);
    });

    test('tolerates a small misspelling', () {
      expect(resolve('ashwin rao')?.name, 'Ashwin Rao');
      expect(resolve('ashwinn rao')?.name, 'Ashwin Rao');
    });

    test('returns null for a name nobody has', () {
      expect(resolve('zebra kumar'), isNull);
    });
  });

  group('ContactMatcher - choosing by position', () {
    test('reads a spoken page position relative to the current page', () {
      // On page two the user says "1" meaning the first name they just heard.
      expect(resolve('1', offset: 4)?.name, isNull, reason: 'no 5th contact');
      expect(resolve('one', offset: 4)?.name, isNull);
    });

    test('reads an ordinal as a position', () {
      expect(resolve('the second one')?.name, 'Aruna Iyer');
      expect(resolve('third')?.name, 'Ashwin Rao');
    });

    test('offsets the position by the current page', () {
      // With the list paged two at a time and the user on page two, "1" is the
      // third contact, not the first.
      expect(resolve('1', offset: 2, pageSize: 2)?.name, 'Ashwin Rao');
    });

    test('ignores an out of range position instead of clamping', () {
      expect(resolve('9'), isNull);
    });

    test('does not read a number inside a name as a position', () {
      // A contact whose name contains digits must still be selectable by name,
      // otherwise the digits get eaten as a list position.
      const withNumberInName = [
        DeviceContact(name: 'Room 21', phone: '9000000000'),
      ];
      expect(
        ContactMatcher.resolve(
          'room 21',
          contacts: withNumberInName,
          pageOffset: 0,
          pageSize: 4,
        )?.name,
        'Room 21',
      );
      expect(ContactMatcher.looksLikePosition('choose room 21'), isFalse);
      expect(ContactMatcher.looksLikePosition('choose 2'), isTrue);
      expect(ContactMatcher.looksLikePosition('the second one'), isTrue);
    });
  });

  group('ContactMatcher - choosing by phone number', () {
    test('reads spoken digits', () {
      expect(
        resolve('nine eight seven six five four three two one zero')
            ?.name,
        'Arun Kumar',
      );
    });

    test('matches on a partial number', () {
      expect(resolve('nine eight seven')?.name, 'Arun Kumar');
    });

    test('a full spoken number outranks a coincidental name match', () {
      // The number is the strongest signal available and is checked first.
      expect(resolve('nine nine zero zero one one two two three three')
          ?.name, 'Ashwin Rao');
    });
  });

  group('ContactMatcher - confirmations', () {
    test('recognises yes and its variants', () {
      for (final phrase in ['yes', 'yeah', 'yep', 'correct', 'confirm']) {
        expect(ContactMatcher.isAffirmative(phrase), isTrue,
            reason: 'expected "$phrase" to confirm');
      }
      expect(ContactMatcher.isAffirmative('no'), isFalse);
    });

    test('recognises no and its variants', () {
      for (final phrase in ['no', 'nope', 'not that', 'wrong', 'cancel']) {
        expect(ContactMatcher.isNegative(phrase), isTrue,
            reason: 'expected "$phrase" to reject');
      }
      expect(ContactMatcher.isNegative('yes'), isFalse);
    });
  });

  group('ContactMatcher - list navigation', () {
    test('separates navigation from names', () {
      expect(ContactMatcher.isNextPage('next'), isTrue);
      expect(ContactMatcher.isNextPage('next page please'), isTrue);
      expect(ContactMatcher.isPreviousPage('previous'), isTrue);
      expect(ContactMatcher.isRepeat('repeat'), isTrue);
      expect(ContactMatcher.isCancel('cancel'), isTrue);
      expect(ContactMatcher.isCancel('go back'), isTrue);

      // A name that merely contains a navigation word is still a name.
      expect(ContactMatcher.isCancel('bhavna'), isFalse);
    });

    test('paginates without wrapping', () {
      expect(ContactMatcher.page(_contacts, offset: 0, size: 2).length, 2);
      expect(ContactMatcher.page(_contacts, offset: 2, size: 2).length, 2);
      expect(ContactMatcher.page(_contacts, offset: 3, size: 2).length, 1);
      expect(ContactMatcher.page(_contacts, offset: 4, size: 2), isEmpty);
      // Past the end returns nothing rather than repeating the start, so a
      // mistimed "previous" cannot throw the user to the top of a long list.
      expect(ContactMatcher.page(_contacts, offset: 99, size: 2), isEmpty);
    });
  });
}
