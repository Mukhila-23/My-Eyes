import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../core/storage/secure_storage.dart';
import 'api_error.dart';
import 'auth_service.dart';
import 'route_geometry.dart';

export 'route_geometry.dart' show GeoPoint, RouteTrack, RouteProjection;

// ================================================================
// MODELS
// ================================================================

class NavGeoPlace {
  final String name;
  final double latitude;
  final double longitude;
  final String formattedAddress;
  final String? category;
  final String? placeId;
  final double? confidence;

  const NavGeoPlace({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.formattedAddress = '',
    this.category,
    this.placeId,
    this.confidence,
  });

  GeoPoint get point => GeoPoint(latitude, longitude);

  factory NavGeoPlace.fromJson(Map<String, dynamic> json) => NavGeoPlace(
    name: json['name']?.toString() ?? '',
    latitude: _toDouble(json['latitude']),
    longitude: _toDouble(json['longitude']),
    formattedAddress: json['formatted_address']?.toString() ?? '',
    category: json['category']?.toString(),
    placeId: json['place_id']?.toString(),
    confidence: _nullableDouble(json['confidence']),
  );
}

class NavPlaceSearch extends NavGeoPlace {
  final double? distanceM;

  const NavPlaceSearch({
    required super.name,
    required super.latitude,
    required super.longitude,
    super.formattedAddress,
    super.category,
    super.placeId,
    this.distanceM,
  });

  factory NavPlaceSearch.fromJson(Map<String, dynamic> json) => NavPlaceSearch(
    name: json['name']?.toString() ?? '',
    latitude: _toDouble(json['latitude']),
    longitude: _toDouble(json['longitude']),
    formattedAddress: json['formatted_address']?.toString() ?? '',
    category: json['category']?.toString(),
    placeId: json['place_id']?.toString(),
    distanceM: _nullableDouble(json['distance_m']),
  );
}

/// One turn-by-turn step.
///
/// [fromIndex]/[toIndex] index into [NavDirections.geometry]. Geoapify
/// explicitly documents these as the way to locate a step on the route;
/// counting steps is not equivalent and must not be used for progress.
class NavStep {
  final String instruction;
  final double distanceM;
  final double durationSec;

  final String maneuver;
  final String preTransition;
  final String postTransition;
  final List<String> streets;

  final int fromIndex;
  final int toIndex;
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;

  const NavStep({
    required this.instruction,
    required this.distanceM,
    this.durationSec = 0,
    this.maneuver = '',
    this.preTransition = '',
    this.postTransition = '',
    this.streets = const <String>[],
    this.fromIndex = 0,
    this.toIndex = 0,
    this.startLat = 0,
    this.startLng = 0,
    this.endLat = 0,
    this.endLng = 0,
  });

  GeoPoint get startPoint => GeoPoint(startLat, startLng);
  GeoPoint get endPoint => GeoPoint(endLat, endLng);

  /// True for the final "you have arrived" style step.
  bool get isArrival =>
      maneuver.toLowerCase().contains('arrive') ||
      instruction.toLowerCase().contains('arrived at');

  factory NavStep.fromJson(Map<String, dynamic> json) => NavStep(
    instruction: json['instruction']?.toString() ?? '',
    distanceM: _toDouble(json['distance_m']),
    durationSec: _toDouble(json['duration_sec']),
    maneuver: json['maneuver']?.toString() ?? '',
    preTransition: json['pre_transition']?.toString() ?? '',
    postTransition: json['post_transition']?.toString() ?? '',
    streets: (json['streets'] as List? ?? [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList(),
    fromIndex: (json['from_index'] as num?)?.toInt() ?? 0,
    toIndex: (json['to_index'] as num?)?.toInt() ?? 0,
    startLat: _toDouble(json['start_lat']),
    startLng: _toDouble(json['start_lng']),
    endLat: _toDouble(json['end_lat']),
    endLng: _toDouble(json['end_lng']),
  );
}

class NavDirections {
  final String origin;
  final String destination;
  final double distanceM;
  final double durationSec;
  final List<NavStep> steps;
  final List<GeoPoint> geometry;
  final String mode;

  double get durationMin => durationSec / 60.0;

  /// Route shape, or null when the provider returned no geometry.
  RouteTrack? get track => geometry.length < 2 ? null : RouteTrack(geometry);

  GeoPoint get destinationPoint =>
      geometry.isNotEmpty ? geometry.last : const GeoPoint(0, 0);

  const NavDirections({
    required this.origin,
    required this.destination,
    required this.distanceM,
    required this.durationSec,
    required this.steps,
    required this.geometry,
    this.mode = 'walk',
  });

  factory NavDirections.fromJson(Map<String, dynamic> json) {
    final steps = (json['steps'] as List? ?? [])
        .whereType<Map>()
        .map((e) => NavStep.fromJson(e.cast<String, dynamic>()))
        .toList();

    // Geometry arrives as [lon, lat] pairs.
    final geometry = (json['geometry'] as List? ?? [])
        .whereType<List>()
        .where((p) => p.length >= 2)
        .map((p) => GeoPoint(_toDouble(p[1]), _toDouble(p[0])))
        .toList();

    return NavDirections(
      origin: json['origin']?.toString() ?? '',
      destination: json['destination']?.toString() ?? '',
      distanceM: _toDouble(json['distance_m']),
      durationSec: _toDouble(json['duration_sec']),
      steps: steps,
      geometry: geometry,
      mode: json['mode']?.toString() ?? 'walk',
    );
  }
}

class NavSavedPlace {
  final int id;
  final String name;
  final double latitude;
  final double longitude;

  const NavSavedPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  GeoPoint get point => GeoPoint(latitude, longitude);

  factory NavSavedPlace.fromJson(Map<String, dynamic> json) => NavSavedPlace(
    id: json['id'] as int,
    name: json['name']?.toString() ?? '',
    latitude: _toDouble(json['latitude']),
    longitude: _toDouble(json['longitude']),
  );
}

/// Only modes Geoapify Routing supports are offered.
enum NavTravelMode { walking, driving, cycling }

extension NavTravelModeInfo on NavTravelMode {
  String get id => switch (this) {
    NavTravelMode.walking => 'walking',
    NavTravelMode.driving => 'driving',
    NavTravelMode.cycling => 'cycling',
  };

  String get label => switch (this) {
    NavTravelMode.walking => 'walking',
    NavTravelMode.driving => 'driving',
    NavTravelMode.cycling => 'cycling',
  };
}

/// Smart Navigation client.
///
/// Device-side GPS (geolocator, the same plugin SOS already uses) plus a
/// JWT-authenticated proxy to the Geoapify Geocoding, Places and Routing APIs
/// through the FastAPI backend. The Geoapify key never reaches the device.
class NavigationService {
  NavigationService._();

  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _locationFixTimeout = Duration(seconds: 10);

  /// Android can take longer than the first command turn to yield a new
  /// high-accuracy fix. A recent fused-location fix is safe as a short-lived
  /// fallback, but an old cached coordinate must never become a route origin.
  static const Duration _maxLastKnownLocationAge = Duration(minutes: 5);

  /// A fix is only trusted for routing decisions when it claims this accuracy
  /// or better. Coarse fixes are still shown to the user, just never used to
  /// decide that they have left the route.
  static const double maxTrustedAccuracyM = 35.0;

  // ================================================================
  // CURRENT LOCATION
  // ================================================================

  /// Requests permission if needed and reports why location is unusable.
  static Future<({bool ok, String? reason})> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return (ok: false, reason: 'off');
    }
    var granted = await Geolocator.checkPermission();
    if (granted == LocationPermission.denied) {
      granted = await Geolocator.requestPermission();
    }
    if (granted == LocationPermission.deniedForever) {
      return (ok: false, reason: 'permanently_denied');
    }
    if (granted == LocationPermission.denied) {
      return (ok: false, reason: 'denied');
    }
    return (ok: true, reason: null);
  }

  /// Returns a [Position] or null when location is unavailable/denied.
  static Future<Position?> getCurrentPosition() async {
    final permission = await ensurePermission();
    if (!permission.ok) return null;

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: _locationFixTimeout,
        ),
      );
    } catch (_) {
      // Fall through to Android's most recent fused-location fix. The caller
      // still receives null when there is no recent, usable coordinate.
    }

    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown == null) return null;
      final age = DateTime.now().difference(lastKnown.timestamp);
      return age <= _maxLastKnownLocationAge ? lastKnown : null;
    } catch (_) {
      return null;
    }
  }

  /// Continuous high-accuracy fixes for active navigation.
  ///
  /// Yields nothing if permission is refused, so callers can simply listen
  /// and treat an empty stream as "no GPS".
  static Stream<Position> positionStream({
    int distanceFilterM = 5,
    Duration interval = const Duration(seconds: 2),
  }) async* {
    final permission = await ensurePermission();
    if (!permission.ok) return;

    yield* Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterM,
        timeLimit: const Duration(seconds: 30),
      ),
    ).timeout(
      interval * 12,
      onTimeout: (sink) => sink.addError(TimeoutException('no fix')),
    );
  }

  /// Whether a fix is accurate enough to drive routing decisions.
  static bool isTrustworthy(Position position) =>
      position.accuracy > 0 && position.accuracy <= maxTrustedAccuracyM;

  // ================================================================
  // GEOAPIFY PROXY (server-side key)
  // ================================================================

  /// Resolve a spoken destination to candidates.
  ///
  /// Supplying the current position biases results towards nearby matches
  /// without excluding distant ones.
  static Future<List<NavGeoPlace>> geocode(
    String query, {
    double? lat,
    double? lng,
  }) async {
    final bias = (lat != null && lng != null) ? '&lat=$lat&lng=$lng' : '';
    final data = await _get(
      '/navigation/geocode?query=${Uri.encodeComponent(query)}$bias',
    );
    return (data as List)
        .whereType<Map>()
        .map((e) => NavGeoPlace.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  static Future<String> reverseGeocode(double lat, double lng) async {
    final data = await _get('/navigation/reverse?lat=$lat&lng=$lng');
    return (data as Map<String, dynamic>)['address']?.toString() ??
        'an unknown area';
  }

  /// Nearest places of a spoken category, e.g. [category] = 'hospital'.
  static Future<List<NavPlaceSearch>> searchNearby(
    String category, {
    required double lat,
    required double lng,
    double radiusM = 5000,
    String? name,
  }) async {
    final params = StringBuffer(
      '/navigation/nearby?'
      'category=${Uri.encodeComponent(category)}'
      '&lat=$lat&lng=$lng&radius_m=${radiusM.round()}',
    );
    if (name != null && name.trim().isNotEmpty) {
      params.write('&name=${Uri.encodeComponent(name.trim())}');
    }
    final data = await _get(params.toString());
    return (data as List)
        .whereType<Map>()
        .map((e) => NavPlaceSearch.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// Categories the backend is able to search.
  static Future<List<String>> categories() async {
    final data = await _get('/navigation/categories');
    return (data as List).map((e) => e.toString()).toList();
  }

  static Future<NavDirections> getDirections({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    NavTravelMode mode = NavTravelMode.walking,
  }) async {
    final data = await _get(
      '/navigation/directions?'
      'origin_lat=$originLat&origin_lng=$originLng'
      '&dest_lat=$destLat&dest_lng=$destLng'
      '&mode=${mode.id}',
    );
    return NavDirections.fromJson(data.cast<String, dynamic>());
  }

  // ================================================================
  // SAVED PLACES
  // ================================================================

  static Future<List<NavSavedPlace>> getSavedPlaces() async {
    final data = await _get('/navigation/saved-places');
    return (data as List)
        .whereType<Map>()
        .map((e) => NavSavedPlace.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  static Future<NavSavedPlace> savePlace({
    required String name,
    required double latitude,
    required double longitude,
  }) async {
    final data = await _send(
      'POST',
      '/navigation/saved-places',
      body: {'name': name, 'latitude': latitude, 'longitude': longitude},
    );
    return NavSavedPlace.fromJson(data.cast<String, dynamic>());
  }

  static Future<bool> deleteSavedPlace(int id) async {
    try {
      await _send('DELETE', '/navigation/saved-places/$id');
      return true;
    } catch (_) {
      return false;
    }
  }

  // ================================================================
  // HTTP HELPERS (JWT authenticated)
  // ================================================================

  static Future<dynamic> _get(String path) async {
    return _send('GET', path);
  }

  static Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = await SecureStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      throw const NavigationException(
        'Your session has expired. Please go back and sign in again.',
      );
    }

    final headers = {
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
    };

    final uri = Uri.parse('${AuthService.baseUrl}$path');

    debugPrint('[MY EYES] NAV $method $path');

    try {
      http.Response response;
      if (method == 'GET') {
        response = await http.get(uri, headers: headers).timeout(_timeout);
      } else if (method == 'DELETE') {
        response = await http.delete(uri, headers: headers).timeout(_timeout);
      } else {
        response = await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(_timeout);
      }

      final decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(response.body) is Map
                ? jsonDecode(response.body) as Map<String, dynamic>
                : jsonDecode(response.body));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NavigationException(
          friendlyApiMessage(
            response.statusCode,
            decoded is Map ? decoded : null,
            fallback: 'Navigation services are temporarily unavailable.',
          ),
        );
      }

      return decoded;
    } on TimeoutException {
      throw const NavigationException(
        'Navigation services took too long to respond. Please try again.',
      );
    } on SocketException {
      throw const NavigationException(
        "I can't reach the server. Please check your internet connection.",
      );
    } on http.ClientException {
      throw const NavigationException(
        "I can't reach the server. Please check your internet connection.",
      );
    }
  }
}

// -------- shared numeric helpers (used by the model classes above) --------

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0.0;
  return 0.0;
}

double? _nullableDouble(dynamic value) {
  if (value == null) return null;
  return _toDouble(value);
}

class NavigationException implements Exception {
  const NavigationException(this.message);
  final String message;

  @override
  String toString() => message;
}
