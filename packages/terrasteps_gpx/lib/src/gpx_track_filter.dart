import 'dart:math' as math;

/// Implements Deliverable 1's GPS breadcrumb sampling & noise gate:
/// - Rejects fixes with horizontal uncertainty worse than [maxAccuracyMeters]
///   (default 25.0 m for clean GPX tracks; must also be > 0 per contract rule).
/// - Accepts a point when elapsed monotonic time >= [minIntervalMs] (3,000 ms)
///   OR ground displacement from the previous accepted fix >= [minDistanceMeters] (5.0 m).
class GpxTrackFilter {
  final double maxAccuracyMeters;
  final int minIntervalMs;
  final double minDistanceMeters;

  double? _lastAcceptedLat;
  double? _lastAcceptedLon;
  int? _lastAcceptedMonotonicMs;

  int acceptedCount = 0;
  int droppedAccuracyCount = 0;
  int skippedRedundantCount = 0;

  GpxTrackFilter({
    this.maxAccuracyMeters = 25.0,
    this.minIntervalMs = 3000,
    this.minDistanceMeters = 5.0,
  });

  void reset() {
    _lastAcceptedLat = null;
    _lastAcceptedLon = null;
    _lastAcceptedMonotonicMs = null;
    acceptedCount = 0;
    droppedAccuracyCount = 0;
    skippedRedundantCount = 0;
  }

  /// Evaluates whether an incoming raw GPS fix should be appended as a `<trkpt>`.
  bool shouldRecord({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required int monotonicMs,
  }) {
    if (latitude.isNaN ||
        longitude.isNaN ||
        latitude < -90.0 ||
        latitude > 90.0 ||
        longitude < -180.0 ||
        longitude > 180.0) {
      droppedAccuracyCount++;
      return false;
    }

    // Contract defect rule: accuracy_m <= 0 is not a real physical measurement.
    if (accuracyMeters <= 0.0 || accuracyMeters > maxAccuracyMeters) {
      droppedAccuracyCount++;
      return false;
    }

    if (_lastAcceptedLat == null ||
        _lastAcceptedLon == null ||
        _lastAcceptedMonotonicMs == null) {
      _accept(latitude, longitude, monotonicMs);
      return true;
    }

    final dtMs = monotonicMs - _lastAcceptedMonotonicMs!;
    if (dtMs < 0) {
      // Non-monotonic timestamp rejected per AGENTS.md monotonic clock rule.
      skippedRedundantCount++;
      return false;
    }

    final movedMeters = haversineMeters(
      _lastAcceptedLat!,
      _lastAcceptedLon!,
      latitude,
      longitude,
    );

    if (dtMs >= minIntervalMs || movedMeters >= minDistanceMeters) {
      _accept(latitude, longitude, monotonicMs);
      return true;
    }

    skippedRedundantCount++;
    return false;
  }

  void _accept(double lat, double lon, int monotonicMs) {
    _lastAcceptedLat = lat;
    _lastAcceptedLon = lon;
    _lastAcceptedMonotonicMs = monotonicMs;
    acceptedCount++;
  }

  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    final c = 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
    return earthRadiusM * c;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}
