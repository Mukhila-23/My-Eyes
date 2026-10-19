import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/biometric_service.dart';
import '../../services/contact_directory.dart';
import '../../services/contact_matcher.dart';
import '../../services/emergency_service.dart';
import '../../services/voice_command_service.dart';
import '../contacts/voice_contact_picker_screen.dart';

/// Emergency Contacts manager.
///
/// Voice-first list of verified emergency contacts. Adding, editing,
/// deleting and switching primary are protected by biometric
/// authentication (local_auth), matching the app's security model.
class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  bool _loading = true;
  String _error = '';
  List<EmergencyContact> _contacts = const [];

  /// Ownership token for this screen's voice session, so a late `dispose()`
  /// cannot stop the dashboard session that replaced it.
  int? _voiceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _start() async {
    await _loadContacts(speak: true);
    if (!mounted) return;
    _voiceSession = await _voice.startSession(onCommand: _handleCommand);
  }

  Future<void> _loadContacts({bool speak = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });

    List<EmergencyContact> contacts;
    try {
      contacts = await EmergencyService.fetchContacts();
    } catch (e) {
      contacts = const [];
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      if (speak) {
        await _voice.speak(
          _error.isEmpty
              ? 'I could not load your emergency contacts.'
              : 'I could not load your contacts. $_error',
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _loading = false;
    });

    if (speak) {
      await _voice.speak(_describeContacts());
    }
  }

  String _describeContacts() {
    if (_contacts.isEmpty) {
      return 'You have no emergency contacts saved yet. '
          'Say add contact to create one.';
    }

    final primary = _contacts.where((c) => c.isPrimary).toList();
    final others = _contacts.where((c) => !c.isPrimary).toList();

    final buffer = StringBuffer('You have ${_contacts.length} emergency contacts. ');
    if (primary.isNotEmpty) {
      buffer.write('Primary: ${primary.first.name}, ${primary.first.phoneNumber}. ');
    }
    if (others.isNotEmpty) {
      for (var i = 0; i < others.length; i++) {
        buffer.write(
            '${i + 1}: ${others[i].name}, ${others[i].phoneNumber}. ');
      }
    }
    buffer.write('Say add contact to add one, or contact number for options.');
    return buffer.toString();
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceCommandService.stripWakeWords(raw);

    if (VoiceCommandService.isBackCommand(text)) {
      Navigator.of(context).pop();
      return;
    }

    if (VoiceCommandService.isRepeatCommand(text)) {
      await _voice.speak(_describeContacts());
      return;
    }

    if (VoiceCommandService.isHelpCommand(text)) {
      await _voice.speak(
        'Say add contact to add a new emergency contact. '
        'Or say contact one, contact two, to manage a specific contact.',
      );
      return;
    }

    if (text.contains('add') || text.contains('new contact') ||
        text.contains('create contact')) {
      _openContactForm();
      return;
    }

    final match = RegExp(r'contact\s+(?:number\s+)?(\d{1,2})').firstMatch(text);
    if (match != null) {
      final index = int.parse(match.group(1)!);
      await _manageContact(index);
    }
  }

  Future<void> _manageContact(int spokenIndex) async {
    final others = _contacts.where((c) => !c.isPrimary).toList();
    if (spokenIndex < 1 || spokenIndex > others.length) {
      await _voice.speak('I could not find contact $spokenIndex. Say repeat to hear your contacts.');
      return;
    }

    final contact = others[spokenIndex - 1];
    await _voice.speak(
      '${contact.name}, ${contact.phoneNumber}. '
      'Say edit to change details, set primary to make them your primary, '
      'or delete to remove them.',
    );
  }

  void _openContactForm({EmergencyContact? contact}) async {
    final authenticated =
        await _authenticate(contact == null ? 'add' : 'edit');

    // No form unless the user's identity is verified.
    if (!authenticated) {
      await _voice.speak('Biometric verification was cancelled.', resumeAfter: false);
      return;
    }

    if (!mounted) return;

    final saved = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ContactFormScreen(existing: contact),
      ),
    );

    if (saved == null) return;
    await _loadContacts(speak: true);
  }

  Future<void> _setPrimary(EmergencyContact contact) async {
    final authenticated = await _authenticate('set primary');
    if (!authenticated) {
      await _voice.speak('Biometric verification was cancelled.', resumeAfter: false);
      return;
    }

    try {
      await EmergencyService.setPrimary(contact.id);
    } catch (e) {
      await _voice.speak('Could not set primary contact. $e', resumeAfter: false);
      return;
    }

    await _loadContacts(speak: true);
  }

  Future<void> _delete(EmergencyContact contact) async {
    final authenticated = await _authenticate('delete');
    if (!authenticated) {
      await _voice.speak('Biometric verification was cancelled.', resumeAfter: false);
      return;
    }

    try {
      await EmergencyService.deleteContact(contact.id);
    } catch (e) {
      await _voice.speak('Could not delete the contact. $e', resumeAfter: false);
      return;
    }

    await _voice.speak('${contact.name} has been deleted.', resumeAfter: false);
    await _loadContacts(speak: true);
  }

  Future<bool> _authenticate(String action) async {
    await _voice.pauseMicrophone();
    final result = await BiometricService.authenticate();
    await _voice.resumeMicrophone();
    return result.authenticated;
  }

  @override
  Widget build(BuildContext context) {
    final primary = const Color(0xFFFF5FA2);
    final secondary = const Color(0xFF9B5CFF);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, primary, secondary),
            Expanded(
              child: _buildBody(primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    Color primary,
    Color secondary,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 12),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: () => Navigator.of(context).pop(),
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
          const SizedBox(width: 15),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: LinearGradient(colors: [primary, secondary]),
            ),
            child: const Icon(
              Icons.emergency_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emergency Contacts',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Verified people to alert in an emergency',
                  style: TextStyle(
                    color: Color(0x73FFFFFF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _addButton(context, primary),
        ],
      ),
    );
  }

  Widget _addButton(BuildContext context, Color primary) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () => _openContactForm(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary,
          ),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 26),
        ),
      ),
    );
  }

  Widget _buildBody(Color primary) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_error.isNotEmpty) {
      return _buildMessage(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load contacts',
        subtitle: _error,
        color: primary,
      );
    }

    if (_contacts.isEmpty) {
      return _buildMessage(
        icon: Icons.emergency_rounded,
        title: 'No emergency contacts yet',
        subtitle: 'Tap the add button or say "add contact" to create one.\n'
            'Your primary contact is notified first in an SOS.',
        color: primary,
        action: _addButton(context, primary),
      );
    }

    final primaryContact = _contacts.where((c) => c.isPrimary).toList();
    final others = _contacts.where((c) => !c.isPrimary).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 30),
      children: [
        if (primaryContact.isNotEmpty) ...[
          _sectionLabel('PRIMARY'),
          const SizedBox(height: 8),
          _contactCard(primaryContact.first, isPrimary: true, color: primary),
          const SizedBox(height: 22),
        ],
        if (others.isNotEmpty) ...[
          _sectionLabel('SECONDARY'),
          const SizedBox(height: 8),
          ..._buildSecondaryCards(others, primary),
        ],
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 2,
      ),
    );
  }

  List<Widget> _buildSecondaryCards(
    List<EmergencyContact> contacts,
    Color color,
  ) {
    return contacts.asMap().entries.map((entry) {
      final card = _contactCard(
        entry.value,
        isPrimary: false,
        color: color,
        number: entry.key + 1,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: card,
      );
    }).toList();
  }

  Widget _contactCard(
    EmergencyContact contact, {
    required bool isPrimary,
    required Color color,
    int? number,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(
          color: isPrimary
              ? color.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.07),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: isPrimary
                    ? [const Color(0xFFFF5FA2), const Color(0xFF9B5CFF)]
                    : [color.withValues(alpha: 0.7), const Color(0xFF6674FF)],
              ),
            ),
            child: Icon(
              isPrimary ? Icons.star_rounded : Icons.person_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        contact.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isPrimary) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: color.withValues(alpha: 0.2),
                        ),
                        child: Text(
                          'PRIMARY',
                          style: TextStyle(
                            color: color,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  contact.phoneNumber,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  contact.relationship,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isPrimary)
            PopupMenuButton<String>(
              color: const Color(0xFF23233A),
              icon: Icon(
                Icons.more_vert_rounded,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              onSelected: (value) async {
                switch (value) {
                  case 'primary':
                    await _setPrimary(contact);
                    break;
                  case 'edit':
                    _openContactForm(contact: contact);
                    break;
                  case 'delete':
                    await _delete(contact);
                    break;
                }
              },
              itemBuilder: (context) => [
                if (number != null)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete'),
                  )
                else ...[
                  const PopupMenuItem(
                    value: 'primary',
                    child: Text('Set as primary'),
                  ),
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete'),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            color: Colors.white.withValues(alpha: 0.035),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [color, const Color(0xFF6674FF)]),
                ),
                child: Icon(icon, color: Colors.white, size: 32),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 24),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Voice-driven contact editor.
///
/// There are deliberately no text fields here.
///
/// Every emergency-contact path in this app used a `TextFormField` for the
/// name, the phone number and the relationship. That is unusable for the user
/// this app exists for: a blind person cannot type a name they cannot see,
/// cannot check a mistyped digit, and has no way to confirm the number before
/// it becomes the number an ambulance calls in a crisis.
///
/// So the contact is *chosen* instead: from the contacts already on the phone,
/// by voice, with the number spoken back digit by digit for confirmation before
/// anything is saved. Tapping still works, so nobody is locked out.
class ContactFormScreen extends StatefulWidget {
  const ContactFormScreen({super.key, this.existing});

  final EmergencyContact? existing;

  @override
  State<ContactFormScreen> createState() => _ContactFormScreenState();
}

class _ContactFormScreenState extends State<ContactFormScreen>
    with WidgetsBindingObserver {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  /// The contact being added or edited, or null while choosing.
  DeviceContact? _chosen;

  /// Relationship, chosen from a fixed list instead of typed.
  ///
  /// A relationship is a small closed set, so it is a choice, never free text.
  static const List<String> _relationships = [
    'Mother',
    'Father',
    'Spouse',
    'Brother',
    'Sister',
    'Son',
    'Daughter',
    'Guardian',
    'Friend',
    'Neighbour',
  ];

  String _relationship = 'Guardian';

  /// True while the voice-driven relationship question is outstanding.
  bool _awaitingRelationship = false;

  bool _saving = false;
  bool _busy = false;
  String _message = '';

  /// Ownership token. This screen must own the session: the parent list screen
  /// pushed it, and without a token of its own every spoken command here would
  /// be delivered to the parent's handler.
  int? _voiceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final existing = widget.existing;
    if (existing != null) {
      _chosen = DeviceContact(
        name: existing.name,
        phone: ContactDirectory.normalizePhone(existing.phoneNumber),
      );
      _relationship = _normaliseRelationship(existing.relationship);
    }

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

  /// Maps a stored relationship back onto the offered list, so a value saved by
  /// an older build still highlights the right option instead of matching
  /// nothing.
  static String _normaliseRelationship(String stored) {
    final lower = stored.toLowerCase();
    for (final option in _relationships) {
      if (option.toLowerCase() == lower) return option;
    }
    return 'Guardian';
  }

  Future<void> _start() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      autoStart: false,
    );
    if (!mounted) return;
    await _announce();
  }

  Future<void> _announce() async {
    final contact = _chosen;

    if (contact == null) {
      await _voice.speak(
        'Choose an emergency contact. Say choose contact to pick someone from '
        'your phone, or say cancel to go back.',
        resumeAfter: false,
      );
      return;
    }

    await _voice.speak(
      '${contact.name}, number ${contact.spokenPhone}. '
      'Relationship: $_relationship. '
      'Say choose contact to change the person, say change relationship to '
      'change how you are related, say save to keep this contact, or say '
      'cancel.',
      resumeAfter: false,
    );
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceCommandService.stripWakeWords(raw).toLowerCase().trim();
    if (text.isEmpty || _saving) return;

    if (ContactMatcher.isCancel(text)) {
      await _leave();
      return;
    }

    // The relationship question is outstanding: any answer that names one of
    // the options is taken as the answer, before the general commands below
    // can swallow it.
    if (_awaitingRelationship) {
      if (_takeRelationship(text)) return;
      if (text.contains('skip') || text.contains('keep')) {
        setState(() => _awaitingRelationship = false);
        await _announce();
        return;
      }
      await _askRelationship();
      return;
    }

    if (text.contains('relationship') || text.contains('related')) {
      await _askRelationship();
      return;
    }

    if (text.contains('choose') || text.contains('pick') ||
        text.contains('change contact') || text.contains('another contact')) {
      await _openPicker();
      return;
    }

    if (text.contains('save') || text.contains('confirm') ||
        text.contains('done') || text.contains('keep')) {
      await _save();
      return;
    }

    await _voice.speak(
      'Say choose contact, change relationship, save, or cancel.',
      resumeAfter: false,
    );
  }

  Future<void> _openPicker() async {
    if (_busy) return;
    setState(() => _busy = true);
    _voice.stopSpeaking();

    final picked = await Navigator.of(context).push<DeviceContact>(
      MaterialPageRoute(
        builder: (_) => const VoiceContactPickerScreen(
          title: 'Choose an emergency contact',
        ),
      ),
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (picked != null) {
        _chosen = picked;
        _message = '';
      }
    });

    await _announce();
  }

  Future<void> _askRelationship() async {
    setState(() => _awaitingRelationship = true);

    await _voice.speak(
      'How is this person related to you? You can say '
      '${_relationships.take(5).join(', ')}, '
      '${_relationships.skip(5).take(5).join(', ')}, '
      'or say skip to keep $_relationship.',
      resumeAfter: false,
    );
    if (!mounted) return;

    await _voice.resumeMicrophone();
  }

  /// Reads a relationship out of a spoken answer. Returns true when it matched
  /// one, so the caller can stop; false asks the question again.
  ///
  /// Accepts the plain word ("mother") and the natural sentence ("she is my
  /// mother"), because a user answering an open question rarely says just the
  /// noun.
  bool _takeRelationship(String text) {
    final options = _relationships.map((r) => r.toLowerCase()).toList();

    for (final option in options) {
      if (text.contains(option)) {
        setState(() {
          _relationship = _titleCase(option);
          _awaitingRelationship = false;
        });
        _announce();
        return true;
      }
    }
    return false;
  }

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  Future<void> _save() async {
    final contact = _chosen;
    if (contact == null) {
      await _voice.speak(
        'Choose a contact first. Say choose contact.',
        resumeAfter: false,
      );
      return;
    }

    setState(() => _saving = true);

    try {
      if (widget.existing == null) {
        await EmergencyService.addContact(
          name: contact.name,
          phoneNumber: contact.phone,
          relationship: _relationship,
        );
      } else {
        await EmergencyService.updateContact(
          widget.existing!.id,
          name: contact.name,
          phoneNumber: contact.phone,
          relationship: _relationship,
        );
      }

      if (!mounted) return;
      await _voice.speak(
        '${contact.name} saved as an emergency contact.',
        resumeAfter: false,
      );
      if (!mounted) return;
      Navigator.of(context).pop(<String, dynamic>{'saved': true});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = e.toString();
      });
      await _voice.speak(
        'I could not save that contact. $e',
        resumeAfter: false,
        pace: TtsPace.important,
      );
    }
  }

  Future<void> _leave() async {
    await _voice.stopSpeaking();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final primary = const Color(0xFFFF5FA2);
    final contact = _chosen;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(isEdit ? 'Edit Contact' : 'New Contact'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _option(
                  icon: Icons.person_rounded,
                  label: 'Contact',
                  value: contact == null
                      ? 'Not chosen yet'
                      : '${contact.name} - ${contact.spokenPhone}',
                  hint: 'Say choose contact, or tap here',
                  color: primary,
                  onTap: _busy ? null : _openPicker,
                ),
                const SizedBox(height: 14),
                _option(
                  icon: Icons.family_restroom_rounded,
                  label: 'Relationship',
                  value: _awaitingRelationship
                      ? 'Say it now, or say skip'
                      : _relationship,
                  hint: 'Say change relationship, or tap here',
                  color: primary,
                  onTap: _busy ? null : _askRelationship,
                ),
                const SizedBox(height: 20),
                if (_message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _message,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _saving || _busy ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(
                      isEdit ? 'Save Changes' : 'Add Contact',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _awaitingRelationship
                      ? 'Listening for a relationship. Say mother, father, '
                          'spouse, guardian, or skip.'
                      : 'Nothing here is typed. Everything is chosen and '
                          'spoken.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A read-only summary row. Shaped like a form field on purpose, so the
  /// layout still reads as "contact details" - but there is no keyboard behind
  /// it, because its value is always the result of a choice, never of typing.
  Widget _option({
    required IconData icon,
    required String label,
    required String value,
    required String hint,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Semantics(
      button: true,
      label: '$label, $value',
      hint: hint,
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
