import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/contact_directory.dart';
import '../../services/sos_contact_store.dart';
import '../../services/voice_command_service.dart';
import '../contacts/voice_contact_picker_screen.dart';

/// Emergency Contacts manager: pick up to 5 contacts from the device contact
/// list, assign priorities 1-5 (highest is called first), and persist them
/// locally (no backend dependency â€” SOS must work offline).
class SosContactsScreen extends StatefulWidget {
  const SosContactsScreen({super.key});

  @override
  State<SosContactsScreen> createState() => _SosContactsScreenState();
}

class _SosContactsScreenState extends State<SosContactsScreen> {
  final VoiceCommandService _voice = VoiceCommandService.instance;

  List<SosContact> _contacts = const [];
  bool _loading = true;
  bool _picking = false;

  /// Ownership token for this screen's voice session, so a late `dispose()`
  /// cannot stop the dashboard session that replaced it.
  int? _voiceSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  @override
  void dispose() {
    _voice.releaseSession(_voiceSession);
    super.dispose();
  }

  Future<void> _setup() async {
    _voiceSession = await _voice.startSession(
      onCommand: _handleCommand,
      autoStart: true,
    );

    await _reload();
    if (!mounted) return;

    await _voice.speak(
      _contacts.isEmpty
          ? 'Emergency contacts. You have no contacts saved yet. '
              'Say add contact to choose up to five people, or say done '
              'when you are finished.'
          : 'You have ${_contacts.length} emergency contacts saved. '
              'Say add contact to add more, or say done when you are finished.',
      pace: TtsPace.important,
    );
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final contacts = await SosContactStore.load();
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _loading = false;
    });
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceCommandService.stripWakeWords(raw);

    if (_picking) {
      if (_containsAny(text, const ['cancel', 'close', 'back'])) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      return;
    }

    if (_containsAny(text, const ['add', 'add contact', 'new contact'])) {
      await _openPicker();
    } else if (_containsAny(text, const ['done', 'close', 'finish', 'back', 'exit'])) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openPicker() async {
    if (_contacts.length >= SosContactStore.maxContacts) {
      await _voice.speak(
        'You already have ${SosContactStore.maxContacts} emergency contacts. '
        'Remove one before adding another.',
        resumeAfter: false,
      );
      return;
    }

    setState(() => _picking = true);

    // Choose from the contacts already on the phone, by voice.
    //
    // This screen previously opened its own bottom sheet with a "Search
    // contacts" text field above a scrollable list. That is unusable for the
    // user this app exists for: a blind user cannot type into a search box
    // they cannot see, cannot see how the results filtered, and gets no spoken
    // position for any row. The voice picker announces four contacts at a
    // time, accepts a name, a position or a phone number, and reads the number
    // back digit by digit before anything is saved.
    final picked = await Navigator.of(context).push<DeviceContact>(
      MaterialPageRoute(
        builder: (_) => VoiceContactPickerScreen(
          title: 'Choose an emergency contact',
          excludePhones: _contacts.map((c) => c.phone).toSet(),
        ),
      ),
    );

    if (!mounted) return;
    setState(() => _picking = false);

    // The picker explains its own failure (contacts permission, no contacts on
    // the phone) in detail. Returning in silence would leave a blind user with
    // no idea whether they had cancelled or something had gone wrong.
    if (picked == null) {
      await _voice.speak(
        'No contact was added. Say add contact to try again, '
        'or say done when you are finished.',
        resumeAfter: false,
      );
      await _voice.resumeMicrophone();
      return;
    }

    await _applySelection(picked);
  }

  Future<void> _applySelection(DeviceContact entry) async {
    final added = await SosContactStore.addContact(
      deviceId: entry.phone,
      name: entry.name,
      phone: entry.phone,
    );

    if (!mounted) return;
    await _reload();

    final priority = _priorityOf(entry.phone);
    final message = added
        ? '${entry.name} added as emergency contact $priority. '
            'Say add contact for another, or say done.'
        : '${entry.name} could not be added. You can save up to five '
            'different contacts.';

    await _voice.speak(message, resumeAfter: false);

    // Reopen the microphone: the next thing this screen expects is another
    // command, and returning to a shut microphone leaves the user talking to
    // an app that is not listening.
    if (!mounted) return;
    await _voice.resumeMicrophone();
  }

  int _priorityOf(String phone) {
    final normalized = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    for (final c in _contacts) {
      if (c.phone.replaceAll(RegExp(r'[\s\-\(\)]'), '') == normalized) {
        return c.priority;
      }
    }
    return 1;
  }

  Future<void> _move(String phone, int delta) async {
    final index = _contacts.indexWhere(
      (c) => c.phone.replaceAll(RegExp(r'[\s\-\(\)]'), '') ==
          phone.replaceAll(RegExp(r'[\s\-\(\)]'), ''),
    );
    if (index < 0) return;
    final newPriority = (index + 1) + delta;
    await SosContactStore.setPriority(phone: phone, newPriority: newPriority);
    if (!mounted) return;
    await _reload();
    await _voice.speak(
      delta < 0 ? 'Priority increased.' : 'Priority decreased.',
      resumeAfter: false,
    );
  }

  Future<void> _remove(String phone, String name) async {
    await SosContactStore.removeContact(phone);
    if (!mounted) return;
    await _reload();
    await _voice.speak('$name removed from emergency contacts.',
        resumeAfter: false);
  }

  bool _containsAny(String text, List<String> words) {
    for (final w in words) {
      if (text.contains(w)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text(
          'Emergency Contacts',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _infoCard(),
              const SizedBox(height: 20),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(
                      color: AppTheme.accent,
                    ),
                  ),
                )
              else if (_contacts.isEmpty)
                _emptyCard()
              else
                ..._contacts.map((c) => _contactCard(c)),
              const SizedBox(height: 20),
              _addButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppTheme.surface,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFF3B3B).withValues(alpha: 0.18),
            ),
            child: const Icon(
              Icons.security_rounded,
              color: Color(0xFFFF3B3B),
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'SOS alerting will message all ${_contacts.length}/'
              '${SosContactStore.maxContacts} contacts and open calls to the '
              'top 3 priorities. Stored on your device only.',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppTheme.surface,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          const Icon(Icons.contacts_rounded, color: Colors.white30, size: 44),
          const SizedBox(height: 12),
          const Text(
            'No emergency contacts yet. Say add contact, or tap the button, '
            'to choose people from your phone book.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _contactCard(SosContact contact) {
    final index = _contacts.indexWhere(
      (c) => c.phone.replaceAll(RegExp(r'[\s\-\(\)]'), '') ==
          contact.phone.replaceAll(RegExp(r'[\s\-\(\)]'), ''),
    );
    final canMoveUp = index > 0;
    final canMoveDown = index >= 0 && index < _contacts.length - 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppTheme.surface,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFF3B3B).withValues(alpha: 0.2),
            ),
            child: Text(
              '${contact.priority}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Priority ${contact.priority} Â· ${contact.phone}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          _iconButton(
            icon: Icons.arrow_upward_rounded,
            enabled: canMoveUp,
            tooltip: 'Increase priority',
            onTap: canMoveUp ? () => _move(contact.phone, -1) : null,
          ),
          _iconButton(
            icon: Icons.arrow_downward_rounded,
            enabled: canMoveDown,
            tooltip: 'Decrease priority',
            onTap: canMoveDown ? () => _move(contact.phone, 1) : null,
          ),
          _iconButton(
            icon: Icons.delete_outline_rounded,
            enabled: true,
            tooltip: 'Remove contact',
            color: AppTheme.error,
            onTap: () => _remove(contact.phone, contact.name),
          ),
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required bool enabled,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      color: enabled
          ? (color ?? Colors.white70)
          : Colors.white24,
      tooltip: tooltip,
      onPressed: onTap,
    );
  }

  Widget _addButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _openPicker,
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [Color(0xFF6C63FF), Color(0xFF9B6CFF)],
            ),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
              SizedBox(width: 10),
              Text(
                'Add contact',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
