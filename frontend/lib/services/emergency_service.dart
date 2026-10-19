import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import 'api_error.dart';
import 'auth_service.dart';

/// Model for an emergency contact returned/stored by the backend.
class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phoneNumber,
    required this.relationship,
    required this.priority,
  });

  final int id;
  final String name;
  final String phoneNumber;
  final String relationship;
  final int priority;

  bool get isPrimary => priority == 1;

  Map<String, dynamic> toJson() => {
        'name': name,
        'phone_number': phoneNumber,
        'relationship': relationship,
        'priority': priority,
      };

  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact(
        id: json['id'] as int,
        name: json['name'] as String,
        phoneNumber: json['phone_number'] as String,
        relationship: json['relationship'] as String,
        priority: json['priority'] as int,
      );
}

/// Model for a triggered SOS event.
class SOSEvent {
  const SOSEvent({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.contactCount,
    required this.triggeredAt,
    this.locationStatus = 'UNAVAILABLE',
    this.notifiedCount = 0,
  });

  final int id;
  final double? latitude;
  final double? longitude;
  final String status;
  final int contactCount;
  final DateTime triggeredAt;
  final String locationStatus;
  final int notifiedCount;

  factory SOSEvent.fromJson(Map<String, dynamic> json) => SOSEvent(
        id: json['id'] as int,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        status: json['status'] as String,
        contactCount: json['contact_count'] as int? ?? 0,
        notifiedCount: json['notified_count'] as int? ?? 0,
        locationStatus: json['location_status'] as String? ?? 'UNAVAILABLE',
        triggeredAt: DateTime.tryParse(
              json['triggered_at']?.toString() ?? '',
            ) ??
            DateTime.now(),
      );
}

/// Server-side SOS configuration, read on every login.
///
/// `configured` is the single authority on whether this user is protected. It
/// comes from the backend's `emergency_contacts` rows for the authenticated
/// user, so the app can never claim SOS is set up when it is not.
class SosConfiguration {
  const SosConfiguration({
    required this.configured,
    required this.contactCount,
    required this.alarmEnabled,
    required this.alarmDurationSeconds,
    this.primaryContact,
    this.contacts = const [],
  });

  final bool configured;
  final int contactCount;
  final String? primaryContact;
  final List<EmergencyContact> contacts;
  final bool alarmEnabled;
  final int alarmDurationSeconds;

  /// A user with contacts on the server but none on this phone still needs
  /// them locally for the offline SOS path, so this is the value the caller
  /// should mirror into the local store.
  static const SosConfiguration unavailable = SosConfiguration(
    configured: false,
    contactCount: 0,
    alarmEnabled: true,
    alarmDurationSeconds: 300,
  );

  factory SosConfiguration.fromJson(Map<String, dynamic> json) {
    final rawContacts = json['contacts'];
    final contacts = <EmergencyContact>[];
    if (rawContacts is List) {
      for (final entry in rawContacts) {
        if (entry is Map<String, dynamic>) {
          try {
            contacts.add(EmergencyContact.fromJson(entry));
          } catch (_) {
            // One malformed row must not hide the rest.
          }
        }
      }
    }

    return SosConfiguration(
      configured: json['configured'] as bool? ?? false,
      contactCount: (json['contact_count'] as num?)?.toInt() ?? contacts.length,
      primaryContact: json['primary_contact'] as String?,
      contacts: contacts,
      alarmEnabled: json['alarm_enabled'] as bool? ?? true,
      alarmDurationSeconds:
          (json['alarm_duration_seconds'] as num?)?.toInt() ?? 300,
    );
  }
}

/// Outcome of `POST /sos-events/trigger`.
class SosTriggerResult {
  const SosTriggerResult({
    required this.success,
    required this.eventId,
    required this.status,
    required this.message,
    required this.locationIncluded,
    required this.locationStatus,
    required this.contactCount,
    required this.notifiedCount,
    required this.failedCount,
    required this.deliveryMethod,
    this.contactsNotified = const [],
    this.mapLink,
  });

  final bool success;
  final int eventId;
  final String status;
  final String message;
  final bool locationIncluded;
  final String locationStatus;
  final int contactCount;
  final int notifiedCount;
  final int failedCount;

  /// "server" = the backend dispatched it, "client" = the phone must hand it
  /// to the messaging app, "none" = nothing was sent.
  final String deliveryMethod;

  final List<String> contactsNotified;
  final String? mapLink;

  factory SosTriggerResult.fromJson(Map<String, dynamic> json) {
    final notified = json['contacts_notified'];
    return SosTriggerResult(
      success: json['success'] as bool? ?? false,
      eventId: (json['event_id'] as num?)?.toInt() ?? -1,
      status: json['status'] as String? ?? 'FAILED',
      message: json['message'] as String? ?? '',
      locationIncluded: json['location_included'] as bool? ?? false,
      locationStatus: json['location_status'] as String? ?? 'UNAVAILABLE',
      contactCount: (json['contact_count'] as num?)?.toInt() ?? 0,
      notifiedCount: (json['notified_count'] as num?)?.toInt() ?? 0,
      failedCount: (json['failed_count'] as num?)?.toInt() ?? 0,
      deliveryMethod: json['delivery_method'] as String? ?? 'none',
      contactsNotified: notified is List
          ? notified.map((value) => value.toString()).toList()
          : const [],
      mapLink: json['map_link'] as String?,
    );
  }
}

/// Raised when the backend says SOS has no contacts yet.
///
/// Distinct from a network failure: the user must be offered setup, not a
/// retry.
class SosNotConfiguredException implements Exception {
  const SosNotConfiguredException();

  String get spoken =>
      'No emergency contacts are configured. Please set up SOS before using it.';
}

/// Thin HTTP client for the emergency/safety backend, mirroring the
/// conventions used by [AuthService] (JWT bearer token + FastAPI).
class EmergencyService {
  EmergencyService._();

  static const baseUrl = AuthService.baseUrl;
  static const maxContacts = 5;

  // ------------------------------------------------------------
  // EMERGENCY CONTACTS
  // ------------------------------------------------------------

  static Future<List<EmergencyContact>> fetchContacts() async {
    final response = await _get('/emergency-contacts');
    final body = _decode(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'Unable to load your contacts.',
        ),
      );
    }

    final list = body as List<dynamic>;
    return list
        .map((e) => EmergencyContact.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<EmergencyContact> addContact({
    required String name,
    required String phoneNumber,
    required String relationship,
    int priority = 2,
  }) async {
    final response = await _post(
      '/emergency-contacts',
      {
        'name': name,
        'phone_number': phoneNumber,
        'relationship': relationship,
        'priority': priority,
      },
    );

    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'Unable to save the contact.',
        ),
      );
    }

    return EmergencyContact.fromJson(body as Map<String, dynamic>);
  }

  static Future<EmergencyContact> updateContact(
    int id, {
    required String name,
    required String phoneNumber,
    required String relationship,
  }) async {
    final response = await _put(
      '/emergency-contacts/$id',
      {
        'name': name,
        'phone_number': phoneNumber,
        'relationship': relationship,
      },
    );

    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'Unable to update the contact.',
        ),
      );
    }

    return EmergencyContact.fromJson(body as Map<String, dynamic>);
  }

  static Future<void> deleteContact(int id) async {
    final response = await _delete('/emergency-contacts/$id');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = _decode(response);
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'Unable to delete the contact.',
        ),
      );
    }
  }

  static Future<EmergencyContact> setPrimary(int id) async {
    final response = await _put('/emergency-contacts/$id/primary', {});
    final body = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'Unable to set the primary contact.',
        ),
      );
    }
    return EmergencyContact.fromJson(body as Map<String, dynamic>);
  }

  // ------------------------------------------------------------
  // SOS CONFIGURATION / TRIGGER
  // ------------------------------------------------------------

  /// Reads whether the authenticated user has usable emergency contacts.
  ///
  /// Throws [AuthException] on transport/auth failure so the login flow can
  /// tell "not configured" apart from "could not check", and never answers
  /// "configured" without a successful read.
  static Future<SosConfiguration> fetchSosConfiguration() async {
    final response = await _get('/sos-events/status');
    final body = _decode(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback: 'I could not check your emergency setup right now.',
        ),
      );
    }

    if (body is! Map<String, dynamic>) {
      throw const AuthException(
        'I could not check your emergency setup right now.',
      );
    }

    return SosConfiguration.fromJson(body);
  }

  /// Triggers one SOS for the authenticated user.
  ///
  /// Coordinates are optional by design: a failed GPS fix must still produce an
  /// alert that says the location is unavailable. Throws
  /// [SosNotConfiguredException] when the account has no contacts, so the
  /// caller can offer setup instead of reporting a delivery failure.
  static Future<SosTriggerResult> triggerSos({
    double? latitude,
    double? longitude,
    String locationStatus = 'UNAVAILABLE',
    String? notes,
  }) async {
    final response = await _post('/sos-events/trigger', {
      'latitude': latitude,
      'longitude': longitude,
      'location_status': locationStatus,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    });

    final body = _decode(response);

    if (response.statusCode == 409) {
      throw const SosNotConfiguredException();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        friendlyApiMessage(
          response.statusCode,
          body,
          fallback:
              'The emergency alert could not be sent. The alarm is still '
              'active.',
        ),
      );
    }

    if (body is! Map<String, dynamic>) {
      throw const AuthException(
        'The emergency alert could not be confirmed. The alarm is still '
        'active.',
      );
    }

    return SosTriggerResult.fromJson(body);
  }

  // ------------------------------------------------------------
  // SOS EVENTS
  // ------------------------------------------------------------

  static Future<void> logSOSEvent({
    double? latitude,
    double? longitude,
    required int contactCount,
  }) async {
    final response = await _post(
      '/sos-events',
      {
        'latitude': latitude,
        'longitude': longitude,
        'status': 'TRIGGERED',
        'contact_count': contactCount,
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Backend logging is best-effort; never fail the local SOS flow.
      return;
    }
  }

  // ------------------------------------------------------------
  // HTTP HELPERS (JWT BEARER)
  // ------------------------------------------------------------

  static Future<http.Response> _get(String path) async {
    final token = await _token();
    return _guard(
      () => http.get(
        Uri.parse('$baseUrl$path'),
        headers: _headers(token),
      ),
    );
  }

  static Future<http.Response> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final token = await _token();
    return _guard(
      () => http.post(
        Uri.parse('$baseUrl$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      ),
    );
  }

  static Future<http.Response> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final token = await _token();
    return _guard(
      () => http.put(
        Uri.parse('$baseUrl$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      ),
    );
  }

  static Future<http.Response> _delete(String path) async {
    final token = await _token();
    return _guard(
      () => http.delete(
        Uri.parse('$baseUrl$path'),
        headers: _headers(token),
      ),
    );
  }

  static Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  static Future<String> _token() async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      throw const AuthException('Your session has expired. Please sign in again.');
    }
    return token;
  }

  static Future<http.Response> _guard(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const AuthException(
        'The server did not respond. Please check your connection.',
      );
    } on SocketException {
      throw const AuthException(
        'Cannot connect to the server. Check Wi-Fi and try again.',
      );
    } on http.ClientException {
      throw const AuthException(
        'Cannot connect to the server. Check Wi-Fi and try again.',
      );
    }
  }

  static dynamic _decode(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    }
  }
}
