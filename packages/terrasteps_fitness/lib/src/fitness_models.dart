/// Core fitness & user anthropometrics models.
///
/// Engineering constraints (AGENTS.md):
/// - Base units: metres, milliseconds, kilograms.
/// - Measured hardware steps and GPS-estimated steps are strictly separate.
/// - Scores carry fixed-point micro-points (`scoreMicro` string) for determinism.
enum BiologicalSex { male, female, unspecified }

enum PreferredUnits { metric, imperial }

enum ActivityIntensity {
  stationary,
  slowWalk,
  briskWalk,
  jogging,
  fastRunning,
}

class UserFitnessProfile {
  final String id;
  final String username;
  final double weightKg;
  final double heightCm;
  final int age;
  final BiologicalSex gender;
  final int dailyStepGoal;
  final PreferredUnits preferredUnits;
  final String factionColor;

  const UserFitnessProfile({
    required this.id,
    this.username = 'pilot_walker',
    this.weightKg = 72.0,
    this.heightCm = 174.0,
    this.age = 22,
    this.gender = BiologicalSex.unspecified,
    this.dailyStepGoal = 8000,
    this.preferredUnits = PreferredUnits.metric,
    this.factionColor = '#10B981',
  });

  /// Walking stride length in metres (`height_cm * 0.415 / 100`).
  double get walkingStrideMeters => (heightCm * 0.415) / 100.0;

  /// Running stride length in metres (`height_cm * 0.45 / 100`).
  double get runningStrideMeters => (heightCm * 0.450) / 100.0;

  UserFitnessProfile copyWith({
    String? id,
    String? username,
    double? weightKg,
    double? heightCm,
    int? age,
    BiologicalSex? gender,
    int? dailyStepGoal,
    PreferredUnits? preferredUnits,
    String? factionColor,
  }) {
    return UserFitnessProfile(
      id: id ?? this.id,
      username: username ?? this.username,
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      dailyStepGoal: dailyStepGoal ?? this.dailyStepGoal,
      preferredUnits: preferredUnits ?? this.preferredUnits,
      factionColor: factionColor ?? this.factionColor,
    );
  }
}

class LiveFitnessSnapshot {
  final int measuredSteps;
  final int estimatedSteps;
  final int cadenceSpm;
  final double distanceMeters;
  final int elapsedDurationMs;
  final int activeDurationMs;
  final double currentSpeedMps;
  final double currentMet;
  final ActivityIntensity intensity;
  final double caloriesBurnedKcal;
  final int counterResetCount;

  const LiveFitnessSnapshot({
    required this.measuredSteps,
    required this.estimatedSteps,
    required this.cadenceSpm,
    required this.distanceMeters,
    required this.elapsedDurationMs,
    required this.activeDurationMs,
    required this.currentSpeedMps,
    required this.currentMet,
    required this.intensity,
    required this.caloriesBurnedKcal,
    required this.counterResetCount,
  });

  /// Current pace in minutes per kilometre (`null` when nearly stationary).
  double? get paceMinPerKm {
    if (currentSpeedMps < 0.35) return null;
    return (1000.0 / currentSpeedMps) / 60.0;
  }

  /// Ratio of ground distance to measured steps (human stride sanity check: 0.30–1.60m).
  double? get measuredStrideMeters {
    if (measuredSteps <= 0) return null;
    return distanceMeters / measuredSteps;
  }
}
