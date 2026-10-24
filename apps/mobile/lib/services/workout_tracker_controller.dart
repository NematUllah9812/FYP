import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';
import 'package:terrasteps_gpx/terrasteps_gpx.dart';
import 'package:uuid/uuid.dart';

import '../config/app_env.dart';
import '../data/local/app_database.dart';
import 'gpx_file_service.dart';
import 'h3_spatial_service.dart';

enum WorkoutLifecycleState { idle, recording, paused }

/// Orchestrates real-time hardware tracking (GPS + Pedometer), dynamic METs
/// calorie calculation, H3 Resolution-9 hex effort scoring, atomic Drift SQLite
/// persistence, crash recovery, and GPX 1.1 file creation.
class WorkoutTrackerController extends ChangeNotifier {
  final AppDatabase db;
  final H3SpatialService h3Service;
  final GpxFileService gpxFileService;

  final StepCounterEngine _stepEngine = StepCounterEngine();
  final GpxTrackFilter _trackFilter = GpxTrackFilter(
    maxAccuracyMeters: 25.0,
    minIntervalMs: 3000,
    minDistanceMeters: 5.0,
  );
  final HexEffortAggregator _hexAggregator = HexEffortAggregator();
  final Stopwatch _monotonicClock = Stopwatch();
  final Uuid _uuid = const Uuid();

  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<StepCount>? _stepSub;
  Timer? _uiTickTimer;
  Timer? _demoSimTimer;

  UserFitnessProfile _profile = const UserFitnessProfile(id: 'local_default');
  WorkoutLifecycleState _lifecycle = WorkoutLifecycleState.idle;
  WorkoutSessionRecord? _recoverableSession;

  String? _activeSessionId;
  String? _activeBatchUuid;
  DateTime? _sessionStartUtc;
  int _lastProcessedMonotonicMs = 0;
  int _activeDurationMs = 0;
  int _sequence = 0;
  int _pendingStepsDelta = 0;
  double _distanceMeters = 0.0;
  double _caloriesKcal = 0.0;
  double _currentSpeedMps = 0.0;
  double _maxSpeedMps = 0.0;
  double _currentMet = 1.3;
  ActivityIntensity _intensity = ActivityIntensity.stationary;

  double _currentLat = AppEnv.pilotCenterLat;
  double _currentLon = AppEnv.pilotCenterLng;
  String _currentH3Cell = '';
  final List<List<double>> _liveTrailLngLat = [];
  String? _interruptionNotice;
  bool _isDemoSimulation = false;

  WorkoutTrackerController({
    required this.db,
    required this.h3Service,
    required this.gpxFileService,
  });

  // Getters for UI layers
  WorkoutLifecycleState get lifecycle => _lifecycle;
  UserFitnessProfile get profile => _profile;
  WorkoutSessionRecord? get recoverableSession => _recoverableSession;
  String? get activeSessionId => _activeSessionId;
  double get currentLat => _currentLat;
  double get currentLon => _currentLon;
  String get currentH3Cell => _currentH3Cell;
  List<List<double>> get liveTrailLngLat => List.unmodifiable(_liveTrailLngLat);
  String? get interruptionNotice => _interruptionNotice;
  bool get isDemoSimulation => _isDemoSimulation;

  HexVisitSummary? get activeHexSummary =>
      _currentH3Cell.isNotEmpty ? _hexAggregator.summaryFor(_currentH3Cell) : null;

  List<HexVisitSummary> get sessionHexSummaries => _hexAggregator.allSummaries;

  LiveFitnessSnapshot get liveSnapshot {
    final elapsedMs = _monotonicClock.elapsedMilliseconds;
    final estSteps = MetCalorieCalculator.estimateStepsFromDistance(
      distanceMeters: _distanceMeters,
      profile: _profile,
      speedMps: _currentSpeedMps,
    );
    return LiveFitnessSnapshot(
      measuredSteps: _stepEngine.measuredSteps,
      estimatedSteps: estSteps,
      cadenceSpm: _stepEngine.currentCadenceSpm(elapsedMs),
      distanceMeters: _distanceMeters,
      elapsedDurationMs: elapsedMs,
      activeDurationMs: _activeDurationMs,
      currentSpeedMps: _currentSpeedMps,
      currentMet: _currentMet,
      intensity: _intensity,
      caloriesBurnedKcal: _caloriesKcal,
      counterResetCount: _stepEngine.counterResetCount,
    );
  }

  Future<void> initialize() async {
    _profile = await db.getUserProfile();
    _recoverableSession = await db.findUnfinishedSession();
    try {
      _currentH3Cell = h3Service.latLonToCell(_currentLat, _currentLon);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> updateUserProfile(UserFitnessProfile updated) async {
    _profile = updated;
    await db.saveUserProfile(updated);
    notifyListeners();
  }

  /// Recovers an interrupted `ACTIVE` workout from Drift SQLite into a valid
  /// `.gpx` 1.1 file (Deliverable 1 Crash Resilience).
  Future<String?> recoverInterruptedSession() async {
    final unfinished = _recoverableSession;
    if (unfinished == null) return null;

    final file = await gpxFileService.generateAndSaveGpxFile(unfinished.sessionId);
    await db.completeWorkoutSession(
      sessionId: unfinished.sessionId,
      endTimeUtc: DateTime.now().toUtc(),
      activeDurationMs: unfinished.activeDurationMs,
      elapsedDurationMs: unfinished.elapsedDurationMs,
      totalMeasuredSteps: unfinished.totalMeasuredSteps,
      totalEstimatedSteps: unfinished.estimatedSteps,
      totalCaloriesKcal: unfinished.totalCaloriesKcal,
      totalDistanceMeters: unfinished.totalDistanceMeters,
      cellsVisited: unfinished.cellsVisited,
      gpxFilePath: file.path,
      syncStatus: 'PENDING',
    );
    _recoverableSession = null;
    notifyListeners();
    return file.path;
  }

  /// Starts a live hardware GPS + Pedometer workout session.
  Future<void> startHardwareWorkout({String title = 'Outdoor Hex Walk'}) async {
    if (_lifecycle != WorkoutLifecycleState.idle) return;
    _interruptionNotice = null;
    _isDemoSimulation = false;

    // Request Android 10+ ACTIVITY_RECOGNITION + fine location permissions
    final activityStatus = await Permission.activityRecognition.request();
    if (!activityStatus.isGranted) {
      _interruptionNotice =
          'Physical Activity permission is off — hardware pedometer steps cannot be measured until granted.';
    }

    var locPerm = await Geolocator.checkPermission();
    if (locPerm == LocationPermission.denied) {
      locPerm = await Geolocator.requestPermission();
    }
    if (locPerm == LocationPermission.denied ||
        locPerm == LocationPermission.deniedForever) {
      _interruptionNotice =
          'Location permission is required to record GPX tracks and H3 hexes.';
      notifyListeners();
      return;
    }

    await _beginSessionState(title: title);

    _stepSub = Pedometer.stepCountStream.listen(
      (StepCount event) {
        final monoMs = _monotonicClock.elapsedMilliseconds;
        final delta = _stepEngine.onSensorReading(
          rawCumulativeSteps: event.steps,
          monotonicMs: monoMs,
        );
        if (delta > 0) {
          _pendingStepsDelta += delta;
          notifyListeners();
        }
      },
      onError: (_) {
        _interruptionNotice ??=
            'Hardware step sensor unavailable on this device; recording GPS trail only.';
        notifyListeners();
      },
    );

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position pos) {
        _ingestLocationSample(
          lat: pos.latitude,
          lon: pos.longitude,
          elevationM: pos.altitude,
          accuracyM: pos.accuracy <= 0 ? 5.0 : pos.accuracy,
          speedMps: math.max(0.0, pos.speed),
        );
      },
      onError: (Object err) {
        _interruptionNotice = 'Location stream interrupted: $err';
        notifyListeners();
      },
    );
  }

  /// Starts a deterministic simulated walk (or vehicle cheat test) for indoor
  /// 30% FYP defense demonstrations when GPS sky view is unavailable inside a hall.
  Future<void> startSimulatedDefenseSession({
    bool vehicleCheatDemo = false,
  }) async {
    if (_lifecycle != WorkoutLifecycleState.idle) return;
    _interruptionNotice = null;
    _isDemoSimulation = true;

    await _beginSessionState(
      title: vehicleCheatDemo
          ? 'Defense Demo: Simulated 48 km/h Car Spoof'
          : 'Defense Demo: Abbottabad Campus Hex Walk',
    );

    var simTick = 0;
    var simRawSteps = 10000;
    var simLat = AppEnv.pilotCenterLat;
    var simLon = AppEnv.pilotCenterLng;
    var heading = 0.48;

    _demoSimTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_lifecycle != WorkoutLifecycleState.recording) return;
      simTick++;
      heading += math.sin(simTick / 12.0) * 0.08;

      final speedMps = vehicleCheatDemo ? 13.4 : 1.48;
      final stepAdd = vehicleCheatDemo ? (simTick % 6 == 0 ? 1 : 0) : 6;
      simRawSteps += stepAdd;

      final monoMs = _monotonicClock.elapsedMilliseconds;
      final stepDelta = _stepEngine.onSensorReading(
        rawCumulativeSteps: simRawSteps,
        monotonicMs: monoMs,
        bootId: 'defense_sim_boot',
      );
      _pendingStepsDelta += stepDelta;

      final movedM = speedMps * 3.0;
      simLat += (movedM * math.cos(heading)) / 111320.0;
      simLon += (movedM * math.sin(heading)) /
          (111320.0 * math.cos(simLat * math.pi / 180.0));

      _ingestLocationSample(
        lat: simLat,
        lon: simLon,
        elevationM: 1256.4 + 4.0 * math.sin(simTick / 8.0),
        accuracyM: 4.4,
        speedMps: speedMps,
      );
    });
  }

  Future<void> _beginSessionState({required String title}) async {
    _stepEngine.reset();
    _trackFilter.reset();
    _hexAggregator.reset();
    _liveTrailLngLat.clear();

    _activeSessionId = _uuid.v4();
    _activeBatchUuid = _uuid.v4();
    _sessionStartUtc = DateTime.now().toUtc();
    _lastProcessedMonotonicMs = 0;
    _activeDurationMs = 0;
    _sequence = 0;
    _pendingStepsDelta = 0;
    _distanceMeters = 0.0;
    _caloriesKcal = 0.0;
    _currentSpeedMps = 0.0;
    _maxSpeedMps = 0.0;
    _currentMet = 1.3;
    _intensity = ActivityIntensity.stationary;

    await db.createWorkoutSession(
      sessionId: _activeSessionId!,
      title: title,
      startTimeUtc: _sessionStartUtc!,
      batchUuid: _activeBatchUuid!,
    );

    _monotonicClock
      ..reset()
      ..start();
    _lifecycle = WorkoutLifecycleState.recording;

    _uiTickTimer?.cancel();
    _uiTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> _ingestLocationSample({
    required double lat,
    required double lon,
    required double elevationM,
    required double accuracyM,
    required double speedMps,
  }) async {
    if (_lifecycle != WorkoutLifecycleState.recording || _activeSessionId == null) {
      return;
    }

    final monoMs = _monotonicClock.elapsedMilliseconds;
    final accepted = _trackFilter.shouldRecord(
      latitude: lat,
      longitude: lon,
      accuracyMeters: accuracyM,
      monotonicMs: monoMs,
    );
    if (!accepted) return;

    final prevLat = _liveTrailLngLat.isNotEmpty ? _liveTrailLngLat.last[1] : lat;
    final prevLon = _liveTrailLngLat.isNotEmpty ? _liveTrailLngLat.last[0] : lon;
    final distDelta = _liveTrailLngLat.isEmpty
        ? 0.0
        : GpxTrackFilter.haversineMeters(prevLat, prevLon, lat, lon);

    final dtMs = (monoMs - _lastProcessedMonotonicMs).clamp(0, 30000);
    _lastProcessedMonotonicMs = monoMs;

    final effectiveSpeed = speedMps > 0.05
        ? speedMps
        : (dtMs > 0 ? (distDelta / (dtMs / 1000.0)) : 0.0);

    final cadence = _stepEngine.currentCadenceSpm(monoMs);
    _intensity = MetCalorieCalculator.classifyIntensity(
      speedMps: effectiveSpeed,
      cadenceSpm: cadence,
    );
    _currentMet = MetCalorieCalculator.metForIntensity(
      _intensity,
      distanceMeters: distDelta,
    );

    var kcalDelta = 0.0;
    if (_intensity != ActivityIntensity.stationary && dtMs > 0) {
      _activeDurationMs += dtMs;
      kcalDelta = MetCalorieCalculator.computeCaloriesKcal(
        met: _currentMet,
        weightKg: _profile.weightKg,
        durationMs: dtMs,
      );
      _caloriesKcal += kcalDelta;
    }

    _distanceMeters += distDelta;
    _currentSpeedMps = effectiveSpeed;
    if (effectiveSpeed > _maxSpeedMps) _maxSpeedMps = effectiveSpeed;
    _currentLat = lat;
    _currentLon = lon;
    _liveTrailLngLat.add([lon, lat]);

    final cellId = h3Service.latLonToCell(lat, lon);
    final parent5 = h3Service.cellToParentRes5(cellId);
    _currentH3Cell = cellId;

    final stepsForPoint = _pendingStepsDelta;
    _pendingStepsDelta = 0;

    final nowUtc = DateTime.now().toUtc();
    final hexSummary = _hexAggregator.recordSample(
      h3Index: cellId,
      parentRes5: parent5,
      latitude: lat,
      longitude: lon,
      accuracyMeters: accuracyM,
      speedMps: effectiveSpeed,
      stepsDelta: stepsForPoint,
      distanceDeltaMeters: distDelta,
      dtMonotonicMs: dtMs,
      cadenceSpm: cadence,
      timestampUtc: nowUtc,
    );

    final trackPoint = GpxTrackPoint(
      sequence: _sequence++,
      latitude: lat,
      longitude: lon,
      elevationMeters: elevationM,
      timestampUtc: nowUtc,
      monotonicMs: monoMs,
      stepsDelta: stepsForPoint,
      cumulativeSteps: _stepEngine.measuredSteps,
      cadenceSpm: cadence,
      speedMps: effectiveSpeed,
      accuracyMeters: accuracyM,
      caloriesDeltaKcal: kcalDelta,
      h3Index: cellId,
      parentRes5: parent5,
      samplingState: _intensity == ActivityIntensity.stationary
          ? 'stationary'
          : 'moving',
    );

    final estSteps = MetCalorieCalculator.estimateStepsFromDistance(
      distanceMeters: _distanceMeters,
      profile: _profile,
      speedMps: effectiveSpeed,
    );

    await db.appendTrackPointAtomic(
      sessionId: _activeSessionId!,
      point: trackPoint,
      hexSummary: hexSummary,
      totalMeasuredSteps: _stepEngine.measuredSteps,
      totalEstimatedSteps: estSteps,
      totalCaloriesKcal: _caloriesKcal,
      totalDistanceMeters: _distanceMeters,
      activeDurationMs: _activeDurationMs,
      elapsedDurationMs: monoMs,
      maxSpeedMps: _maxSpeedMps,
      cellsVisited: _hexAggregator.visitedCellsCount,
    );

    notifyListeners();
  }

  void pauseWorkout() {
    if (_lifecycle != WorkoutLifecycleState.recording) return;
    _monotonicClock.stop();
    _stepEngine.pause();
    _lifecycle = WorkoutLifecycleState.paused;
    notifyListeners();
  }

  void resumeWorkout() {
    if (_lifecycle != WorkoutLifecycleState.paused) return;
    _stepEngine.resume();
    _monotonicClock.start();
    _lifecycle = WorkoutLifecycleState.recording;
    notifyListeners();
  }

  /// Stops sensors, writes the `.gpx` 1.1 XML file on device storage, and marks
  /// the workout session completed in Drift SQLite.
  Future<String?> finishAndExportGpx() async {
    if (_lifecycle == WorkoutLifecycleState.idle || _activeSessionId == null) {
      return null;
    }

    _monotonicClock.stop();
    await _gpsSub?.cancel();
    await _stepSub?.cancel();
    _uiTickTimer?.cancel();
    _demoSimTimer?.cancel();
    _gpsSub = null;
    _stepSub = null;

    final sid = _activeSessionId!;
    final elapsedMs = _monotonicClock.elapsedMilliseconds;
    final estSteps = MetCalorieCalculator.estimateStepsFromDistance(
      distanceMeters: _distanceMeters,
      profile: _profile,
      speedMps: _currentSpeedMps,
    );

    final gpxFile = await gpxFileService.generateAndSaveGpxFile(sid);
    await db.completeWorkoutSession(
      sessionId: sid,
      endTimeUtc: DateTime.now().toUtc(),
      activeDurationMs: _activeDurationMs,
      elapsedDurationMs: elapsedMs,
      totalMeasuredSteps: _stepEngine.measuredSteps,
      totalEstimatedSteps: estSteps,
      totalCaloriesKcal: _caloriesKcal,
      totalDistanceMeters: _distanceMeters,
      cellsVisited: _hexAggregator.visitedCellsCount,
      gpxFilePath: gpxFile.path,
      syncStatus: 'PENDING',
    );

    _lifecycle = WorkoutLifecycleState.idle;
    _activeSessionId = null;
    _isDemoSimulation = false;
    notifyListeners();
    return gpxFile.path;
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _stepSub?.cancel();
    _uiTickTimer?.cancel();
    _demoSimTimer?.cancel();
    super.dispose();
  }
}
