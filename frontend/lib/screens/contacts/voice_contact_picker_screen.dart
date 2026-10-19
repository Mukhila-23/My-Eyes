import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/contact_directory.dart';
import '../../services/contact_matcher.dart';
import '../../services/voice_command_service.dart';

/// Voice-first "choose an emergency contact". Replaces reading a contact list
/// out loud.
///
/// A phone can hold 100 to 500 contacts. Reading them - even four at a time -
/// is not a selection interface: it is a chore, and a blind user has to hold
/// every position in memory to go back to one. So the app proposes instead.
///
/// The proposal is the person the user calls most, drawn from the device call
/// log and spoken with its frequency attached ("Arun Kumar, called 42 times"),
/// because a count is something the user can actually verify - and it makes a
/// wrong guess obvious immediately.
///
/// The user is never trapped in the proposal:
///   "yes"                      take the suggestion
///   "alternative"              hear the next most-called person
///   "1".."5"                   take that one from the shortlist
///   "Maya" / "9 8 7 6"         jump straight to anyone in the full list
///   "who do I call most"       hear the top suggestion again
///   "list"                     hear all five suggestions
///   "cancel"                   leave without choosing
///
/// Name and number matching search the whole contact list instantly, so the
/// other 495 contacts are reachable without a single one of them being read
/// out.
class VoiceContactPickerScreen extends StatefulWidget {
  const VoiceContactPickerScreen({
    super.key,
    required this.title,
    this.excludePhones = const <String>{},
  });

  /// What the user is choosing a contact for, spoken and displayed.
  final String title;

  /// Phone numbers that must not be offered again (already added).
  final Set<String> excludePhones;

  @override
  State<VoiceContactPickerScreen> createState() =>
      _VoiceContactPickerScreenState();
}

class _VoiceContactPickerScreenState extends State<VoiceContactPickerScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  /// Every contact, ranked most-called first.
  List<DeviceContact> _contacts = const [];

  /// How many of [shortlist] came from real call history.
  int _calledCount = 0;

  /// True when the ranking signal was genuine call history.
  bool _rankedByCalls = false;

  /// Why the ranking is unavailable, spoken instead of silently degrading.
  String _rankingNote = '';

  /// Why the list is empty, when it is.
  String _problem = '';

  /// Index into [_contacts] of the contact currently being proposed.
  int _cursor = 0;

  /// True when call history was usable, so the app may claim to know who the
  /// user calls.
  bool _loading = true;

  /// Awaiting spoken confirmation of the proposal in [_pending].
  DeviceContact? _pending;

  /// Contacts whose names matched the user's phrase but were ambiguous.
  List<DeviceContact> _ambiguous = const [];

  String _lastHeard = '';

  /// Ownership token, so a late dispose cannot stop the session that replaced
  /// this screen.
  int? _voiceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _voice.resumeAfterLifecycle();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  DeviceContact? get _proposal {
    if (_cursor < 0 || _cursor >= _contacts.length) return null;
    return _contacts[_cursor];
  }

  /// The ranked contacts, capped at the number of emergency slots.
  List<DeviceContact> get _shortlist =>
      _contacts.take(ContactDirectory.shortlistSize).toList(growable: false);

  Future<void> _start() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      onHeard: (text) {
        if (!mounted) return;
        setState(() => _lastHeard = text);
      },
      autoStart: false,
    );
    if (!mounted) return;

    final result = await ContactDirectory.instance.load();
    if (!mounted) return;

    setState(() {
      _loading = false;
      _contacts = result.contacts
          .where((c) => !widget.excludePhones.contains(c.phone))
          .toList(growable: false);
      _calledCount = _contacts.where((c) => c.hasCallHistory).length;
      _rankedByCalls = result.callHistoryAvailable && _calledCount > 0;
      _rankingNote = result.callHistoryAvailable ? '' : _fallbackNote();
      _problem = result.problem ?? '';
      _cursor = 0;
    });

    await _speakCurrent(justLoaded: true);
  }

  /// Explains the ranking honestly when call history was not available.
  String _fallbackNote() {
    if (_contacts.isEmpty) return '';
    return 'I could not read your call history, so I cannot tell who you call '
        'most. I will suggest names from your contacts, and you can also say '
        'any name directly.';
  }

  /// Speaks [text], then reopens the microphone.
  ///
  /// Always speaks first and opens the mic afterwards. Opening the mic first
  /// makes the recognizer hear this announcement and execute it as a command,
  /// which is how a picker ends up choosing a contact nobody named.
  Future<void> _speakCurrent({bool justLoaded = false}) async {
    if (!mounted) return;

    await _voice.speak(_speechFor(justLoaded: justLoaded), resumeAfter: false);
    if (!mounted) return;

    await _voice.resumeMicrophone();
  }

  String _speechFor({bool justLoaded = false}) {
    if (_loading) return 'Loading your contacts.';

    if (_contacts.isEmpty) {
      // Say *why* the list is empty. "No contacts found" leaves a blind user
      // stuck, because the real cause is usually a permission they can fix.
      return '$_emptyReason Say cancel to go back.';
    }

    final pending = _pending;
    if (pending != null) {
      return 'You chose ${pending.name}, number ${pending.spokenPhone}. '
          'Say yes to confirm, or no to choose someone else.';
    }

    if (_ambiguous.isNotEmpty) {
      final buffer = StringBuffer('More than one contact matches. ');
      for (var i = 0; i < _ambiguous.length && i < 4; i++) {
        buffer.write('${i + 1}: ${_ambiguous[i].name}. ');
      }
      buffer.write('Say the name again, or say cancel.');
      return buffer.toString();
    }

    final proposal = _proposal;
    if (proposal == null) {
      return 'That was everyone in your shortlist. Say a name to choose anyone '
          'else, or say cancel.';
    }

    final buffer = StringBuffer();

    if (justLoaded) {
      buffer.write(widget.title);
      if (_rankedByCalls) {
        buffer.write(
          ' I looked at who you call most. You have $_calledCount contacts '
          'I can rank. Here is the first one.',
        );
      } else if (_rankingNote.isNotEmpty) {
        buffer.write(' $_rankingNote');
      }
    }

    buffer.write('${proposal.name}, number ${proposal.spokenPhone}');

    // The frequency is the checkable part: the user can immediately tell when
    // the app has the wrong person, or has merged two people into one.
    if (_rankedByCalls && proposal.hasCallHistory) {
      buffer.write(', ${proposal.spokenCallCount}');
    } else if (_cursor > 0) {
      buffer.write(', next suggestion');
    }

    buffer.write(
      '. Say yes to choose, say alternative for the next person, '
      'or say any name.',
    );
    return buffer.toString();
  }

  /// Explains why there is nothing to choose from, so a denied permission is
  /// not reported as "you have no contacts".
  String get _emptyReason => _problem.isNotEmpty
      ? _problem
      : 'I could not find any contacts to choose from.';

  Future<void> _handleCommand(String raw) async {
    final phrase =
        VoiceCommandService.stripWakeWords(raw).toLowerCase().trim();
    if (phrase.isEmpty) return;
    if (_loading) return;

    // A pending confirmation wins over everything, so "no" is never mistaken
    // for a contact whose name happens to be "No".
    final pending = _pending;
    if (pending != null) {
      if (ContactMatcher.isAffirmative(phrase)) {
        _confirm(pending);
        return;
      }
      if (ContactMatcher.isNegative(phrase)) {
        setState(() => _pending = null);
        await _speakCurrent();
        return;
      }
      // Anything else during confirmation is treated as a fresh request rather
      // than silently ignored, so the user is never stuck on a question.
    }

    if (ContactMatcher.isCancel(phrase)) {
      await _leave();
      return;
    }

    if (ContactMatcher.isRepeat(phrase)) {
      await _speakCurrent();
      return;
    }

    if (ContactMatcher.isAlternative(phrase)) {
      await _proposeAlternative();
      return;
    }

    if (ContactMatcher.isWhoDoICall(phrase)) {
      await _speakTopCallers();
      return;
    }

    if (_isReadListRequest(phrase)) {
      await _speakShortlist();
      return;
    }

    if (ContactMatcher.isNextPage(phrase)) {
      await _proposeAlternative();
      return;
    }

    await _tryResolve(phrase);
  }

  bool _isReadListRequest(String phrase) =>
      phrase.contains('list') ||
      phrase.contains('everyone') ||
      phrase.contains('all of them') ||
      phrase.contains('all five') ||
      phrase.contains('show me everyone');

  /// Moves to the next ranked suggestion.
  ///
  /// Never wraps and never reads the whole list: once the shortlist is
  /// exhausted it tells the user how to reach anybody else by name, which is
  /// the only way 500 contacts are made navigable.
  Future<void> _proposeAlternative() async {
    final next = _cursor + 1;

    if (next >= _contacts.length) {
      await _voice.speak(
        'That was the last suggestion. You have ${_contacts.length} contacts '
        'on this phone. Say a name to choose anyone else, or say cancel.',
        resumeAfter: false,
      );
      if (!mounted) return;
      await _voice.resumeMicrophone();
      return;
    }

    setState(() {
      _cursor = next;
      _pending = null;
      _ambiguous = const [];
    });
    await _speakCurrent();
  }

  /// Reads the shortlist as a single list, for a user who prefers to hear the
  /// options together.
  Future<void> _speakShortlist() async {
    final buffer = StringBuffer('The people you call most often. ');
    for (var i = 0; i < _shortlist.length; i++) {
      final contact = _shortlist[i];
      final frequency = (_rankedByCalls && contact.hasCallHistory)
          ? ', ${contact.spokenCallCount}'
          : '';
      buffer.write('${i + 1}: ${contact.name}$frequency. ');
    }
    buffer.write('Say a number, or a name. Say alternative for the next one.');

    await _voice.speak(buffer.toString(), resumeAfter: false);
    if (!mounted) return;
    await _voice.resumeMicrophone();
  }

  Future<void> _speakTopCallers() async {
    if (!_rankedByCalls) {
      await _voice.speak(
        'I need access to your call history to know who you call most. '
        'You can still say any name to choose.',
        resumeAfter: false,
      );
      if (!mounted) return;
      await _voice.resumeMicrophone();
      return;
    }

    final top = _contacts.where((c) => c.hasCallHistory).take(3).toList();
    if (top.isEmpty) {
      await _voice.speak(
        'I could not find any calls in your history. Say any name to choose.',
        resumeAfter: false,
      );
      if (!mounted) return;
      await _voice.resumeMicrophone();
      return;
    }

    final buffer = StringBuffer('You call ');
    for (var i = 0; i < top.length; i++) {
      if (i > 0) buffer.write(i == top.length - 1 ? ', and ' : ', ');
      buffer.write('${top[i].name}, ${top[i].spokenCallCount}');
    }
    buffer.write(' most. Say a name, or alternative for another.');

    await _voice.speak(buffer.toString(), resumeAfter: false);
    if (!mounted) return;
    await _voice.resumeMicrophone();
  }

  Future<void> _tryResolve(String phrase) async {
    // An ambiguous phrase narrows to the shortlist rather than failing, so the
    // user can then say "1" or a name.
    if (_ambiguous.isNotEmpty) {
      final narrowed = _resolveIn(_ambiguous, phrase);
      if (narrowed != null) {
        _choose(narrowed);
        return;
      }
    }

    final match = _resolveIn(_contacts, phrase);
    if (match != null) {
      _choose(match);
      return;
    }

    // Collect near-misses so the next announcement can offer them, instead of
    // the bare "not found" dead end a blind user cannot recover from.
    final name = ContactMatcher.nameFromPhrase(phrase);
    if (name.length >= 2) {
      final needle = name.replaceAll(RegExp('[^a-z]'), '');
      final prefix = needle.substring(0, needle.length.clamp(0, 3));
      final candidates = _contacts
          .where((c) => c.name.toLowerCase().replaceAll(RegExp('[^a-z]'), '')
              .startsWith(prefix))
          .take(4)
          .toList();

      if (candidates.isNotEmpty) {
        setState(() => _ambiguous = candidates);
      }
    }

    await _voice.speak(
      'I could not match that to a contact. '
      'You have ${_contacts.length} contacts. Say a name, '
      'say alternative for the next suggestion, or say cancel.',
      resumeAfter: false,
    );
    if (!mounted) return;
    await _speakCurrent();
  }

  /// Resolves against the WHOLE contact list, not the visible few.
  ///
  /// This is what makes 500 contacts navigable: the user names someone
  /// directly and is found instantly, with nothing read out and nothing to
  /// remember.
  DeviceContact? _resolveIn(List<DeviceContact> pool, String phrase) {
    return ContactMatcher.resolve(
      phrase,
      contacts: pool,
      pageOffset: 0,
      pageSize: ContactDirectory.shortlistSize,
    );
  }

  void _choose(DeviceContact contact) {
    setState(() {
      _pending = contact;
      _ambiguous = const [];
    });
    _speakCurrent();
  }

  void _confirm(DeviceContact contact) {
    if (!mounted) return;
    Navigator.of(context).pop(contact);
  }

  Future<void> _leave() async {
    await _voice.stopSpeaking();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _proposalCard(),
              const SizedBox(height: 16),
              Expanded(child: _shortlistView()),
              const SizedBox(height: 16),
              _hint(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _proposalCard() {
    final pending = _pending;
    final proposal = _proposal;
    final showing = pending ?? proposal;
    final color = showing == null ? Colors.white24 : AppTheme.primary;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.4),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pending == null ? 'SUGGESTED' : 'CONFIRM YOUR CHOICE',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _loading
                ? 'Loading your contacts...'
                : showing == null
                    ? 'No suggestion available'
                    : '${showing.name}\n${showing.spokenPhone}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (showing != null &&
              _rankedByCalls &&
              showing.hasCallHistory &&
              pending == null) ...[
            const SizedBox(height: 6),
            Text(
              showing.spokenCallCount,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shortlistView() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    if (_contacts.isEmpty) {
      return const Center(
        child: Text(
          'No contacts to choose from.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    final shown = _ambiguous.isNotEmpty ? _ambiguous : _shortlist;

    return ListView.separated(
      itemCount: shown.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final contact = shown[index];
        final isProposal = _ambiguous.isEmpty && contact == _proposal;

        return Semantics(
          button: true,
          selected: isProposal,
          label: 'Option ${index + 1}, ${contact.name}',
          hint: isProposal
              ? 'Currently suggested. Number ${contact.spokenPhone}'
              : 'Number ${contact.spokenPhone}',
          child: Material(
            color: isProposal
                ? AppTheme.primary.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _choose(contact),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          AppTheme.primary.withValues(alpha: 0.25),
                      child: Text(
                        contact.initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
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
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            contact.spokenPhone,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                              letterSpacing: 1.1,
                            ),
                          ),
                          if (_rankedByCalls && contact.hasCallHistory)
                            Text(
                              contact.spokenCallCount,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (isProposal)
                      const Icon(
                        Icons.volume_up_rounded,
                        color: AppTheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _hint() {
    return Column(
      children: [
        Text(
          _lastHeard.isEmpty ? 'Listening...' : 'Heard: "$_lastHeard"',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white38, fontSize: 13),
        ),
        const SizedBox(height: 6),
      const Text(
        'Say yes, alternative, a name, or cancel',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white30, fontSize: 12),
      ),
    ],
  );
  }
}
