import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';
import 'package:terrasteps_gpx/terrasteps_gpx.dart';

/// Offline-first local relational database built on **Drift (SQLite)**.
///
/// Implements the 4 core milestone tables + 1 offline map tile/hex cache table:
/// 1. `user_profile`      — weight_kg, height_cm, age, gender, daily_step_goal
/// 2. `workout_sessions`  — UUID, start/end UTC, measured/estimated steps, kcal,
///                          distance_m, gpx_file_path, sync_status
/// 3. `track_points`      — crash-resilient GPS + step + H3 breadcrumbs
/// 4. `local_hex_effort`  — per-hex steps, distance, active dwell, effort & score_micro
/// 5. `cached_map_hexes`  — offline Map API viewport hex cache for Airplane Mode
class AppDatabase extends GeneratedDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Named reactive table hooks so Drift stream queries auto-emit on writes.
  late final CustomTable _userProfileTable = CustomTable('user_profile');
  late final CustomTable _sessionsTable = CustomTable('workout_sessions');
  late final CustomTable _trackPointsTable = CustomTable('track_points');
  late final CustomTable _hexEffortTable = CustomTable('local_hex_effort');
  late final CustomTable _cachedHexesTable = CustomTable('cached_map_hexes');

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await customStatement('''
            CREATE TABLE IF NOT EXISTS user_profile (
              id TEXT PRIMARY KEY NOT NULL,
              username TEXT NOT NULL DEFAULT 'pilot_walker',
              weight_kg REAL NOT NULL DEFAULT 72.0,
              height_cm REAL NOT NULL DEFAULT 174.0,
              age INTEGER NOT NULL DEFAULT 22,
              gender TEXT NOT NULL DEFAULT 'unspecified',
              daily_step_goal INTEGER NOT NULL DEFAULT 8000,
              preferred_units TEXT NOT NULL DEFAULT 'metric',
              faction_color TEXT NOT NULL DEFAULT '#10B981',
              updated_at_utc TEXT NOT NULL
            );
          ''');

          await customStatement('''
            CREATE TABLE IF NOT EXISTS workout_sessions (
              session_id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              start_time_utc TEXT NOT NULL,
              end_time_utc TEXT,
              active_duration_ms INTEGER NOT NULL DEFAULT 0,
              elapsed_duration_ms INTEGER NOT NULL DEFAULT 0,
              total_steps INTEGER NOT NULL DEFAULT 0,
              estimated_steps INTEGER NOT NULL DEFAULT 0,
              total_calories_kcal REAL NOT NULL DEFAULT 0.0,
              total_distance_m REAL NOT NULL DEFAULT 0.0,
              max_speed_mps REAL NOT NULL DEFAULT 0.0,
              cells_visited INTEGER NOT NULL DEFAULT 0,
              gpx_file_path TEXT,
              sync_status TEXT NOT NULL DEFAULT 'ACTIVE',
              batch_uuid TEXT,
              server_receipt_json TEXT
            );
          ''');

          await customStatement('''
            CREATE TABLE IF NOT EXISTS track_points (
              point_id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              timestamp_utc TEXT NOT NULL,
              monotonic_ms INTEGER NOT NULL,
              lat REAL NOT NULL,
              lon REAL NOT NULL,
              elevation REAL,
              accuracy_m REAL NOT NULL,
              speed_mps REAL NOT NULL,
              steps_delta INTEGER NOT NULL DEFAULT 0,
              cumulative_steps INTEGER NOT NULL DEFAULT 0,
              cadence_spm INTEGER NOT NULL DEFAULT 0,
              calories_delta_kcal REAL NOT NULL DEFAULT 0.0,
              h3_index TEXT NOT NULL,
              parent_res5 TEXT,
              sampling_state TEXT NOT NULL DEFAULT 'moving',
              FOREIGN KEY (session_id) REFERENCES workout_sessions(session_id) ON DELETE CASCADE
            );
          ''');

          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_track_points_session ON track_points(session_id, sequence);',
          );

          await customStatement('''
            CREATE TABLE IF NOT EXISTS local_hex_effort (
              session_id TEXT NOT NULL,
              h3_index TEXT NOT NULL,
              parent_res5 TEXT NOT NULL,
              last_lat REAL NOT NULL,
              last_lon REAL NOT NULL,
              steps_in_hex INTEGER NOT NULL DEFAULT 0,
              distance_in_hex_m REAL NOT NULL DEFAULT 0.0,
              dwell_time_sec INTEGER NOT NULL DEFAULT 0,
              active_dwell_sec INTEGER NOT NULL DEFAULT 0,
              fix_count INTEGER NOT NULL DEFAULT 0,
              mean_accuracy_m REAL NOT NULL DEFAULT 5.0,
              max_speed_mps REAL NOT NULL DEFAULT 0.0,
              effort_score REAL NOT NULL DEFAULT 0.0,
              server_effort REAL NOT NULL DEFAULT 0.0,
              score_micro TEXT NOT NULL DEFAULT '0',
              window_start_utc TEXT NOT NULL,
              window_end_utc TEXT NOT NULL,
              PRIMARY KEY (session_id, h3_index),
              FOREIGN KEY (session_id) REFERENCES workout_sessions(session_id) ON DELETE CASCADE
            );
          ''');

          await customStatement('''
            CREATE TABLE IF NOT EXISTS cached_map_hexes (
              h3_index TEXT PRIMARY KEY NOT NULL,
              parent_res5 TEXT NOT NULL,
              state TEXT NOT NULL,
              nickname TEXT,
              kingdom_name TEXT,
              fill_color TEXT NOT NULL,
              influence REAL NOT NULL DEFAULT 0.0,
              score_micro TEXT,
              masked INTEGER NOT NULL DEFAULT 0,
              mask_reason TEXT,
              geojson_feature TEXT NOT NULL,
              cached_at_utc TEXT NOT NULL
            );
          ''');

          // Seed default offline user profile
          await customStatement('''
            INSERT OR IGNORE INTO user_profile
              (id, username, weight_kg, height_cm, age, gender, daily_step_goal, preferred_units, faction_color, updated_at_utc)
            VALUES
              ('local_default', 'pilot_walker', 72.0, 174.0, 22, 'unspecified', 8000, 'metric', '#10B981', '${DateTime.now().toUtc().toIso8601String()}');
          ''');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON;');
        },
      );

  // ---------------------------------------------------------------------------
  // User Profile DAO methods
  // ---------------------------------------------------------------------------

  Future<UserFitnessProfile> getUserProfile() async {
    final rows = await customSelect(
      'SELECT * FROM user_profile LIMIT 1',
      readsFrom: {_userProfileTable},
    ).get();
    if (rows.isEmpty) {
      return const UserFitnessProfile(id: 'local_default');
    }
    return _mapProfile(rows.first);
  }

  Stream<UserFitnessProfile> watchUserProfile() {
    return customSelect(
      'SELECT * FROM user_profile LIMIT 1',
      readsFrom: {_userProfileTable},
    ).watch().map((rows) {
      if (rows.isEmpty) return const UserFitnessProfile(id: 'local_default');
      return _mapProfile(rows.first);
    });
  }

  Future<void> saveUserProfile(UserFitnessProfile profile) async {
    await customInsert(
      '''
      INSERT INTO user_profile
        (id, username, weight_kg, height_cm, age, gender, daily_step_goal, preferred_units, faction_color, updated_at_utc)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(id) DO UPDATE SET
        username = excluded.username,
        weight_kg = excluded.weight_kg,
        height_cm = excluded.height_cm,
        age = excluded.age,
        gender = excluded.gender,
        daily_step_goal = excluded.daily_step_goal,
        preferred_units = excluded.preferred_units,
        faction_color = excluded.faction_color,
        updated_at_utc = excluded.updated_at_utc
      ''',
      variables: [
        Variable.withString(profile.id),
        Variable.withString(profile.username),
        Variable.withReal(profile.weightKg),
        Variable.withReal(profile.heightCm),
        Variable.withInt(profile.age),
        Variable.withString(profile.gender.name),
        Variable.withInt(profile.dailyStepGoal),
        Variable.withString(profile.preferredUnits.name),
        Variable.withString(profile.factionColor),
        Variable.withString(DateTime.now().toUtc().toIso8601String()),
      ],
      updates: {_userProfileTable},
    );
  }

  // ---------------------------------------------------------------------------
  // Workout Session & Crash-Safe TrackPoint DAO methods
  // ---------------------------------------------------------------------------

  Future<void> createWorkoutSession({
    required String sessionId,
    required String title,
    required DateTime startTimeUtc,
    required String batchUuid,
  }) async {
    await customInsert(
      '''
      INSERT INTO workout_sessions
        (session_id, title, start_time_utc, sync_status, batch_uuid)
      VALUES (?1, ?2, ?3, 'ACTIVE', ?4)
      ''',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(title),
        Variable.withString(startTimeUtc.toUtc().toIso8601String()),
        Variable.withString(batchUuid),
      ],
      updates: {_sessionsTable},
    );
  }

  /// Appends a GPS+step trackpoint AND updates running session & per-hex effort
  /// inside a single atomic SQLite transaction (Deliverable 1 crash resilience).
  Future<void> appendTrackPointAtomic({
    required String sessionId,
    required GpxTrackPoint point,
    required HexVisitSummary hexSummary,
    required int totalMeasuredSteps,
    required int totalEstimatedSteps,
    required double totalCaloriesKcal,
    required double totalDistanceMeters,
    required int activeDurationMs,
    required int elapsedDurationMs,
    required double maxSpeedMps,
    required int cellsVisited,
  }) async {
    await transaction(() async {
      await customInsert(
        '''
        INSERT INTO track_points (
          session_id, sequence, timestamp_utc, monotonic_ms, lat, lon, elevation,
          accuracy_m, speed_mps, steps_delta, cumulative_steps, cadence_spm,
          calories_delta_kcal, h3_index, parent_res5, sampling_state
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        ''',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(point.sequence),
          Variable.withString(point.timestampUtc.toIso8601String()),
          Variable.withInt(point.monotonicMs),
          Variable.withReal(point.latitude),
          Variable.withReal(point.longitude),
          point.elevationMeters != null
              ? Variable.withReal(point.elevationMeters!)
              : const Variable<double>(null),
          Variable.withReal(point.accuracyMeters),
          Variable.withReal(point.speedMps),
          Variable.withInt(point.stepsDelta),
          Variable.withInt(point.cumulativeSteps),
          Variable.withInt(point.cadenceSpm),
          Variable.withReal(point.caloriesDeltaKcal),
          Variable.withString(point.h3Index),
          point.parentRes5 != null
              ? Variable.withString(point.parentRes5!)
              : const Variable<String>(null),
          Variable.withString(point.samplingState),
        ],
        updates: {_trackPointsTable},
      );

      await customInsert(
        '''
        INSERT INTO local_hex_effort (
          session_id, h3_index, parent_res5, last_lat, last_lon,
          steps_in_hex, distance_in_hex_m, dwell_time_sec, active_dwell_sec,
          fix_count, mean_accuracy_m, max_speed_mps,
          effort_score, server_effort, score_micro, window_start_utc, window_end_utc
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
        ON CONFLICT(session_id, h3_index) DO UPDATE SET
          last_lat = excluded.last_lat,
          last_lon = excluded.last_lon,
          steps_in_hex = excluded.steps_in_hex,
          distance_in_hex_m = excluded.distance_in_hex_m,
          dwell_time_sec = excluded.dwell_time_sec,
          active_dwell_sec = excluded.active_dwell_sec,
          fix_count = excluded.fix_count,
          mean_accuracy_m = excluded.mean_accuracy_m,
          max_speed_mps = excluded.max_speed_mps,
          effort_score = excluded.effort_score,
          server_effort = excluded.server_effort,
          score_micro = excluded.score_micro,
          window_end_utc = excluded.window_end_utc
        ''',
        variables: [
          Variable.withString(sessionId),
          Variable.withString(hexSummary.h3Index),
          Variable.withString(hexSummary.parentRes5),
          Variable.withReal(hexSummary.lastLat),
          Variable.withReal(hexSummary.lastLon),
          Variable.withInt(hexSummary.stepsInHex),
          Variable.withReal(hexSummary.distanceInHexMeters),
          Variable.withInt(hexSummary.totalDwellSeconds),
          Variable.withInt(hexSummary.activeDwellSeconds),
          Variable.withInt(hexSummary.fixCount),
          Variable.withReal(hexSummary.meanAccuracyMeters),
          Variable.withReal(hexSummary.maxSpeedMps),
          Variable.withReal(hexSummary.milestoneEffortScore),
          Variable.withReal(hexSummary.serverAuthoritativeEffort),
          Variable.withString(hexSummary.scoreMicro),
          Variable.withString(hexSummary.windowStartUtc.toIso8601String()),
          Variable.withString(hexSummary.windowEndUtc.toIso8601String()),
        ],
        updates: {_hexEffortTable},
      );

      await customUpdate(
        '''
        UPDATE workout_sessions SET
          active_duration_ms = ?2,
          elapsed_duration_ms = ?3,
          total_steps = ?4,
          estimated_steps = ?5,
          total_calories_kcal = ?6,
          total_distance_m = ?7,
          max_speed_mps = ?8,
          cells_visited = ?9
        WHERE session_id = ?1
        ''',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(activeDurationMs),
          Variable.withInt(elapsedDurationMs),
          Variable.withInt(totalMeasuredSteps),
          Variable.withInt(totalEstimatedSteps),
          Variable.withReal(totalCaloriesKcal),
          Variable.withReal(totalDistanceMeters),
          Variable.withReal(maxSpeedMps),
          Variable.withInt(cellsVisited),
        ],
        updates: {_sessionsTable},
      );
    });
  }

  Future<void> completeWorkoutSession({
    required String sessionId,
    required DateTime endTimeUtc,
    required int activeDurationMs,
    required int elapsedDurationMs,
    required int totalMeasuredSteps,
    required int totalEstimatedSteps,
    required double totalCaloriesKcal,
    required double totalDistanceMeters,
    required int cellsVisited,
    String? gpxFilePath,
    String syncStatus = 'PENDING',
  }) async {
    await customUpdate(
      '''
      UPDATE workout_sessions SET
        end_time_utc = ?2,
        active_duration_ms = ?3,
        elapsed_duration_ms = ?4,
        total_steps = ?5,
        estimated_steps = ?6,
        total_calories_kcal = ?7,
        total_distance_m = ?8,
        cells_visited = ?9,
        gpx_file_path = COALESCE(?10, gpx_file_path),
        sync_status = ?11
      WHERE session_id = ?1
      ''',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(endTimeUtc.toUtc().toIso8601String()),
        Variable.withInt(activeDurationMs),
        Variable.withInt(elapsedDurationMs),
        Variable.withInt(totalMeasuredSteps),
        Variable.withInt(totalEstimatedSteps),
        Variable.withReal(totalCaloriesKcal),
        Variable.withReal(totalDistanceMeters),
        Variable.withInt(cellsVisited),
        gpxFilePath != null
            ? Variable.withString(gpxFilePath)
            : const Variable<String>(null),
        Variable.withString(syncStatus),
      ],
      updates: {_sessionsTable},
    );
  }

  Future<void> updateSessionSyncReceipt({
    required String sessionId,
    required String syncStatus,
    Map<String, dynamic>? receipt,
  }) async {
    await customUpdate(
      '''
      UPDATE workout_sessions SET
        sync_status = ?2,
        server_receipt_json = ?3
      WHERE session_id = ?1
      ''',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(syncStatus),
        receipt != null
            ? Variable.withString(jsonEncode(receipt))
            : const Variable<String>(null),
      ],
      updates: {_sessionsTable},
    );
  }

  Future<void> attachGpxPath(String sessionId, String gpxFilePath) async {
    await customUpdate(
      'UPDATE workout_sessions SET gpx_file_path = ?2 WHERE session_id = ?1',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(gpxFilePath),
      ],
      updates: {_sessionsTable},
    );
  }

  /// Crash recovery query: returns any session left in `ACTIVE` state if the OS
  /// terminated the process mid-workout.
  Future<WorkoutSessionRecord?> findUnfinishedSession() async {
    final rows = await customSelect(
      "SELECT * FROM workout_sessions WHERE sync_status = 'ACTIVE' ORDER BY start_time_utc DESC LIMIT 1",
      readsFrom: {_sessionsTable},
    ).get();
    if (rows.isEmpty) return null;
    return _mapSession(rows.first);
  }

  Stream<List<WorkoutSessionRecord>> watchWorkoutSessions() {
    return customSelect(
      'SELECT * FROM workout_sessions ORDER BY start_time_utc DESC',
      readsFrom: {_sessionsTable},
    ).watch().map((rows) => rows.map(_mapSession).toList());
  }

  Future<WorkoutSessionRecord?> getWorkoutSession(String sessionId) async {
    final rows = await customSelect(
      'SELECT * FROM workout_sessions WHERE session_id = ?1',
      variables: [Variable.withString(sessionId)],
      readsFrom: {_sessionsTable},
    ).get();
    if (rows.isEmpty) return null;
    return _mapSession(rows.first);
  }

  Future<List<GpxTrackPoint>> getTrackPointsForSession(String sessionId) async {
    final rows = await customSelect(
      'SELECT * FROM track_points WHERE session_id = ?1 ORDER BY sequence ASC',
      variables: [Variable.withString(sessionId)],
      readsFrom: {_trackPointsTable},
    ).get();

    return rows.map((r) {
      return GpxTrackPoint(
        sequence: r.read<int>('sequence'),
        latitude: r.read<double>('lat'),
        longitude: r.read<double>('lon'),
        elevationMeters: r.readNullable<double>('elevation'),
        timestampUtc: DateTime.parse(r.read<String>('timestamp_utc')).toUtc(),
        monotonicMs: r.read<int>('monotonic_ms'),
        stepsDelta: r.read<int>('steps_delta'),
        cumulativeSteps: r.read<int>('cumulative_steps'),
        cadenceSpm: r.read<int>('cadence_spm'),
        speedMps: r.read<double>('speed_mps'),
        accuracyMeters: r.read<double>('accuracy_m'),
        caloriesDeltaKcal: r.read<double>('calories_delta_kcal'),
        h3Index: r.read<String>('h3_index'),
        parentRes5: r.readNullable<String>('parent_res5'),
        samplingState: r.read<String>('sampling_state'),
      );
    }).toList();
  }

  Future<List<HexVisitSummary>> getHexEffortsForSession(String sessionId) async {
    final rows = await customSelect(
      'SELECT * FROM local_hex_effort WHERE session_id = ?1 ORDER BY window_start_utc ASC',
      variables: [Variable.withString(sessionId)],
      readsFrom: {_hexEffortTable},
    ).get();

    return rows.map((r) {
      return HexVisitSummary(
        h3Index: r.read<String>('h3_index'),
        parentRes5: r.read<String>('parent_res5'),
        lastLat: r.read<double>('last_lat'),
        lastLon: r.read<double>('last_lon'),
        stepsInHex: r.read<int>('steps_in_hex'),
        distanceInHexMeters: r.read<double>('distance_in_hex_m'),
        totalDwellSeconds: r.read<int>('dwell_time_sec'),
        activeDwellSeconds: r.read<int>('active_dwell_sec'),
        fixCount: r.read<int>('fix_count'),
        meanAccuracyMeters: r.read<double>('mean_accuracy_m'),
        maxSpeedMps: r.read<double>('max_speed_mps'),
        windowStartUtc: DateTime.parse(r.read<String>('window_start_utc')).toUtc(),
        windowEndUtc: DateTime.parse(r.read<String>('window_end_utc')).toUtc(),
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Offline Map API Hex Cache
  // ---------------------------------------------------------------------------

  Future<void> cacheMapHexFeatures(List<Map<String, dynamic>> features) async {
    if (features.isEmpty) return;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    await transaction(() async {
      for (final f in features) {
        final props = (f['properties'] as Map<String, dynamic>?) ?? const {};
        final h3Id = (props['h3_id'] ?? f['id'] ?? '').toString();
        if (h3Id.isEmpty) continue;
        // Only persist occupied/masked cells in offline cache to stay compact
        final state = (props['state'] ?? 'neutral').toString();
        if (state == 'neutral') continue;

        await customInsert(
          '''
          INSERT INTO cached_map_hexes (
            h3_index, parent_res5, state, nickname, kingdom_name, fill_color,
            influence, score_micro, masked, mask_reason, geojson_feature, cached_at_utc
          ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
          ON CONFLICT(h3_index) DO UPDATE SET
            state = excluded.state,
            nickname = excluded.nickname,
            kingdom_name = excluded.kingdom_name,
            fill_color = excluded.fill_color,
            influence = excluded.influence,
            score_micro = excluded.score_micro,
            masked = excluded.masked,
            mask_reason = excluded.mask_reason,
            geojson_feature = excluded.geojson_feature,
            cached_at_utc = excluded.cached_at_utc
          ''',
          variables: [
            Variable.withString(h3Id),
            Variable.withString((props['parent_res5'] ?? '').toString()),
            Variable.withString(state),
            props['nickname'] != null
                ? Variable.withString(props['nickname'].toString())
                : const Variable<String>(null),
            props['kingdom_name'] != null
                ? Variable.withString(props['kingdom_name'].toString())
                : const Variable<String>(null),
            Variable.withString((props['fill_color'] ?? '#10B981').toString()),
            Variable.withReal(((props['influence'] ?? 0) as num).toDouble()),
            props['score_micro'] != null
                ? Variable.withString(props['score_micro'].toString())
                : const Variable<String>(null),
            Variable.withInt(props['masked'] == true ? 1 : 0),
            props['mask_reason'] != null
                ? Variable.withString(props['mask_reason'].toString())
                : const Variable<String>(null),
            Variable.withString(jsonEncode(f)),
            Variable.withString(nowIso),
          ],
          updates: {_cachedHexesTable},
        );
      }
    });
  }

  Future<Map<String, dynamic>> buildOfflineGeoJsonFeatureCollection() async {
    final rows = await customSelect(
      'SELECT geojson_feature FROM cached_map_hexes LIMIT 2500',
      readsFrom: {_cachedHexesTable},
    ).get();
    final features = rows
        .map((r) => jsonDecode(r.read<String>('geojson_feature')) as Map<String, dynamic>)
        .toList();
    return {
      'type': 'FeatureCollection',
      'features': features,
    };
  }

  UserFitnessProfile _mapProfile(QueryRow r) {
    final genderStr = r.read<String>('gender');
    final unitsStr = r.read<String>('preferred_units');
    return UserFitnessProfile(
      id: r.read<String>('id'),
      username: r.read<String>('username'),
      weightKg: r.read<double>('weight_kg'),
      heightCm: r.read<double>('height_cm'),
      age: r.read<int>('age'),
      gender: BiologicalSex.values.firstWhere(
        (e) => e.name == genderStr,
        orElse: () => BiologicalSex.unspecified,
      ),
      dailyStepGoal: r.read<int>('daily_step_goal'),
      preferredUnits: PreferredUnits.values.firstWhere(
        (e) => e.name == unitsStr,
        orElse: () => PreferredUnits.metric,
      ),
      factionColor: r.read<String>('faction_color'),
    );
  }

  WorkoutSessionRecord _mapSession(QueryRow r) {
    final endStr = r.readNullable<String>('end_time_utc');
    final receiptStr = r.readNullable<String>('server_receipt_json');
    return WorkoutSessionRecord(
      sessionId: r.read<String>('session_id'),
      title: r.read<String>('title'),
      startTimeUtc: DateTime.parse(r.read<String>('start_time_utc')).toUtc(),
      endTimeUtc: endStr != null ? DateTime.parse(endStr).toUtc() : null,
      activeDurationMs: r.read<int>('active_duration_ms'),
      elapsedDurationMs: r.read<int>('elapsed_duration_ms'),
      totalMeasuredSteps: r.read<int>('total_steps'),
      estimatedSteps: r.read<int>('estimated_steps'),
      totalCaloriesKcal: r.read<double>('total_calories_kcal'),
      totalDistanceMeters: r.read<double>('total_distance_m'),
      maxSpeedMps: r.read<double>('max_speed_mps'),
      cellsVisited: r.read<int>('cells_visited'),
      gpxFilePath: r.readNullable<String>('gpx_file_path'),
      syncStatus: r.read<String>('sync_status'),
      batchUuid: r.readNullable<String>('batch_uuid'),
      serverReceipt: receiptStr != null
          ? (jsonDecode(receiptStr) as Map<String, dynamic>)
          : null,
    );
  }
}

class CustomTable extends Table implements TableInfo<Table, Object?> {
  @override
  final String actualTableName;

  CustomTable(this.actualTableName);

  @override
  String get aliasedName => actualTableName;
  @override
  List<GeneratedColumn<Object>> get $columns => const [];
  @override
  Map<String, GeneratedColumn<Object>> get columnsByName => const {};
  @override
  Table get asDslTable => this;
  @override
  Set<GeneratedColumn<Object>> get $primaryKey => const {};
  @override
  List<Set<GeneratedColumn<Object>>> get uniqueKeys => const [];
  @override
  bool get withoutRowId => false;
  @override
  bool get isStrict => false;
  @override
  FutureOr<Object?> map(Map<String, dynamic> data, {String? tablePrefix}) => data;
  @override
  TableInfo<Table, Object?> createAlias(String alias) => CustomTable(alias);
  @override
  VerificationContext validateIntegrity(
    Insertable<Object?> instance, {
    bool isInserting = false,
  }) =>
      VerificationContext();
}

class WorkoutSessionRecord {
  final String sessionId;
  final String title;
  final DateTime startTimeUtc;
  final DateTime? endTimeUtc;
  final int activeDurationMs;
  final int elapsedDurationMs;
  final int totalMeasuredSteps;
  final int estimatedSteps;
  final double totalCaloriesKcal;
  final double totalDistanceMeters;
  final double maxSpeedMps;
  final int cellsVisited;
  final String? gpxFilePath;
  final String syncStatus;
  final String? batchUuid;
  final Map<String, dynamic>? serverReceipt;

  const WorkoutSessionRecord({
    required this.sessionId,
    required this.title,
    required this.startTimeUtc,
    this.endTimeUtc,
    required this.activeDurationMs,
    required this.elapsedDurationMs,
    required this.totalMeasuredSteps,
    required this.estimatedSteps,
    required this.totalCaloriesKcal,
    required this.totalDistanceMeters,
    required this.maxSpeedMps,
    required this.cellsVisited,
    this.gpxFilePath,
    required this.syncStatus,
    this.batchUuid,
    this.serverReceipt,
  });
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'terrasteps_offline.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
