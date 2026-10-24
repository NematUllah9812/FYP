import 'package:terrasteps_gpx/terrasteps_gpx.dart';
import 'package:test/test.dart';

void main() {
  group('GpxTrackFilter (Deliverable 1 Sampling Strategy)', () {
    test('rejects GPS fixes worse than 25m accuracy or <= 0m uncertainty', () {
      final filter = GpxTrackFilter(maxAccuracyMeters: 25.0);
      expect(
        filter.shouldRecord(
          latitude: 34.15867,
          longitude: 73.25964,
          accuracyMeters: 0.0,
          monotonicMs: 0,
        ),
        isFalse,
      );
      expect(
        filter.shouldRecord(
          latitude: 34.15867,
          longitude: 73.25964,
          accuracyMeters: 31.4,
          monotonicMs: 1000,
        ),
        isFalse,
      );
      expect(filter.droppedAccuracyCount, equals(2));
    });

    test('records when >= 3s elapsed OR >= 5m displaced', () {
      final filter = GpxTrackFilter(
        maxAccuracyMeters: 25.0,
        minIntervalMs: 3000,
        minDistanceMeters: 5.0,
      );

      // Initial fix always accepted
      expect(
        filter.shouldRecord(
          latitude: 34.158670,
          longitude: 73.259640,
          accuracyMeters: 4.8,
          monotonicMs: 0,
        ),
        isTrue,
      );

      // 1s later, moved < 1m -> skipped
      expect(
        filter.shouldRecord(
          latitude: 34.158672,
          longitude: 73.259641,
          accuracyMeters: 4.5,
          monotonicMs: 1000,
        ),
        isFalse,
      );

      // 1.5s later, moved ~8m North -> accepted via distance gate
      expect(
        filter.shouldRecord(
          latitude: 34.158745,
          longitude: 73.259641,
          accuracyMeters: 4.2,
          monotonicMs: 1500,
        ),
        isTrue,
      );

      // 4.6s later (>3000ms delta), stationary -> accepted via time gate
      expect(
        filter.shouldRecord(
          latitude: 34.158745,
          longitude: 73.259641,
          accuracyMeters: 4.2,
          monotonicMs: 4600,
        ),
        isTrue,
      );
    });
  });

  group('GpxSerializer & GpxParser round-trip', () {
    test('serializes valid GPX 1.1 XML with fitness & H3 extensions and parses back identically', () {
      final t0 = DateTime.utc(2026, 10, 24, 17, 0, 0);
      final meta = GpxSessionMetadata(
        sessionId: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
        name: 'Session_2026-10-24T17:00:00Z',
        trackName: 'Evening Hex Run',
        activityType: 'walking',
        createdAtUtc: t0,
        h3Resolution: 9,
        totalMeasuredSteps: 28,
        totalDistanceMeters: 19.6,
        totalCaloriesKcal: 1.42,
        activeDurationMs: 10000,
        uniqueH3Cells: 1,
      );

      final points = [
        GpxTrackPoint(
          sequence: 0,
          latitude: 34.158672,
          longitude: 73.259642,
          elevationMeters: 1256.4,
          timestampUtc: t0.add(const Duration(seconds: 5)),
          monotonicMs: 5000,
          stepsDelta: 14,
          cumulativeSteps: 14,
          cadenceSpm: 112,
          speedMps: 1.96,
          accuracyMeters: 4.8,
          caloriesDeltaKcal: 0.71,
          h3Index: '89209a0aa73ffff',
          parentRes5: '85209a0bfffffff',
        ),
        GpxTrackPoint(
          sequence: 1,
          latitude: 34.158760,
          longitude: 73.259710,
          elevationMeters: 1257.1,
          timestampUtc: t0.add(const Duration(seconds: 10)),
          monotonicMs: 10000,
          stepsDelta: 14,
          cumulativeSteps: 28,
          cadenceSpm: 114,
          speedMps: 1.98,
          accuracyMeters: 4.3,
          caloriesDeltaKcal: 0.71,
          h3Index: '89209a0aa73ffff',
          parentRes5: '85209a0bfffffff',
        ),
      ];

      const serializer = GpxSerializer();
      final xml = serializer.serialize(metadata: meta, points: points);

      expect(xml, contains('<gpx version="1.1"'));
      expect(xml, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(xml, contains('<ext:steps_delta>14</ext:steps_delta>'));
      expect(xml, contains('<ext:h3_index>89209a0aa73ffff</ext:h3_index>'));
      expect(xml, contains('2026-10-24T17:00:05.000Z'));

      const parser = GpxParser();
      final parsed = parser.parse(xml);
      expect(parsed.metadata.sessionId, equals(meta.sessionId));
      expect(parsed.metadata.totalMeasuredSteps, equals(28));
      expect(parsed.points.length, equals(2));
      expect(parsed.points.first.h3Index, equals('89209a0aa73ffff'));
      expect(parsed.points.last.cumulativeSteps, equals(28));
    });
  });
}
