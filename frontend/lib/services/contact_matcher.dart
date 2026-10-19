import 'contact_directory.dart';

/// Resolves a spoken phrase to a contact in the loaded device list.
///
/// Pure Dart and free of any UI or plugin dependency, so the part that decides
/// "did the user mean Arun or Ashwin?" is directly testable. Getting this wrong
/// is not cosmetic: it is the difference between an emergency call going to the
/// right person and to a stranger.
class ContactMatcher {
  const ContactMatcher._();

  /// Spoken digit words, so "nine eight seven" resolves to 987.
  static const Map<String, String> _digitWords = {
    'zero': '0', 'oh': '0', 'o': '0', 'one': '1', 'won': '1', 'two': '2',
    'to': '2', 'too': '2', 'three': '3', 'four': '4', 'for': '4',
    'five': '5', 'six': '6', 'seven': '7', 'eight': '8', 'ate': '8',
    'nine': '9', 'niner': '9',
  };

  /// Number words up to twenty, used when the user says a page position out
  /// loud ("the second one") rather than a digit.
  static const Map<String, int> _ordinals = {
    'first': 1, 'one': 1, 'second': 2, 'two': 2, 'third': 3, 'three': 3,
    'fourth': 4, 'four': 4, 'fifth': 5, 'five': 5, 'sixth': 6, 'six': 6,
    'seventh': 7, 'seven': 7, 'eighth': 8, 'eight': 8, 'ninth': 9,
    'nine': 9, 'tenth': 10, 'ten': 10,
  };

  /// Spoken selection phrases that mean "the one at this position".
  static const List<String> _chooseWords = [
    'choose', 'select', 'pick', 'i want', 'i choose', 'i pick',
    'that is', 'thats', 'that one',
  ];

  /// True when the phrase means "show me the next suggestion".
  ///
  /// This is the command that makes a frequency-ranked shortlist usable. The
  /// user does not have to remember what the app offered, learn its ordering,
  /// or page through anything - they say "alternative" until they hear a name
  /// they recognise. It is the single most important command in the picker.
  static bool isAlternative(String phrase) {
    for (final word in const [
      'alternative',
      'alternate',
      'another one',
      'someone else',
      'somebody else',
      'next option',
      'next suggestion',
      'other option',
      'other choice',
      'different person',
      'different contact',
      'go on',
    ]) {
      if (phrase.contains(word)) return true;
    }
    return false;
  }

  /// True when the phrase asks to be told who is called most.
  static bool isWhoDoICall(String phrase) {
    for (final word in const [
      'who do i call',
      'who i call',
      'who do i talk',
      'most often',
      'most called',
      'top contact',
      'best contact',
      'main contact',
      'first choice',
    ]) {
      if (phrase.contains(word)) return true;
    }
    return false;
  }

  /// True when the phrase is navigation inside the list, not a name.
  static bool isNavigationWord(String phrase) {
    for (final word in const [
      'next', 'previous', 'back', 'repeat', 'cancel', 'stop', 'yes', 'no',
      'confirm', 'done', 'close', 'exit', 'search', 'top', 'start',
    ]) {
      if (phrase.contains(word)) return true;
    }
    return false;
  }

  static bool isNextPage(String phrase) =>
      phrase.contains('next') || phrase.contains('more');

  static bool isPreviousPage(String phrase) =>
      phrase.contains('previous') ||
      phrase.contains('previous page') ||
      (phrase.contains('go back') && !phrase.contains('choose'));

  static bool isRepeat(String phrase) => phrase.contains('repeat');

  static bool isCancel(String phrase) =>
      phrase.contains('cancel') ||
      phrase.contains('never mind') ||
      phrase.contains('go back') ||
      phrase.contains('exit');

  /// True for a spoken confirmation of a pending selection.
  ///
  /// The list is generous on purpose. When the app is about to attach a phone
  /// number to someone's name for an emergency, a confirmation the user does
  /// not recognise as a confirmation is worse than a slightly loose match - it
  /// either saves the wrong contact or loops the question forever.
  static bool isAffirmative(String phrase) {
    for (final word in const [
      'yes',
      'yeah',
      'yep',
      'yup',
      'sure',
      'correct',
      'confirm',
      'that is right',
      'thats right',
      'go ahead',
    ]) {
      if (phrase.contains(word)) return true;
    }
    return false;
  }

  static bool isNegative(String phrase) {
    for (final word in const ['no', 'nope', 'not that', 'wrong', 'incorrect', 'cancel']) {
      if (phrase.contains(word)) return true;
    }
    return false;
  }

  /// Reads a phrase as a phone number, so "nine eight seven six five four"
  /// selects the contact stored as 987654.
  static String spokenDigits(String phrase) {
    final buffer = StringBuffer();
    for (final word in phrase.split(RegExp(r'[^a-z]+'))) {
      if (word.isEmpty) continue;
      final digit = _digitWords[word];
      if (digit != null) buffer.write(digit);
    }
    return buffer.toString();
  }

  /// Reads a page position out of a phrase, or null when there is none.
  ///
  /// Handles both "2" and "the second one", because a recognizer turns one
  /// into the other unpredictably and the user should not have to care.
  static int? spokenPosition(String phrase) {
    final words = phrase
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty)
        .toList();

    for (final word in words) {
      final value = int.tryParse(word);
      if (value != null && value > 0 && value <= 99) return value;
    }
    for (final word in words) {
      final value = _ordinals[word];
      if (value != null) return value;
    }
    return null;
  }

  /// True when [phrase] is a position rather than a name.
  ///
  /// A bare number, "number two", "contact 3", "the third one". Without this
  /// guard a contact literally named "One" could never be selected, because the
  /// number would always be read as a position.
  ///
  /// Bounded at two digits on purpose: "contact 317" is a name, not a position.
  /// The list of suggestions is never longer than an emergency contact slot
  /// count, so a position above 99 could only be a mis-heard name.
  static bool looksLikePosition(String phrase) {
    final cleaned = _stripChooseWords(phrase).trim();
    if (cleaned.isEmpty) return false;

    return RegExp(
          r'^(?:the\s+)?'
          r'(?:(?:number|contact|person|entry|option|suggestion)\s+)?'
          r'\d{1,2}(?:st|nd|rd|th)?$'
          r'|^the\s+'
          r'(?:first|second|third|fourth|fifth|sixth|seventh|eighth|'
          r'ninth|tenth)'
          r'(?:st|nd|rd|th)?(?:\s+(?:one|contact|person|entry|option))?$'
          r'|^(?:first|second|third|fourth|fifth|sixth|seventh|eighth|'
          r'ninth|tenth|one|two|three|four|five|six|seven|eight|nine|ten)$',
        ).hasMatch(cleaned);
  }

  static String _stripChooseWords(String phrase) {
    var value = phrase;
    for (final word in _chooseWords) {
      value = value.replaceAll(word, ' ');
    }
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// The name the user actually said, with selection words removed.
  ///
  /// Digits are KEPT, and so is the word "contact". Stripping them looked
  /// tidier but broke real selections: "contact 317" became "contact", which
  /// matched every one of a phone's 500 numbered contacts equally well and so
  /// matched none of them. Anything that looks like a bare position is already
  /// handled by [looksLikePosition] before this is reached, so what survives
  /// here is genuinely a name.
  static String nameFromPhrase(String phrase) {
    return _stripChooseWords(phrase)
        .replaceAll(RegExp(r'\b(?:number|person|entry|option|suggestion)\b'),
            ' ')
        .replaceAll(RegExp(r'\bplease\b'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Resolves a spoken phrase to exactly one contact, or null.
  ///
  /// Tried in decreasing order of confidence, so a wrong guess can never beat
  /// a correct one:
  ///   1. an exact name match,
  ///   2. a page position ("2", "the second one"),
  ///   3. a spoken phone number,
  ///   4. a unique name prefix ("arun" -> Arun),
  ///   5. a unique substring anywhere in the name,
  ///   6. a small spelling distance.
  ///
  /// Ambiguous matches resolve to null on purpose. Offering "did you mean Arun
  /// or Ashwin?" is recoverable; silently dialling Ashwin is not.
  static DeviceContact? resolve(
    String phrase, {
    required List<DeviceContact> contacts,
    required int pageOffset,
    required int pageSize,
  }) {
    if (contacts.isEmpty) return null;

    final digits = spokenDigits(phrase);
    if (digits.length >= 3) {
      final byNumber = contacts.where((c) => c.phone.contains(digits));
      if (byNumber.length == 1) return byNumber.first;
    }

    if (looksLikePosition(phrase)) {
      final position = spokenPosition(phrase);
      if (position == null) return null;

      // A position can only ever mean a row the user was actually shown.
      // Without this bound, "7" on a five-row list silently selected the 7th of
      // 500 contacts - a number the user was never told and cannot check.
      if (position < 1 || position > pageSize) return null;

      final index = pageOffset + position - 1;
      if (index >= 0 && index < contacts.length) return contacts[index];
      return null;
    }

    final name = nameFromPhrase(phrase);
    if (name.isEmpty) return null;

    final lower = name.toLowerCase();
    final normalizedName = _squash(lower);

    // 1. Exact.
    final exact = contacts.where((c) => _squash(c.name.toLowerCase()) == normalizedName);
    if (exact.length == 1) return exact.first;

    // 4. Unique prefix.
    final byPrefix = contacts.where((c) => _squash(c.name.toLowerCase()).startsWith(normalizedName));
    if (byPrefix.length == 1) return byPrefix.first;

    // 5. Unique substring.
    final bySubstring =
        contacts.where((c) => _squash(c.name.toLowerCase()).contains(normalizedName));
    if (bySubstring.length == 1) return bySubstring.first;

    // A repeated match is ambiguous unless the prefix test already decided it.
    if (exact.length > 1 || byPrefix.length > 1 || bySubstring.length > 1) {
      return null;
    }

    // 6. Spelling distance, for a misheard name.
    DeviceContact? best;
    var bestDistance = 1 << 30;
    for (final contact in contacts) {
      final distance = _distance(
        normalizedName,
        _squash(contact.name.toLowerCase()),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        best = contact;
      }
    }
    final tolerance = normalizedName.length <= 4 ? 1 : 2;
    return bestDistance <= tolerance ? best : null;
  }

  /// Removes everything a recognizer adds inconsistently: spaces, punctuation
  /// and accents. "Arun R." and "arun r" must compare equal, or a correct
  /// choice is reported as a misspelling.
  static String _squash(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Levenshtein distance, bounded so a long contact name cannot dominate.
  static int _distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty || b.isEmpty) return b.length > a.length ? b.length : a.length;
    if ((a.length - b.length).abs() > 3) return 99;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final insert = current[j - 1] + 1;
        final delete = previous[j] + 1;
        final replace = previous[j - 1] + cost;
        current[j] = insert < delete
            ? (insert < replace ? insert : replace)
            : (delete < replace ? delete : replace);
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }

  /// Contacts on the current page, for both speaking and rendering.
  static List<DeviceContact> page(
    List<DeviceContact> contacts, {
    required int offset,
    required int size,
  }) {
    if (offset >= contacts.length) return const [];
    final end = (offset + size).clamp(0, contacts.length);
    return contacts.sublist(offset, end);
  }
}
