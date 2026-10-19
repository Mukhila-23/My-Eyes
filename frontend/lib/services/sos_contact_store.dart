import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage/secure_storage.dart';
import 'emergency_service.dart';

/// A locally persisted emergency contact selected from the device contact
/// list. Up to [SosContactStore.maxContacts] contacts can be configured.
class SosContact {
  const SosContact({
    required this.id,
    required this.name,
    required this.phone,
    this.priority = 1,
  });

  /// Stable id (device contact id + phone) so re-picking does not duplicate.
  final String id;
  final String name;

  /// E.164-ish number used for SMS and calls.
  final String phone;

  /// 1 (highest priority, called first) .. 5 (lowest).
  final int priority;

  factory SosContact.fromJson(Map<String, dynamic> json) => SosContact(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        priority: json['priority'] as int? ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'priority': priority,
      };

  SosContact copyWith({int? priority}) => SosContact(
        id: id,
        name: name,
        phone: phone,
        priority: priority ?? this.priority,
      );
}

/// Persists the user's emergency contacts locally (device contacts only,
/// priority 1-5, max 5). No backend dependency: SOS must work offline.
class SosContactStore {
  SosContactStore._();

  static const int maxContacts = 5;

  /// Loads saved contacts, newest first. Never throws; returns [] on failure.
  static Future<List<SosContact>> load() async {
    try {
      final raw = await SecureStorage.readSosContacts();
      if (raw == null || raw.isEmpty) return const [];
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(SosContact.fromJson)
          .toList();
      return list..sort((a, b) => a.priority.compareTo(b.priority));
    } catch (_) {
      return const [];
    }
  }

  /// Replaces the local list with the account's contacts from the backend.
  ///
  /// This is how a contact chosen on one device (or through the voice setup
  /// flow, which writes to the backend) reaches the phone that actually runs
  /// SOS. The local copy still exists on purpose: the emergency path must work
  /// with no network at all, so the backend is the source of truth when it is
  /// reachable and this store is the offline mirror.
  ///
  /// Returns the number of contacts mirrored. Returns 0 without touching the
  /// local list when the server cannot be reached, so a temporary outage can
  /// never wipe a working emergency configuration.
  static Future<int> syncFromServer() async {
    try {
      final remote = await EmergencyService.fetchContacts();
      if (remote.isEmpty) return 0;

      final mirrored = remote
          .map(
            (contact) => SosContact(
              id: 'server-${contact.id}',
              name: contact.name,
              phone: contact.phoneNumber,
              priority: contact.priority.clamp(1, maxContacts),
            ),
          )
          .toList();

      await save(mirrored);
      return mirrored.length;
    } catch (error) {
      debugPrint('[SOS] contact sync skipped: $error');
      return 0;
    }
  }

  /// True when the phone already mirrors at least one server-sourced contact.
  ///
  /// Lets the setup flow tell "never configured" apart from "configured
  /// elsewhere but not on this phone", which need different spoken guidance.
  static Future<bool> hasServerContacts() async {
    final contacts = await load();
    return contacts.any((contact) => contact.id.startsWith('server-'));
  }

  static Future<void> save(List<SosContact> contacts) async {
    final sorted = [...contacts]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final trimmed = sorted.take(maxContacts).toList();
    await SecureStorage.saveSosContacts(jsonEncode(trimmed.map((c) => c.toJson()).toList()));
  }

  /// Attempts to add a device contact, assigning the lowest free priority.
  /// Returns true when saved, false when the list is already full or the
  /// contact is a duplicate.
  static Future<bool> addContact({
    required String deviceId,
    required String name,
    required String phone,
  }) async {
    final existing = await load();
    final normalizedPhone = _normalizePhone(phone);
    if (normalizedPhone.isEmpty) return false;
    if (existing.any((c) => _normalizePhone(c.phone) == normalizedPhone)) {
      return false;
    }
    if (existing.length >= maxContacts) return false;

    final used = existing.map((c) => c.priority).toSet();
    var priority = 1;
    while (used.contains(priority)) {
      priority++;
    }

    final next = [
      ...existing,
      SosContact(
        id: '$_deviceIdHash|$normalizedPhone',
        name: name,
        phone: normalizedPhone,
        priority: priority,
      ),
    ];
    await save(next);
    return true;
  }

  static Future<void> removeContact(String phone) async {
    final existing = await load();
    await save(existing
        .where((c) => _normalizePhone(c.phone) != _normalizePhone(phone))
        .toList());
  }

  /// Re-assigns the priority of one contact, shifting others out of the way
  /// so priorities stay dense and unique (1..n, n <= 5).
  static Future<void> setPriority({
    required String phone,
    required int newPriority,
  }) async {
    final existing = await load();
    if (existing.isEmpty) return;

    final current = existing.toList();
    final target =
        current.indexWhere((c) => _normalizePhone(c.phone) == _normalizePhone(phone));
    if (target < 0) return;

    var clamped = newPriority.clamp(1, maxContacts);
    if (clamped > current.length) clamped = current.length;

    final moving = current.removeAt(target);
    current.insert(clamped - 1, moving);

    final renumbered = <SosContact>[];
    for (var i = 0; i < current.length; i++) {
      renumbered.add(current[i].copyWith(priority: i + 1));
    }
    await save(renumbered);
  }

  static String _normalizePhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    return digits.length >= 7 ? digits : '';
  }

  static String _deviceIdHash(String deviceId) {
    var hash = 0;
    for (final unit in deviceId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash.toRadixString(36);
  }
}