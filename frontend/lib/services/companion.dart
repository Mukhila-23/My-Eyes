import 'package:flutter/foundation.dart';

/// The two My Eyes companions.
///
/// The name -> gender mapping lives here and *only* here. It used to be
/// duplicated in `voice_command_service.dart` and `companion_selection_screen.dart`
/// with different fallback rules, which is how Alex could end up speaking with
/// a female engine voice. One catalog now feeds the onboarding picker, the
/// central TTS engine and the Dashboard.
enum CompanionGender { male, female }

@immutable
class CompanionProfile {
  const CompanionProfile({
    required this.id,
    required this.name,
    required this.gender,
    required this.tagline,
    required this.pitch,
  });

  /// Wire value sent to the backend (`companion` field).
  final String id;

  /// Spoken / displayed name.
  final String name;

  final CompanionGender gender;

  final String tagline;

  /// Pitch applied to the engine voice as an extra gender cue, because not
  /// every Android build ships an identifiable male and female voice.
  final double pitch;

  bool get isMale => gender == CompanionGender.male;
}

class Companions {
  const Companions._();

  static const CompanionProfile alex = CompanionProfile(
    id: 'alex',
    name: 'Alex',
    gender: CompanionGender.male,
    tagline: 'Calm, confident, and always ready to help.',
    pitch: 0.90,
  );

  static const CompanionProfile maya = CompanionProfile(
    id: 'maya',
    name: 'Maya',
    gender: CompanionGender.female,
    tagline: 'Warm, friendly, and always here for you.',
    pitch: 1.10,
  );

  static const List<CompanionProfile> all = [alex, maya];

  static CompanionProfile of(CompanionGender gender) =>
      gender == CompanionGender.male ? alex : maya;

  /// Lenient lookup used for stored values and backend payloads.
  static CompanionProfile byId(String? id) {
    final value = (id ?? '').trim().toLowerCase();
    for (final companion in all) {
      if (companion.id == value) return companion;
    }
    return alex;
  }

  static CompanionProfile byName(String? name) {
    final value = (name ?? '').trim().toLowerCase();
    for (final companion in all) {
      if (companion.name.toLowerCase() == value) return companion;
    }
    return byId(value);
  }

  /// Rehydrates a companion from the values kept in secure storage, which may
  /// come from an older build that stored e.g. `ALEX` + `male`.
  static CompanionProfile fromStored({
    required String name,
    required String gender,
  }) {
    final storedName = name.trim();
    if (storedName.isNotEmpty) {
      final match = all.firstWhere(
        (c) => c.name.toLowerCase() == storedName.toLowerCase(),
        orElse: () => alex,
      );
      return match;
    }
    return of(genderFrom(gender));
  }

  static CompanionGender genderFrom(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized == 'maya' || normalized == 'female' || normalized == 'f') {
      return CompanionGender.female;
    }
    return CompanionGender.male;
  }
}

/// The engine voice that will actually be used, plus whether it really is the
/// gender that was requested.
///
/// [ResolvedVoice.matchesRequestedGender] is false when the device only offers
/// voices of the other gender (or nothing identifiable). The caller logs that
/// honestly instead of silently pretending the voice is correct, and the
/// companion's pitch is applied to compensate.
@immutable
class ResolvedVoice {
  const ResolvedVoice({
    required this.name,
    required this.locale,
    required this.matchesRequestedGender,
  });

  final String name;
  final String locale;
  final bool matchesRequestedGender;

  @override
  String toString() => '$name ($locale)';
}

/// Picks an English TTS engine voice for a companion.
///
/// The previous implementation fell back to `english.first` for male and
/// `english.last` for female. On Android the voice list is usually dominated by
/// names such as `en-us-x-sfg#female_1-local`, so "first" was very often a
/// female voice: Alex spoke with Maya's voice. This picker scores every English
/// voice against explicit male/female evidence and refuses to hand a voice
/// identified as the *opposite* gender to a companion.
class CompanionVoicePicker {
  const CompanionVoicePicker._();

  /// Voice names that identify a male voice. `sam` is deliberately absent:
  /// it is a substring of `samantha`.
  static const List<String> maleKeywords = <String>[
    'male',
    'david',
    'mark',
    'guy',
    'daniel',
    'james',
    'george',
    'rms',
    'nda',
    'joe',
    'fred',
    'ralph',
    'tom',
    'oliver',
    'ryan',
    'aaron',
    'brian',
    'arthur',
    'alex',
  ];

  /// Voice names that identify a female voice, including the `female_N` suffix
  /// used by the Google TTS engine.
  static const List<String> femaleKeywords = <String>[
    'female',
    'zira',
    'jenny',
    'samantha',
    'aria',
    'susan',
    'hazel',
    'sara',
    'karen',
    'moira',
    'tessa',
    'fiona',
    'victoria',
    'allison',
    'joanna',
    'kate',
    'nicole',
    'catherine',
    'amelie',
    'anna',
    'lily',
    'serena',
  ];

  /// Normalizes the raw `FlutterTts.getVoices` payload into simple maps.
  static List<Map<String, String>> parse(List<dynamic>? raw) {
    if (raw == null) return const <Map<String, String>>[];

    final voices = <Map<String, String>>[];
    for (final voice in raw) {
      if (voice is! Map) continue;
      final name = voice['name']?.toString() ?? '';
      final locale = voice['locale']?.toString() ?? '';
      if (name.isEmpty || locale.isEmpty) continue;
      voices.add(<String, String>{'name': name, 'locale': locale});
    }
    return voices;
  }

  /// English voices, most preferred locale first.
  static List<Map<String, String>> english(List<dynamic>? raw) {
    final voices = parse(raw)
        .where((v) => v['locale']!.toLowerCase().startsWith('en'))
        .toList();

    int rank(Map<String, String> voice) {
      final locale = voice['locale']!.toLowerCase();
      if (locale == 'en-us') return 0;
      if (locale.startsWith('en-us-')) return 1;
      if (locale == 'en-gb') return 2;
      if (locale.startsWith('en-gb-')) return 3;
      return 4;
    }

    voices.sort((a, b) => rank(a).compareTo(rank(b)));
    return voices;
  }

  /// Highest score wins; a voice that carries evidence for the other gender is
  /// pushed below zero so it is never chosen while any better option exists.
  static int _score(Map<String, String> voice, CompanionGender gender) {
    final name = voice['name']!.toLowerCase();
    final locale = voice['locale']!.toLowerCase();

    final maleHit = maleKeywords.any(name.contains);
    final femaleHit = femaleKeywords.any(name.contains);

    var score = 0;
    if (gender == CompanionGender.male) {
      if (femaleHit) score -= 6;
      if (maleHit) score += 4;
    } else {
      if (maleHit) score -= 6;
      if (femaleHit) score += 4;
    }

    if (locale == 'en-us') score += 1;
    return score;
  }

  /// Best voice for [gender], or null when nothing suitable exists.
  ///
  /// [excludeName] keeps the male and female picks distinct on devices that
  /// only ship a single identifiable English voice.
  static ResolvedVoice? pick(
    List<dynamic>? raw,
    CompanionGender gender, {
    String? excludeName,
  }) {
    final voices = english(raw);
    if (voices.isEmpty) return null;

    final candidates = <Map<String, String>>[
      for (final voice in voices)
        if (excludeName == null || voice['name'] != excludeName) voice,
    ];
    if (candidates.isEmpty) return null;

    var best = candidates.first;
    var bestScore = _score(best, gender);
    var bestMatches = bestScore > 0;

    for (final voice in candidates.skip(1)) {
      final score = _score(voice, gender);
      final matches = score > 0;

      // A positively identified voice always beats an unidentified one.
      final better = score > bestScore || (matches && !bestMatches);
      if (better) {
        best = voice;
        bestScore = score;
        bestMatches = matches;
      }
    }

    // Nothing on this device identifies a voice of the requested gender. A
    // voice identified as the *other* gender is worse than an unknown voice,
    // so prefer the unknown one and report the mismatch honestly.
    if (bestMatches) {
      return ResolvedVoice(
        name: best['name']!,
        locale: best['locale']!,
        matchesRequestedGender: true,
      );
    }

    for (final voice in candidates) {
      if (_score(voice, gender) >= 0) {
        return ResolvedVoice(
          name: voice['name']!,
          locale: voice['locale']!,
          matchesRequestedGender: false,
        );
      }
    }

    return null;
  }

  /// Picks the female voice first (Google ships them reliably), then derives
  /// the male pick while excluding it so Alex and Maya never share a voice.
  static ({ResolvedVoice? male, ResolvedVoice? female}) pickPair(
    List<dynamic>? raw,
  ) {
    final female = pick(raw, CompanionGender.female);
    final male = pick(
      raw,
      CompanionGender.male,
      excludeName: female?.name,
    );
    return (male: male, female: female);
  }
}
