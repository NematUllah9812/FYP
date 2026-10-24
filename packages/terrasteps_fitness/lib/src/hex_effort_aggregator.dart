import 'dart:math' as math;

/// Per-hex visit & effort record aligned with BOTH:
/// 1. The live Supabase PostgreSQL `claim_cells` / `validate_cell_claim` / `compute_effort`
///    authoritative contract (H3 Resolution 9, min 120 steps, 80m distance, 90s dwell, 5 fixes).
/// 2. The 30% Milestone local Effort Score (`1.0 * steps + 0.5 * activeDwellSec`).
/// 3. Fixed-point micro-points (`scoreMicro` digit string = `round(effort * 1e6)`).
class HexVisitSummary {
  final String h3Index;
  final String parentRes5;
  final double lastLat;
  final double lastLon;
  final int stepsInHex;
  final double distanceInHexMeters;
  final int totalDwellSeconds;
  final int activeDwellSeconds;
  final int fixCount;
  final double meanAccuracyMeters;
  final double maxSpeedMps;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;

  HexVisitSummary({
    required String h3Index,
    required String parentRes5,
    required this.lastLat,
    required this.lastLon,
    required this.stepsInHex,
    required this.distanceInHexMeters,
    required this.totalDwellSeconds,
    required this.activeDwellSeconds,
    required this.fixCount,
    required this.meanAccuracyMeters,
    required this.maxSpeedMps,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
  })  : h3Index = h3Index.toLowerCase(),
        parentRes5 = parentRes5.toLowerCase(),
        windowStartUtc = windowStartUtc.toUtc(),
        windowEndUtc = windowEndUtc.toUtc();

  /// Local 30% Milestone Effort Score: `(1.0 * steps) + (0.5 * activeDwellSeconds)`
  double get milestoneEffortScore =>
      (1.0 * stepsInHex) + (0.5 * activeDwellSeconds);

  /// Authoritative Supabase PostgreSQL `compute_effort` preview:
  /// `min(600, 1.00 * steps + 0.35 * distance_m + 0.05 * dwell_s)`
  double get serverAuthoritativeEffort => math.min(
        600.0,
        (1.00 * stepsInHex) +
            (0.35 * distanceInHexMeters.round()) +
            (0.05 * activeDwellSeconds),
      );

  /// Fixed-point micro-points as a digit string (`score * 1,000,000`),
  /// matching `contracts/map-snapshot.schema.json`.
  String get scoreMicro =>
      (serverAuthoritativeEffort * 1000000).round().toString();

  /// Progress fraction [0.0..1.0] toward meeting all 4 minimum claim floors
  /// (`120 steps`, `80 m`, `90 s`, `5 fixes`).
  double get claimReadinessProgress {
    final pSteps = (stepsInHex / 120.0).clamp(0.0, 1.0);
    final pDist = (distanceInHexMeters / 80.0).clamp(0.0, 1.0);
    final pDwell = (activeDwellSeconds / 90.0).clamp(0.0, 1.0);
    final pFixes = (fixCount / 5.0).clamp(0.0, 1.0);
    return (pSteps + pDist + pDwell + pFixes) / 4.0;
  }

  /// Runs local pre-flight Referee rule checks mirroring PostgreSQL `validate_cell_claim`.
  /// Returns `null` when ready to claim, or the machine reason code otherwise.
  String? preflightRefereeCheck() {
    if (h3Index.length < 15 || h3Index.length > 16) return 'bad_cell_id';
    if (stepsInHex < 120) return 'below_min_steps';
    if (distanceInHexMeters.round() < 80) return 'below_min_distance';
    if (activeDwellSeconds < 90) return 'below_min_dwell';
    if (fixCount < 5) return 'too_few_fixes';
    if (meanAccuracyMeters > 80.0) return 'poor_gps_accuracy';
    if (maxSpeedMps > 8.0) return 'implausible_speed';

    final strideRatio =
        distanceInHexMeters.round() / math.max(1, stepsInHex).toDouble();
    if (strideRatio < 0.30) return 'steps_without_distance';
    if (strideRatio > 1.60) return 'distance_without_steps';
    if (stepsInHex / math.max(1, activeDwellSeconds) > 3.5) {
      return 'implausible_cadence';
    }
    return null;
  }

  bool get isClaimEligible => preflightRefereeCheck() == null;

  /// Payload formatted directly for Supabase `claim_cells` RPC & `POST /map-api/sessions/sync`.
  Map<String, dynamic> toClaimCellPayload() => {
        'cell_id': h3Index,
        'parent_res5': parentRes5,
        'lat': lastLat,
        'lng': lastLon,
        'steps': stepsInHex,
        'distance_m': distanceInHexMeters.round(),
        'dwell_s': activeDwellSeconds,
        'fix_count': fixCount,
        'mean_accuracy_m': double.parse(meanAccuracyMeters.toStringAsFixed(2)),
        'max_speed_mps': double.parse(maxSpeedMps.toStringAsFixed(2)),
        'window_start': windowStartUtc.toIso8601String(),
        'window_end': windowEndUtc.toIso8601String(),
      };
}

/// Aggregates incoming GPS + step samples per H3 Resolution-9 cell during an
/// active workout session.
class HexEffortAggregator {
  final Map<String, _MutableCellBucket> _buckets = {};

  void reset() => _buckets.clear();

  HexVisitSummary recordSample({
    required String h3Index,
    required String parentRes5,
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMps,
    required int stepsDelta,
    required double distanceDeltaMeters,
    required int dtMonotonicMs,
    required int cadenceSpm,
    required DateTime timestampUtc,
  }) {
    final key = h3Index.toLowerCase();
    final p5 = parentRes5.toLowerCase();
    final ts = timestampUtc.toUtc();

    // Only count active dwell seconds when moving realistically (0.4–6.5 m/s or cadence > 40 spm)
    // so standing still does not farm effort (Deliverable 3 rule).
    final isActiveMovement =
        (speedMps >= 0.40 && speedMps <= 6.50) || cadenceSpm > 40;
    final dtSec = (dtMonotonicMs / 1000.0);

    final bucket = _buckets.putIfAbsent(
      key,
      () => _MutableCellBucket(
        h3Index: key,
        parentRes5: p5,
        windowStartUtc: ts,
        lastLat: latitude,
        lastLon: longitude,
      ),
    );

    bucket.lastLat = latitude;
    bucket.lastLon = longitude;
    bucket.windowEndUtc = ts;
    bucket.stepsInHex += math.max(0, stepsDelta);
    bucket.distanceInHexMeters += math.max(0.0, distanceDeltaMeters);
    bucket.totalDwellSecDouble += math.max(0.0, dtSec);
    if (isActiveMovement) {
      bucket.activeDwellSecDouble += math.max(0.0, dtSec);
    }
    bucket.fixCount += 1;
    bucket.accuracySum += accuracyMeters;
    if (speedMps > bucket.maxSpeedMps) {
      bucket.maxSpeedMps = speedMps;
    }

    return bucket.toSummary();
  }

  HexVisitSummary? summaryFor(String h3Index) =>
      _buckets[h3Index.toLowerCase()]?.toSummary();

  List<HexVisitSummary> get allSummaries =>
      _buckets.values.map((b) => b.toSummary()).toList()
        ..sort((a, b) => a.windowStartUtc.compareTo(b.windowStartUtc));

  int get visitedCellsCount => _buckets.length;
  int get claimEligibleCellsCount =>
      _buckets.values.where((b) => b.toSummary().isClaimEligible).length;
}

class _MutableCellBucket {
  final String h3Index;
  final String parentRes5;
  final DateTime windowStartUtc;
  DateTime windowEndUtc;
  double lastLat;
  double lastLon;
  int stepsInHex = 0;
  double distanceInHexMeters = 0.0;
  double totalDwellSecDouble = 0.0;
  double activeDwellSecDouble = 0.0;
  int fixCount = 0;
  double accuracySum = 0.0;
  double maxSpeedMps = 0.0;

  _MutableCellBucket({
    required this.h3Index,
    required this.parentRes5,
    required this.windowStartUtc,
    required this.lastLat,
    required this.lastLon,
  }) : windowEndUtc = windowStartUtc;

  HexVisitSummary toSummary() {
    final totalSec = totalDwellSecDouble.round();
    final activeSec = activeDwellSecDouble.round();
    return HexVisitSummary(
      h3Index: h3Index,
      parentRes5: parentRes5,
      lastLat: lastLat,
      lastLon: lastLon,
      stepsInHex: stepsInHex,
      distanceInHexMeters: distanceInHexMeters,
      totalDwellSeconds: totalSec,
      activeDwellSeconds: activeSec,
      fixCount: fixCount,
      meanAccuracyMeters: fixCount > 0 ? (accuracySum / fixCount) : 99.0,
      maxSpeedMps: maxSpeedMps,
      windowStartUtc: windowStartUtc,
      windowEndUtc: windowEndUtc,
    );
  }
}
