import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/theme/app_theme.dart';
import '../../services/navigation_service.dart';
import '../../services/voice_command_service.dart';
import '../sos/sos_screen.dart';

/// Explicit states of the voice-first navigation flow.
enum _NavPhase {
  idle,
  listening,
  searching,
  confirming,
  navigating,
  rerouting,
  arrived,
}

/// SMART NAVIGATION - a true voice-first navigation system for blind users.
///
/// The user controls everything by voice and listens for spoken turn-by-turn
/// guidance. There is deliberately no map widget and no map SDK: the screen
/// shows large, high-contrast text for the next instruction, distance and time,
/// while the authoritative feedback is speech.
class NavigationScreen extends StatefulWidget {
  /// Optional command phrase handed over from the central router (e.g.
  /// "take me to PSG college", "where am I", "find the nearest hospital").
  final String? initialCommand;

  const NavigationScreen({super.key, this.initialCommand});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  // ---- tuning ----
  //
  // Every threshold below is widened by the reported GPS accuracy, so a
  // coarse indoor fix cannot trigger a reroute or a false arrival.
  static const double _earlyGuidanceM = 120; // announce a turn this far out
  static const double _nearGuidanceM = 35; // drop the "in X metres" prefix
  static const double _baseArrivalRadiusM = 25;
  static const double _baseOffRouteM = 45;
  static const int _requiredArrivalFixes = 3;
  static const int _requiredOffRouteFixes = 3;
  static const Duration _rerouteCooldown = Duration(seconds: 45);

  _NavPhase _phase = _NavPhase.idle;

  /// True while a spoken command is executing. Guarded with try/finally so it
  /// can never wedge the microphone off.
  bool _commandBusy = false;

  Position? _position;

  // Pending destination awaiting confirmation.
  List<_DestCandidate> _candidates = [];
  String _pendingLabel = '';

  // Active navigation.
  NavDirections? _route;
  RouteTrack? _track;
  NavTravelMode _mode = NavTravelMode.walking;
  String _spokenDestination = '';

  /// Highest step index already spoken, so no instruction repeats.
  int _announcedStep = -1;
  String _lastSpoken = '';

  /// Ownership token for this screen's voice session, so a late `dispose()`
  /// cannot stop the dashboard session that replaced it.
  int? _voiceSession;

  StreamSubscription<Position>? _navSub;

  // Live guidance values for the UI.
  double _alongRouteM = 0;
  double _remainingM = 0;
  double _distanceToRouteM = 0;
  String _nextInstruction = '';
  double _nextManeuverM = 0;

  // Debounce counters.
  int _arrivalStreak = 0;
  int _offRouteStreak = 0;
  bool _rerouteLock = false;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  List<NavSavedPlace> _savedPlaces = [];

  /// These common categories remain usable when the backend category lookup
  /// is slow or temporarily unavailable. The actual place search is still
  /// performed by the backend; this only prevents the voice command from
  /// being rejected before that search gets a chance to run.
  static const List<String> _fallbackCategories = <String>[
    'hospital',
    'pharmacy',
    'police',
    'bus stop',
    'railway station',
    'bank',
    'atm',
    'restaurant',
    'petrol station',
    'toilet',
  ];
  List<String> _categories = _fallbackCategories;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopNavStream();
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _voice.resumeAfterLifecycle();
    } else {
      _voice.pauseForLifecycle();
    }
  }

  // ================================================================
  // START
  // ================================================================

  Future<void> _start() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      onHeard: (_) {},
      // Register the handler before the microphone opens. The network-backed
      // data below is deliberately loaded in the background, so navigation is
      // ready to hear its first command immediately.
      autoStart: false,
    );
    if (!mounted) return;

    // Never keep the user waiting silently for network-backed convenience
    // data. The fallback categories above already make common spoken commands
    // actionable, and saved places can arrive while the first command is being
    // heard.
    unawaited(_loadNavigationData());

    final initial = widget.initialCommand;
    if (initial != null && initial.trim().isNotEmpty) {
      setState(() => _phase = _NavPhase.listening);
      await _handleCommand(initial);
      return;
    }

    setState(() => _phase = _NavPhase.listening);
    await _voice.speak(
      'Navigation ready. Say a destination, say where am I, '
      'or say find the nearest hospital.',
    );
    await _restoreNavigationListening();
  }

  Future<List<NavSavedPlace>> _loadSavedPlaces() async {
    try {
      return await NavigationService.getSavedPlaces();
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _loadCategories() async {
    try {
      return await NavigationService.categories();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadNavigationData() async {
    final loaded = await Future.wait([_loadSavedPlaces(), _loadCategories()]);
    if (!mounted || !_voice.ownsSession(_voiceSession)) return;
    _savedPlaces = loaded[0] as List<NavSavedPlace>;
    final serverCategories = loaded[1] as List<String>;
    if (serverCategories.isNotEmpty) _categories = serverCategories;
  }

  // ================================================================
  // VOICE COMMAND DISPATCH
  // ================================================================

  Future<void> _handleCommand(String raw) async {
    final t = VoiceCommandService.stripWakeWords(raw);
    if (t.isEmpty || _commandBusy) return;
    debugPrint('[ROUTER] NAV command: $t');

    _commandBusy = true;
    try {
      await _dispatch(t);
    } catch (e) {
      debugPrint('[ROUTER] NAV command failed: $e');
      if (mounted && e is NavigationException) {
        await _voice.speak(e.message);
      }
    } finally {
      // Always released: a stuck microphone is worse than a repeated command.
      _commandBusy = false;
      await _restoreNavigationListening();
    }
  }

  /// The shared recognizer is intentionally closed as soon as it captures a
  /// command. Navigation owns the next turn, so it must explicitly reclaim
  /// it after every awaited response. This guard prevents a late callback from
  /// reviving the mic after this route has exited or another route took over.
  Future<void> _restoreNavigationListening() async {
    if (!mounted || !_voice.ownsSession(_voiceSession)) return;
    if (_phase == _NavPhase.idle || _voice.isSpeaking) return;
    await _voice.resumeMicrophone();
  }

  Future<void> _dispatch(String t) async {
    final lower = t.toLowerCase();

    // SOS always takes priority.
    if (_isSos(lower)) return _handleSos();
    if (_isExit(lower)) return _exit();

    // Arrival confirmation: "yes" ends navigation, "no" keeps it running.
    if (_phase == _NavPhase.arrived && !_isFreeText(lower)) {
      return _handleArrivalReply(lower);
    }

    // During destination confirmation, yes/no/first/second/cancel.
    if (_phase == _NavPhase.confirming && !_isFreeText(lower)) {
      return _handleConfirmation(lower);
    }

    // During active navigation, nav-control commands.
    if (_phase == _NavPhase.navigating || _phase == _NavPhase.arrived) {
      if (await _handleNavControl(lower)) return;
    }

    if (_isWhereAmI(lower)) return _whereAmI();
    if (_isChangeMode(lower)) return _changeMode(lower);
    if (_isRepeat(lower)) return _repeat();
    if (_isFindNearest(lower)) return _findNearest(lower);
    if (_isSavePlace(lower)) return _savePlace(lower);
    if (_isDeleteSaved(lower)) return _deleteSaved(lower);
    if (_isTakeHomeOrSaved(lower)) return _takeToSaved(lower);

    final dest = _extractFreeDestination(t);
    if (dest != null && dest.isNotEmpty) return _searchDestination(dest);

    await _voice.speak(
      "I didn't understand that. Say a destination, or say find the "
      'nearest hospital.',
    );
  }

  // -------- confirmation --------

  static const _yesWords = [
    'yes',
    'yeah',
    'yep',
    'ok',
    'okay',
    'sure',
    'start',
  ];
  static const _noWords = ['no', 'nope', 'cancel', 'abort', 'not now', 'stop'];
  static const _choiceWords = ['first', 'second', 'third', 'fourth', 'last'];

  bool _isFreeText(String lower) {
    if (_yesWords.any(lower.contains)) return false;
    if (_noWords.any(lower.contains)) return false;
    if (_choiceWords.any(lower.contains)) return false;
    return true;
  }

  Future<void> _handleArrivalReply(String lower) async {
    if (_yesWords.any(lower.contains)) {
      await _stopNavigation(announce: true);
      return;
    }
    if (_noWords.any(lower.contains)) {
      // _arrive() stopped the GPS stream, so it must be restarted before we
      // can track progress again. Reset the arrival streak too, otherwise the
      // user would re-trigger arrival on the very next fix.
      _arrivalStreak = 0;
      setState(() => _phase = _NavPhase.navigating);
      _startNavStream();
      await _voice.speak(
        'Staying on the route. Say repeat or next turn for guidance.',
      );
      return;
    }
    await _voice.speak('Say yes to finish, or no to keep navigating.');
  }

  Future<void> _handleConfirmation(String lower) async {
    final candidates = _candidates;

    if (_noWords.any(lower.contains)) {
      _candidates = [];
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak('Cancelled. Navigation stopped.');
      return;
    }

    final choice = _choiceIndex(lower, candidates.length);
    if (choice != null) {
      if (choice >= candidates.length) {
        await _voice.speak(
          "I couldn't find that option. Please say first or second.",
        );
        return;
      }
      final c = candidates[choice];
      return _startNavigation(c.latitude, c.longitude, spokenName: c.name);
    }

    if (_yesWords.any(lower.contains)) {
      if (candidates.isEmpty) {
        await _voice.speak('Please say a destination first, or say cancel.');
        return;
      }
      final c = candidates.first;
      return _startNavigation(c.latitude, c.longitude, spokenName: c.name);
    }

    await _voice.speak(
      'Please say yes to start, or say no or cancel to abort.',
    );
  }

  /// Maps a spoken selection onto a candidate index.
  ///
  /// The index may be out of range; the caller reports that to the user instead
  /// of silently starting a search for it as a place name. [count] is passed so
  /// "last" resolves to the real final candidate rather than a fixed one.
  static int? _choiceIndex(String lower, int count) {
    if (count <= 0) return null;
    const words = {
      'first': 1,
      '1': 1,
      'one': 1,
      'second': 2,
      '2': 2,
      'two': 2,
      'third': 3,
      '3': 3,
      'three': 3,
      'fourth': 4,
      '4': 4,
      'four': 4,
      'fifth': 5,
      '5': 5,
      'five': 5,
    };
    for (final e in words.entries) {
      if (lower.contains(e.key)) return e.value - 1;
    }
    if (lower.contains('last')) return count - 1;
    return null;
  }

  // -------- nav control --------

  Future<bool> _handleNavControl(String lower) async {
    if (_noWords.any(lower.contains) ||
        lower.contains('end navigation') ||
        lower.contains('stop navigating')) {
      await _stopNavigation(announce: true);
      return true;
    }
    if (_isRepeat(lower)) {
      await _repeat();
      return true;
    }
    if (lower.contains('how far') ||
        lower.contains('distance') ||
        lower.contains('how long is')) {
      await _speakRemainingDistance();
      return true;
    }
    if (lower.contains('how long') ||
        lower.contains('time') ||
        lower.contains('minutes')) {
      await _speakRemainingTime();
      return true;
    }
    if (lower.contains('next turn') ||
        lower.contains('next instruction') ||
        lower.contains("what's next") ||
        lower.contains('instruction')) {
      await _speakNextInstruction();
      return true;
    }
    if (_isWhereAmI(lower)) {
      await _whereAmI();
      return true;
    }
    return false;
  }

  Future<void> _repeat() async {
    final previous = _lastSpoken.isNotEmpty
        ? _lastSpoken
        : (_voice.lastSpokenResponse ?? '');
    if (previous.isEmpty) {
      await _voice.speak('There is nothing to repeat yet.');
      return;
    }
    await _voice.speak(previous, pace: TtsPace.moduleResult);
  }

  // ================================================================
  // INTENT MATCHERS
  // ================================================================

  static bool _isSos(String lower) =>
      lower.contains('sos') ||
      lower.contains('emergency') ||
      lower.contains('i need help');

  static bool _isExit(String lower) {
    // Matched as whole phrases: a bare "exit" substring would otherwise
    // swallow legitimate destinations.
    const phrases = [
      'go back',
      'back to dashboard',
      'back to home',
      'close navigation',
      'exit navigation',
      'leave navigation',
      'quit navigation',
      'stop navigation',
    ];
    return phrases.any(lower.contains);
  }

  static bool _isWhereAmI(String lower) =>
      lower.contains('where am i') ||
      lower.contains('what is my location') ||
      lower.contains('tell me where i am') ||
      lower.contains('current location') ||
      lower.contains('my location');

  static bool _isChangeMode(String lower) =>
      lower.contains('walking mode') ||
      lower.contains('driving mode') ||
      lower.contains('cycling mode') ||
      lower.contains('bike mode') ||
      lower.contains('bicycle mode') ||
      lower.contains('change to walking') ||
      lower.contains('change to driving') ||
      lower.contains('change to cycling') ||
      lower.contains('switch to walking') ||
      lower.contains('switch to driving') ||
      lower.contains('switch to cycling');

  static bool _isFindNearest(String lower) =>
      lower.contains('find the nearest') ||
      lower.contains('find nearest') ||
      lower.contains('nearest ');

  static bool _isSavePlace(String lower) =>
      lower.contains('save this location') ||
      lower.contains('save this place') ||
      lower.contains('save my ');

  static bool _isDeleteSaved(String lower) =>
      lower.contains('delete my ') ||
      lower.contains('remove my saved') ||
      lower.contains('delete my saved place') ||
      lower.contains('delete home');

  static bool _isTakeHomeOrSaved(String lower) =>
      lower.contains('take me home') ||
      lower.contains('go home') ||
      lower.contains('take me to home') ||
      lower.contains('navigate to home') ||
      lower.contains('take me to college') ||
      lower.contains('navigate to college') ||
      lower.contains('take me to my ');

  static bool _isRepeat(String lower) =>
      VoiceCommandService.isRepeatCommand(lower);

  static String? _extractFreeDestination(String t) {
    final lower = t.toLowerCase();
    if (lower.contains('nearest')) return null;

    final patterns = [
      RegExp(
        r'(?:navigate to|navigation to|take me to|go to|going to|head to|'
        r'directions to|route to|walk to|drive to)\s+(.+)',
      ),
      RegExp(r'(?:find|open|show)\s+(.+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(t);
      if (m != null) {
        final dest = m.group(1)?.trim();
        if (dest != null && dest.isNotEmpty && dest.length < 60) {
          final clean = dest.replaceAll(
            RegExp(r'\s+(please|now|kindly|thanks)$', caseSensitive: false),
            '',
          );
          if (clean.isNotEmpty) return clean;
        }
      }
    }

    // A bare short phrase is treated as a destination, which is what a user
    // naturally says when the app asks "where would you like to go".
    final bare = t.trim();
    if (bare.length >= 3 && bare.length <= 40 && !bare.contains('?')) {
      return bare;
    }
    return null;
  }

  // ================================================================
  // WHERE AM I
  // ================================================================

  Future<void> _whereAmI() async {
    setState(() => _phase = _NavPhase.searching);
    final pos = await NavigationService.getCurrentPosition();
    if (!mounted) return;
    if (pos == null) {
      setState(() => _phase = _resumePhase());
      await _voice.speak(
        'Unable to determine your current location. Please enable GPS.',
      );
      return;
    }

    _position = pos;
    try {
      final address = await NavigationService.reverseGeocode(
        pos.latitude,
        pos.longitude,
      );
      if (!mounted) return;
      final accuracy = pos.accuracy > 0
          ? ', accurate to about ${_formatDistance(pos.accuracy)}'
          : '';
      await _voice.speak('You are currently near $address$accuracy.');
    } catch (_) {
      if (!mounted) return;
      await _voice.speak(
        'Your location is ${pos.latitude.toStringAsFixed(4)}, '
        '${pos.longitude.toStringAsFixed(4)}.',
      );
    }
    if (!mounted) return;
    setState(() => _phase = _resumePhase());
  }

  // ================================================================
  // DESTINATION SEARCH
  // ================================================================

  Future<void> _searchDestination(String query) async {
    setState(() => _phase = _NavPhase.searching);
    _pendingLabel = query;
    await _voice.speak('Searching for $query.', resumeAfter: false);

    // A destination can be resolved without the device position. Previously
    // this returned before geocoding whenever Android missed a fresh GPS fix
    // in ten seconds, so the spoken place never reached the backend at all.
    // When available, the position still biases duplicate place names nearby.
    final pos = await NavigationService.getCurrentPosition();
    if (!mounted) return;
    if (pos != null) _position = pos;

    try {
      final geo = await NavigationService.geocode(
        query,
        lat: pos?.latitude,
        lng: pos?.longitude,
      );
      if (!mounted) return;

      if (geo.isEmpty) {
        await _voice.speak('I could not find $query. Please try another name.');
        setState(() => _phase = _NavPhase.listening);
        return;
      }
      await _presentCandidates(
        geo
            .map(
              (g) => _DestCandidate(
                g.name,
                g.latitude,
                g.longitude,
                address: g.formattedAddress,
                confidence: g.confidence,
              ),
            )
            .toList(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak(
        e is NavigationException
            ? e.message
            : 'Unable to search for that place. Please check your connection.',
      );
    }
  }

  Future<void> _presentCandidates(List<_DestCandidate> list) async {
    _candidates = list;
    setState(() => _phase = _NavPhase.confirming);

    // A single clear match should start a route from the original command.
    // We continue to ask for a choice when the provider returns competing
    // places, because silently navigating to the wrong one is unsafe.
    if (_isUnambiguousDestination(list)) {
      final destination = list.first;
      await _voice.speak(
        'I found ${destination.name}. Starting navigation.',
        resumeAfter: false,
      );
      await _startNavigation(
        destination.latitude,
        destination.longitude,
        spokenName: destination.name,
      );
      return;
    }
    await _speakCandidates(list);
  }

  static bool _isUnambiguousDestination(List<_DestCandidate> list) {
    if (list.length == 1) return true;
    if (list.isEmpty) return false;
    final first = list.first;
    if ((first.confidence ?? 0) < 0.95) return false;

    // The provider may return several records for one place. Only auto-start
    // if the first result clearly outranks the next candidate.
    final secondConfidence = list[1].confidence ?? 0;
    return secondConfidence < (first.confidence! - 0.05);
  }

  Future<void> _speakCandidates(List<_DestCandidate> list) async {
    if (list.isEmpty) return;
    if (list.length == 1) {
      final c = list.first;
      final dist = c.distanceM != null
          ? ', approximately ${_formatDistance(c.distanceM!)} away'
          : '';
      await _voice.speak(
        'I found ${c.name}$dist. Say yes to start navigation, or no to cancel.',
      );
      return;
    }
    final sb = StringBuffer(
      'I found ${list.length} places named '
      '$_pendingLabel. ',
    );
    for (var i = 0; i < list.length && i < 3; i++) {
      final c = list[i];
      final dist = c.distanceM != null
          ? ' ${_formatDistance(c.distanceM!)} away'
          : '';
      sb.write('The ${_ordinal(i)} is$dist. ');
    }
    sb.write('Say first, second, or say cancel.');
    await _voice.speak(sb.toString());
  }

  static String _ordinal(int i) => const ['first', 'second', 'third'][i];

  // ================================================================
  // FIND NEAREST
  // ================================================================

  Future<void> _findNearest(String lower) async {
    final placeType = _matchCategory(lower);
    if (placeType == null) {
      final examples = _categories.take(6).join(', ');
      await _voice.speak(
        'I did not recognise that place type. You can say find the nearest '
        'hospital, or one of: $examples.',
      );
      return;
    }

    setState(() => _phase = _NavPhase.searching);
    _pendingLabel = 'nearest $placeType';

    final pos = await NavigationService.getCurrentPosition();
    if (!mounted) return;
    if (pos == null) {
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak(
        'Unable to determine your location. Please enable GPS.',
      );
      return;
    }
    _position = pos;

    try {
      final places = await NavigationService.searchNearby(
        placeType,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (!mounted) return;
      if (places.isEmpty) {
        setState(() => _phase = _NavPhase.listening);
        await _voice.speak(
          'I could not find a $placeType within 5 kilometers of you.',
        );
        return;
      }
      await _presentCandidates(
        places
            .map(
              (p) => _DestCandidate(
                p.name,
                p.latitude,
                p.longitude,
                distanceM: p.distanceM,
                address: p.formattedAddress,
              ),
            )
            .toList(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak(
        e is NavigationException
            ? e.message
            : 'Unable to search for a $placeType nearby.',
      );
    }
  }

  /// Longest-match lookup against the backend's supported category list.
  String? _matchCategory(String lower) {
    if (_categories.isEmpty) return null;
    String? best;
    for (final c in _categories) {
      if (lower.contains(c) && (best == null || c.length > best.length)) {
        best = c;
      }
    }
    return best;
  }

  // ================================================================
  // START / STOP NAVIGATION
  // ================================================================

  _NavPhase _resumePhase() => (_route != null && _phase == _NavPhase.searching)
      ? _NavPhase.navigating
      : _NavPhase.listening;

  Future<void> _startNavigation(
    double destLat,
    double destLng, {
    required String spokenName,
  }) async {
    _candidates = [];
    _spokenDestination = spokenName;
    setState(() => _phase = _NavPhase.searching);

    // A search may have used a cached fix purely to bias destination results.
    // Route calculation must always request a current origin rather than
    // reusing that earlier screen-level value.
    final pos = await NavigationService.getCurrentPosition();
    if (!mounted) return;
    if (pos == null) {
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak(
        'Unable to determine your location. Please enable GPS.',
      );
      return;
    }
    _position = pos;

    try {
      final route = await NavigationService.getDirections(
        originLat: pos.latitude,
        originLng: pos.longitude,
        destLat: destLat,
        destLng: destLng,
        mode: _mode,
      );
      if (!mounted) return;

      if (route.steps.isEmpty && route.geometry.length < 2) {
        setState(() => _phase = _NavPhase.listening);
        await _voice.speak('No route could be found to $spokenName.');
        return;
      }

      _installRoute(route);
      setState(() => _phase = _NavPhase.navigating);

      await _voice.speak(
        'Navigation started to $spokenName. '
        '${_formatDistance(route.distanceM)} away, '
        'about ${_durationWords(route.durationSec)}. '
        '${_nextInstruction.isEmpty ? '' : _nextInstruction}',
        resumeAfter: false,
      );
      await _voice.speak(
        'You can say repeat, how far, how long, next turn, where am I, or stop.',
      );
      _startNavStream();
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _NavPhase.listening);
      await _voice.speak(
        e is NavigationException
            ? e.message
            : 'Unable to calculate a route right now.',
      );
    }
  }

  void _installRoute(NavDirections route) {
    _route = route;
    _track = route.track;
    _announcedStep = -1;
    _arrivalStreak = 0;
    _offRouteStreak = 0;
    _alongRouteM = 0;
    _remainingM = route.distanceM;
    _distanceToRouteM = 0;
    _nextInstruction = '';
    _nextManeuverM = 0;
    _lastSpoken = '';
  }

  // ================================================================
  // GPS STREAM + GUIDANCE ENGINE
  // ================================================================

  void _startNavStream() {
    _stopNavStream();
    _navSub = NavigationService.positionStream().listen(
      _onFix,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _stopNavStream() {
    _navSub?.cancel();
    _navSub = null;
  }

  void _onFix(Position fix) {
    _position = fix;
    if (_phase != _NavPhase.navigating && _phase != _NavPhase.arrived) return;

    final track = _track;
    if (track == null) return;

    final here = GeoPoint(fix.latitude, fix.longitude);
    final projection = track.project(here);

    _alongRouteM = projection.alongRouteM;
    _remainingM = projection.remainingM;
    _distanceToRouteM = projection.distanceToRouteM;

    // Accuracy widens every threshold so a noisy fix cannot act on itself.
    final slack = fix.accuracy > 0 ? fix.accuracy : 0.0;
    final arrivalRadius = _baseArrivalRadiusM + slack;
    final offRouteLimit = _baseOffRouteM + slack * 2;

    // ---- arrival ----
    final straightToDest = track.distanceToDestinationM(here);
    if (straightToDest <= arrivalRadius) {
      _arrivalStreak++;
      if (_arrivalStreak >= _requiredArrivalFixes &&
          _phase == _NavPhase.navigating) {
        _arrive();
        return;
      }
    } else {
      _arrivalStreak = 0;
    }

    // ---- off-route, only from trustworthy fixes ----
    if (NavigationService.isTrustworthy(fix)) {
      if (projection.distanceToRouteM > offRouteLimit) {
        _offRouteStreak++;
        final cooledDown =
            DateTime.now().difference(_lastReroute) >= _rerouteCooldown;
        if (_offRouteStreak >= _requiredOffRouteFixes &&
            !_rerouteLock &&
            cooledDown) {
          _reroute(here);
          return;
        }
      } else {
        _offRouteStreak = 0;
      }
    }

    _advanceGuidance(projection);
    if (mounted) setState(() {});
  }

  /// Chooses the maneuver the user is approaching and speaks it exactly once.
  void _advanceGuidance(RouteProjection projection) {
    final route = _route;
    final track = _track;
    if (route == null || track == null) return;

    final steps = route.steps;
    if (steps.isEmpty) return;

    // The first step whose maneuver is still ahead of us on the geometry.
    var target = 0;
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].fromIndex > projection.nearestIndex) {
        target = i;
        break;
      }
      target = i;
    }

    final step = steps[target];
    final maneuverM = (track.alongToM(step.fromIndex) - projection.alongRouteM)
        .clamp(0.0, double.infinity);

    _nextInstruction = step.instruction;
    _nextManeuverM = maneuverM;

    if (_announcedStep >= target) return;
    if (maneuverM > _earlyGuidanceM) return;

    _announcedStep = target;

    final String phrase;
    if (maneuverM > _nearGuidanceM) {
      // Prepend the distance only while it is useful; near the turn the bare
      // instruction is clearer and shorter to speak.
      final lead = step.preTransition.isNotEmpty
          ? step.preTransition
          : step.instruction;
      phrase = 'In ${_formatDistance(maneuverM)}, $lead';
    } else {
      phrase = step.instruction;
    }

    _lastSpoken = phrase;
    // Turn-by-turn guidance is spoken slower and stored as the shared
    // response so "repeat" works anywhere in the app.
    _voice.speak(phrase, pace: TtsPace.moduleResult, remember: true);
  }

  Future<void> _reroute(GeoPoint here) async {
    final route = _route;
    if (route == null || _rerouteLock) return;

    _rerouteLock = true;
    _offRouteStreak = 0;
    _lastReroute = DateTime.now();
    if (mounted) {
      setState(() => _phase = _NavPhase.rerouting);
    }
    await _voice.speak(
      'You are about ${_formatDistance(_distanceToRouteM)} off the route. '
      'Recalculating.',
      resumeAfter: false,
    );

    try {
      final newRoute = await NavigationService.getDirections(
        originLat: here.latitude,
        originLng: here.longitude,
        destLat: route.destinationPoint.latitude,
        destLng: route.destinationPoint.longitude,
        mode: _mode,
      );
      if (!mounted) return;
      if (newRoute.steps.isEmpty && newRoute.geometry.length < 2) {
        throw const NavigationException('No new route found.');
      }
      _installRoute(newRoute);
      setState(() => _phase = _NavPhase.navigating);
      await _voice.speak(
        'New route found. ${_formatDistance(newRoute.distanceM)} to go, '
        'about ${_durationWords(newRoute.durationSec)}.',
      );
      if (_nextInstruction.isNotEmpty) await _voice.speak(_nextInstruction);
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _NavPhase.navigating);
      await _voice.speak(
        e is NavigationException
            ? e.message
            : 'I could not recalculate the route. Please try again.',
      );
    } finally {
      _rerouteLock = false;
    }
  }

  Future<void> _arrive() async {
    _stopNavStream();
    if (!mounted) return;
    setState(() => _phase = _NavPhase.arrived);
    _lastSpoken = 'You have arrived at $_spokenDestination.';
    await _voice.speak(
      'You have arrived at $_spokenDestination. '
      'Would you like me to stop navigation? Say yes or no.',
    );
  }

  Future<void> _stopNavigation({bool announce = true}) async {
    _stopNavStream();
    _route = null;
    _track = null;
    _announcedStep = -1;
    _arrivalStreak = 0;
    _offRouteStreak = 0;
    _nextInstruction = '';
    _remainingM = 0;
    _distanceToRouteM = 0;
    if (!mounted) return;
    setState(() => _phase = _NavPhase.listening);
    if (announce) await _voice.speak('Navigation stopped.');
  }

  // ================================================================
  // SPOKEN STATUS
  // ================================================================

  Future<void> _speakRemainingDistance() async {
    final route = _route;
    if (route == null) {
      await _voice.speak('Navigation is not active.');
      return;
    }
    final track = _track;
    final pos = _position;
    if (track == null || pos == null) {
      await _voice.speak('I cannot determine the remaining distance.');
      return;
    }
    final projection = track.project(GeoPoint(pos.latitude, pos.longitude));
    await _voice.speak(
      'You have approximately ${_formatDistance(projection.remainingM)} '
      'remaining along the route.',
    );
  }

  Future<void> _speakRemainingTime() async {
    final route = _route;
    final track = _track;
    final pos = _position;
    if (route == null || track == null || pos == null) {
      await _voice.speak('Navigation is not active.');
      return;
    }
    final projection = track.project(GeoPoint(pos.latitude, pos.longitude));
    final fraction = route.distanceM <= 0
        ? 0.0
        : (projection.alongRouteM / route.distanceM).clamp(0.0, 1.0);
    final remainingSec = route.durationSec * (1 - fraction);
    await _voice.speak('About ${_durationWords(remainingSec)} remaining.');
  }

  Future<void> _speakNextInstruction() async {
    if (_route == null) {
      await _voice.speak('Navigation is not active.');
      return;
    }
    if (_nextInstruction.isEmpty) {
      await _voice.speak('There is no upcoming instruction on this route.');
      return;
    }
    final dist = _nextManeuverM;
    await _voice.speak(
      _nextManeuverM > _nearGuidanceM
          ? '$_nextInstruction, in ${_formatDistance(dist)}.'
          : _nextInstruction,
    );
  }

  // ================================================================
  // SAVED PLACES
  // ================================================================

  Future<void> _takeToSaved(String lower) async {
    final name = _savedPlaceName(lower);
    if (name == null) {
      await _voice.speak('I did not recognise that saved place.');
      return;
    }
    final place = _savedPlaces
        .where((p) => p.name.toLowerCase() == name)
        .toList();
    if (place.isEmpty) {
      await _voice.speak(
        'You do not have a saved $name place yet. '
        'Say save this location as $name to add it.',
      );
      return;
    }
    await _startNavigation(
      place.first.latitude,
      place.first.longitude,
      spokenName: place.first.name,
    );
  }

  String? _savedPlaceName(String lower) {
    for (final p in _savedPlaces) {
      final n = p.name.toLowerCase();
      if (n.isNotEmpty && lower.contains(n)) return n;
    }
    return null;
  }

  Future<void> _savePlace(String lower) async {
    final name = _extractSaveName(lower);
    if (name == null) {
      await _voice.speak(
        'Please say save this location as home, or as a place name.',
      );
      return;
    }
    final pos = _position ?? await NavigationService.getCurrentPosition();
    if (!mounted) return;
    if (pos == null) {
      await _voice.speak('Unable to determine your location to save.');
      return;
    }
    try {
      await NavigationService.savePlace(
        name: name,
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      _savedPlaces = await _loadSavedPlaces();
      if (!mounted) return;
      await _voice.speak('Saved this location as $name.');
    } catch (_) {
      await _voice.speak('I could not save that location.');
    }
  }

  static String? _extractSaveName(String lower) {
    final patterns = [
      RegExp(r'save this location as\s+([a-z ]+)'),
      RegExp(r'save this place as\s+([a-z ]+)'),
      RegExp(r'save my\s+([a-z ]+)\s+location'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(lower);
      if (m != null) {
        final name = m.group(1)?.trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    return null;
  }

  Future<void> _deleteSaved(String lower) async {
    final name =
        _savedPlaceName(lower) ??
        (lower.contains('delete home') ? 'home' : null);
    if (name == null) {
      await _voice.speak(
        'Please say which saved place to delete, for example '
        'delete my home location.',
      );
      return;
    }
    final place = _savedPlaces
        .where((p) => p.name.toLowerCase() == name)
        .toList();
    if (place.isEmpty) {
      await _voice.speak('You do not have a saved $name place to delete.');
      return;
    }
    final ok = await NavigationService.deleteSavedPlace(place.first.id);
    _savedPlaces = await _loadSavedPlaces();
    if (!mounted) return;
    await _voice.speak(
      ok ? 'Deleted your saved $name place.' : 'I could not delete that place.',
    );
  }

  // ================================================================
  // TRAVEL MODE
  // ================================================================

  Future<void> _changeMode(String lower) async {
    final next = lower.contains('driving')
        ? NavTravelMode.driving
        : (lower.contains('cycling') ||
              lower.contains('bike') ||
              lower.contains('bicycle'))
        ? NavTravelMode.cycling
        : NavTravelMode.walking;
    _mode = next;
    if (mounted) setState(() {});
    await _voice.speak('${next.label} navigation selected.');

    if (_route != null && _position != null) {
      await _voice.speak('Recalculating for ${next.label}.');
      await _startNavigation(
        _route!.destinationPoint.latitude,
        _route!.destinationPoint.longitude,
        spokenName: _spokenDestination,
      );
    }
  }

  // ================================================================
  // SOS + EXIT
  // ================================================================

  Future<void> _handleSos() async {
    _stopNavStream();
    await _voice.releaseSession(_voiceSession);
    await _voice.speak('Opening emergency SOS.', pace: TtsPace.important);
    if (!mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SosScreen()));
  }

  Future<void> _exit() async {
    _stopNavStream();
    await _voice.releaseSession(_voiceSession);
    if (mounted) Navigator.of(context).pop();
  }

  // ================================================================
  // HELPERS
  // ================================================================

  static String _formatDistance(double m) {
    if (m >= 1000) {
      final km = m / 1000;
      return '${km.toStringAsFixed(km >= 10 ? 0 : 1)} kilometers';
    }
    if (m < 10) return 'a few meters';
    return '${m.round()} meters';
  }

  static String _durationWords(double seconds) {
    if (seconds <= 0) return 'less than a minute';
    final minutes = (seconds / 60).round();
    if (minutes < 1) return 'less than a minute';
    if (minutes == 1) return '1 minute';
    if (minutes < 60) return '$minutes minutes';
    final hours = (minutes / 60).floor();
    final rest = minutes % 60;
    return rest == 0
        ? '$hours ${hours == 1 ? 'hour' : 'hours'}'
        : '$hours hour${hours == 1 ? '' : 's'} and $rest minutes';
  }

  // ================================================================
  // BUILD
  // ================================================================

  bool get _isNavigating =>
      _phase == _NavPhase.navigating ||
      _phase == _NavPhase.rerouting ||
      _phase == _NavPhase.arrived;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildGuidance()),
            _buildStats(),
            _buildVoiceBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: _exit,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
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
          const SizedBox(width: 14),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [Color(0xFF42D392), Color(0xFF42D9FF)],
              ),
            ),
            child: const Icon(
              Icons.navigation_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NAVIGATION',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  'Voice-first travel assistant',
                  style: TextStyle(color: Color(0xFFA9B0C3), fontSize: 11),
                ),
              ],
            ),
          ),
          _statusChip(),
        ],
      ),
    );
  }

  Widget _statusChip() {
    final (label, color) = switch (_phase) {
      _NavPhase.idle ||
      _NavPhase.listening => ('LISTENING', const Color(0xFF42D392)),
      _NavPhase.searching => ('SEARCHING', const Color(0xFF42D9FF)),
      _NavPhase.confirming => ('CONFIRM', const Color(0xFFFFB04D)),
      _NavPhase.navigating => ('NAVIGATING', const Color(0xFF42D9FF)),
      _NavPhase.rerouting => ('REROUTING', const Color(0xFFFFB04D)),
      _NavPhase.arrived => ('ARRIVED', const Color(0xFF5DFFB0)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  /// Replaces the former map widget. Everything here is a secondary visual
  /// echo of what is already being spoken.
  Widget _buildGuidance() {
    if (!_isNavigating || _route == null) {
      return _buildIdlePanel();
    }

    final route = _route!;
    final accuracy = _position?.accuracy ?? 0;
    final progress = route.distanceM <= 0
        ? 0.0
        : (_alongRouteM / route.distanceM).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NEXT INSTRUCTION',
                  style: TextStyle(
                    color: Color(0xFFA9B0C3),
                    fontSize: 11,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _nextInstruction.isEmpty
                      ? 'Follow the route.'
                      : _nextInstruction,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (_isNavigating && _nextManeuverM > _nearGuidanceM) ...[
                  const SizedBox(height: 8),
                  Text(
                    'in ${_formatDistance(_nextManeuverM)}',
                    style: const TextStyle(
                      color: Color(0xFF42D9FF),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _panel(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _metric('REMAINING', _formatDistance(_remainingM)),
                    _metric(
                      'ABOUT',
                      _durationWords(
                        route.durationSec *
                            (1 - (route.distanceM <= 0 ? 0.0 : progress)),
                      ),
                    ),
                    _metric(
                      'GPS',
                      accuracy > 0 ? '±${_formatDistance(accuracy)}' : '—',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF42D9FF)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(progress * 100).round()} percent of the route completed',
                  style: const TextStyle(
                    color: Color(0xFFA9B0C3),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdlePanel() {
    final saved = _savedPlaces.map((p) => p.name).take(5).join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'READY TO NAVIGATE',
              style: TextStyle(
                color: Color(0xFFA9B0C3),
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Say a destination, or ask for the nearest hospital, '
              'pharmacy, ATM or bus stop.',
              style: TextStyle(color: Colors.white, fontSize: 20, height: 1.3),
            ),
            const SizedBox(height: 12),
            Text(
              'Travel mode: ${_mode.label}',
              style: const TextStyle(color: Color(0xFF42D9FF), fontSize: 14),
            ),
            if (saved.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Saved places: $saved',
                style: const TextStyle(color: Color(0xFFA9B0C3), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF141A28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: child,
    );
  }

  Widget _metric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFA9B0C3),
            fontSize: 10,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildStats() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DESTINATION:  ${_spokenDestination.isEmpty ? '—' : _spokenDestination.toUpperCase()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isNavigating && _distanceToRouteM > _baseOffRouteM
                ? 'WARNING:  ABOUT ${_formatDistance(_distanceToRouteM).toUpperCase()} OFF ROUTE'
                : 'MODE:  ${_mode.label}',
            style: TextStyle(
              color: _isNavigating && _distanceToRouteM > _baseOffRouteM
                  ? const Color(0xFFFFB04D)
                  : const Color(0xFFA9B0C3),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic_rounded, color: Color(0xFF42D392)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Fully voice controlled. Say a destination or command.',
              style: TextStyle(
                color: Color(0xFFA9B0C3),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.stop_rounded, color: Colors.white),
            onPressed: () => _stopNavigation(),
            tooltip: 'Stop navigation',
          ),
        ],
      ),
    );
  }
}

class _DestCandidate {
  const _DestCandidate(
    this.name,
    this.latitude,
    this.longitude, {
    this.distanceM,
    this.address = '',
    this.confidence,
  });

  final String name;
  final double latitude;
  final double longitude;
  final double? distanceM;
  final String address;
  final double? confidence;
}
