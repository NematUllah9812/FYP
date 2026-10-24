import 'dart:collection';

/// Processes hardware step sensor events (`Sensor.TYPE_STEP_COUNTER`), which
/// report cumulative steps since the last OS boot.
///
/// Key guarantees (Deliverable 2 + AGENTS.md §12):
/// 1. Captures `baselineSteps` at `t = 0` so prior boot steps are subtracted.
/// 2. Cleanly handles pause/resume windows so steps walked while paused are
///    not credited to the active workout.
/// 3. Detects hardware counter resets or `bootId` changes mid-workout without
///    emitting negative deltas or losing accumulated session steps.
/// 4. Computes rolling cadence (steps/minute) over a monotonic 15-second window.
class StepCounterEngine {
  int? _baselineSensorSteps;
  int? _lastRawSensorSteps;
  String? _activeBootId;

  int _accumulatedMeasuredSteps = 0;
  int _counterResetCount = 0;
  bool _isPaused = false;
  bool _reanchorAfterPause = false;

  final Queue<_StepWindowEntry> _recentDeltas = Queue<_StepWindowEntry>();
  static const int _cadenceWindowMs = 15000;

  int get measuredSteps => _accumulatedMeasuredSteps;
  int get counterResetCount => _counterResetCount;
  bool get isPaused => _isPaused;
  int? get baselineSensorSteps => _baselineSensorSteps;

  void reset() {
    _baselineSensorSteps = null;
    _lastRawSensorSteps = null;
    _activeBootId = null;
    _accumulatedMeasuredSteps = 0;
    _counterResetCount = 0;
    _isPaused = false;
    _reanchorAfterPause = false;
    _recentDeltas.clear();
  }

  void pause() {
    _isPaused = true;
  }

  void resume() {
    if (_isPaused) {
      _isPaused = false;
      _reanchorAfterPause = true;
    }
  }

  /// Ingests a raw cumulative hardware step count and returns the step delta
  /// earned since the previous accepted reading.
  int onSensorReading({
    required int rawCumulativeSteps,
    required int monotonicMs,
    String bootId = 'default_boot',
  }) {
    if (rawCumulativeSteps < 0) {
      return 0;
    }

    if (_isPaused) {
      _lastRawSensorSteps = rawCumulativeSteps;
      _activeBootId = bootId;
      return 0;
    }

    // First reading of the session: anchor baseline, delta = 0
    if (_baselineSensorSteps == null || _lastRawSensorSteps == null) {
      _baselineSensorSteps = rawCumulativeSteps;
      _lastRawSensorSteps = rawCumulativeSteps;
      _activeBootId = bootId;
      return 0;
    }

    // First reading after resuming from pause: re-anchor cursor so steps
    // taken during pause are excluded cleanly.
    if (_reanchorAfterPause) {
      _lastRawSensorSteps = rawCumulativeSteps;
      _activeBootId = bootId;
      _reanchorAfterPause = false;
      return 0;
    }

    // Detect device reboot / sensor counter reset (`bootId` changed or raw dropped)
    final bootChanged = _activeBootId != null && _activeBootId != bootId;
    final counterRolledBack = rawCumulativeSteps < _lastRawSensorSteps!;

    if (bootChanged || counterRolledBack) {
      _counterResetCount++;
      _activeBootId = bootId;
      _baselineSensorSteps = rawCumulativeSteps;
      _lastRawSensorSteps = rawCumulativeSteps;
      return 0;
    }

    final delta = rawCumulativeSteps - _lastRawSensorSteps!;
    _lastRawSensorSteps = rawCumulativeSteps;

    if (delta > 0) {
      _accumulatedMeasuredSteps += delta;
      _recentDeltas.addLast(_StepWindowEntry(monotonicMs: monotonicMs, steps: delta));
    }
    _pruneCadenceWindow(monotonicMs);
    return delta;
  }

  /// Computes rolling step cadence in steps per minute (spm) at [monotonicMs].
  int currentCadenceSpm(int monotonicMs) {
    _pruneCadenceWindow(monotonicMs);
    if (_recentDeltas.isEmpty) return 0;

    var sumSteps = 0;
    for (final entry in _recentDeltas) {
      sumSteps += entry.steps;
    }
    final earliestMs = _recentDeltas.first.monotonicMs;
    final spanMs = (monotonicMs - earliestMs).clamp(3000, _cadenceWindowMs);
    return ((sumSteps * 60000.0) / spanMs).round();
  }

  void _pruneCadenceWindow(int nowMonotonicMs) {
    while (_recentDeltas.isNotEmpty &&
        (nowMonotonicMs - _recentDeltas.first.monotonicMs) > _cadenceWindowMs) {
      _recentDeltas.removeFirst();
    }
  }
}

class _StepWindowEntry {
  final int monotonicMs;
  final int steps;
  const _StepWindowEntry({required this.monotonicMs, required this.steps});
}
