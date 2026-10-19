/// Pure route-geometry maths for turn-by-turn navigation.
///
/// Kept free of Flutter/plugin dependencies so it can be unit tested without
/// a device. Every function works in metres on the WGS84 ellipsoid mean
/// radius, which is accurate to well under a metre for the few-kilometre
/// spans involved in pedestrian navigation.
library;

import 'dart:math' as math;

const double _earthRadiusM = 6371000.0;
const double _degToRad = math.pi / 180.0;

double _rad(double deg) => deg * _degToRad;

class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint(this.latitude, this.longitude);

  @override
  String toString() => '($latitude, $longitude)';
}

/// Great-circle distance in metres.
double haversineMeters(GeoPoint a, GeoPoint b) {
  final p1 = _rad(a.latitude);
  final p2 = _rad(b.latitude);
  final dp = _rad(b.latitude - a.latitude);
  final dl = _rad(b.longitude - a.longitude);
  final h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * _earthRadiusM * math.asin(math.sqrt(h));
}

/// Converts longitude/latitude to a local flat plane in metres, anchored at
/// the query point.
///
/// Using a local equirectangular projection keeps segment projections
/// accurate over short distances while remaining far cheaper than full
/// geodesic maths for every segment.
class _LocalPlane {
  final double _originLat;
  final double _originLng;
  final double _mPerDegLat = _earthRadiusM * _degToRad;
  late final double _mPerDegLng =
      _earthRadiusM * _degToRad * math.cos(_rad(_originLat)).abs();

  _LocalPlane(this._originLat, this._originLng);

  double x(double lng) => (lng - _originLng) * _mPerDegLng;
  double y(double lat) => (lat - _originLat) * _mPerDegLat;
}

/// Result of projecting a point onto a single segment.
class _SegmentProjection {
  /// Perpendicular distance in metres.
  final double distance;

  /// Position along the segment, clamped to 0..1.
  final double t;

  const _SegmentProjection(this.distance, this.t);
}

_SegmentProjection _projectOnSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
  final plane = _LocalPlane(p.latitude, p.longitude);
  final px = plane.x(p.longitude);
  final py = plane.y(p.latitude);

  final ax = plane.x(a.longitude);
  final ay = plane.y(a.latitude);
  final bx = plane.x(b.longitude);
  final by = plane.y(b.latitude);

  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;

  if (lenSq <= 0) {
    final ex = px - ax;
    final ey = py - ay;
    return _SegmentProjection(math.sqrt(ex * ex + ey * ey), 0.0);
  }

  // Clamp t to [0, 1] so the projection lands on the segment, not its line.
  final t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  final clamped = t.clamp(0.0, 1.0);

  final cx = ax + clamped * dx;
  final cy = ay + clamped * dy;
  final ex = px - cx;
  final ey = py - cy;
  return _SegmentProjection(math.sqrt(ex * ex + ey * ey), clamped);
}

/// Shortest distance in metres from [p] to the segment [a]..[b].
double distanceToSegmentMeters(GeoPoint p, GeoPoint a, GeoPoint b) =>
    _projectOnSegment(p, a, b).distance;

/// Where a live position sits relative to a planned route.
class RouteProjection {
  /// Perpendicular distance from the route line, in metres. This is the
  /// value used for off-route detection.
  final double distanceToRouteM;

  /// Index of the route segment the position best matches.
  final int nearestIndex;

  /// Distance travelled along the route up to the projected point.
  final double alongRouteM;

  /// Remaining distance along the route to the destination.
  final double remainingM;

  const RouteProjection({
    required this.distanceToRouteM,
    required this.nearestIndex,
    required this.alongRouteM,
    required this.remainingM,
  });
}

/// Immutable view over a route's geometry, with precomputed cumulative
/// distances so tracking a position is O(segments) with no allocation.
class RouteTrack {
  final List<GeoPoint> points;

  /// Cumulative distance along the route at each vertex.
  final List<double> _cumulative;

  final double totalM;

  RouteTrack._(this.points, this._cumulative)
      : totalM = _cumulative.isEmpty ? 0.0 : _cumulative.last;

  factory RouteTrack(List<GeoPoint> points) =>
      RouteTrack._(List.unmodifiable(points), _buildCumulative(points));

  bool get isEmpty => points.length < 2;

  static List<double> _buildCumulative(List<GeoPoint> pts) {
    final out = List<double>.filled(pts.length, 0.0);
    for (var i = 1; i < pts.length; i++) {
      out[i] = out[i - 1] + haversineMeters(pts[i - 1], pts[i]);
    }
    return out;
  }

  GeoPoint get start => points.first;
  GeoPoint get destination => points.last;

  /// Distance along the route at vertex [index], clamped to the route ends.
  double alongToM(int index) {
    if (_cumulative.isEmpty) return 0.0;
    final i = index.clamp(0, _cumulative.length - 1);
    return _cumulative[i];
  }

  /// Locates [p] on the route.
  ///
  /// [RouteProjection.alongRouteM] is interpolated inside the matched segment
  /// rather than snapped to the segment start, so progress advances smoothly
  /// instead of jumping a whole step at each vertex.
  RouteProjection project(GeoPoint p) {
    if (points.isEmpty) {
      return const RouteProjection(
        distanceToRouteM: double.infinity,
        nearestIndex: 0,
        alongRouteM: 0,
        remainingM: double.infinity,
      );
    }
    if (points.length == 1) {
      return RouteProjection(
        distanceToRouteM: haversineMeters(p, points.first),
        nearestIndex: 0,
        alongRouteM: 0,
        remainingM: 0,
      );
    }

    var best = const RouteProjection(
      distanceToRouteM: double.infinity,
      nearestIndex: 0,
      alongRouteM: 0,
      remainingM: 0,
    );

    for (var i = 0; i < points.length - 1; i++) {
      final projection = _projectOnSegment(p, points[i], points[i + 1]);
      if (projection.distance >= best.distanceToRouteM) continue;

      final segmentLength = _cumulative[i + 1] - _cumulative[i];
      final along = _cumulative[i] + projection.t * segmentLength;
      best = RouteProjection(
        distanceToRouteM: projection.distance,
        nearestIndex: i,
        alongRouteM: along,
        remainingM: math.max(0.0, totalM - along),
      );
    }

    return best;
  }

  /// Straight-line distance to the final destination.
  double distanceToDestinationM(GeoPoint p) => haversineMeters(p, destination);
}