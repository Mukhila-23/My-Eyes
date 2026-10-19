import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/voice_command_router.dart';

void main() {
  group('VoiceCommandRouter - existing behaviour', () {
    test('routes object finder commands with the requested target', () {
      final command = VoiceCommandRouter.route('Find my bottle');

      expect(command.intent, VoiceIntent.object);
      expect(command.target, 'bottle');
    });

    test('keeps generic object identification separate from object finder', () {
      final command = VoiceCommandRouter.route('What is this object?');

      expect(command.intent, VoiceIntent.object);
      expect(command.target, isNull);
    });

    test('routes specific readers before the general text reader', () {
      expect(
        VoiceCommandRouter.route('Read this medicine').intent,
        VoiceIntent.medicine,
      );
      expect(
        VoiceCommandRouter.route('Read this product package').intent,
        VoiceIntent.product,
      );
    });

    test('routes navigation before general AI questions', () {
      final command = VoiceCommandRouter.route(
        'Navigate to Coimbatore railway station',
      );

      expect(command.intent, VoiceIntent.navigation);
      expect(command.target, 'coimbatore railway station');
    });

    test('preserves every supported route phrase and its destination', () {
      for (final phrase in <String>[
        'route to PSG College',
        'walk to the railway station',
        'drive to Coimbatore airport',
        'head to the hospital',
      ]) {
        final command = VoiceCommandRouter.route(phrase);
        expect(command.intent, VoiceIntent.navigation, reason: phrase);
        expect(command.target, isNotNull, reason: phrase);
      }
    });

    test('recognizes help requests for the AI-backed Help flow', () {
      expect(
        VoiceCommandRouter.route('How do I use My Eyes?').intent,
        VoiceIntent.help,
      );
    });

    test('normalizes wake words and punctuation', () {
      final command = VoiceCommandRouter.route('Hey My Eyes, scan QR!');

      expect(command.intent, VoiceIntent.payment);
    });

    test('keeps every module command on its original intent', () {
      expect(
        VoiceCommandRouter.route('Read text').intent,
        VoiceIntent.readText,
      );
      expect(
        VoiceCommandRouter.route('Currency detection').intent,
        VoiceIntent.currency,
      );
      expect(
        VoiceCommandRouter.route('Product detection').intent,
        VoiceIntent.product,
      );
      expect(
        VoiceCommandRouter.route('Scene detection').intent,
        VoiceIntent.scene,
      );
    });

    test('still triggers SOS from the emergency phrases', () {
      expect(VoiceCommandRouter.route('SOS').intent, VoiceIntent.sos);
      expect(VoiceCommandRouter.route('send sos').intent, VoiceIntent.sos);
    });

    test('still separates emergency contacts from an SOS trigger', () {
      expect(
        VoiceCommandRouter.route('emergency contacts').intent,
        VoiceIntent.emergencyContacts,
      );
    });
  });

  group('VoiceCommandRouter - module history', () {
    test('matches a bare "history"', () {
      expect(VoiceCommandRouter.route('history').intent, VoiceIntent.history);
    });

    test('matches the explicit history phrasings', () {
      for (final phrase in <String>[
        'show history',
        'open history',
        'my history',
        'view history',
        'recent scans',
        'past results',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.history,
          reason: 'expected "$phrase" to route to history',
        );
      }
    });

    test('resolves the module named in a history request', () {
      expect(
        VoiceCommandRouter.route('currency history').historyModule?.name,
        'currency',
      );
      expect(
        VoiceCommandRouter.route('medicine history').historyModule?.name,
        'medicine',
      );
      expect(
        VoiceCommandRouter.route('read text history').historyModule?.name,
        'readText',
      );
    });

    test('resolves no module for a bare history request', () {
      // The dashboard must ask which module rather than guessing.
      expect(VoiceCommandRouter.route('history').historyModule, isNull);
      expect(VoiceCommandRouter.route('show history').historyModule, isNull);
    });
  });

  group('VoiceCommandRouter - companion', () {
    test('routes the direct switch commands', () {
      for (final phrase in <String>[
        'change companion',
        'switch companion',
        'switch to maya',
        'use alex',
        'change voice',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.changeCompanion,
          reason: 'expected "$phrase" to route to changeCompanion',
        );
      }
    });

    test('leaves a question about companions to the assistant', () {
      expect(
        VoiceCommandRouter.route('how do i change the companion').intent,
        isNot(VoiceIntent.changeCompanion),
      );
    });
  });

  group('VoiceCommandRouter - instructions', () {
    test('routes the guide requests', () {
      for (final phrase in <String>[
        'repeat instructions',
        'instructions',
        'play instructions',
        'guide me',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.instructions,
          reason: 'expected "$phrase" to route to instructions',
        );
      }
    });

    test('"repeat instructions" is not swallowed by the repeat command', () {
      // Regression guard: "repeat" alone re-says the last answer, but the
      // guide request must win or the user never hears the guide.
      expect(VoiceCommandRouter.route('repeat').intent, VoiceIntent.repeat);
      expect(
        VoiceCommandRouter.route('repeat instructions').intent,
        VoiceIntent.instructions,
      );
    });

    test('routes SOS instructions without triggering SOS', () {
      for (final phrase in <String>[
        'SOS instructions',
        'how does SOS work',
        'how do I activate SOS',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.sosInstructions,
          reason: 'expected "$phrase" to route to sosInstructions',
        );
      }
    });
  });

  group('VoiceCommandRouter - substring module matching', () {
    test('inflects instead of failing on plurals and gerunds', () {
      // The recognizer emits "medicines" and "reading" far more often than the
      // singular/lemma written in the keyword table. Matching was substring
      // based, which failed to relate "medicine" to "medicines" at all.
      for (final phrase in <String>[
        'identify these medicines',
        'what is this medicine',
        'reading this text',
        'identify these tablets',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          isNot(VoiceIntent.unknown),
          reason: 'expected "$phrase" to reach a module',
        );
      }

      expect(
        VoiceCommandRouter.route('identify these medicines').intent,
        VoiceIntent.medicine,
      );
      expect(
        VoiceCommandRouter.route('reading this text').intent,
        VoiceIntent.readText,
      );
    });

    test('does not match a keyword inside a longer unrelated word', () {
      // "note" is a Currency keyword. Matched as a raw substring it also fired
      // on "notebook", "noted" and "denote", so a blind user searching for a
      // notebook was sent to the currency scanner instead of Object Finder.
      final command = VoiceCommandRouter.route('find my notebook');

      expect(command.intent, VoiceIntent.object);
      expect(command.target, 'notebook');
    });

    test('a module-specific noun outranks a generic phrase', () {
      // "tell me about this" is a generic object phrase; "scene" is the whole
      // subject of the sentence. Coverage-based tie-breaking must not let the
      // generic phrase win.
      expect(
        VoiceCommandRouter.route('tell me about this scene').intent,
        VoiceIntent.scene,
      );
      expect(
        VoiceCommandRouter.route('what is this medicine').intent,
        VoiceIntent.medicine,
      );
    });

    test('resolves the module from an inflected history request', () {
      expect(
        VoiceCommandRouter.route('medicines history').historyModule?.name,
        'medicine',
      );
      expect(
        VoiceCommandRouter.route('scenes history').historyModule?.name,
        'scene',
      );
    });
  });

  group('VoiceCommandRouter - safety', () {
    test('a routine search never triggers SOS', () {
      // Regression guard, and the most dangerous misroute this app can make.
      // "help me find my keys" contains the generic "help me" SOS phrase, so a
      // blind user asking for a lost-keys search raised a false emergency
      // alarm. A user whose app cries wolf stops trusting the real alarm.
      expect(
        VoiceCommandRouter.route('help me find my keys').intent,
        VoiceIntent.object,
      );
      expect(VoiceCommandRouter.route('help me find my keys').target, 'keys');
      expect(
        VoiceCommandRouter.route('help me locate my wallet').intent,
        isNot(VoiceIntent.sos),
      );
    });

    test('genuine distress still triggers SOS through an apostrophe', () {
      // Apostrophes used to be turned into spaces, so "i'm in trouble"
      // normalized to "i m in trouble" and matched nothing. A user in danger
      // said the exact right words and the app stayed silent.
      for (final phrase in <String>[
        "i'm in trouble",
        'I am in trouble',
        'i need help',
        'send sos',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.sos,
          reason: 'expected "$phrase" to raise SOS',
        );
      }
    });
  });

  group('VoiceCommandRouter - navigation vs object finder', () {
    test('a question naming a place is navigation, not an object search', () {
      // "where is" is an Object Finder verb, so a place question used to open
      // the object camera on a word the user never meant to photograph.
      for (final phrase in <String>[
        'where is the bus stop',
        'where is the pharmacy',
        'which hospital is nearest',
      ]) {
        expect(
          VoiceCommandRouter.route(phrase).intent,
          VoiceIntent.navigation,
          reason: 'expected "$phrase" to route to navigation',
        );
      }
    });

    test('an object target is still an object search', () {
      expect(
        VoiceCommandRouter.route('where is my phone').intent,
        VoiceIntent.object,
      );
      expect(VoiceCommandRouter.route('where is my phone').target, 'phone');
    });

    test('accepts the everyday "take me" navigation phrasings', () {
      final home = VoiceCommandRouter.route('take me home');
      expect(home.intent, VoiceIntent.navigation);
      expect(home.target, 'home');

      expect(
        VoiceCommandRouter.route('take me back').intent,
        VoiceIntent.goBack,
      );
      expect(VoiceCommandRouter.route('go to the bank').target, 'bank');
    });
  });

  group('VoiceCommandRouter - completeness', () {
    test('every intent has a spoken name except unknown', () {
      for (final intent in VoiceIntent.values) {
        final spoken = VoiceCommandRouter.spokenNameFor(intent);
        if (intent == VoiceIntent.unknown) {
          expect(spoken, isEmpty);
        } else {
          expect(
            spoken,
            isNotEmpty,
            reason: '${intent.name} has no spoken name',
          );
        }
      }
    });

    test('visionModeFor maps each module intent and nothing else', () {
      expect(
        VoiceCommandRouter.visionModeFor(VoiceIntent.readText)?.name,
        'readText',
      );
      expect(
        VoiceCommandRouter.visionModeFor(VoiceIntent.currency)?.name,
        'currency',
      );
      expect(VoiceCommandRouter.visionModeFor(VoiceIntent.history), isNull);
    });
  });
}
