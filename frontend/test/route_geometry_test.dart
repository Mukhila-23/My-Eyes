import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/route_geometry.dart';

/// A straight north-south route along a meridian, 4 vertices 0.001 deg apart
/// (~111 m each, ~333 m total).
final List<GeoPoint> meridian = <GeoPoint>[
  GeoPoint(0.0, 77.0),
  GeoPoint(0.001, 77.0),
  GeoPoint(0.002, 77.0),
  GeoPoint(0.003, 77.0),
];

void main() {
  group('haversineMeters', () {
    test('one degree of latitude is about 111195 m', () {
      expect(
        haversineMeters(const GeoPoint(0, 0), const GeoPoint(1, 0)),
        closeTo(111195, 50),
      );
    });

    test('London to Paris is about 343500 m', () {
      expect(
        haversineMeters(
          const GeoPoint(51.5074, -0.1278),
          const GeoPoint(48.8566, 2.3522),
        ),
        closeTo(343500, 3000),
      );
    });

    test('returns zero for identical points', () {
      expect(
        haversineMeters(const GeoPoint(5, 5), const GeoPoint(5, 5)),
        closeTo(0, 1e-9),
      );
    });

    test('is symmetric', () {
      const a = GeoPoint(12.9716, 77.5946);
      const b = GeoPoint(13.0827, 80.2707);
      expect(haversineMeters(a, b), closeTo(haversineMeters(b, a), 1e-6));
    });
  });

  group('distanceToSegmentMeters', () {
    // Equator, due-east segment from (0,0) to (0,1). A point at (0, 0.5)
    // offset north by ~0.0005 deg should sit ~55.6 m away.
    test('measures perpendicular offset from the mid-segment', () {
      expect(
        distanceToSegmentMeters(
          const GeoPoint(0.0005, 0.5),
          const GeoPoint(0, 0),
          const GeoPoint(0, 1),
        ),
        closeTo(55.6, 1.0),
      );
    });

    test('returns zero for a point on the segment', () {
      expect(
        distanceToSegmentMeters(
          const GeoPoint(0, 0.5),
          const GeoPoint(0, 0),
          const GeoPoint(0, 1),
        ),
        closeTo(0, 0.5),
      );
    });

    test('clamps beyond the segment end instead of using the infinite line',
        () {
      expect(
        distanceToSegmentMeters(
          const GeoPoint(0, 2),
          const GeoPoint(0, 0),
          const GeoPoint(0, 1),
        ),
        closeTo(
          haversineMeters(const GeoPoint(0, 2), const GeoPoint(0, 1)),
          1.0,
        ),
      );
    });

    test('collapses a degenerate segment to a point distance', () {
      expect(
        distanceToSegmentMeters(
          const GeoPoint(0, 0),
          const GeoPoint(0, 1),
          const GeoPoint(0, 1),
        ),
        closeTo(
          haversineMeters(const GeoPoint(0, 0), const GeoPoint(0, 1)),
          0.5,
        ),
      );
    });
  });

  group('RouteTrack empty and single-point tracks', () {
    test('an empty track reports isEmpty and zero length', () {
      final empty = RouteTrack(const <GeoPoint>[]);
      expect(empty.isEmpty, isTrue);
      expect(empty.totalM, 0);
    });

    test('an empty track projects to infinite distance', () {
      final empty = RouteTrack(const <GeoPoint>[]);
      expect(
        empty.project(const GeoPoint(1, 1)).distanceToRouteM,
        double.infinity,
      );
    });

    test('a single-point track counts as empty but still projects', () {
      final single = RouteTrack(const <GeoPoint>[GeoPoint(1, 1)]);
      expect(single.isEmpty, isTrue);

      final projection = single.project(const GeoPoint(1, 1));
      expect(projection.distanceToRouteM, closeTo(0, 0.5));
      expect(projection.remainingM, 0);
    });
  });

  group('RouteTrack.project', () {
    final track = RouteTrack(meridian);

    test('measures the total route length', () {
      expect(track.isEmpty, isFalse);
      expect(track.totalM, closeTo(333.6, 2.0));
    });

    test('a point on the route snaps to its segment', () {
      final on = track.project(const GeoPoint(0.0015, 77.0));
      expect(on.distanceToRouteM, closeTo(0, 0.5));
      expect(on.nearestIndex, 1);
    });

    test('a point beside the route keeps its cross-track distance', () {
      final off = track.project(GeoPoint(0.0015, 77.0 + 30 / 111195.0));
      expect(off.distanceToRouteM, closeTo(30, 1.0));
      expect(off.nearestIndex, 1);
    });

    test('the start vertex reports nothing travelled', () {
      final start = track.project(const GeoPoint(0, 77.0));
      expect(start.nearestIndex, 0);
      expect(start.alongRouteM, closeTo(0, 0.5));
    });

    test('the destination vertex reports everything travelled', () {
      final end = track.project(const GeoPoint(0.003, 77.0));
      expect(end.alongRouteM, closeTo(track.totalM, 0.5));
      expect(end.remainingM, closeTo(0, 0.5));
    });

    test('along-route progress never goes backwards', () {
      final samples = <double>[];
      for (var i = 0; i <= 30; i++) {
        samples.add(track.project(GeoPoint(0.003 * i / 30, 77.0)).alongRouteM);
      }
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i], greaterThanOrEqualTo(samples[i - 1] - 1e-6));
      }
      expect(
        samples.last + track.project(const GeoPoint(0.003, 77.0)).remainingM,
        closeTo(track.totalM, 0.5),
      );
    });
  });

  group('RouteTrack.alongToM', () {
    final track = RouteTrack(meridian);

    test('maps vertex indices onto metres travelled', () {
      expect(track.alongToM(0), closeTo(0, 1e-9));
      expect(track.alongToM(2), closeTo(222.4, 2.0));
    });

    test('clamps indices outside the geometry', () {
      expect(track.alongToM(99), closeTo(track.totalM, 1e-9));
      expect(track.alongToM(-5), closeTo(0, 1e-9));
    });
  });

  group('RouteTrack.distanceToDestinationM', () {
    final track = RouteTrack(meridian);

    test('is zero at the destination', () {
      expect(
        track.distanceToDestinationM(const GeoPoint(0.003, 77.0)),
        closeTo(0, 0.5),
      );
    });

    test('measures the straight line back down the route', () {
      expect(
        track.distanceToDestinationM(const GeoPoint(0.002, 77.0)),
        closeTo(111.2, 2.0),
      );
    });
  });

  group('RouteTrack on a multi-leg route', () {
    // Chennai: an L-shaped route with a corner, matching how a walk actually
    // turns. Off-route distance must be measured to the corner, not the origin.
    final leg = RouteTrack(const <GeoPoint>[
      GeoPoint(13.0000, 80.0000),
      GeoPoint(13.0000, 80.0010),
      GeoPoint(13.0010, 80.0010),
    ]);

    test('measures offset from the second leg', () {
      final projection = leg.project(const GeoPoint(13.0005, 80.0011));
      expect(projection.distanceToRouteM, closeTo(11.2, 1.5));
    });

    test('measures the diagonal to the destination', () {
      expect(
        leg.distanceToDestinationM(const GeoPoint(13.0000, 80.0000)),
        closeTo(157.4, 3.0),
      );
    });

    test('uses the nearest leg when the point is far from both', () {
      final far = leg.project(const GeoPoint(12.9990, 80.0000));
      expect(far.distanceToRouteM, closeTo(111.2, 2.0));
    });
  });
}