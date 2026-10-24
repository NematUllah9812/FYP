import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';
import 'package:terrasteps_gpx/terrasteps_gpx.dart';

import '../config/app_env.dart';
import '../data/local/app_database.dart';

/// Deliverable 1: Device GPX 1.1 File Builder, Crash Recovery & Exporter.
///
/// Reads persisted `track_points` from Drift SQLite, builds a standards-compliant
/// GPX 1.1 XML file inside `<app_documents>/terrasteps_gpx/`, and supports native
/// OS share-sheet export as well as importing Google Drive benchmark `.gpx` files.
class GpxFileService {
  final AppDatabase db;
  final GpxSerializer _serializer = const GpxSerializer();
  final GpxParser _parser = const GpxParser();

  GpxFileService({required this.db});

  Future<Directory> _ensureGpxDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'terrasteps_gpx'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Serializes all SQLite `track_points` of [sessionId] into a `.gpx` file on disk
  /// and saves the resulting file path back onto `workout_sessions.gpx_file_path`.
  Future<File> generateAndSaveGpxFile(String sessionId) async {
    final session = await db.getWorkoutSession(sessionId);
    if (session == null) {
      throw StateError('Workout session $sessionId not found in local database.');
    }

    final points = await db.getTrackPointsForSession(sessionId);
    final uniqueCells = points.map((pt) => pt.h3Index).toSet().length;

    final safeTs = session.startTimeUtc
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final meta = GpxSessionMetadata(
      sessionId: session.sessionId,
      name: 'Session_${safeTs}Z',
      trackName: session.title,
      activityType: 'walking',
      createdAtUtc: session.startTimeUtc,
      h3Resolution: AppEnv.h3Resolution,
      totalMeasuredSteps: session.totalMeasuredSteps,
      totalEstimatedSteps: session.estimatedSteps,
      totalDistanceMeters: session.totalDistanceMeters,
      totalCaloriesKcal: session.totalCaloriesKcal,
      activeDurationMs: session.activeDurationMs,
      uniqueH3Cells: uniqueCells > 0 ? uniqueCells : session.cellsVisited,
    );

    final xml = _serializer.serialize(metadata: meta, points: points);
    final dir = await _ensureGpxDirectory();
    final shortId = session.sessionId.split('-').first;
    final file = File(p.join(dir.path, 'terrasteps_${safeTs}_$shortId.gpx'));
    await file.writeAsString(xml, flush: true);

    await db.attachGpxPath(session.sessionId, file.path);
    return file;
  }

  /// Reads raw XML content of an existing or newly built session `.gpx` file
  /// so evaluators can inspect `<trkpt>` extensions directly on-screen.
  Future<String> readSessionGpxXml(String sessionId) async {
    final session = await db.getWorkoutSession(sessionId);
    if (session?.gpxFilePath != null) {
      final existing = File(session!.gpxFilePath!);
      if (await existing.exists()) {
        return existing.readAsString();
      }
    }
    final built = await generateAndSaveGpxFile(sessionId);
    return built.readAsString();
  }

  /// Opens the native Android/iOS share sheet with the `.gpx` file attached.
  Future<void> shareSessionGpx(String sessionId) async {
    final file = await generateAndSaveGpxFile(sessionId);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/gpx+xml')],
      subject: 'TerraSteps Workout GPX 1.1 ($sessionId)',
      text: 'Recorded with TerraSteps (H3 Res-9 + Step/MET Extensions).',
    );
  }

  /// Imports a raw `.gpx` XML string (e.g., downloaded from Google Drive benchmark
  /// datasets) into Drift SQLite so it can be viewed, replayed, and verified.
  Future<String> importGpxXmlToDatabase({
    required String xmlContent,
    required String batchUuid,
  }) async {
    final doc = _parser.parse(xmlContent);
    final sid = doc.metadata.sessionId;

    await db.createWorkoutSession(
      sessionId: sid,
      title: doc.metadata.trackName,
      startTimeUtc: doc.metadata.createdAtUtc,
      batchUuid: batchUuid,
    );

    final hexAgg = HexEffortAggregator();
    var prevLat = doc.points.isNotEmpty ? doc.points.first.latitude : 0.0;
    var prevLon = doc.points.isNotEmpty ? doc.points.first.longitude : 0.0;
    var prevMono = 0;
    var cumDist = 0.0;
    var maxSpeed = 0.0;

    for (final pt in doc.points) {
      final distDelta = GpxTrackFilter.haversineMeters(
        prevLat,
        prevLon,
        pt.latitude,
        pt.longitude,
      );
      final dtMs = (pt.monotonicMs - prevMono).clamp(0, 60000);
      cumDist += distDelta;
      if (pt.speedMps > maxSpeed) maxSpeed = pt.speedMps;

      final hexSummary = hexAgg.recordSample(
        h3Index: pt.h3Index,
        parentRes5: pt.parentRes5 ?? AppEnv.pilotRegionRes5,
        latitude: pt.latitude,
        longitude: pt.longitude,
        accuracyMeters: pt.accuracyMeters,
        speedMps: pt.speedMps,
        stepsDelta: pt.stepsDelta,
        distanceDeltaMeters: distDelta,
        dtMonotonicMs: dtMs,
        cadenceSpm: pt.cadenceSpm,
        timestampUtc: pt.timestampUtc,
      );

      // Downsample imported 1Hz benchmarks to every 5th point in SQLite if > 600 pts
      // while keeping exact per-hex aggregator totals, then write full GPX file.
      if (doc.points.length <= 600 ||
          pt.sequence % 5 == 0 ||
          pt.sequence == doc.points.length - 1) {
        await db.appendTrackPointAtomic(
          sessionId: sid,
          point: pt,
          hexSummary: hexSummary,
          totalMeasuredSteps: doc.metadata.totalMeasuredSteps,
          totalEstimatedSteps: doc.metadata.totalEstimatedSteps,
          totalCaloriesKcal: doc.metadata.totalCaloriesKcal,
          totalDistanceMeters: doc.metadata.totalDistanceMeters > 0
              ? doc.metadata.totalDistanceMeters
              : cumDist,
          activeDurationMs: doc.metadata.activeDurationMs,
          elapsedDurationMs: doc.metadata.activeDurationMs,
          maxSpeedMps: maxSpeed,
          cellsVisited: hexAgg.visitedCellsCount,
        );
      }

      prevLat = pt.latitude;
      prevLon = pt.longitude;
      prevMono = pt.monotonicMs;
    }

    final dir = await _ensureGpxDirectory();
    final outFile = File(p.join(dir.path, 'imported_$sid.gpx'));
    await outFile.writeAsString(xmlContent, flush: true);

    await db.completeWorkoutSession(
      sessionId: sid,
      endTimeUtc: doc.points.isNotEmpty
          ? doc.points.last.timestampUtc
          : doc.metadata.createdAtUtc,
      activeDurationMs: doc.metadata.activeDurationMs,
      elapsedDurationMs: doc.metadata.activeDurationMs,
      totalMeasuredSteps: doc.metadata.totalMeasuredSteps,
      totalEstimatedSteps: doc.metadata.totalEstimatedSteps,
      totalCaloriesKcal: doc.metadata.totalCaloriesKcal,
      totalDistanceMeters: doc.metadata.totalDistanceMeters > 0
          ? doc.metadata.totalDistanceMeters
          : cumDist,
      cellsVisited: hexAgg.visitedCellsCount,
      gpxFilePath: outFile.path,
      syncStatus: 'PENDING',
    );

    return sid;
  }
}
