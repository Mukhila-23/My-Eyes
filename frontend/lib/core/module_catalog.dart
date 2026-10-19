import 'package:flutter/material.dart';

import '../services/companion.dart';
import 'vision_mode.dart';

/// What kind of dashboard surface a catalog entry describes.
///
/// Used by the instruction system to decide how a feature is *reached* rather
/// than hard-coding a paragraph per screen. A new module only has to pick one
/// of these kinds and supply a [FeatureDoc.purpose]; the dashboard
/// instructions, the unknown-command hint and the SOS guide all follow.
enum FeatureKind {
  /// A vision module opened through [ModuleRouter] (camera / file).
  vision,

  /// A dedicated screen with its own flow (payment, navigation, AI Help).
  screen,

  /// A safety feature (SOS and its setup).
  safety,

  /// A global action (instructions, companion switch).
  action,
}

/// One entry of the single, authoritative feature catalog.
///
/// Everything user-facing about "what does this module do and how do I reach
/// it" lives here exactly once. Adding a module means adding one entry - the
/// spoken dashboard instructions, the spoken module instructions, the history
/// mapping and the voice-command hints all read from this list.
@immutable
class FeatureDoc {
  const FeatureDoc({
    required this.id,
    required this.title,
    required this.purpose,
    required this.kind,
    this.mode,
    this.icon,
    this.examples = const <String>[],
  });

  /// Stable machine id, also used as the analytics/logging key.
  final String id;

  /// What the button says.
  final String title;

  /// Spoken, user-friendly explanation of *why* the feature exists and *when*
  /// to use it. Written to be read aloud, so no brackets, no abbreviations and
  /// no punctuation a screen reader would stumble over.
  final String purpose;

  final FeatureKind kind;

  /// Set for [FeatureKind.vision] entries: the scanner mode this opens.
  final VisionMode? mode;

  final IconData? icon;

  /// Spoken "you can say ..." examples. Used by the instruction system, never
  /// rendered as a requirement.
  final List<String> examples;

  /// The vision mode, for [FeatureKind.vision] entries.
  ///
  /// Throws rather than returning null so a mistyped catalog entry fails
  /// loudly in development instead of silently losing its History button.
  VisionMode requireMode() {
    final value = mode;
    if (value == null) {
      throw StateError('Feature "$id" is a vision feature with no VisionMode.');
    }
    return value;
  }

  /// True when this feature stores scan results and therefore has history.
  bool get hasHistory => mode != null && mode!.scanType != null;
}

/// The catalog of every My Eyes feature reachable from the dashboard.
///
/// ORDER MATTERS: it is the order the instructions are spoken in, so it follows
/// the dashboard from top to bottom (safety first, then vision, then the
/// dedicated screens, then the global actions).
class ModuleCatalog {
  ModuleCatalog._();

  static const FeatureDoc sos = FeatureDoc(
    id: 'sos',
    title: 'Emergency SOS',
    kind: FeatureKind.safety,
    icon: Icons.sos_rounded,
    purpose:
        'Emergency S O S alerts your emergency contacts with your name and '
        'your current location, and sounds an alarm for five minutes so people '
        'nearby can find you. Use it only during a real emergency.',
    examples: <String>['activate SOS', 'send emergency'],
  );

  static const FeatureDoc sosSetup = FeatureDoc(
    id: 'sos-setup',
    title: 'Set up Emergency SOS',
    kind: FeatureKind.safety,
    icon: Icons.shield_moon_rounded,
    purpose:
        'Sets up the people SOS should contact. You give a name, a phone '
        'number, the relationship and a priority, and you can add up to five '
        'contacts.',
    examples: <String>['set up SOS', 'emergency contacts'],
  );

  static const FeatureDoc scanObject = FeatureDoc(
    id: 'scan-object',
    title: 'Scan Object',
    kind: FeatureKind.vision,
    mode: VisionMode.scanObject,
    icon: Icons.center_focus_strong_rounded,
    purpose:
        'Scan Object identifies an object in front of you and tells you what '
        'it is. Use it when you want to know the name of something you are '
        'looking at.',
    examples: <String>['scan object', 'what is this'],
  );

  static const FeatureDoc readText = FeatureDoc(
    id: 'read-text',
    title: 'Read Text',
    kind: FeatureKind.vision,
    mode: VisionMode.readText,
    icon: Icons.document_scanner_rounded,
    purpose:
        'Read Text reads text from a document, an image or the camera and '
        'speaks it aloud. Say Read Text when you want written information '
        'read out to you.',
    examples: <String>['read text', 'read this'],
  );

  static const FeatureDoc medicine = FeatureDoc(
    id: 'medicine',
    title: 'Medicine Detection',
    kind: FeatureKind.vision,
    mode: VisionMode.medicine,
    icon: Icons.medication_rounded,
    purpose:
        'Medicine Detection identifies a medicine package and reads out the '
        'medicine name and the information printed on it. Use it when you want '
        'help identifying a medicine.',
    examples: <String>['medicine detection', 'read this medicine'],
  );

  static const FeatureDoc product = FeatureDoc(
    id: 'product',
    title: 'Product Detection',
    kind: FeatureKind.vision,
    mode: VisionMode.product,
    icon: Icons.inventory_2_rounded,
    purpose:
        'Product Detection identifies a packaged product and reads useful '
        'information from its label, such as the product name, the brand, the '
        'net quantity, the price, the ingredients and the expiry date when '
        'they are printed.',
    examples: <String>['product detection', 'read this product'],
  );

  static const FeatureDoc currency = FeatureDoc(
    id: 'currency',
    title: 'Currency Detection',
    kind: FeatureKind.vision,
    mode: VisionMode.currency,
    icon: Icons.currency_rupee_rounded,
    purpose:
        'Currency Detection identifies a currency note with the camera and '
        'tells you which currency and denomination it is. Use it when you want '
        'to know the value of the note in your hand.',
    examples: <String>['currency detection', 'check this note'],
  );

  static const FeatureDoc scene = FeatureDoc(
    id: 'scene',
    title: 'Scene Detection',
    kind: FeatureKind.vision,
    mode: VisionMode.scene,
    icon: Icons.landscape_rounded,
    purpose:
        'Scene Detection describes the environment around you so you '
        'understand what is near you. Use it when you arrive somewhere new '
        'or need to know what the place looks like.',
    examples: <String>['scene detection', 'describe my surroundings'],
  );

  static const FeatureDoc objectFinder = FeatureDoc(
    id: 'object-finder',
    title: 'Object Detection',
    kind: FeatureKind.vision,
    mode: VisionMode.objectFinder,
    icon: Icons.radar_rounded,
    purpose:
        'Object Finder looks for one specific object that you name and tells '
        'you when it finds it. Say find my bottle, or find my keys, and point '
        'the camera around. Inside Object Finder you can also ask what is in '
        'front of you and it will identify the objects around you.',
    examples: <String>['find my bottle', 'identify the object'],
  );

  static const FeatureDoc payment = FeatureDoc(
    id: 'payment',
    title: 'Scan Payment',
    kind: FeatureKind.screen,
    icon: Icons.qr_code_2_rounded,
    purpose:
        'Scan Payment reads a U P I Q R code, tells you who you are paying '
        'and how much, and then opens your payment app so you can confirm. '
        'Use it at a shop counter when you are asked to scan to pay.',
    examples: <String>['scan payment', 'pay by Q R'],
  );

  static const FeatureDoc navigation = FeatureDoc(
    id: 'navigation',
    title: 'Smart Navigation',
    kind: FeatureKind.screen,
    icon: Icons.navigation_rounded,
    purpose:
        'Smart Navigation finds nearby places and gives you spoken, step by '
        'step directions to the one you choose. Use it when you need to find '
        'a hospital, a pharmacy, a bank, a bus stop or any other place.',
    examples: <String>['navigate to hospital', 'find the nearest pharmacy'],
  );

  static const FeatureDoc aiHelp = FeatureDoc(
    id: 'ai-help',
    title: 'AI Help',
    kind: FeatureKind.screen,
    icon: Icons.auto_awesome_rounded,
    purpose:
        'AI Help answers spoken questions in plain language, using voice for '
        'both sides of the conversation. Use it whenever you want to ask a '
        'question that is not one of the vision modules.',
    examples: <String>['ask A I help', 'what is inflation'],
  );

  static const FeatureDoc history = FeatureDoc(
    id: 'history',
    title: 'History',
    kind: FeatureKind.action,
    icon: Icons.history_rounded,
    purpose:
        'History replays your previous results. Inside a module, History opens '
        'only that module past results, with the date, the time and what was '
        'detected. On the dashboard it lists which modules have results and '
        'lets you pick one.',
    examples: <String>['show history', 'open history'],
  );

  static const FeatureDoc changeCompanion = FeatureDoc(
    id: 'change-companion',
    title: 'Change Companion',
    kind: FeatureKind.action,
    icon: Icons.swap_horiz_rounded,
    purpose:
        'Change Companion switches the voice that guides you between Alex and '
        'Maya. Your choice is saved to your account, so the same companion '
        'speaks to you every time you sign in.',
    examples: <String>['change companion', 'switch companion'],
  );

  static const FeatureDoc instructions = FeatureDoc(
    id: 'instructions',
    title: 'Repeat Instructions',
    kind: FeatureKind.action,
    icon: Icons.visibility_rounded,
    purpose:
        'Repeat Instructions plays this whole guide again with the voice of '
        'the companion you are currently using. Use it whenever you have '
        'forgotten what something does, or want to hear the steps again.',
    examples: <String>['repeat instructions', 'instructions'],
  );

  /// Every catalog entry, in the order the instructions are spoken.
  static const List<FeatureDoc> all = <FeatureDoc>[
    sos,
    sosSetup,
    scanObject,
    readText,
    medicine,
    product,
    currency,
    scene,
    objectFinder,
    payment,
    navigation,
    aiHelp,
    history,
    changeCompanion,
    instructions,
  ];

  /// Only the features that open a scanner and therefore own a History button.
  static const List<FeatureDoc> vision = <FeatureDoc>[
    scanObject,
    readText,
    medicine,
    product,
    currency,
    scene,
    objectFinder,
  ];

  static const List<FeatureDoc> safety = <FeatureDoc>[sos, sosSetup];

  static const List<FeatureDoc> actions = <FeatureDoc>[
    history,
    changeCompanion,
    instructions,
  ];

  /// Catalog entry for a vision mode, or null when the mode has no module.
  ///
  /// Backs [VisionMode.historyLabel] so the scanner and the dashboard can
  /// never disagree about a module's name or its history.
  static FeatureDoc? forMode(VisionMode mode) {
    for (final feature in all) {
      if (feature.mode == mode) return feature;
    }
    return null;
  }

  /// Catalog entry for a dashboard card title, or null when the card is not a
  /// vision module (Scan Payment).
  ///
  /// Matches on [VisionMode.title] rather than the catalog's own [title], so
  /// the two are guaranteed to agree.
  static FeatureDoc? forTitle(String cardTitle) {
    final normalized = cardTitle.trim().toLowerCase();
    for (final feature in vision) {
      if (feature.requireMode().title.toLowerCase() == normalized) {
        return feature;
      }
    }
    return null;
  }

  static FeatureDoc byId(String id) {
    for (final feature in all) {
      if (feature.id == id) return feature;
    }
    return instructions;
  }

  /// How to reach a vision feature, spoken as one sentence.
  static String reachSpoken(FeatureDoc feature) {
    switch (feature.kind) {
      case FeatureKind.vision:
        return feature.examples.isEmpty
            ? 'Say ${feature.title} to open it.'
            : 'Say ${feature.examples.first} to open it.';
      case FeatureKind.screen:
        return feature.examples.isEmpty
            ? 'Open ${feature.title} from the dashboard.'
            : 'Say ${feature.examples.first} to open it.';
      case FeatureKind.safety:
        return feature.examples.isEmpty
            ? 'Use the S O S control on the dashboard.'
            : 'Say ${feature.examples.first} to open it.';
      case FeatureKind.action:
        return feature.examples.isEmpty
            ? 'Use the ${feature.title} button on the dashboard.'
            : 'Say ${feature.examples.first}.';
    }
  }

  /// How to open a feature's history, spoken.
  static String historySpoken(FeatureDoc feature) {
    if (feature.hasHistory) {
      return 'Say history while ${feature.title} is open to hear that '
          "module's past results.";
    }
    return feature.kind == FeatureKind.screen
        ? 'Say history on the dashboard to open its list.'
        : 'Say history on the dashboard to see every module with results.';
  }

  /// The companion name that speaks the instructions, kept next to the catalog
  /// so a greeting can never name a companion the user did not choose.
  static String greeting(CompanionProfile companion) =>
      '${companion.name} here, your My Eyes companion.';
}
