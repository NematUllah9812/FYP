import 'package:flutter_test/flutter_test.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';
import 'package:terrasteps_gpx/terrasteps_gpx.dart';

void main() {
  test('TerraSteps mobile integrates fitness & GPX modules cleanly', () {
    const profile = UserFitnessProfile(
      id: 'pilot_1',
      weightKg: 72.0,
      heightCm: 175.0,
    );
    expect(profile.walkingStrideMeters, closeTo(0.72625, 1e-4));

    final kcal = MetCalorieCalculator.computeCaloriesKcal(
      met: 4.3,
      weightKg: profile.weightKg,
      durationMs: 15 * 60 * 1000,
    );
    expect(kcal, greaterThan(80.0));

    final filter = GpxTrackFilter();
    expect(
      filter.shouldRecord(
        latitude: 34.158672,
        longitude: 73.259642,
        accuracyMeters: 4.5,
        monotonicMs: 0,
      ),
      isTrue,
    );
  });
}
