/// Domain models for GPX 1.1 serialization and parsing with TerraSteps
/// fitness & H3 spatial extensions.
///
/// Engineering constraints (AGENTS.md):
/// - H3 IDs are always lowercase TEXT (never 64-bit JSON numbers).
/// - All timestamps are UTC (`toUtc().toIso8601String()` ending in `Z`).
/// - Monotonic elapsed milliseconds (`monotonicMs`) accompany wall-clock UTC.
class GpxTrackPoint {
  final int sequence;
  final double latitude;
  final double longitude;
  final double? elevationMeters;
  final DateTime timestampUtc;
  final int monotonicMs;
  final int stepsDelta;
  final int cumulativeSteps;
  final int cadenceSpm;
  final double speedMps;
  final double accuracyMeters;
  final double caloriesDeltaKcal;
  final String h3Index;
  final String? parentRes5;
  final String samplingState;

  GpxTrackPoint({
    required this.sequence,
    required this.latitude,
    required this.longitude,
    this.elevationMeters,
    required DateTime timestampUtc,
    required this.monotonicMs,
    required this.stepsDelta,
    required this.cumulativeSteps,
    this.cadenceSpm = 0,
    required this.speedMps,
    required this.accuracyMeters,
    this.caloriesDeltaKcal = 0.0,
    required String h3Index,
    this.parentRes5,
    this.samplingState = 'moving',
  })  : timestampUtc = timestampUtc.toUtc(),
        h3Index = h3Index.toLowerCase();

  Map<String, dynamic> toMap() => {
        'sequence': sequence,
        'lat': latitude,
        'lon': longitude,
        'ele': elevationMeters,
        'timestamp_utc': timestampUtc.toIso8601String(),
        'monotonic_ms': monotonicMs,
        'steps_delta': stepsDelta,
        'cumulative_steps': cumulativeSteps,
        'cadence_spm': cadenceSpm,
        'speed_mps': speedMps,
        'accuracy_m': accuracyMeters,
        'calories_delta_kcal': caloriesDeltaKcal,
        'h3_index': h3Index,
        'parent_res5': parentRes5,
        'sampling_state': samplingState,
      };
}

class GpxBounds {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const GpxBounds({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });
}

class GpxSessionMetadata {
  final String sessionId;
  final String name;
  final String trackName;
  final String activityType;
  final DateTime createdAtUtc;
  final int h3Resolution;
  final int totalMeasuredSteps;
  final int totalEstimatedSteps;
  final double totalDistanceMeters;
  final double totalCaloriesKcal;
  final int activeDurationMs;
  final int uniqueH3Cells;

  GpxSessionMetadata({
    required this.sessionId,
    required this.name,
    required this.trackName,
    this.activityType = 'walking',
    required DateTime createdAtUtc,
    this.h3Resolution = 9,
    required this.totalMeasuredSteps,
    this.totalEstimatedSteps = 0,
    required this.totalDistanceMeters,
    required this.totalCaloriesKcal,
    required this.activeDurationMs,
    required this.uniqueH3Cells,
  }) : createdAtUtc = createdAtUtc.toUtc();
}

class GpxDocument {
  final GpxSessionMetadata metadata;
  final List<GpxTrackPoint> points;
  final GpxBounds? bounds;

  const GpxDocument({
    required this.metadata,
    required this.points,
    this.bounds,
  });
}
