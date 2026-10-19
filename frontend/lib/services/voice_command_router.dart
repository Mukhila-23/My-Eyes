import '../core/vision_mode.dart';

/// Centralized, deterministic intent router for My Eyes.
///
/// Moves all natural-language command matching out of the dashboard and
/// individual screens into one place so a blind user can speak naturally
/// ("what is this?", "can you read this?") and the correct module is chosen
/// with a confidence level. AI Help and Navigation are classified here but
/// do NOT drive the vision modules â€” only explicit phrases route to them.
enum VoiceIntent {
  readText,
  medicine,
  currency,
  product,
  object,
  scene,
  navigation,
  aiHelp,
  sos,
  emergencyContacts,
  payment,
  history,

  /// "change companion" / "switch companion".
  changeCompanion,

  /// "repeat instructions" / "instructions" - the spoken dashboard guide.
  /// "repeat instructions" / "instructions" / "guide me" - the static spoken
  /// dashboard guide.
  ///
  /// Matched BEFORE [repeat], so "repeat instructions" plays the guide rather
  /// than re-saying the previous answer.
  instructions,

  /// "SOS instructions" / "how does SOS work" - the SOS-only guide.
  ///
  /// Matched BEFORE [sos], so asking about SOS is never treated as a trigger.
  sosInstructions,

  help,
  stop,
  repeat,
  goBack,
  unknown,
}

/// Confidence of an intent classification.
enum IntentConfidence { high, medium, low }

/// Outcome of [VoiceCommandRouter.route].
class RoutedCommand {
  const RoutedCommand({
    required this.intent,
    required this.confidence,
    this.target,
    this.historyModule,
    required this.raw,
  });

  final VoiceIntent intent;
  final IntentConfidence confidence;

  /// Contextual argument (object name for objectFinder, destination for
  /// navigation, etc.).
  final String? target;

  /// Set only for [VoiceIntent.history] when the spoken phrase names a module
  /// ("currency history"). Separate from [target] because it is a resolved
  /// module identity, not free text.
  final VisionMode? historyModule;

  /// The normalized spoken phrase. Passed to the module that opens so it can
  /// act on the request immediately instead of re-listening from scratch.
  final String raw;

  bool get isUnknown => intent == VoiceIntent.unknown;
}

class VoiceCommandRouter {
  VoiceCommandRouter._();

  // ------------------------------------------------------------
  // ENTRY POINT
  // ------------------------------------------------------------

  /// Normalizes and classifies a spoken transcript into an intent.
  ///
  /// This is the single central command router. It always returns an intent
  /// plus the normalized phrase so the dashboard can open exactly one module
  /// and hand it the request. AI Help and Navigation are never merged: they
  /// are chosen by mutually-exclusive matchers below and dispatch to their
  /// own dedicated screens.
  static RoutedCommand route(String raw) {
    final text = normalize(raw);
    if (text.isEmpty) {
      return const RoutedCommand(
        intent: VoiceIntent.unknown,
        confidence: IntentConfidence.low,
        raw: '',
      );
    }
    return _classify(text);
  }

  /// Deterministic matcher chain. Extracted from [route] so the single
  /// classification log line covers every outcome.
  /// Deterministic matcher chain, kept separate from [route] so `route` stays
  /// a thin normalize-then-classify wrapper over pure Dart.
  static RoutedCommand _classify(String text) {
    // Contacts management must be classified BEFORE SOS below, otherwise the
    // bare 'emergency' keyword inside "open emergency contacts" would be
    // mistaken for an SOS trigger.
    if (_isEmergencyContacts(text)) {
      return RoutedCommand(
        intent: VoiceIntent.emergencyContacts,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // Safety-critical: SOS must be robust and unambiguous.
    if (_isSos(text)) {
      return RoutedCommand(
        intent: VoiceIntent.sos,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // Voice-based UPI QR payment ("scan payment", "pay by QR", "upi
    // payment"). Kept early so the payment screen opens before any vision or
    // AI classification for payment phrases.
    if (_isPayment(text)) {
      return RoutedCommand(
        intent: VoiceIntent.payment,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    if (_isStop(text)) {
      return RoutedCommand(
        intent: VoiceIntent.stop,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    if (_isGoBack(text)) {
      return RoutedCommand(
        intent: VoiceIntent.goBack,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // "SOS instructions" is checked BEFORE _isRepeat because "SOS
    // instructions" also matches the repeat matcher on its leading word, and
    // an SOS question must never re-say the previous answer.
    if (_isSosInstructions(text)) {
      return RoutedCommand(
        intent: VoiceIntent.sosInstructions,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // The full spoken guide ("repeat instructions", "instructions",
    // "guide me"). Checked before help so the static guide wins over the AI
    // assistant for these explicit phrases.
    // Same ordering reason as above: "repeat instructions" would otherwise be
    // swallowed by _isRepeat and only echo the previous answer.
    if (_isInstructions(text)) {
      return RoutedCommand(
        intent: VoiceIntent.instructions,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // Bare "repeat" re-says the previous answer. Kept here, after the two
    // instruction matchers above, so the guide always wins.
    if (_isRepeat(text)) {
      return RoutedCommand(
        intent: VoiceIntent.repeat,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    if (_isHelp(text)) {
      return RoutedCommand(
        intent: VoiceIntent.help,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // Explicit "open AI Help" command (no question attached -> open the
    // assistant and let it ask what the user needs).
    if (_isAiHelp(text)) {
      return RoutedCommand(
        intent: VoiceIntent.aiHelp,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    // Companion switch. After help and AI so "how do I change companion"
    // would be an AI question, while the direct "change companion" routes.
    if (_isChangeCompanion(text)) {
      return RoutedCommand(
        intent: VoiceIntent.changeCompanion,
        confidence: IntentConfidence.high,
        raw: text,
      );
    }

    if (_isHistory(text)) {
      return RoutedCommand(
        intent: VoiceIntent.history,
        confidence: IntentConfidence.high,
        // A module named in the phrase ("currency history") lets the dashboard
        // open that module's history directly instead of asking which one.
        historyModule: _extractHistoryModule(text),
        raw: text,
      );
    }

    // Navigation: "take me to X", "find nearest hospital", "where am I?".
    final navigation = _matchNavigation(text);
    if (navigation != null) {
      return RoutedCommand(
        intent: VoiceIntent.navigation,
        confidence: navigation.confidence,
        target: navigation.target,
        raw: text,
      );
    }

    // Vision modules: object, read text, medicine, product, currency, scene.
    final vision = _matchVision(text);
    if (vision != null) {
      return RoutedCommand(
        intent: vision.intent,
        confidence: vision.confidence,
        target: vision.target,
        raw: text,
      );
    }

    // General spoken AI question ("what is X", "explain X", "tell me about
    // X"). Kept after navigation and vision so those always win when the
    // phrase is actually a command.
    if (_matchAiQuestion(text)) {
      return RoutedCommand(
        intent: VoiceIntent.aiHelp,
        confidence: IntentConfidence.high,
        target: text,
        raw: text,
      );
    }

    return const RoutedCommand(
      intent: VoiceIntent.unknown,
      confidence: IntentConfidence.low,
      raw: '',
    );
  }

  /// Lower-cases, trims, collapses whitespace and strips common filler so
  /// later keyword matching is more forgiving.
  static String normalize(String raw) {
    // Apostrophes are deleted rather than turned into spaces.
    //
    // Every keyword matcher is a substring test over the normalized phrase, so
    // the choice decides whether a safety-critical phrase is recognised at all.
    // "i'm in trouble" became "i m in trouble", which matched no SOS keyword:
    // a blind user in distress said the exact right words and the app stayed
    // silent. Collapsing to "im in trouble" also makes "what's" and "whats"
    // (both emitted by the recognizer) compare equal.
    var t = raw
        .toLowerCase()
        .replaceAll(RegExp("['\u2019]"), '')
        .replaceAll(RegExp(r'[^\w\s@+.]'), ' ') // drop punctuation
        .trim();

    const fillers = [
      'can you',
      'could you',
      'please',
      'would you',
      'will you',
      'i need you to',
      'i want you to',
      'can i',
      'could i',
      'do you think you can',
      'hey',
      'ok',
      'okay',
    ];
    for (final f in fillers) {
      // Word-boundary replacement, not a bare replaceAll. The old bare
      // substring strip silently corrupted any word containing a filler:
      // "book" -> "bo", "look" -> "lo", "broken" -> "br en", and an email-like
      // "ram@ok.com" -> "ram@ .com". Because these replacements feed substring
      // matchers, a corrupted word quietly stopped matching its module - a
      // navigation request for a "library" or a scan of a "book" would fail
      // with no visible error.
      t = t.replaceAllMapped(RegExp('\\b${RegExp.escape(f)}\\b'), (_) => ' ');
    }

    // Spelled-out letters: "activate s o s" and "activate sos" are the same
    // request, and only the second contains the substring the safety matcher
    // looks for. Collapsing this means a command is never ignored because the
    // recognizer heard an acronym as separate words - the single most
    // dangerous way for a command to be missed.
    t = t
        .replaceAll(RegExp(r'\bs\s+o\s+s\b'), 'sos')
        .replaceAll(RegExp(r'\ba\s+i\b'), 'ai');

    // Articles. A recognizer inserts them constantly, and every keyword matcher
    // is a substring test: "read the page" and "read page" have to compare
    // equal. Dropping "the"/"a"/"an" lets one keyword list cover both phrasings
    // instead of doubling every entry.
    t = t.replaceAll(RegExp(r'\b(?:the|a|an)\b'), ' ');

    // Collapse whitespace.
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// Short spoken hint for low/unknown-confidence commands.
  static const String unknownHint =
      "I didn't understand. Say read this, what is this, "
      'navigate somewhere, or ask AI.';

  static String spokenNameFor(VoiceIntent intent, {String? target}) {
    switch (intent) {
      case VoiceIntent.readText:
        return 'read the text';
      case VoiceIntent.medicine:
        return 'identify the medicine';
      case VoiceIntent.currency:
        return 'check the currency';
      case VoiceIntent.product:
        return 'read the product';
      case VoiceIntent.object:
        return 'identify the object';
      case VoiceIntent.scene:
        return 'describe the surroundings';
      case VoiceIntent.navigation:
        return target == null || target.isEmpty
            ? 'navigate'
            : 'navigate to $target';
      case VoiceIntent.aiHelp:
        return 'AI Help';
      case VoiceIntent.sos:
        return 'SOS';
      case VoiceIntent.emergencyContacts:
        return 'emergency contacts';
      case VoiceIntent.payment:
        return 'scan payment';
      case VoiceIntent.history:
        return 'history';
      case VoiceIntent.changeCompanion:
        return 'change companion';
      case VoiceIntent.instructions:
        return 'repeat instructions';
      case VoiceIntent.sosInstructions:
        return 'SOS instructions';
      case VoiceIntent.help:
        return 'help';
      case VoiceIntent.stop:
        return 'stop';
      case VoiceIntent.repeat:
        return 'repeat';
      case VoiceIntent.goBack:
        return 'go back';
      case VoiceIntent.unknown:
        return '';
    }
  }

  /// Maps an intent to the existing [VisionMode] used by the scanner, or
  /// null when the intent is not a camera vision module.
  static VisionMode? visionModeFor(VoiceIntent intent) {
    switch (intent) {
      case VoiceIntent.readText:
        return VisionMode.readText;
      case VoiceIntent.medicine:
        return VisionMode.medicine;
      case VoiceIntent.currency:
        return VisionMode.currency;
      case VoiceIntent.product:
        return VisionMode.product;
      case VoiceIntent.object:
        return VisionMode.scanObject;
      case VoiceIntent.scene:
        return VisionMode.scene;
      default:
        return null;
    }
  }

  // ------------------------------------------------------------
  // DETERMINISTIC MATCHERS
  // ------------------------------------------------------------

  /// Phrasings of the form "help me VERB ...", where the help requested is a
  /// routine task rather than assistance or an emergency.
  ///
  /// These are the requests a blind user says constantly - "help me find my
  /// keys", "help me read this label". They must reach the module, not the
  /// help screen and never the SOS alert, because a false alarm trains the user
  /// to distrust the real one.
  static const List<String> _helpWithATask = [
    'help me find',
    'help me locate',
    'help me search',
    'help me look',
    'help me identify',
    'help me read',
    'help me see',
    'help me scan',
    'help me check',
  ];

  static bool _isSos(String t) {
    // A contacts-management phrase must never be read as an SOS trigger,
    // even though it contains the word "emergency".
    if (_isEmergencyContacts(t)) return false;

    // Nor may a question ABOUT SOS be one. "how does SOS work" is an
    // instruction request; only an imperative triggers the alert.
    if (_isSosInstructions(t)) return false;

    // "Help me find my keys" is an Object Finder request, not an emergency.
    // The generic "help me" phrase used to fire the alert for it.
    if (_isHelpWithATask(t)) return false;

    const phrases = [
      'sos',
      'emergency',
      'i need emergency help',
      'i need help',
      'im in trouble',
      'i am in trouble',
      'help me',
      'help me now',
      'call for help',
      'send emergency',
      'send sos',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isHelpWithATask(String t) {
    for (final p in _helpWithATask) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isStop(String t) {
    const phrases = [
      'stop listening',
      'stop talking',
      'be quiet',
      'shut up',
      'silence',
      'stop now',
      'quiet',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }

    // A standalone "stop" is a stop-intent only when it is the dominant word
    // (not "stop at the hospital" from navigation).
    if (t == 'stop' || t.startsWith('stop ')) return true;
    return false;
  }

  static bool _isGoBack(String t) {
    const phrases = [
      'go back',
      'take me back',
      'bring me back',
      'back to dashboard',
      'back to home',
      'dashboard',
      'main menu',
      'close this',
      'cancel this',
      'exit',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isRepeat(String t) {
    const phrases = [
      'repeat',
      'say again',
      'say that again',
      'what did you say',
      'once more',
      'pardon',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isHelp(String t) {
    // "help me find my keys" is a task request, not a request for the help
    // screen. Without this it was swallowed here and never reached Object
    // Finder - and it had already been rejected by the SOS matcher.
    if (_isHelpWithATask(t)) return false;

    const phrases = [
      'help',
      'what can i say',
      'what can you do',
      'commands',
      'options',
      'how do i use this',
      'how do i use my eyes',
      'how can i use my eyes',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  /// Matches "repeat instructions", "instructions", "guide me", "show me the
  /// instructions" - the static spoken dashboard guide, NOT the AI assistant.
  ///
  /// "help" and "instructions" were removed from [_isHelp] and now live here,
  /// so "instructions" reaches the real guide instead of the AI screen.
  static bool _isInstructions(String t) {
    const phrases = [
      'repeat instructions',
      'instructions again',
      'play instructions',
      'show instructions',
      'give me instructions',
      'instructions',
      'guide me',
      'show me guide',
      'explain app',
      'what are modules',
      'what modules are there',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  /// Matches the SOS-only guide: "SOS instructions", "how does SOS work",
  /// "how do I activate SOS".
  static bool _isSosInstructions(String t) {
    if (!t.contains('sos') && !t.contains('s o s')) return false;
    const phrases = [
      'sos instruction',
      'sos instructions',
      'instructions for sos',
      'how does sos work',
      'how do i activate sos',
      'how to activate sos',
      'how do i use sos',
      'how to use sos',
      'explain sos',
      'about sos',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  /// Matches the companion switch without swallowing AI questions about it:
  /// "how do I change the companion" is a question (handled earlier by
  /// _matchAiQuestion), "change companion" is a command.
  static bool _isChangeCompanion(String t) {
    if (t.startsWith('how') ||
        t.startsWith('what') ||
        t.startsWith('why') ||
        t.startsWith('who')) {
      return false;
    }
    if (t.contains('cancel') || t.startsWith('stop ')) return false;

    const phrases = [
      'change companion',
      'switch companion',
      'change my companion',
      'switch my companion',
      'change voice',
      'switch voice',
      'use maya',
      'use alex',
      'switch to maya',
      'switch to alex',
      'change to maya',
      'change to alex',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  /// Extracts a module named in a history request.
  ///
  /// "currency history" -> VisionMode.currency. Lets the dashboard open a
  /// specific module's history in one command; anything unrecognised returns
  /// null and the dashboard asks which module.
  static VisionMode? _extractHistoryModule(String t) {
    if (!_matches(t, 'history')) return null;

    // Whole-word matching here, not a bare substring: "medicine history" must
    // resolve to the Medicine module, while "shelf history" must not be pulled
    // in by the "f" inside some unrelated word. It also means the plural and
    // inflected forms ("medicines", "scenes") resolve without extra entries.
    if (_matches(t, 'currency') ||
        _matches(t, 'note detector') ||
        _matches(t, 'money') ||
        _matches(t, 'rupee') ||
        _matches(t, 'cash')) {
      return VisionMode.currency;
    }
    if (_matches(t, 'medicine') ||
        _matches(t, 'tablet') ||
        _matches(t, 'pill') ||
        _matches(t, 'medication')) {
      return VisionMode.medicine;
    }
    if (_matches(t, 'product') || _matches(t, 'packaged')) {
      return VisionMode.product;
    }
    if (_matches(t, 'scene') || _matches(t, 'surrounding')) {
      return VisionMode.scene;
    }
    if (_matches(t, 'object') || _matches(t, 'find')) {
      return VisionMode.scanObject;
    }
    if (_matches(t, 'read') || _matches(t, 'text') || _matches(t, 'ocr')) {
      return VisionMode.readText;
    }
    return null;
  }

  static bool _isEmergencyContacts(String t) {
    const phrases = [
      'emergency contacts',
      'manage contacts',
      'my contacts',
      'add contacts',
      'manage emergency',
      'edit contacts',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isPayment(String t) {
    // Questions about how to pay should be answered, not routed to the live
    // payment scanner.
    if (t.startsWith('how') ||
        t.startsWith('what is') ||
        t.startsWith('what are') ||
        t.startsWith('why') ||
        t.startsWith('where can i') ||
        t.contains('how do i') ||
        t.contains('how to make')) {
      return false;
    }
    // "stop payment" / "cancel payment" are not starts of a new payment.
    if (t.startsWith('stop ') ||
        t.contains('cancel payment') ||
        t.contains('stop payment')) {
      return false;
    }

    const phrases = [
      'scan payment',
      'scan and pay',
      'pay by qr',
      'pay with qr',
      'upi payment',
      'upi pay',
      'qr payment',
      'scan qr',
      'scan qr code',
      'make payment',
      'do payment',
      'start payment',
      'payment',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isAiHelp(String t) {
    const phrases = [
      'ai help',
      'ask ai',
      'open ai',
      'start ai help',
      'ask assistant',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }
    return false;
  }

  static bool _isHistory(String t) {
    // "past results" and "recent scans" without the word "history" are the
    // only non-literal forms; a bare "history" must now match too, because
    // that is the exact command a module's History button answers to.
    const phrases = [
      'show history',
      'my history',
      'open history',
      'recent scans',
      'past results',
    ];
    for (final p in phrases) {
      if (t.contains(p)) return true;
    }

    // A bare "history" (or "read history", "view history", "history please")
    // is the primary command. Guarded so "instructions" and other words that
    // merely contain "hist" cannot be swallowed.
    return t == 'history' ||
        t.endsWith(' history') ||
        t.startsWith('history ') ||
        t.contains(' history ');
  }

  /// Matches a "use the camera" answer during the camera-or-file prompt.
  static bool isCameraSource(String t) {
    if (t.contains('camera')) return true;
    return _containsAny(t, [
      'take photo',
      'take picture',
      'snap photo',
      'click photo',
      'use camera',
    ]);
  }

  /// Matches a "choose a file" answer during the camera-or-file prompt.
  static bool isFileSource(String t) {
    return _containsAny(t, [
          'choose file',
          'use file',
          'pick file',
          'select file',
          'open file',
          'choose image',
          'choose image file',
          'from gallery',
          'from my files',
          'from files',
          'upload file',
        ]) ||
        t == 'file' ||
        t == 'files' ||
        t == 'gallery';
  }

  // ------------------------------------------------------------
  // NAVIGATION
  // ------------------------------------------------------------

  /// Places a user can ask to be taken to, or ask where they are.
  ///
  /// Hoisted to class scope because both navigation and Object Finder have to
  /// agree on what a "place" is: without that agreement "where is the bus
  /// stop" opened the object camera, because Object Finder treats "where is"
  /// as a search verb and had no idea the target was a place.
  static const List<String> _placeKeywords = [
    'hospital',
    'clinic',
    'pharmacy',
    'chemist',
    'store',
    'shop',
    'college',
    'school',
    'university',
    'station',
    'airport',
    'mall',
    'bank',
    'atm',
    'restaurant',
    'cafe',
    'coffee',
    'hotel',
    'park',
    'home',
    'police station',
    'bus stop',
    'theater',
    'theatre',
  ];

  static _NavigationMatch? _matchNavigation(String t) {
    // "Where am I?" / "What is my location?" -> the navigation/location module
    // reads the device GPS and reports the current place.
    if (_isWhereClause(t)) {
      return _NavigationMatch(confidence: IntentConfidence.high, target: t);
    }

    final mentionsPlace = _placeKeywords.any(t.contains);

    // "Where is the bus stop?", "which hospital is nearest?" - a question that
    // names a *place* is navigation, however it is phrased. Without this it
    // was read as an Object Finder search and opened the object camera on a
    // word the user never meant to photograph.
    if (mentionsPlace &&
        _containsAny(t, [
          'where',
          'nearest',
          'closest',
          'direction',
          'locate',
        ])) {
      return _NavigationMatch(
        confidence: IntentConfidence.high,
        target: _extractDestination(t),
      );
    }

    final isNavVerb =
        _containsAny(t, [
          'navigate',
          'take me',
          'take us',
          'go to',
          'go back to',
          'directions',
          'route to',
          'walk to',
          'drive to',
          'head to',
        ]) ||
        _containsAny(t, ['nearest', 'closest', 'find nearest', 'find']);

    if (!isNavVerb) return null;

    if (!mentionsPlace) {
      // "find my wallet", "help me find my keys" - the target is an object, so
      // this is an Object Finder search. Testing the extracted target rather
      // than only a leading "find" catches the same request behind a polite
      // opening, which is how blind users phrase it.
      if (_extractObjectTarget(t) != null) return null;
      if (t.startsWith('find ')) return null;
    }

    final destination = _extractDestination(t);
    return _NavigationMatch(
      confidence: mentionsPlace || destination == null
          ? IntentConfidence.high
          : IntentConfidence.medium,
      target: destination,
    );
  }

  static String? _extractDestination(String t) {
    final patterns = [
      RegExp(
        r'(?:take me(?:\s+to)?|go to|navigate to|directions to|route to|walk to|drive to|head to)\s+(.+)',
      ),
      RegExp(r'(?:nearest|closest)\s+(.+)'),
      RegExp(r'(?:find the nearest|find a)\s+(.+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(t);
      if (m != null) {
        final dest = m.group(1)?.trim();
        if (dest != null && dest.isNotEmpty && dest.length < 60) {
          return dest;
        }
      }
    }
    return null;
  }

  static bool _containsAny(String t, List<String> words) {
    for (final w in words) {
      if (t.contains(w)) return true;
    }
    return false;
  }

  /// "Where am I?" family -> reports current location via navigation/location.
  static bool _isWhereClause(String t) {
    return t.contains('where am i') ||
        t.contains("what is my location") ||
        t.contains("what's my location") ||
        t.contains('tell me where i am') ||
        t.contains('current location') ||
        t.contains('my current location') ||
        t.contains('where are we');
  }

  /// A general spoken question intended for the AI assistant (not a vision or
  /// navigation command). Runs last so explicit commands always win.
  static bool _matchAiQuestion(String t) {
    const questionStarts = [
      'what is ',
      "what's ",
      'what are ',
      'what does ',
      'what do ',
      'what was ',
      'what will ',
      'what can ',
      'why is ',
      'why are ',
      'why do ',
      'why does ',
      'how is ',
      'how do ',
      'how does ',
      'how to ',
      'is it ',
      'can you explain ',
    ];
    for (final s in questionStarts) {
      if (t.startsWith(s) || t.contains(' $s')) return true;
    }

    const actionWords = [
      'explain',
      'define',
      'tell me about',
      'meaning of',
      'what is meaning',
      'what does it mean',
      'about ',
    ];
    for (final w in actionWords) {
      if (t.contains(w)) return true;
    }

    // A question needs a question shape. Without this, the old
    // `t.length >= 6` fallback opened the AI assistant for ANY long
    // utterance - including pure recognition noise such as "asdfgh", which
    // cost a blind user a slow, useless round trip instead of the immediate
    // "say again" hint.
    const followUpStarts = ['who', 'when', 'which', 'whose'];
    for (final s in followUpStarts) {
      if (t.startsWith('$s ')) return true;
    }

    // Ends on a question word, which is how most real questions arrive.
    const questionEnds = ['how', 'why', 'what', 'when', 'where', 'which'];
    return questionEnds.contains(t.split(' ').last);
  }

  // ------------------------------------------------------------
  // VISION MODULES
  // ------------------------------------------------------------

  /// One substring the recognizer might produce for an intent, with the score it
  /// contributes when found.
  ///
  /// Weight encodes how *uniquely* the substring identifies the module:
  ///  * 12-14 - the module's own noun ("medicine", "currency"). Nothing else
  ///             in this app means those.
  ///  *  7-9  - a strong phrase ("what is this", "identify"). Plausible for
  ///             more than one module, so it needs support.
  ///  *  3-5  - a generic word ("note", "read"). Real, but only decisive in
  ///             combination, which is exactly what scoring is for.
  ///
  /// A generic word can therefore never outrank a module-specific noun:
  /// "what is this medicine" scores medicine 14 and the generic object phrase
  /// 8, so medicine wins. Under the previous first-match-wins ordering that same
  /// phrase went to the object detector, because "what is this" was tested
  /// first in the file.

  /// Minimum score before an utterance counts as a module command.
  ///
  /// Anything below this falls through to the AI assistant, which can answer a
  /// real question instead of blindly opening a scanner.
  static const double _minModuleScore = 5;

  /// Scored, substring-based module matching.
  ///
  /// Deliberately *not* ordered first-match-wins. A recognizer produces a
  /// different phrasing on a different day - "scan a medicine", "what is this
  /// medicine", "medicine strip", "read this product" - and with ordered
  /// matching whichever rule happened to be written first won, regardless of
  /// how much of the sentence it actually explained. Scoring counts the
  /// evidence the *whole* utterance gives for each module, so the best-fitting
  /// module is chosen every time.
  ///
  /// Still runs after the safety-critical and unambiguous intents, so SOS,
  /// history, payment and navigation can never be captured by a vision word.
  static _VisionMatch? _matchVision(String t) {
    _VisionMatch? best;
    var bestScore = 0.0;
    var bestCoverage = -1.0;

    final utteranceTokens = _tokens(t);
    final totalTokens = utteranceTokens.length;

    for (final entry in _visionKeywords.entries) {
      var score = 0.0;
      final covered = <int>{};

      for (final keyword in entry.value) {
        final spans = _findSpans(t, keyword.text);
        if (spans.isEmpty) continue;
        score += keyword.weight;
        // Reward a longer match on top of its own weight: a three-word phrase
        // is stronger evidence than its first word alone.
        final words = keyword.text.split(' ').length;
        if (words > 1) score += (words - 1) * 1.5;
        covered.addAll(spans);
      }

      // How much of what the user actually said this module explains. This is
      // the generalisation that keeps working for phrasings nobody wrote down:
      // "what is this medicine strip" explains far more of the sentence for the
      // Medicine module (generic phrase + module noun) than for the object
      // detector (generic phrase only), so Medicine wins without anyone adding
      // that exact sentence to the table.
      final coverage = totalTokens == 0 ? 0.0 : covered.length / totalTokens;

      // Higher score wins. On a near-tie, the module that explains more of the
      // sentence wins - that is what keeps "read this text" on the text reader
      // rather than the generic object detector.
      final isBetter =
          score > bestScore + 0.001 ||
          (score >= bestScore - _coverageTieBand &&
              coverage > bestCoverage + 0.0001);
      if (isBetter) {
        bestScore = score;
        bestCoverage = coverage;
        best = _VisionMatch(entry.key, _confidenceFor(bestScore));
      }
    }

    if (best == null || bestScore < _minModuleScore) return null;

    // Object Finder is the one module that needs a target. If the utterance
    // reads as "find my X", the target is X; otherwise this is plain object
    // identification.
    final target = _extractObjectTarget(t);
    if (best.intent == VoiceIntent.object && target != null) {
      return _VisionMatch(
        VoiceIntent.object,
        IntentConfidence.high,
        target: target,
      );
    }

    return best;
  }

  /// How close two scores must be for coverage to break the tie.
  ///
  /// Deliberately narrow. Coverage is a tiebreaker, not an override: it exists
  /// to separate "what is this" (one generic phrase) from "what is this
  /// medicine" (a generic phrase plus a module-specific noun). With a wide band
  /// it started overruling genuine module nouns, sending "tell me about this
  /// scene" to the object detector because the generic phrase covered more of
  /// the words - even though the scene word is the whole point of the sentence.
  static const double _coverageTieBand = 1.0;

  static IntentConfidence _confidenceFor(double score) {
    if (score >= 12) return IntentConfidence.high;
    if (score >= 8) return IntentConfidence.medium;
    return IntentConfidence.low;
  }

  /// Every substring the recognizer may produce, grouped by intent.
  static const Map<VoiceIntent, List<_Keyword>> _visionKeywords = {
    VoiceIntent.medicine: [
      _Keyword('medicine', 14),
      _Keyword('medicines', 14),
      _Keyword('medication', 14),
      _Keyword('tablet', 12),
      _Keyword('tablets', 12),
      _Keyword('pill', 12),
      _Keyword('pills', 12),
      _Keyword('drug', 12),
      _Keyword('prescription', 12),
      _Keyword('medicine strip', 12),
      _Keyword('medicine name', 12),
      _Keyword('drug name', 11),
      _Keyword('what medicine', 12),
      _Keyword('which medicine', 12),
      _Keyword('identify medicine', 12),
      _Keyword('capsule', 11),
      _Keyword('syrup', 9),
    ],
    VoiceIntent.product: [
      _Keyword('product', 14),
      _Keyword('products', 14),
      _Keyword('packaged food', 13),
      _Keyword('packaged', 11),
      _Keyword('barcode', 12),
      _Keyword('ingredients', 12),
      _Keyword('nutrition', 11),
      _Keyword('food label', 12),
      _Keyword('food details', 12),
      _Keyword('food item', 11),
      _Keyword('grocery', 8),
      _Keyword('packet', 7),
      _Keyword('brand name', 9),
      _Keyword('expiry', 7),
      _Keyword('what product', 12),
    ],
    VoiceIntent.currency: [
      _Keyword('currency', 14),
      _Keyword('banknote', 13),
      _Keyword('bank note', 13),
      _Keyword('money note', 13),
      _Keyword('rupee note', 13),
      _Keyword('currency note', 13),
      _Keyword('rupees', 12),
      _Keyword('rupee', 12),
      _Keyword('cash', 12),
      _Keyword('money', 11),
      _Keyword('denomination', 11),
      _Keyword('how much money', 12),
      _Keyword('dollars', 10),
      _Keyword('dollar', 10),
      _Keyword('pound', 9),
      // A bare "note" is weak on its own and can only win when the money words
      // above reinforce it. That is what stops "take a note" opening a scanner.
      // These are the phrasings where "note" IS the whole subject, so they
      // have to carry the weight themselves once articles are normalised away.
      _Keyword('identify note', 13),
      _Keyword('identify money', 13),
      _Keyword('what note', 11),
      _Keyword('what currency', 13),
      _Keyword('this note', 9),
      _Keyword('that note', 9),
      _Keyword('note in my hand', 12),
      _Keyword('note in hand', 12),
      _Keyword('note', 4),
      _Keyword('notes', 4),
      _Keyword('change', 8),
      _Keyword('coin', 9),
      _Keyword('coins', 9),
      _Keyword('cheque', 8),
    ],
    VoiceIntent.readText: [
      _Keyword('read text', 13),
      _Keyword('read this text', 13),
      _Keyword('text reader', 13),
      _Keyword('read page', 12),
      _Keyword('read document', 12),
      _Keyword('read paper', 12),
      _Keyword('read book', 12),
      _Keyword('read letter', 12),
      _Keyword('read sign', 12),
      _Keyword('read message', 11),
      _Keyword('read label', 11),
      _Keyword('read out', 11),
      _Keyword('read aloud', 12),
      _Keyword('what does this say', 13),
      _Keyword('what is written', 13),
      _Keyword('whats written', 13),
      _Keyword('read whats written', 13),
      _Keyword('ocr', 12),
      _Keyword('document scanner', 12),
      _Keyword('scan text', 12),
      // Natural continuations a blind user reaches for. Because matching is
      // stemmed, "reading"/"scan the text" are covered without listing every
      // inflection, and these phrases carry the weight for the longer forms.
      _Keyword('scan document', 12),
      _Keyword('scan page', 12),
      _Keyword('scan letter', 12),
      _Keyword('text in this', 11),
      _Keyword('written on this', 11),
      _Keyword('printed on this', 11),
      _Keyword('read number', 11),
      _Keyword('read name', 11),
      _Keyword('read address', 11),
      _Keyword('read menu', 11),
      _Keyword('read price', 11),
      // Generic verbs: only decisive alongside a text-ish noun.
      _Keyword('read this', 6),
      _Keyword('read', 3),
      _Keyword('text', 4),
    ],
    VoiceIntent.scene: [
      _Keyword('describe my surroundings', 14),
      _Keyword('describe surroundings', 14),
      _Keyword('describe scene', 14),
      _Keyword('describe place', 13),
      _Keyword('surroundings', 13),
      _Keyword('scene', 13),
      _Keyword('what do you see', 12),
      _Keyword('around me', 11),
      _Keyword('environment', 11),
      _Keyword('whats around', 11),
      _Keyword('place am i', 10),
      _Keyword('surround me', 12),
      _Keyword('look around', 11),
      _Keyword('in front of me', 9),
      _Keyword('describe', 7),
    ],
    VoiceIntent.object: [
      // Object Finder phrasings. Weighted above the generic identification
      // phrases below so "find my phone" is a *search*, not a scan.
      _Keyword('find my', 12),
      _Keyword('locate my', 12),
      _Keyword('where is my', 12),
      _Keyword('where are my', 12),
      _Keyword('search for my', 12),
      _Keyword('lost my', 12),
      _Keyword('help me find', 12),
      _Keyword('can you find', 12),
      _Keyword('find the', 11),
      _Keyword('missing', 8),
      // Plain object identification.
      _Keyword('identify object', 11),
      _Keyword('object detection', 12),
      _Keyword('detect object', 12),
      _Keyword('scan object', 12),
      _Keyword('identify this', 9),
      _Keyword('identify that', 9),
      _Keyword('recognize this', 9),
      _Keyword('tell me what this is', 10),
      _Keyword('what object', 9),
      _Keyword('what is this', 8),
      _Keyword('whats this', 8),
      _Keyword('what is that', 8),
      _Keyword('name this', 8),
      _Keyword('what is in front', 9),
      // Weighted below every module-specific noun on purpose: this phrase is
      // about *any* subject, so it may only win when nothing more specific was
      // said. At a higher weight "tell me about this scene" lost to it.
      _Keyword('tell me about this', 5),
      _Keyword('describe this', 7),
      _Keyword('object', 4),
    ],
  };

  // ------------------------------------------------------------
  // SUBSTRING MATCHING PRIMITIVES
  // ------------------------------------------------------------

  static final RegExp _separator = RegExp(r'[^a-z0-9]+');

  /// Splits text into comparable lowercase word tokens.
  static List<String> _tokens(String text) =>
      text.split(_separator).where((w) => w.isNotEmpty).toList(growable: false);

  /// True when [keyword] appears in [text] as whole words (or as stems of them).
  static bool _matches(String text, String keyword) =>
      _findSpans(text, keyword).isNotEmpty;

  /// Token indices in [text] covered by [keyword], or an empty list.
  ///
  /// This replaces the bare `text.contains(keyword)` test, which was wrong in
  /// both directions:
  ///
  ///   * too generous - the keyword "note" matched "noted", "notebook" and
  ///     "denote", so "find my notebook" scored the Currency module for a word
  ///     that has nothing to do with money;
  ///   * too strict - the keyword "medicine" never matched "medicines", even
  ///     though the plural is what the recognizer emits most often, and
  ///     "read" never matched "reading".
  ///
  /// Matching per token, on word boundaries, and accepting a longer token that
  /// starts with the keyword (stemming), fixes both without hand-writing every
  /// plural into the table. Multi-word keywords additionally require their
  /// tokens to appear in order and adjacent, so "read text" is still only
  /// evidence for the text reader and never for a bare "read" plus an unrelated
  /// "text" later in an unrelated sentence.
  static List<int> _findSpans(String text, String keyword) {
    final haystack = _tokens(text);
    final needle = _tokens(keyword);
    if (needle.isEmpty || haystack.length < needle.length) return const [];

    if (needle.length == 1) {
      final spans = <int>[];
      for (var i = 0; i < haystack.length; i++) {
        if (_tokenMatches(haystack[i], needle.first)) spans.add(i);
      }
      return spans;
    }

    final spans = <int>{};
    for (var start = 0; start + needle.length <= haystack.length; start++) {
      var ok = true;
      for (var i = 0; i < needle.length; i++) {
        if (!_tokenMatches(haystack[start + i], needle[i])) {
          ok = false;
          break;
        }
      }
      if (ok) {
        for (var i = 0; i < needle.length; i++) {
          spans.add(start + i);
        }
      }
    }
    return spans.toList(growable: false);
  }

  /// A token satisfies a keyword token when they are equal, or when the spoken
  /// token merely extends it ("medicine" -> "medicines", "note" -> "notes").
  ///
  /// Only the spoken token may be longer. A keyword may not be a prefix of a
  /// spoken token that happens to start the same way but means something else
  /// ("med" must not swallow "medium").
  static bool _tokenMatches(String token, String keyword) {
    if (token == keyword) return true;
    return token.length > keyword.length && token.startsWith(keyword);
  }

  static String? _extractObjectTarget(String t) {
    // "i lost my pen" is the same request as "find my pen"; the verb just
    // happens to describe what happened rather than what to do.
    const verbs = [
      'find',
      'locate',
      'where is',
      'where are',
      'wheres',
      'wherear',
      'search for',
      'looking for',
      'lost',
      'missing',
    ];
    if (!_containsAny(t, verbs)) {
      return null;
    }

    // Articles are already removed by [normalize], so the optional article in
    // each pattern only has to cover "my".
    final patterns = [
      RegExp(
        r'(?:find|locate|search for|looking for|where is|where are|wheres|wherear)\s+(?:my )?(.+)$',
      ),
      RegExp(r'(?:find|locate)\s+(?:my )?(.+?)(?:\s+please|\s+now)$'),
      RegExp(r'(?:lost|missing)\s+(?:my )?(.+)$'),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(t);
      if (m != null) {
        // Skip if the "target" reads like a place (navigation handled above).
        final candidate = m.group(1)?.trim();
        if (candidate != null &&
            candidate.isNotEmpty &&
            candidate.length < 40) {
          return candidate;
        }
      }
    }
    return null;
  }
}

/// One substring the recognizer might produce for an intent, with the score it
/// contributes when found.
///
/// Weight encodes how *uniquely* the substring identifies the module:
///  * 12-14 - the module's own noun ("medicine", "currency"). Nothing else in
///             this app means those.
///  *  7-9  - a strong phrase ("what is this", "identify"). Plausible for more
///             than one module, so it needs support.
///  *  3-5  - a generic word ("note", "read"). Real, but only decisive in
///             combination, which is exactly what scoring is for.
///
/// A generic word can therefore never outrank a module-specific noun:
/// "what is this medicine" scores medicine 14 against the generic object
/// phrase 8, so medicine wins. Under the previous first-match-wins ordering
/// that same phrase went to the object detector, because "what is this" was
/// tested first in the file.
class _Keyword {
  const _Keyword(this.text, this.weight);

  final String text;
  final double weight;
}

class _VisionMatch {
  const _VisionMatch(this.intent, this.confidence, {this.target});
  final VoiceIntent intent;
  final IntentConfidence confidence;
  final String? target;
}

class _NavigationMatch {
  const _NavigationMatch({required this.confidence, required this.target});
  final IntentConfidence confidence;
  final String? target;
}
