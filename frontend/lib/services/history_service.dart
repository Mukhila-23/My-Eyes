import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import '../core/vision_mode.dart';
import 'api_error.dart';
import 'auth_service.dart';

/// One stored scan result, as returned by `GET /history/module/{scan_type}`.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.scanType,
    required this.result,
    required this.createdAt,
    this.inputImage,
  });

  final int id;
  final String scanType;
  final String result;
  final DateTime createdAt;
  final String? inputImage;

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        scanType: json['scan_type'] as String? ?? '',
        result: json['result'] as String? ?? '',
        inputImage: json['input_image'] as String?,
        createdAt:
            DateTime.tryParse(json['created_at']?.toString() ?? '') ??
                DateTime.now(),
      );

  /// "12 March, 3:45 pm" - unambiguous across a month/day boundary, which a
  /// bare "03/04" would not be for a listener.
  String get spokenTimestamp {
    const months = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    final local = createdAt.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final meridiem = local.hour < 12 ? 'am' : 'pm';

    return '${local.day} ${months[local.month - 1]}, '
        '$hour:$minute $meridiem';
  }

  /// Short form for the history card: `12/03/2026  3:45 PM`.
  ///
  /// Day, month and year are all zero-padded to two digits. That is what makes
  /// it unambiguous: `3/4/2026` could be 3 April or 4 March, and this is the
  /// one place where the compact form is shown rather than read aloud.
  String get displayTimestamp {
    final local = createdAt.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final meridiem = local.hour < 12 ? 'AM' : 'PM';
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');

    return '$day/$month/${local.year}  $hour:$minute $meridiem';
  }

  /// The result, cleaned up for reading aloud and for the card.
  ///
  /// The backend stores whatever the module produced, which for Product
  /// Detection is a Python dict repr. Collapsing whitespace and trimming keeps
  /// the spoken line from becoming an unreadable wall of punctuation.
  String get readableResult {
    final trimmed = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return trimmed.isEmpty ? 'No result was stored.' : trimmed;
  }

  /// A short spoken summary: the timestamp plus the first part of the result.
  String spokenSummary({int maxChars = 140}) {
    var body = readableResult;
    if (body.length > maxChars) {
      body = '${body.substring(0, maxChars).trimRight()} and more';
    }
    return '$spokenTimestamp. $body';
  }
}

/// Why a history load failed, so the screen can say something truthful.
enum HistoryFailure {
  /// The server could not be reached.
  network,

  /// The session is gone.
  unauthorized,

  /// The server refused or broke.
  server,
}

/// Thrown by [HistoryService] with a message that is safe to read aloud.
class HistoryException implements Exception {
  const HistoryException(this.spoken, this.failure);

  final String spoken;
  final HistoryFailure failure;
}

/// Reads module-scoped scan history from the backend.
///
/// Deliberately scoped to ONE module per call: the History button inside Read
/// Text must never be able to render Currency results, and the backend
/// enforces the same scoping by filtering on the authenticated user id and the
/// requested scan type.
class HistoryService {
  HistoryService._();

  static const Duration _timeout = Duration(seconds: 15);

  static const String _loadFailureSpoken =
      "I couldn't load your history right now. Please try again.";

  /// History for one module, newest first.
  ///
  /// Throws [HistoryException] on any failure; never returns a partially
  /// loaded list, because a half-empty history is worse than an honest
  /// failure message for a listener.
  static Future<List<HistoryEntry>> fetchModuleHistory(
    VisionMode mode,
  ) async {
    final scanType = mode.scanType;
    if (scanType == null) {
      throw const HistoryException(
        'This module does not keep a history.',
        HistoryFailure.server,
      );
    }
    return _fetch('/history/module/$scanType');
  }

  /// Per-module counts, used by the dashboard-level history list.
  ///
  /// Returns an empty map on failure: the dashboard uses this to enrich a
  /// picker, and an empty count list must never block opening it.
  static Future<Map<String, int>> fetchScanCounts() async {
    try {
      final body = await _request('/history/types');
      final summaries = (body as Map<String, dynamic>)['summaries'];
      if (summaries is! List) return const {};

      final counts = <String, int>{};
      for (final entry in summaries) {
        if (entry is! Map) continue;
        final type = entry['scan_type'] as String?;
        final count = (entry['count'] as num?)?.toInt();
        if (type != null && type.isNotEmpty && count != null) {
          counts[type.toUpperCase()] = count;
        }
      }
      return counts;
    } catch (_) {
      return const {};
    }
  }

  static Future<List<HistoryEntry>> _fetch(String path) async {
    final body = await _request(path);
    if (body is! List) {
      throw const HistoryException(_loadFailureSpoken, HistoryFailure.server);
    }

    return body
        .whereType<Map<String, dynamic>>()
        .map(HistoryEntry.fromJson)
        .toList();
  }

  static Future<dynamic> _request(String path) async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      throw const HistoryException(
        'Your session has expired. Please sign in again.',
        HistoryFailure.unauthorized,
      );
    }

    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('${AuthService.baseUrl}$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const HistoryException(
        "The server did not respond. Please try again.",
        HistoryFailure.network,
      );
    } on SocketException {
      throw const HistoryException(
        'I cannot reach the server right now. Please try again later.',
        HistoryFailure.network,
      );
    } on http.ClientException {
      throw const HistoryException(
        'I cannot reach the server right now. Please try again later.',
        HistoryFailure.network,
      );
    } on FormatException {
      throw const HistoryException(_loadFailureSpoken, HistoryFailure.server);
    }

    dynamic body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body);
      } on FormatException {
        throw const HistoryException(_loadFailureSpoken, HistoryFailure.server);
      }
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const HistoryException(
        'Your session has expired. Please sign in again.',
        HistoryFailure.unauthorized,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HistoryException(
        friendlyApiMessage(response.statusCode, body, fallback: _loadFailureSpoken),
        HistoryFailure.server,
      );
    }

    return body;
  }
}
