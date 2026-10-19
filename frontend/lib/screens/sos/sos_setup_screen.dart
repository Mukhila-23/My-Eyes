import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/app_instructions.dart';
import '../../services/companion.dart';
import '../../services/contact_directory.dart';
import '../../services/contact_matcher.dart';
import '../../services/emergency_service.dart';
import '../../services/sos_contact_store.dart';
import '../../services/voice_command_service.dart';

/// Voice-only emergency-contact setup. Nothing here is ever typed.
///
/// The app does the work: it reads the device call log, works out the handful of
/// people this user actually calls, and offers them one at a time. A phone can
/// hold 100 to 500 contacts, and reading that list out - even five at a time -
/// is not a selection interface, it is a chore. So the app ranks, proposes, and
/// the user only ever answers yes or no.
///
/// Spoken commands, all available at every step:
///   "yes" / "save"      accept the suggestion (or save, at the end)
///   "alternative"       skip this person and hear the next suggestion
///   "no"                the same as alternative
///   "1" .. "5"          accept that numbered suggestion straight away
///   any name            take that person, found anywhere in all 500 contacts
///   any phone number    spoken digit by digit, takes that person
///   "who do I call"     hear the top callers again
///   "list"              hear the five suggestions together
///   "repeat"            hear the current question again
///   "repeat the number" hear the full number of the current suggestion
///   "skip this setup"   leave without saving
///
/// There is no text field and no keyboard button anywhere on this screen. The
/// only ways through are speech and the large controls pinned at the bottom:
/// microphone, save and skip. That is the point - a blind user who cannot make
/// the recogniser hear them must still have a way out that is always on screen,
/// which is why the skip button is never hidden, including in the mandatory
/// login-time run.
class SosSetupScreen extends StatefulWidget {
  const SosSetupScreen({
    super.key,
    required this.companion,
    this.isMandatory = true,
  });

  final CompanionProfile companion;

  /// True when reached from the login flow. Only changes the wording of the
  /// opening line; the escape hatch is identical either way.
  final bool isMandatory;

  @override
  State<SosSetupScreen> createState() => _SosSetupScreenState();
}

/// Where the wizard is.
enum _Step {
  loading,
  proposing,
  review,
  saving,
  done,
  blocked,
}

/// One contact the user has accepted, not yet saved.
class _Accepted {
  _Accepted({
    required this.name,
    required this.phone,
    required this.relationship,
    required this.priority,
  });

  final String name;
  final String phone;
  final String relationship;

  /// 1 is alerted first, up to [SosSetupLimits.maxContacts].
  final int priority;

  String get tail =>
      phone.length <= 4 ? phone : phone.substring(phone.length - 4);

  /// Announced when the list is read back, so a mistake is caught before the
  /// save rather than after an emergency call goes to the wrong person.
  String spoken() => '$name, your ${relationship.toLowerCase()}, '
      'priority ${SosSetupLimits.ordinal(priority)}, '
      'number ending $tail';
}

class _SosSetupScreenState extends State<SosSetupScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _service = VoiceCommandService.instance;

  /// Every device contact with a phone number, ranked most-called first.
  List<DeviceContact> _pool = const [];

  /// Contacts the user has accepted, in the order they will be alerted.
  final List<_Accepted> _accepted = [];

  /// People sent past with "alternative", never offered again.
  final Set<String> _rejected = {};

  /// Index into [_pool] of the contact currently being proposed.
  int _cursor = 0;

  /// Contacts whose names matched but could not be told apart.
  List<DeviceContact> _ambiguous = const [];

  _Step _step = _Step.loading;
  String _prompt = '';
  String _status = '';
  String _lastHeard = '';

  /// True when the ranking really came from call history.
  bool _rankedByCalls = false;

  /// Spoken explanation when the ranking had to fall back.
  String _rankingNote = '';

  /// Why there is nothing to offer, when there is nothing.
  String _problem = '';

  bool _disposed = false;
  bool _listening = false;
  bool _micHealthy = false;

  /// Flipped just before leaving so the deliberate pop is not blocked by the
  /// [PopScope] that routes every *other* exit through the spoken notice.
  bool _allowPop = false;

  /// A skip is already in progress, and the route pop has already been queued.
  /// Both are needed because the announcement takes several seconds, and a user
  /// who taps skip twice must not start two of them or pop two routes.
  bool _leaving = false;
  bool _popping = false;

  int? _voiceSession;

  @override
  void initState() {
    super.initState();

    // Contacts access, call-log access and the notification prompt each make the
    // app inactive, which parks the voice engine. Without this observer the
    // microphone never came back and the screen kept asking questions into a
    // dead microphone for the rest of the run.
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;

    if (state == AppLifecycleState.resumed) {
      unawaited(_service.resumeAfterLifecycle());
      unawaited(_openMicrophone());
    } else {
      unawaited(_service.pauseForLifecycle());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _service.releaseSession(_voiceSession);
    super.dispose();
  }

  // ------------------------------------------------------------
  // BOOT
  // ------------------------------------------------------------

  Future<void> _start() async {
    _service.configureCompanionProfile(widget.companion);

    _voiceSession = await _service.startSession(
      onCommand: _handleCommand,
      onHeard: (transcript) {
        if (!mounted) return;
        setState(() => _lastHeard = transcript);
      },
      onListeningChanged: (listening) {
        if (!mounted) return;
        setState(() {
          _listening = listening;
          if (listening) _micHealthy = true;
        });
      },
      autoStart: false,
    );
    if (_disposed || !mounted) return;

    await _say(
      // The way out is named once, up front, and repeated on every dead end
      // below. A user who does not know they can leave is the one most likely
      // to be stuck here.
      'Let us set up your emergency contacts. I will read out the people you '
      'call most, and you only need to say yes or no. Nothing to type. '
      '${SosSetupLimits.skipHintSpoken}',
    );
    if (_disposed || !mounted) return;

    await _loadContacts();
  }

  /// Reads the contact list, ranks it, then makes the first offer.
  ///
  /// The read is bounded and hash-indexed: a phone with 500 contacts must not
  /// look like the app has hung on the one screen that has to look instant.
  Future<void> _loadContacts() async {
    if (mounted) {
      setState(() {
        _step = _Step.loading;
        _prompt = 'Looking at your contacts and call history.';
      });
    }

    final result = await ContactDirectory.instance.load();
    if (_disposed || !mounted) return;

    setState(() {
      _pool = result.contacts;
      _problem = result.problem ?? '';
      _rankedByCalls = result.callHistoryAvailable &&
          result.contacts.any((contact) => contact.hasCallHistory);
      _rankingNote = _rankedByCalls ? '' : _fallbackNote();
      _cursor = 0;
    });

    if (_pool.isEmpty) {
      final reason = _problem.isEmpty
          ? 'I could not find any contacts to choose from.'
          : _problem;
      setState(() {
        _step = _Step.blocked;
        _prompt = reason;
      });
      await _say(
        '$reason You can still skip this setup and do it later.',
        important: true,
      );
      return;
    }

    await _proposeNext(opening: true);
  }

  String _fallbackNote() => 'I could not read your call history, so I cannot '
      'tell who you call most. I will suggest names from your contacts, and '
      'you can say any name yourself.';

  // ------------------------------------------------------------
  // SPEAK, THEN LISTEN
  // ------------------------------------------------------------

  /// Speaks [text], shows it, then reopens the microphone.
  ///
  /// Always speak-then-listen. The reverse order makes the recogniser hear this
  /// app's own announcement and execute it, which is how a contact nobody named
  /// ends up on an emergency list.
  Future<void> _say(String text, {bool important = false}) async {
    if (_disposed || !mounted) return;

    setState(() => _prompt = text);

    await _service.speak(
      text,
      resumeAfter: false,
      pace: important ? TtsPace.important : TtsPace.normal,
      remember: true,
    );
    if (_disposed || !mounted) return;

    await _openMicrophone();
  }

  /// Opens the microphone and then *proves* it is open.
  ///
  /// `resumeMicrophone()` returns normally in several situations where the
  /// microphone is nonetheless shut: the app is briefly backgrounded, the
  /// recogniser is still initialising, or the engine is between restarts. The
  /// old wizard awaited it and moved on, so a dead microphone looked exactly
  /// like a silent room - the user spoke, nothing happened, and the screen
  /// still said the question. That is the worst possible failure here.
  ///
  /// The check is on `recognizerHealthy`, not `isListening`: the latter reports
  /// the *intent* to listen and stays true after initialisation fails.
  Future<void> _openMicrophone() async {
    if (_disposed || !mounted) return;

    await _service.resumeMicrophone();
    if (_disposed || !mounted) return;

    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_disposed || !mounted) return;
      if (_service.recognizerHealthy) break;
      await _service.resumeMicrophone();
    }

    if (_disposed || !mounted) return;

    final healthy = _service.recognizerHealthy;
    final available = _service.recognizerAvailable;

    if (mounted) {
      setState(() => _micHealthy = healthy || available);
    }

    // Only a genuine, unfixable-by-waiting failure is worth interrupting for. A
    // microphone that is merely restarting is repaired by the engine's own
    // watchdog, and telling the user it is broken while it works is worse than
    // saying nothing.
    if (!available) {
      debugPrint('[SOS-SETUP] recognizer unavailable: '
          '${_service.lastRecognizerError}');
      await _service.speak(
        'I cannot open the microphone, so I will not hear you. Please check '
        'that My Eyes has microphone permission in your phone settings, then '
        'tap the microphone button. You can skip this setup at any time.',
        resumeAfter: false,
        pace: TtsPace.important,
      );
    }
  }

  // ------------------------------------------------------------
  // THE PROPOSALS
  // ------------------------------------------------------------

  /// The first person at or after [from] who is neither accepted nor sent past.
  int _nextCandidate(int from) {
    for (var i = from; i < _pool.length; i++) {
      final contact = _pool[i];
      if (_rejected.contains(contact.phone)) continue;
      if (_isAccepted(contact)) continue;
      return i;
    }
    return -1;
  }

  DeviceContact? get _candidate {
    if (_cursor < 0 || _cursor >= _pool.length) return null;
    return _pool[_cursor];
  }

  bool _isAccepted(DeviceContact contact) =>
      _accepted.any((entry) => entry.phone == contact.phone);

  /// The highest ranked contacts still on offer, for "list".
  List<DeviceContact> get _suggestions {
    final remaining = _pool.where((contact) => !_isAccepted(contact)).toList();
    return ContactDirectory.shortlist(remaining);
  }

  Future<void> _proposeNext({bool opening = false}) async {
    if (_accepted.length >= SosSetupLimits.maxContacts) {
      await _review();
      return;
    }

    final next = _nextCandidate(opening ? 0 : _cursor + 1);
    if (next < 0) {
      await _review();
      return;
    }

    setState(() {
      _cursor = next;
      _step = _Step.proposing;
      _ambiguous = const [];
    });

    await _say(_proposalSpeech(opening: opening));
  }

  String _proposalSpeech({bool opening = false}) {
    final contact = _candidate;
    if (contact == null) return 'I have no more suggestions.';

    final ordinal = SosSetupLimits.ordinal(_accepted.length + 1);

    final buffer = StringBuffer();
    if (opening) {
      buffer.write(
        _rankedByCalls
            ? 'I looked at who you call most. Here is the first of five people.'
            : '$_rankingNote Here is the first of five people.',
      );
    } else {
      buffer.write('Suggestion $ordinal.');
    }

    buffer.write(' ${contact.name}.');
    if (contact.hasCallHistory && _rankedByCalls) {
      buffer.write(
        ' ${contact.spokenCallCount}, number ending ${contact.spokenTail}.',
      );
    } else {
      buffer.write(' Number ending ${contact.spokenTail}.');
    }

    buffer.write(_commandsFor(contact));
    return buffer.toString();
  }

  /// The two answers that matter, repeated on every single proposal.
  ///
  /// Repeated rather than mentioned once because a blind user who does not know
  /// what to say is otherwise stuck looking at a question they cannot answer.
  String _commandsFor(DeviceContact contact) =>
      ' Say yes to add ${contact.name}, or say alternative to skip and hear '
      'the next person. You can also say any name.';

  /// Adds [contact] and moves straight on to the next person.
  Future<void> _accept(DeviceContact contact) async {
    if (_disposed || !mounted) return;

    if (_isAccepted(contact)) {
      await _say(
        '${contact.name} is already on your list. ${_commandsFor(contact)}',
      );
      return;
    }

    if (_accepted.length >= SosSetupLimits.maxContacts) {
      await _review();
      return;
    }

    final priority =
        (_accepted.length + 1).clamp(1, SosSetupLimits.maxContacts);
    final relationship = contact.relationshipGuess;

    setState(() {
      _accepted.add(
        _Accepted(
          name: contact.name,
          phone: contact.phone,
          relationship: relationship,
          priority: priority,
        ),
      );
      _ambiguous = const [];
      _status =
          '${_accepted.length} of ${SosSetupLimits.maxContacts} chosen.';
    });

    // Move the cursor on *before* composing the next announcement, so the
    // proposal that follows is the next person rather than the one just taken.
    final next = _nextCandidate(_cursor + 1);
    if (next < 0) {
      await _review();
      return;
    }

    setState(() {
      _cursor = next;
      _step = _Step.proposing;
    });

    // Announce what was taken *before* the next proposal, so a wrong pick is
    // still correctable while the user is listening.
    await _say(
      'I have added ${contact.name}, your ${relationship.toLowerCase()}, '
      'priority ${SosSetupLimits.ordinal(priority)}. '
      '${_proposalSpeech()}',
    );
  }

  /// Sends the current person past and offers the next one.
  Future<void> _advance() async {
    final contact = _candidate;
    if (contact != null) {
      setState(() => _rejected.add(contact.phone));
    }

    if (_accepted.isEmpty && _rejected.length >= SosSetupLimits.maxContacts) {
      // Enough people have been sent past that continuing is pointless.
      await _review();
      return;
    }

    await _proposeNext();
  }

  // ------------------------------------------------------------
  // REVIEW AND SAVE
  // ------------------------------------------------------------

  Future<void> _review() async {
    setState(() {
      _step = _Step.review;
      _ambiguous = const [];
    });

    final count = _accepted.length;
    if (count == 0) {
      await _say(
        'You have not chosen anyone yet. Say any name from your contacts, or '
        'say skip this setup to leave. Say list and I will read out the people '
        'you call most.',
        important: true,
      );
      return;
    }

    final word = count == 1 ? 'contact' : 'contacts';
    final buffer = StringBuffer('I have $count emergency $word.');
    for (var i = 0; i < _accepted.length; i++) {
      buffer.write(' ${i + 1}. ${_accepted[i].spoken()}.');
    }

    // Saying "alternative" with nothing left to offer would otherwise replay
    // this exact recap, which reads as the app being stuck. Naming the way out
    // is what keeps it a choice rather than a loop.
    final exhausted = _nextCandidate(0) < 0 &&
        count < SosSetupLimits.maxContacts;
    buffer.write(
      exhausted
          ? ' Those were all the suggestions I have. Say save to keep them, or '
              'say any name from your contacts to add someone else.'
          : ' Say save to keep them. Say alternative to hear more suggestions, '
              'or say any name to add someone else.',
    );

    await _say(buffer.toString(), important: true);
  }

  /// What "no" means once the list has been read back.
  Future<void> _reviewNo() async {
    if (_accepted.length >= SosSetupLimits.maxContacts) {
      await _say(
        'You already have five emergency contacts. Say save to keep them, or '
        'say skip this setup.',
        important: true,
      );
      return;
    }

    // Keeps what has already been chosen: "no" means "not these", not "start
    // from nothing and make me say everything again".
    setState(() {
      _rejected.clear();
      _cursor = -1;
    });

    await _proposeNext(opening: true);
  }

  Future<void> _save() async {
    if (_step == _Step.saving || _accepted.isEmpty) return;

    setState(() {
      _step = _Step.saving;
      _status = 'Saving your emergency contacts.';
    });

    await _service.pauseMicrophone();
    await _service.speak(
      'Saving your emergency contacts.',
      resumeAfter: false,
      pace: TtsPace.important,
    );
    if (_disposed || !mounted) return;

    var saved = 0;
    for (final contact in _accepted) {
      try {
        await EmergencyService.addContact(
          name: contact.name,
          phoneNumber: contact.phone,
          relationship: contact.relationship,
          priority: contact.priority,
        );
        saved++;
      } catch (error) {
        debugPrint('[SOS-SETUP] could not save ${contact.name}: $error');
      }
    }

    if (_disposed || !mounted) return;

    if (saved == 0) {
      // Do not claim success. The user has to be able to try again.
      setState(() {
        _step = _Step.blocked;
        _status = "I couldn't save your contacts right now.";
        _prompt = _status;
      });
      await _service.speak(
        "I couldn't complete emergency setup right now. You can try again from "
        'the dashboard.',
        resumeAfter: false,
        pace: TtsPace.important,
      );
      return;
    }

    // Mirror locally for the offline SOS path. A failure here is not fatal: the
    // account already holds the contacts and will be mirrored on next login.
    try {
      await SosContactStore.syncFromServer();
    } catch (error) {
      debugPrint('[SOS-SETUP] local mirror skipped: $error');
    }

    if (_disposed || !mounted) return;

    final word = saved == 1 ? 'contact' : 'contacts';
    setState(() {
      _step = _Step.done;
      _status = '$saved emergency $word saved.';
      _prompt = _status;
    });

    await _service.speak(
      'Your emergency contacts are saved. '
      '${AppInstructions.sosInstructions(
        companionName: widget.companion.name,
        configured: true,
      )}',
      resumeAfter: false,
      pace: TtsPace.important,
    );
  }

  /// Leaves without saving, saying so first.
  ///
  /// A silent skip would leave the user believing they are protected when they
  /// are not, so the notice is always delivered before the route pops.
  Future<void> _leave() async {
    if (!mounted || _leaving) return;
    _leaving = true;

    if (_step == _Step.saving || _step == _Step.done) {
      _pop(_step == _Step.done);
      return;
    }

    await _service.speak(
      'Skipping emergency setup. Your emergency contacts are not saved yet. '
      'Say set up S O S any time from the dashboard to do this later.',
      resumeAfter: false,
      pace: TtsPace.important,
    );

    if (!mounted) return;
    _pop(false);
  }

  /// Pops the route, lifting the [PopScope] guard for this one deliberate exit.
  ///
  /// The pop is deferred to the next frame on purpose. `setState` only marks
  /// the widget dirty, so the route still reports `doNotPop` for the rest of
  /// this tick: calling `Navigator.pop` immediately would be swallowed and would
  /// come straight back through [PopScope.onPopInvokedWithResult] as "pop
  /// blocked", which restarts the announcement on a loop.
  void _pop(bool completed) {
    if (!mounted || _popping) return;
    _popping = true;
    setState(() => _allowPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(completed);
    });
  }

  void _done() => _pop(true);

  Future<void> _restart() async {
    if (_disposed || !mounted) return;

    setState(() {
      _accepted.clear();
      _rejected.clear();
      _ambiguous = const [];
      _cursor = 0;
      _status = '';
    });

    if (_pool.isEmpty) {
      await _loadContacts();
      return;
    }

    await _proposeNext(opening: true);
  }

  // ------------------------------------------------------------
  // COMMANDS
  // ------------------------------------------------------------

  /// Decision words, matched on word boundaries.
  ///
  /// Boundaries matter: a bare `contains('yes')` also fires on a contact called
  /// "Yessica", and that name would be swallowed as a confirmation.
  static const List<String> _yesWords = [
    'yes',
    'yeah',
    'yep',
    'yup',
    'sure',
    'ok',
    'okay',
    'correct',
    'confirm',
  ];

  static const List<String> _noWords = ['no', 'nope', 'nah', 'wrong'];

  /// Words that mean "I am done, keep these".
  static const List<String> _saveWords = [
    'save',
    'keep them',
    'keep it',
    'keep these',
    'store them',
    'done',
    'finished',
  ];

  static bool _isSaveCommand(String phrase) =>
      _mentionsAny(phrase, _saveWords) ||
      phrase.contains('keep') && _mentionsAny(phrase, _yesWords);

  static bool _mentionsAny(String phrase, List<String> words) =>
      words.any((word) => phrase.contains(RegExp('\\b${RegExp.escape(word)}\\b')));

  /// True when [phrase] is nothing but a decision, with no name attached.
  ///
  /// "yes" is a confirmation. "yes Arun" is a name, and the name wins: the user
  /// said who they meant, which is more information than the yes.
  static bool _isDecisionOnly(String phrase) {
    var cleaned = phrase;
    for (final word in [..._yesWords, ..._noWords]) {
      cleaned = cleaned.replaceAll(RegExp('\\b$word\\b'), ' ');
    }
    for (final filler in const [
      'please',
      'add',
      'save',
      'them',
      'him',
      'her',
      'this',
      'person',
      'contact',
      'it',
    ]) {
      cleaned = cleaned.replaceAll(RegExp('\\b$filler\\b'), ' ');
    }
    cleaned = cleaned.replaceAll(RegExp(r'[^a-z0-9]'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim().isEmpty;
  }

  /// Removes a leading "yes" / "no" so the rest can be read as a name.
  static String _stripDecision(String phrase) => phrase
      .replaceFirst(
        RegExp(r'^\s*(yes|yeah|yep|no|nope|nah|ok|okay|sure|please)\b[\s,]*'),
        '',
      )
      .trim();

  Future<void> _handleCommand(String raw) async {
    if (_disposed || !mounted) return;

    final phrase =
        VoiceCommandService.stripWakeWords(raw).toLowerCase().trim();
    if (phrase.isEmpty) return;

    if (_step == _Step.loading || _step == _Step.saving) return;

    // Escape hatches first. They are checked before every other command because
    // this screen must never be a trap, and the prompts themselves contain the
    // words "setup" and "save".
    if (_isSkipCommand(phrase)) {
      await _leave();
      return;
    }

    if (_step == _Step.done || _step == _Step.blocked) {
      await _handleTerminalCommand(phrase);
      return;
    }

    if (ContactMatcher.isCancel(phrase)) {
      await _leave();
      return;
    }

    // Checked before "repeat", which is the looser of the two: "repeat the
    // number" contains "repeat" and would otherwise never reach the number.
    if (_isReadNumberRequest(phrase)) {
      await _speakFullNumber();
      return;
    }

    if (_isReadListRequest(phrase)) {
      await _speakSuggestions();
      return;
    }

    if (ContactMatcher.isWhoDoICall(phrase)) {
      await _speakTopCallers();
      return;
    }

    if (ContactMatcher.isRepeat(phrase)) {
      await _repeatPrompt();
      return;
    }

    if (ContactMatcher.isAlternative(phrase) ||
        ContactMatcher.isNextPage(phrase)) {
      await _advance();
      return;
    }

    // A pending ambiguity narrows first: the user is answering "which one?".
    if (_ambiguous.isNotEmpty) {
      final narrowed = _resolveIn(_ambiguous, _stripDecision(phrase));
      if (narrowed != null) {
        await _accept(narrowed);
        return;
      }
    }

    // A number picks straight off the shortlist. Bounded to what was actually
    // offered: "7" on a five-item list is a misheard name, not a position.
    final position = _shortlistPosition(phrase);
    if (position != null && position < _suggestions.length) {
      await _accept(_suggestions[position]);
      return;
    }

    // Any name, anywhere in the contact list. This is what makes 500 contacts
    // reachable: the other 495 are found by being named, never by being read.
    if (!_isDecisionOnly(phrase)) {
      final named = _resolveIn(_pool, _stripDecision(phrase));
      if (named != null) {
        await _accept(named);
        return;
      }

      final nearMiss = _nearMisses(_stripDecision(phrase));
      if (nearMiss.isNotEmpty) {
        setState(() => _ambiguous = nearMiss);
        await _say(_ambiguousSpeech(nearMiss));
        return;
      }
    }

    // "save" is checked before the decision words because the review prompt asks
    // for exactly that word, and a command the app itself just requested must
    // never fall through to "I did not catch that".
    if (_isSaveCommand(phrase)) {
      if (_step == _Step.review) {
        await _save();
      } else if (_accepted.isNotEmpty) {
        // Not a yes/no proposal any more: the user is done picking, so read
        // the list back and let them confirm it properly.
        await _review();
      } else {
        await _nudge();
      }
      return;
    }

    // Nothing to resolve it to: fall back to the decision words.
    if (_mentionsAny(phrase, _yesWords)) {
      if (_step == _Step.review) {
        await _save();
      } else {
        final candidate = _candidate;
        if (candidate != null) await _accept(candidate);
      }
      return;
    }

    if (_mentionsAny(phrase, _noWords)) {
      if (_step == _Step.review) {
        await _reviewNo();
      } else {
        await _advance();
      }
      return;
    }

    await _nudge();
  }

  /// The finished and blocked states only have two useful answers.
  Future<void> _handleTerminalCommand(String phrase) async {
    final moveOn = ContactMatcher.isAffirmative(phrase) ||
        phrase.contains('continue') ||
        phrase.contains('done');

    if (_step == _Step.done) {
      if (moveOn) {
        _done();
        return;
      }
      await _say(_prompt, important: true);
      return;
    }

    // Blocked: retry, or leave.
    if (moveOn || phrase.contains('try again') || phrase.contains('retry')) {
      await _restart();
      return;
    }

    await _say(
      _prompt.isEmpty ? _status : _prompt,
      important: true,
    );
  }

  Future<void> _repeatPrompt() async {
    if (_step == _Step.done || _step == _Step.saving) return;

    if (_prompt.isEmpty) {
      await _proposeNext();
      return;
    }
    await _say(_prompt, important: _step == _Step.review);
  }

  /// Restates the current question after an answer that could not be used.
  ///
  /// Never a dead end: the user is told exactly what to say next, and the
  /// people already sent past are still one "alternative" away.
  Future<void> _nudge() async {
    if (_step == _Step.review) {
      await _say(
        'I did not catch that. Say save to keep your contacts, say alternative '
        'to hear more suggestions, or say any name to add someone. '
        '${SosSetupLimits.skipHintSpoken}',
        important: true,
      );
      return;
    }

    final contact = _candidate;
    if (contact == null) {
      await _say(
        'I did not catch that. Say any name from your contacts, or say skip '
        'this setup. ${SosSetupLimits.skipHintSpoken}',
        important: true,
      );
      return;
    }

    await _say(
      'I did not catch a name there. Say yes to add ${contact.name}, say '
      'alternative for the next person, or say any name from your contacts. '
      '${SosSetupLimits.skipHintSpoken}',
      important: true,
    );
  }

  /// Reads the current suggestions together.
  Future<void> _speakSuggestions() async {
    if (_pool.isEmpty) {
      await _nudge();
      return;
    }

    final suggestions = _suggestions;
    if (suggestions.isEmpty) {
      await _review();
      return;
    }

    final buffer = StringBuffer('The people you call most. ');
    for (var i = 0; i < suggestions.length; i++) {
      final contact = suggestions[i];
      final frequency = (_rankedByCalls && contact.hasCallHistory)
          ? ', ${contact.spokenCallCount}'
          : '';
      buffer.write('${i + 1}: ${contact.name}$frequency. ');
    }
    buffer.write(
      'Say a number to choose one, say yes to add ${suggestions.first.name}, '
      'or say any name.',
    );

    await _say(buffer.toString());
  }

  Future<void> _speakTopCallers() async {
    if (!_rankedByCalls) {
      await _say('$_rankingNote Say any name to choose.', important: true);
      return;
    }

    final top = _pool
        .where((contact) => contact.hasCallHistory && !_isAccepted(contact))
        .take(3)
        .toList();

    if (top.isEmpty) {
      await _say(
        'I could not find any calls in your history. Say any name to choose.',
        important: true,
      );
      return;
    }

    final buffer = StringBuffer('You call ');
    for (var i = 0; i < top.length; i++) {
      if (i > 0) buffer.write(i == top.length - 1 ? ', and ' : ', ');
      buffer.write('${top[i].name}, ${top[i].spokenCallCount}');
    }
    buffer.write(' most. Say yes, alternative, or a name.');

    await _say(buffer.toString());
  }

  Future<void> _speakFullNumber() async {
    final contact = _candidate;
    if (contact == null) {
      await _nudge();
      return;
    }
    await _say('${contact.name}, ${contact.spokenPhone}. ${_commandsFor(contact)}');
  }

  String _ambiguousSpeech(List<DeviceContact> candidates) {
    final buffer = StringBuffer('More than one contact matches. ');
    for (var i = 0; i < candidates.length && i < 4; i++) {
      buffer.write('${i + 1}: ${candidates[i].name}. ');
    }
    buffer.write(
      'Say the number for the right one, say the full name, or say alternative '
      'to go back to my suggestions.',
    );
    return buffer.toString();
  }

  /// A number the user can mean as "that suggestion", bounded to the five that
  /// were actually offered.
  int? _shortlistPosition(String phrase) {
    if (!ContactMatcher.looksLikePosition(phrase)) return null;

    final position = ContactMatcher.spokenPosition(phrase);
    if (position == null) return null;
    if (position < 1 || position > SosSetupLimits.maxContacts) return null;
    return position - 1;
  }

  /// Matches [phrase] against the WHOLE contact list.
  DeviceContact? _resolveIn(List<DeviceContact> pool, String phrase) {
    if (phrase.trim().length < 2) return null;

    return ContactMatcher.resolve(
      phrase,
      contacts: pool,
      pageOffset: 0,
      pageSize: SosSetupLimits.maxContacts,
    );
  }

  /// Contacts that start like the phrase but could not be told apart.
  ///
  /// Offering "did you mean Arun or Ashwin?" is recoverable; attaching the wrong
  /// number to an emergency contact is not.
  List<DeviceContact> _nearMisses(String phrase) {
    final name = ContactMatcher.nameFromPhrase(phrase)
        .replaceAll(RegExp('[^a-z0-9]'), '');
    if (name.length < 2) return const [];

    final prefix = name.substring(0, name.length.clamp(2, 3));
    return _pool
        .where((contact) => !_isAccepted(contact))
        .where(
          (contact) => contact.name
              .toLowerCase()
              .replaceAll(RegExp('[^a-z0-9]'), '')
              .startsWith(prefix),
        )
        .take(4)
        .toList();
  }

  bool _isReadListRequest(String phrase) =>
      const [
        'list',
        'everyone',
        'all of them',
        'all five',
        'who are they',
        'who are the five',
      ].any(phrase.contains);

  bool _isReadNumberRequest(String phrase) =>
      phrase.contains('repeat the number') ||
      phrase.contains('full number') ||
      phrase.contains('whole number') ||
      phrase.contains('say the number') ||
      phrase.contains('what is the number');

  /// True when [phrase] means "leave without saving".
  static bool _isSkipCommand(String phrase) =>
      const [
        'skip this',
        'skip setup',
        'skip it',
        'skip',
        'set up later',
        'setup later',
        'do it later',
        'do this later',
        'not now',
        'cancel setup',
        'cancel this setup',
        'exit setup',
        'leave setup',
        'i will do it later',
        'i want to do it later',
      ].any(phrase.contains);

  /// The big microphone control.
  ///
  /// A wizard that only works when speech recognition happens to work is a dead
  /// end, so the microphone is a real, visible, always-present control - not an
  /// indicator that merely reports what the engine is doing.
  Future<void> _toggleListening() async {
    if (_listening) {
      await _service.pauseMicrophone(_voiceSession);
      if (!mounted) return;
      await _service.speak(
        'Microphone off. Tap the microphone when you want me to listen again.',
        resumeAfter: false,
        pace: TtsPace.important,
      );
      return;
    }

    await _openMicrophoneAndConfirm();
  }

  Future<void> _openMicrophoneAndConfirm() async {
    await _openMicrophone();
    if (_disposed || !mounted) return;
    if (!_micHealthy) return;

    // The confirmation is folded into the question rather than spoken on its
    // own, because an extra utterance between the two would leave the
    // microphone shut when the user actually needs to answer. The prompt on
    // screen is deliberately left alone so it does not grow a new prefix every
    // time the button is pressed.
    await _service.speak(
      _prompt.isEmpty ? 'I am listening.' : 'I am listening. $_prompt',
      resumeAfter: false,
      pace: TtsPace.important,
      remember: true,
    );
    if (_disposed || !mounted) return;

    await _openMicrophone();
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Every *other* exit is routed through [_leave] so the user always hears
      // what happened before the screen disappears.
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPromptCard(),
                      const SizedBox(height: 18),
                      if (_accepted.isNotEmpty) _buildAccepted(),
                      const SizedBox(height: 18),
                      _buildSuggestions(),
                    ],
                  ),
                ),
              ),
              // Pinned outside the scroll view: however long the list grows,
              // the controls a blind user may need are always on screen.
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Skip this setup',
            hint: 'Leaves without saving your emergency contacts',
            child: ExcludeSemantics(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => unawaited(_leave()),
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.white.withValues(alpha: 0.05),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Semantics(
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Emergency Contacts',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.isMandatory
                        ? 'Required for your safety. Nothing to type.'
                        : 'Nothing to type. You can skip this at any time.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptCard() {
    final busy = _step == _Step.loading || _step == _Step.saving;
    final color = _step == _Step.blocked
        ? Colors.white38
        : const Color(0xFFFF3B3B);

    return Semantics(
      liveRegion: true,
      label: _prompt.isEmpty ? _status : _prompt,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _prompt.isEmpty ? 'Reading your contacts...' : _prompt,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                ),
              ),
            ],
            if (_lastHeard.isNotEmpty && !busy) ...[
              const SizedBox(height: 8),
              Text(
                _listening ? 'Heard: "$_lastHeard"' : 'Last heard: "$_lastHeard"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.40),
                  fontSize: 12,
                ),
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(color: Color(0xFFFF6B6B)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccepted() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'CHOSEN (${_accepted.length} of ${SosSetupLimits.maxContacts})',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 10),
        ..._accepted.asMap().entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildAcceptedRow(entry.key + 1, entry.value),
              ),
            ),
      ],
    );
  }

  Widget _buildAcceptedRow(int ordinal, _Accepted contact) {
    return Semantics(
      label: '$ordinal. ${contact.spoken()}.',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: AppTheme.primary.withValues(alpha: 0.10),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.30),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$ordinal',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${contact.relationship} - ends ${contact.tail} - '
                      'priority ${SosSetupLimits.ordinal(contact.priority)}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (contact.priority == 1)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: AppTheme.accent.withValues(alpha: 0.18),
                  ),
                  child: const Text(
                    'FIRST',
                    style: TextStyle(
                      color: AppTheme.accent,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The ranked head of the contact list, so the screen shows exactly what the
  /// app ranked and why.
  Widget _buildSuggestions() {
    if (_step == _Step.blocked || _step == _Step.done) {
      return const SizedBox.shrink();
    }

    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'WHO YOU CALL MOST',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 10),
        ...suggestions.asMap().entries.map(
              (entry) => _buildSuggestionRow(entry.key + 1, entry.value),
            ),
      ],
    );
  }

  Widget _buildSuggestionRow(int ordinal, DeviceContact contact) {
    final isCurrent = _step == _Step.proposing && contact == _candidate;

    return Semantics(
      button: true,
      selected: isCurrent,
      label: 'Option $ordinal, ${contact.name}',
      hint: isCurrent
          ? 'Currently suggested. Say yes to add this contact'
          : 'Say the number $ordinal to add this contact',
      child: ExcludeSemantics(
        child: Material(
          color: isCurrent
              ? AppTheme.accent.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => unawaited(_accept(contact)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '$ordinal',
                      style: TextStyle(
                        color: isCurrent
                            ? AppTheme.accent
                            : Colors.white.withValues(alpha: 0.5),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          contact.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _rankedByCalls && contact.hasCallHistory
                              ? '${contact.spokenCallCount} - ends '
                                  '${contact.tail}'
                              : 'ends ${contact.tail}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCurrent)
                    const Icon(
                      Icons.volume_up_rounded,
                      color: AppTheme.accent,
                      size: 20,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final busy = _step == _Step.saving;
    final done = _step == _Step.done;
    final interactive = !busy && !done && _step != _Step.loading;

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
      decoration: BoxDecoration(
        color: AppTheme.background,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (interactive)
            Row(
              children: [
                Expanded(child: _buildMicButton()),
                const SizedBox(width: 12),
                Expanded(child: _buildRepeatButton()),
              ],
            ),
          if (_step == _Step.review) ...[
            const SizedBox(height: 12),
            _buildSaveButton(),
          ],
          if (_step == _Step.blocked) ...[
            const SizedBox(height: 12),
            _buildRetryButton(),
          ],
          if (!done) const SizedBox(height: 12),
          _buildSkipButton(),
        ],
      ),
    );
  }

  /// The microphone, as a full-width control rather than a status icon.
  Widget _buildMicButton() {
    final live = _listening && _micHealthy;

    return _button(
      label: live ? 'LISTENING' : 'TAP TO SPEAK',
      icon: live ? Icons.stop_rounded : Icons.mic_rounded,
      color: live ? AppTheme.primary : AppTheme.accent,
      semanticLabel: live ? 'Stop listening' : 'Start listening',
      semanticHint: live
          ? 'Stops the microphone'
          : 'Opens the microphone so you can say your answer out loud',
      onTap: _toggleListening,
      compact: true,
    );
  }

  Widget _buildRepeatButton() {
    return _button(
      label: 'REPEAT',
      icon: Icons.replay_rounded,
      color: AppTheme.primary,
      semanticLabel: 'Repeat the question',
      semanticHint: 'Speaks the current question again',
      onTap: _repeatPrompt,
      compact: true,
    );
  }

  Widget _buildSaveButton() {
    return _button(
      label: 'SAVE THESE CONTACTS',
      icon: Icons.save_rounded,
      color: const Color(0xFF3BE38B),
      semanticLabel: 'Save these contacts',
      semanticHint: 'Saves your emergency contacts and finishes the setup',
      onTap: _save,
      important: true,
    );
  }

  Widget _buildRetryButton() {
    return _button(
      label: 'TRY AGAIN',
      icon: Icons.refresh_rounded,
      color: AppTheme.primary,
      semanticLabel: 'Try again',
      semanticHint: 'Starts the emergency contact setup over',
      onTap: _restart,
      important: true,
    );
  }

  /// The always-available escape hatch.
  ///
  /// Shown in every state and for the mandatory login-time run too. A wizard a
  /// blind user cannot leave is a trap, and this is the only way out when the
  /// microphone fails - which is exactly when it matters most.
  Widget _buildSkipButton() {
    if (_step == _Step.saving) return const SizedBox.shrink();

    if (_step == _Step.done) {
      return _button(
        label: 'CONTINUE',
        icon: Icons.arrow_forward_rounded,
        color: AppTheme.primary,
        semanticLabel: 'Continue',
        semanticHint: 'Leaves the emergency contact setup',
        onTap: _doneAsync,
        important: true,
      );
    }

    return _button(
      label: 'SKIP THIS SETUP',
      icon: Icons.skip_next_rounded,
      color: Colors.white70,
      semanticLabel: 'Skip this setup',
      semanticHint:
          'Leaves without saving your emergency contacts. You can set them up '
          'later from the dashboard',
      onTap: _leave,
    );
  }

  Future<void> _doneAsync() async => _done();

  /// A large, fully labelled control.
  ///
  /// [semanticLabel] and [semanticHint] are required rather than optional: this
  /// app has no sighted user to fall back on, so a control that reads as
  /// "button" is a control nobody can use.
  Widget _button({
    required String label,
    required IconData icon,
    required Color color,
    required String semanticLabel,
    required String semanticHint,
    required Future<void> Function() onTap,
    bool compact = false,
    bool important = false,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            if (_disposed) return;
            unawaited(onTap());
          },
          child: Container(
            constraints: BoxConstraints(minHeight: important ? 64 : 58),
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: compact ? 14 : 18,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: color.withValues(alpha: important ? 0.22 : 0.12),
              border: Border.all(color: color.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: compact ? 12 : 14,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wizard-wide limits and wording, in one place.
///
/// The same number is enforced by the account service and by the local SOS
/// mirror; stating it once means the spoken "five people" and the code that
/// refuses a sixth can never disagree.
class SosSetupLimits {
  const SosSetupLimits._();

  static const int maxContacts = 5;

  /// Appended to every prompt that could otherwise be a dead end.
  ///
  /// Repeated on every question rather than mentioned once, because a user who
  /// reached this wizard from the login gate has no other way out of it and must
  /// never be left wondering whether there is one.
  static const String skipHintSpoken =
      'Say skip this setup, or tap Skip this setup at the bottom of the '
      'screen, to continue without saving.';

  /// Priority number as a word, so nothing depends on a numeral being read
  /// correctly by the text to speech engine.
  static String ordinal(int value) => switch (value) {
        1 => 'one',
        2 => 'two',
        3 => 'three',
        4 => 'four',
        _ => 'five',
      };
}