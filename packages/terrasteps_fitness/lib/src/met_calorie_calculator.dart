import 'fitness_models.dart';

/// Implements Deliverable 2's dynamic METs calorie & distance engine:
///
/// Formula:
///   `Calories (kcal) = (MET * 3.5 * weightKg / 200.0) * durationMinutes`
///
/// Speed brackets (Deliverable 2):
/// - Stationary (< 0.40 m/s and cadence < 35 spm): `MET = 1.3` (not active movement)
/// - Slow walk (< 4.0 km/h / < 1.111 m/s):         `MET = 2.8`
/// - Brisk walk (4.0–6.5 km/h / 1.111–1.806 m/s):  `MET = 4.3`
/// - Jogging/Running (6.5–10.0 km/h):              `MET = 8.0`
/// - Fast running (> 10.0 km/h):                   `MET = 11.0`
class MetCalorieCalculator {
  const MetCalorieCalculator();

  /// Classifies movement intensity from ground speed (m/s) and step cadence (spm).
  static ActivityIntensity classifyIntensity({
    required double speedMps,
    int cadenceSpm = 0,
  }) {
    if (speedMps < 0.40 && cadenceSpm < 35) {
      return ActivityIntensity.stationary;
    }
    final speedKmh = speedMps * 3.6;
    if (speedKmh < 4.0) {
      return ActivityIntensity.slowWalk;
    } else if (speedKmh <= 6.5) {
      return ActivityIntensity.briskWalk;
    } else if (speedKmh <= 10.0) {
      return ActivityIntensity.jogging;
    } else {
      return ActivityIntensity.fastRunning;
    }
  }

  /// Returns the Compendium of Physical Activities MET multiplier for [intensity],
  /// with optional positive uphill grade bonus (`elevationGainMeters / distanceMeters`).
  static double metForIntensity(
    ActivityIntensity intensity, {
    double distanceMeters = 0.0,
    double elevationGainMeters = 0.0,
  }) {
    double baseMet;
    switch (intensity) {
      case ActivityIntensity.stationary:
        baseMet = 1.3;
        break;
      case ActivityIntensity.slowWalk:
        baseMet = 2.8;
        break;
      case ActivityIntensity.briskWalk:
        baseMet = 4.3;
        break;
      case ActivityIntensity.jogging:
        baseMet = 8.0;
        break;
      case ActivityIntensity.fastRunning:
        baseMet = 11.0;
        break;
    }

    if (intensity != ActivityIntensity.stationary &&
        distanceMeters >= 5.0 &&
        elevationGainMeters > 0.2) {
      final grade = (elevationGainMeters / distanceMeters).clamp(0.0, 0.25);
      // ACSM uphill metabolic increment (~0.9 MET per 5% positive incline)
      baseMet += (grade / 0.05) * 0.9;
    }
    return baseMet;
  }

  /// Computes kilocalories burned over a monotonic time slice [durationMs].
  static double computeCaloriesKcal({
    required double met,
    required double weightKg,
    required int durationMs,
  }) {
    if (durationMs <= 0 || weightKg <= 0 || met <= 0) return 0.0;
    final durationMinutes = durationMs / 60000.0;
    return ((met * 3.5 * weightKg) / 200.0) * durationMinutes;
  }

  /// Estimates fallback steps from GPS distance ONLY for personal display/comparison.
  /// Never copy this return value into `measuredSteps` (AGENTS.md §12).
  static int estimateStepsFromDistance({
    required double distanceMeters,
    required UserFitnessProfile profile,
    required double speedMps,
  }) {
    if (distanceMeters <= 0) return 0;
    final isRunning = (speedMps * 3.6) > 6.5;
    final stride = isRunning
        ? profile.runningStrideMeters
        : profile.walkingStrideMeters;
    return (distanceMeters / stride.clamp(0.45, 1.50)).round();
  }
}
