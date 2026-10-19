import '../core/module_catalog.dart';
import '../core/vision_mode.dart';
import 'companion.dart';

/// Builds the spoken guidance for My Eyes.
///
/// Everything is derived from [ModuleCatalog] and [VisionMode], so a newly
/// added module is explained by the instructions without anyone editing a
/// paragraph here. The only My Eyes-specific knowledge this file adds is the
/// order and the framing sentences ("here is how the app works").
///
/// Two entry points matter:
///  * [dashboardInstructions] - the full guide, played by the eye icon on the
///    dashboard and by "repeat instructions".
///  * [sosInstructions] - the short, dedicated SOS guide, playable from the
///    dashboard without sitting through the whole manual.
class AppInstructions {
  AppInstructions._();

  /// Static, companion-independent SOS guide.
  ///
  /// [activationMechanism] describes the mechanism the app actually uses, so
  /// the sentence can never drift away from the real trigger.
  static String sosInstructions({
    required String companionName,
    String activationMechanism = _defaultActivationMechanism,
    bool configured = true,
  }) {
    final buffer = StringBuffer()
      ..writeln('$companionName here. This is how Emergency S O S works.')
      ..writeln(activationMechanism)
      ..writeln(
        'When you activate it, I try to get your current location, prepare a '
        'message with your name and that location, and send it to your '
        'emergency contacts in priority order.',
      )
      ..writeln(
        'I also start an alarm that sounds for five minutes so people nearby '
        'can hear you. The alarm keeps running while the message is being '
        'sent, and it stops by itself after five minutes.',
      )
      ..writeln(
        'If your location is not available, I still send the alert and tell '
        'your contacts that the location could not be obtained.',
      );

    if (configured) {
      buffer.writeln(
        'Your emergency contacts are already set up. To change them, say '
        'emergency contacts.',
      );
    } else {
      buffer.writeln(
        'Your emergency S O S is not set up yet. Say set up S O S, or use the '
        'emergency contacts button, and I will guide you through adding your '
        'contacts.',
      );
    }

    buffer.write('Only use Emergency S O S during a real emergency.');

    return buffer.toString();
  }

  /// The full dashboard guide.
  ///
  /// Reads as one continuous script: welcome, how to operate the app, the
  /// modules with their purpose, then history, companion, SOS and the ways to
  /// get back. No technical detail (no endpoints, no scan-type names, no
  /// version numbers).
  static String dashboardInstructions({
    required CompanionProfile companion,
    bool sosConfigured = true,
    String activationMechanism = _defaultActivationMechanism,
  }) {    final name = companion.name;
    final buffer = StringBuffer();

    buffer
      ..writeln(
        'Welcome to My Eyes. I am $name, and I will guide you through the '
        'application using voice.',
      )
      ..writeln(ModuleCatalog.greeting(companion))
      ..writeln(
        'My Eyes is controlled mainly by your voice and by a few simple touch '
        'controls. Speak a command at any time, or tap a button on the '
        'dashboard.',
      )
      ..writeln(
        'Every important action is spoken out loud, so you never have to read '
        'the screen to know what happened.',
      )
      ..writeln(
        'If I do not understand you, I will tell you what I can do. You can '
        'also say repeat, and I will say my last answer again.',
      );

    // ---- Safety first -------------------------------------------------
    buffer
      ..writeln('Let us start with your safety.')
      ..writeln(
        '${ModuleCatalog.sos.title}. ${ModuleCatalog.sos.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.sos)}',
      )
      ..writeln(
        '${ModuleCatalog.sosSetup.title}. ${ModuleCatalog.sosSetup.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.sosSetup)}',
      );

    if (!sosConfigured) {
      buffer.writeln(
        'Right now your emergency S O S is not configured. I will guide you '
        'through setting it up after you sign in.',
      );
    }

    // ---- Vision modules ----------------------------------------------
    buffer
      ..writeln('Now the vision modules. Each one does a different job.')
      ..writeln(
        '${ModuleCatalog.readText.title}. ${ModuleCatalog.readText.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.readText)}',
      )
      ..writeln(
        '${ModuleCatalog.medicine.title}. ${ModuleCatalog.medicine.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.medicine)}',
      )
      ..writeln(
        '${ModuleCatalog.product.title}. ${ModuleCatalog.product.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.product)}',
      )
      ..writeln(
        '${ModuleCatalog.currency.title}. ${ModuleCatalog.currency.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.currency)}',
      )
      ..writeln(
        '${ModuleCatalog.scene.title}. ${ModuleCatalog.scene.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.scene)}',
      )
      ..writeln(
        '${ModuleCatalog.objectFinder.title}. ${ModuleCatalog.objectFinder.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.objectFinder)}',
      )
      ..writeln(
        '${ModuleCatalog.scanObject.title}. ${ModuleCatalog.scanObject.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.scanObject)}',
      );

    // ---- Other screens ------------------------------------------------
    buffer
      ..writeln('There are also modules with their own flow.')
      ..writeln(
        '${ModuleCatalog.payment.title}. ${ModuleCatalog.payment.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.payment)}',
      )
      ..writeln(
        '${ModuleCatalog.navigation.title}. ${ModuleCatalog.navigation.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.navigation)}',
      )
      ..writeln(
        '${ModuleCatalog.aiHelp.title}. ${ModuleCatalog.aiHelp.purpose} '
        '${ModuleCatalog.reachSpoken(ModuleCatalog.aiHelp)}',
      );

    // ---- How each module is used -------------------------------------
    buffer
      ..writeln('Here is how you use a vision module.')
      ..writeln(
        'Say the module name, for example read text. I will ask whether to '
        'use the camera or to choose a file.',
      )
      ..writeln(
        'Say camera, and I open the camera for you. Hold the phone steady; it '
        'captures by itself after a few seconds.',
      )
      ..writeln(
        "Say choose a file, and your phone's file picker opens so you can "
        'pick an image or a document that is already on the phone. I will '
        'tell you if that file cannot be read, and you can simply try '
        'another one.',
      )
      ..writeln(
        'While a module is open you can also say help, and I will explain that '
        'module. Say go back, or tap the arrow, to return to the dashboard.',
      );

    // ---- History ------------------------------------------------------
    buffer
      ..writeln('Now, your history.')
      ..writeln(
        'Every module has a History button in its top bar. It shows the date, '
        'the time and what was detected, newest first.',
      )
      ..writeln(
        'You can also say history while a module is open, and I will open that '
        'module history only. Say show history on the dashboard and I will '
        'ask which module you want.',
      )
      ..writeln(
        'If a module has no results yet, I will tell you that there is no '
        'history for it yet, instead of showing an empty screen.',
      );

    // ---- Companion ----------------------------------------------------
    buffer
      ..writeln(
        'You are using $name right now. $name is ${companion.tagline}',
      )
      ..writeln(
        'Say change companion, or tap Change Companion, and I will tell you '
        'which companion you are using and offer to switch you to '
        '${_otherName(companion)}. Your choice is saved to your account, so '
        'the same companion speaks to you when you sign in again.',
      );

    // ---- SOS detail ---------------------------------------------------
    buffer
      ..writeln('Let me repeat the safety part.')
      ..writeln(sosInstructions(
        companionName: name,
        activationMechanism: activationMechanism,
        configured: sosConfigured,
      ));

    // ---- Wrap up ------------------------------------------------------
    buffer
      ..writeln('A few last things you can always do.')
      ..writeln(
        'Say repeat instructions, or tap the eye icon at the top left of this '
        'dashboard, and I will play this whole guide again.',
      )
      ..writeln(
        'Say dashboard, or tap the back arrow, to come back here from any '
        'module.',
      )
      ..writeln(
        'That is everything. $name is here whenever you need me, and you can '
        'ask me to repeat any of this at any time.',
      );

    return buffer.toString();
  }

  /// The one-line summary spoken when the user asks for instructions but the
  /// full guide is already on screen (e.g. from the module History screen).
  static String instructionsShortNotice(CompanionProfile companion) =>
      'Tap the eye icon at the top left of the dashboard, or say repeat '
      'instructions, and I will explain everything again.';

  /// The reason the module History button exists, spoken on the module screen.
  static String moduleHistoryHint(VisionMode mode) =>
      'Say history to open your ${mode.historyLabel}.';

  /// Spoken straight after a module's answer, so the user learns that the scan
  /// was saved and how to see it again.
  ///
  /// This is spoken while the module screen is still open and it then pops to
  /// the dashboard, so the wording has to work in both places: the user must
  /// know the command works *here* (it is answered by this module) and be able
  /// to say the same thing again from the dashboard ("currency history" opens
  /// the same screen).
  static String historyAfterResultSpoken(VisionMode mode) =>
      'This result is saved. Say history now to hear your '
      '${mode.historyLabel}, or say ${mode.title.toLowerCase()} history from '
      'the dashboard to come back to it later.';

  static String _otherName(CompanionProfile current) {
    for (final candidate in Companions.all) {
      if (candidate.id != current.id) return candidate.name;
    }
    return 'other companion';
  }

  /// Default description of how SOS is triggered.
  ///
  /// Must match what the app really does: the dashboard S O S control and the
  /// voice command both open a confirmation screen where the alert is sent.
  static const String _defaultActivationMechanism =
      'To activate Emergency S O S, tap the red S O S control at the top of '
      'the dashboard, or say activate S O S. I then ask you to confirm, and '
      'the alert is sent after a five second countdown so you can cancel it. '
      'Say cancel during the countdown to stop it.';
}
