import 'package:terrasteps_fitness/terrasteps_fitness.dart';
import 'package:test/test.dart';

void main() {
  group('StepCounterEngine (Deliverable 2 Hardware Sensor Offset & Reboot)', () {
    test('subtracts boot baseline, excludes paused steps, and survives reboot reset', () {
      final engine = StepCounterEngine();

      // Device booted earlier with 42,100 cumulative steps
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 42100,
          monotonicMs: 0,
          bootId: 'boot_a',
        ),
        equals(0),
      );
      expect(engine.measuredSteps, equals(0));

      // Walked 35 steps
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 42135,
          monotonicMs: 15000,
          bootId: 'boot_a',
        ),
        equals(35),
      );
      expect(engine.measuredSteps, equals(35));
      expect(engine.currentCadenceSpm(15000), greaterThan(100));

      // Pause workout, walk 50 steps to buy water, then resume
      engine.pause();
      engine.onSensorReading(
        rawCumulativeSteps: 42185,
        monotonicMs: 45000,
        bootId: 'boot_a',
      );
      engine.resume();

      // First reading on resume re-anchors without crediting paused steps
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 42185,
          monotonicMs: 46000,
          bootId: 'boot_a',
        ),
        equals(0),
      );
      expect(engine.measuredSteps, equals(35));

      // Walk 20 more active steps
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 42205,
          monotonicMs: 56000,
          bootId: 'boot_a',
        ),
        equals(20),
      );
      expect(engine.measuredSteps, equals(55));

      // Simulate OS sensor reset / reboot (`boot_b`, raw resets to 4)
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 4,
          monotonicMs: 70000,
          bootId: 'boot_b',
        ),
        equals(0),
      );
      expect(engine.counterResetCount, equals(1));
      expect(engine.measuredSteps, equals(55));

      // Walk 15 steps after reboot -> preserved 55 + 15 = 70!
      expect(
        engine.onSensorReading(
          rawCumulativeSteps: 19,
          monotonicMs: 78000,
          bootId: 'boot_b',
        ),
        equals(15),
      );
      expect(engine.measuredSteps, equals(70));
    });
  });

  group('MetCalorieCalculator (Deliverable 2 METs Formula)', () {
    test('selects accurate MET brackets and computes exact kcal', () {
      // Brisk walk: 1.5 m/s = 5.4 km/h -> MET 4.3
      final intensity = MetCalorieCalculator.classifyIntensity(
        speedMps: 1.5,
        cadenceSpm: 112,
      );
      expect(intensity, equals(ActivityIntensity.briskWalk));
      final met = MetCalorieCalculator.metForIntensity(intensity);
      expect(met, closeTo(4.3, 1e-6));

      // 30 minutes (1,800,000 ms) at 70 kg:
      // kcal = (4.3 * 3.5 * 70 / 200) * 30 = 158.025 kcal
      final kcal = MetCalorieCalculator.computeCaloriesKcal(
        met: met,
        weightKg: 70.0,
        durationMs: 30 * 60 * 1000,
      );
      expect(kcal, closeTo(158.025, 1e-4));
    });
  });

  group('HexEffortAggregator & Referee Pre-Flight', () {
    test('marks genuine walking hex eligible and flags vehicle spoofing', () {
      final agg = HexEffortAggregator();
      final t0 = DateTime.utc(2026, 10, 24, 12, 0, 0);

      // Feed 20 x 5s valid walking ticks (100s dwell, 160 steps, 120m)
      for (var i = 1; i <= 20; i++) {
        agg.recordSample(
          h3Index: '89209a0aa73ffff',
          parentRes5: '85209a0bfffffff',
          latitude: 34.15867 + i * 0.00005,
          longitude: 73.25964,
          accuracyMeters: 4.5,
          speedMps: 1.4,
          stepsDelta: 8,
          distanceDeltaMeters: 6.0,
          dtMonotonicMs: 5000,
          cadenceSpm: 96,
          timestampUtc: t0.add(Duration(seconds: i * 5)),
        );
      }

      final valid = agg.summaryFor('89209a0aa73ffff')!;
      expect(valid.isClaimEligible, isTrue);
      expect(valid.preflightRefereeCheck(), isNull);
      // Server effort: 160*1.0 + 120*0.35 + 100*0.05 = 160 + 42 + 5 = 207.0
      expect(valid.serverAuthoritativeEffort, closeTo(207.0, 1e-6));
      expect(valid.scoreMicro, equals('207000000'));

      // Feed simulated car ride in neighboring hex (13.5 m/s = 48.6 km/h, 2 steps, 675m)
      for (var i = 1; i <= 10; i++) {
        agg.recordSample(
          h3Index: '89209a0aa77ffff',
          parentRes5: '85209a0bfffffff',
          latitude: 34.16012 + i * 0.0005,
          longitude: 73.26331,
          accuracyMeters: 3.8,
          speedMps: 13.5,
          stepsDelta: i == 5 ? 2 : 0,
          distanceDeltaMeters: 67.5,
          dtMonotonicMs: 10000,
          cadenceSpm: 0,
          timestampUtc: t0.add(Duration(seconds: 100 + i * 10)),
        );
      }
      final spoofed = agg.summaryFor('89209a0aa77ffff')!;
      expect(spoofed.isClaimEligible, isFalse);
      expect(spoofed.preflightRefereeCheck(), isNotNull);
    });
  });
}
