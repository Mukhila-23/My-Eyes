import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/module_catalog.dart';
import 'package:frontend/core/vision_mode.dart';
import 'package:frontend/services/app_instructions.dart';
import 'package:frontend/services/companion.dart';

void main() {
  group('VisionMode - history identity', () {
    test('every mode has a backend scan type', () {
      for (final mode in VisionMode.values) {
        expect(
          mode.scanType,
          isNotNull,
          reason: '${mode.name} has no scan type and would lose its history',
        );
        expect(mode.hasHistory, isTrue);
      }
    });

    test('scan types match the values the backend writes', () {
      // Wire contract with app/services/*.py. Changing one silently empties
      // that module's history.
      const expected = <String, String>{
        'scanObject': 'OBJECT_DETECTION',
        'readText': 'OCR',
        'medicine': 'MEDICINE',
        'product': 'PRODUCT',
        'currency': 'CURRENCY',
        'scene': 'SCENE',
        'objectFinder': 'OBJECT_DETECTION',
      };

      expected.forEach((name, scanType) {
        final mode = VisionMode.values.firstWhere((m) => m.name == name);
        expect(mode.scanType, scanType, reason: '$name scan type drifted');
      });
    });

    test('object finder shares the object detection history stream', () {
      expect(
        VisionMode.objectFinder.scanType,
        VisionMode.scanObject.scanType,
      );
    });

    test('history labels name the module, never just "history"', () {
      for (final mode in VisionMode.values) {
        expect(
          mode.historyLabel,
          '${mode.title} history',
        );
        expect(mode.historyLabel.length, greaterThan(8));
      }
    });

    test('the empty history message names the module', () {
      expect(
        VisionMode.currency.historyEmptySpoken(),
        'There is no history available for Currency Detection yet.',
      );
      expect(
        VisionMode.readText.historyEmptySpoken(),
        contains('Read Text'),
      );
    });
  });

  group('ModuleCatalog - completeness', () {
    test('every vision mode has a catalog entry', () {
      for (final mode in VisionMode.values) {
        final doc = ModuleCatalog.forMode(mode);
        expect(doc, isNotNull, reason: '${mode.name} has no catalog entry');
        expect(doc!.mode, mode);
        expect(doc.purpose, isNotEmpty);
        // A purpose is one spoken thought, so it must terminate properly. The
        // catalog writes single-sentence purposes, so the single terminal mark
        // is the contract.
        expect(
          RegExp(r'[.!?]\s*$').hasMatch(doc.purpose),
          isTrue,
          reason: '${mode.name} purpose is not a terminated spoken sentence',
        );
      }
    });

    test('every dashboard card title resolves to a vision module', () {
      for (final title in <String>[
        'Scan Object',
        'Read Text',
        'Medicine Detection',
        'Product Detection',
        'Currency Detection',
        'Scene Detection',
        'Object Detection',
      ]) {
        expect(
          ModuleCatalog.forTitle(title)?.mode,
          isNotNull,
          reason: 'dashboard card "$title" does not resolve to a module',
        );
      }
    });

    test('a non-scanner card resolves to nothing', () {
      expect(ModuleCatalog.forTitle('Scan Payment'), isNull);
      expect(ModuleCatalog.forTitle('Something Unknown'), isNull);
    });

    test('catalog titles agree with VisionMode titles', () {
      for (final doc in ModuleCatalog.vision) {
        expect(doc.title, doc.requireMode().title);
      }
    });

    test('every feature has a spoken purpose and a way to reach it', () {
      for (final doc in ModuleCatalog.all) {
        expect(doc.purpose, isNotEmpty, reason: '${doc.id} has no purpose');
        expect(
          ModuleCatalog.reachSpoken(doc),
          isNotEmpty,
          reason: '${doc.id} has no spoken way to reach it',
        );
      }
    });

    test('vision features can describe how to open their history', () {
      for (final doc in ModuleCatalog.vision) {
        expect(doc.hasHistory, isTrue);
        expect(
          ModuleCatalog.historySpoken(doc),
          contains(doc.requireMode().title),
        );
      }
    });
  });

  group('AppInstructions - dashboard guide', () {
    const alex = CompanionProfile(
      id: 'alex',
      name: 'Alex',
      gender: CompanionGender.male,
      tagline: 'Calm, confident, and always ready to help.',
      pitch: 0.9,
    );

    final script = AppInstructions.dashboardInstructions(companion: alex);

    test('welcomes the user by the selected companion name', () {
      expect(script, contains('Alex'));
      expect(script, contains('Welcome to My Eyes'));
    });

    test('explains the purpose of every vision module', () {
      for (final doc in ModuleCatalog.vision) {
        expect(
          script,
          contains(doc.title),
          reason: 'the guide never mentions ${doc.title}',
        );
        expect(
          script,
          contains(doc.purpose),
          reason: 'the guide never explains ${doc.title}',
        );
      }
    });

    test('explains the dedicated screens too', () {
      for (final doc in <FeatureDoc>[
        ModuleCatalog.payment,
        ModuleCatalog.navigation,
        ModuleCatalog.aiHelp,
      ]) {
        expect(script, contains(doc.purpose));
      }
    });

    test('covers camera, file selection, history and repeat', () {
      expect(script, contains('camera'));
      expect(script, contains('file'));
      expect(script, contains('history'));
      expect(script, contains('repeat instructions'));
    });

    test('explains how to return to the dashboard', () {
      expect(script, contains('dashboard'));
    });

    test('includes the SOS activation mechanism', () {
      expect(script, contains('S O S'));
      expect(script.toLowerCase(), contains('countdown'));
    });

    test('tells the user how to change companion', () {
      expect(script, contains('change companion'));
      expect(script, contains('Maya'));
    });

    test('states when SOS is not configured', () {
      final unconfigured = AppInstructions.dashboardInstructions(
        companion: alex,
        sosConfigured: false,
      );
      expect(unconfigured, contains('not configured'));
    });

    test('every sentence ends with terminal punctuation', () {
      // Spoken output is read sentence by sentence; a run-on is unreadable.
      for (final sentence in script.split(RegExp(r'(?<=[.!?])\s+'))) {
        final trimmed = sentence.trim();
        if (trimmed.isEmpty) continue;
        expect(
          RegExp(r'[.!?]$').hasMatch(trimmed),
          isTrue,
          reason: 'unterminated sentence: "$trimmed"',
        );
      }
    });

    test('avoids technical wording', () {
      // No endpoint names, scan-type constants or file paths.
      for (final forbidden in <String>[
        '/history/',
        'scan_type',
        'OBJECT_DETECTION',
        'http',
        '.dart',
      ]) {
        expect(script, isNot(contains(forbidden)));
      }
    });
  });

  group('AppInstructions - SOS guide', () {
    final guide = AppInstructions.sosInstructions(companionName: 'Maya');

    test('addresses the selected companion', () {
      expect(guide, contains('Maya'));
    });

    test('describes the alarm duration', () {
      expect(guide, contains('five minutes'));
    });

    test('explains the GPS failure path', () {
      expect(guide.toLowerCase(), contains('location'));
    });

    test('offers setup when SOS is not configured', () {
      expect(
        AppInstructions.sosInstructions(
          companionName: 'Maya',
          configured: false,
        ),
        contains('not set up yet'),
      );
    });

    test('mentions the confirmation countdown', () {
      expect(guide.toLowerCase(), contains('countdown'));
      expect(guide, contains('cancel'));
    });
  });
}
