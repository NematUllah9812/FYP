import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';

import '../../config/app_env.dart';
import '../local/app_database.dart';

class ViewportHexResponse {
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> geojson;
  final bool fromOfflineCache;

  const ViewportHexResponse({
    required this.snapshot,
    required this.geojson,
    this.fromOfflineCache = false,
  });

  List<Map<String, dynamic>> get features {
    final raw = geojson['features'];
    if (raw is List) {
      return raw.whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }
}

class RoutePreviewResult {
  final String provider;
  final int distanceMeters;
  final int durationSeconds;
  final int estimatedSteps;
  final double estimatedCaloriesKcal;
  final double metUsed;
  final int totalHexesTraversed;
  final int neutralHexes;
  final int rivalHexes;
  final int ownedHexes;
  final Map<String, dynamic> routeGeoJson;
  final Map<String, dynamic> hexesGeoJson;

  const RoutePreviewResult({
    required this.provider,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.estimatedSteps,
    required this.estimatedCaloriesKcal,
    required this.metUsed,
    required this.totalHexesTraversed,
    required this.neutralHexes,
    required this.rivalHexes,
    required this.ownedHexes,
    required this.routeGeoJson,
    required this.hexesGeoJson,
  });
}

/// Deliverable 3: Mobile Client for the TypeScript Supabase Edge Function (`map-api`)
/// backed by PostgreSQL + PostGIS.
///
/// Automatically caches fetched occupied/masked hex polygons in Drift SQLite so
/// the Mapbox view degrades gracefully in Airplane Mode.
class MapApiClient {
  final AppDatabase db;
  final http.Client _http;

  MapApiClient({
    required this.db,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'apikey': AppEnv.supabaseKey,
    };

    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null && session.accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${session.accessToken}';
      }
    } catch (_) {
      // Supabase not initialized or offline — public Map API reads still work.
    }

    if (AppEnv.hasMapboxToken) {
      headers['x-mapbox-token'] = AppEnv.mapboxAccessToken;
    }
    return headers;
  }

  /// Queries `GET /functions/v1/map-api/viewport` for H3 Resolution-9 hexes in
  /// the visible Mapbox bounding box. Falls back to Drift SQLite cache offline.
  Future<ViewportHexResponse> fetchViewportHexes({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool includeNeutral = true,
  }) async {
    final uri = Uri.parse('${AppEnv.mapApiBaseUrl}/viewport').replace(
      queryParameters: {
        'min_lat': minLat.toStringAsFixed(6),
        'min_lon': minLon.toStringAsFixed(6),
        'max_lat': maxLat.toStringAsFixed(6),
        'max_lon': maxLon.toStringAsFixed(6),
        'res': AppEnv.h3Resolution.toString(),
        'include_neutral': includeNeutral.toString(),
      },
    );

    try {
      final res = await _http
          .get(uri, headers: _buildHeaders())
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        final geojson =
            (decoded['geojson'] as Map<String, dynamic>?) ??
            {'type': 'FeatureCollection', 'features': <dynamic>[]};
        final snapshot =
            (decoded['snapshot'] as Map<String, dynamic>?) ?? <String, dynamic>{};

        final rawFeatures =
            (geojson['features'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
            const [];
        await db.cacheMapHexFeatures(rawFeatures);

        return ViewportHexResponse(
          snapshot: snapshot,
          geojson: geojson,
          fromOfflineCache: false,
        );
      }
    } catch (_) {
      // Network unreachable (e.g., Airplane Mode demo) -> fall back to Drift cache
    }

    final cachedGeoJson = await db.buildOfflineGeoJsonFeatureCollection();
    return ViewportHexResponse(
      snapshot: {
        'region_id': 'offline:${AppEnv.pilotRegionRes5}:cache',
        'as_of': DateTime.now().toUtc().toIso8601String(),
        'cursor': 'offline_cache',
        'h3_resolution': AppEnv.h3Resolution,
        'cells': const <dynamic>[],
      },
      geojson: cachedGeoJson,
      fromOfflineCache: true,
    );
  }

  /// Fetches detailed ownership, neighbor ring, and `effort_to_capture` for a tapped hex.
  Future<Map<String, dynamic>?> fetchCellDetail(String cellId) async {
    final uri = Uri.parse('${AppEnv.mapApiBaseUrl}/cells/${cellId.toLowerCase()}');
    try {
      final res = await _http
          .get(uri, headers: _buildHeaders())
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Calls `POST /functions/v1/map-api/route-preview` to project a Mapbox walking
  /// route onto H3 Resolution-9 hexes and estimate steps + MET calories.
  Future<RoutePreviewResult?> fetchRoutePreview({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    required UserFitnessProfile profile,
  }) async {
    final uri = Uri.parse('${AppEnv.mapApiBaseUrl}/route-preview');
    try {
      final res = await _http
          .post(
            uri,
            headers: _buildHeaders(),
            body: jsonEncode({
              'origin': [originLat, originLon],
              'destination': [destLat, destLon],
              'weight_kg': profile.weightKg,
              'height_cm': profile.heightCm,
              'mapbox_token': AppEnv.mapboxAccessToken,
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final summary = data['summary'] as Map<String, dynamic>;
        return RoutePreviewResult(
          provider: (data['provider'] ?? 'geodesic_fallback').toString(),
          distanceMeters: (summary['distance_m'] as num).round(),
          durationSeconds: (summary['duration_s'] as num).round(),
          estimatedSteps: (summary['estimated_steps'] as num).round(),
          estimatedCaloriesKcal:
              (summary['estimated_calories_kcal'] as num).toDouble(),
          metUsed: (summary['met_used'] as num).toDouble(),
          totalHexesTraversed:
              (summary['total_hexes_traversed'] as num).round(),
          neutralHexes: (summary['neutral_hexes'] as num).round(),
          rivalHexes: (summary['rival_hexes'] as num).round(),
          ownedHexes: (summary['owned_hexes'] as num).round(),
          routeGeoJson: data['route_geojson'] as Map<String, dynamic>,
          hexesGeoJson: data['hexes_geojson'] as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Submits a completed workout session & per-hex effort list to
  /// `POST /functions/v1/map-api/sessions/sync` for authoritative Referee
  /// verification and transactional PostgreSQL territory updates.
  Future<Map<String, dynamic>> submitWorkoutSession({
    required WorkoutSessionRecord session,
    required List<HexVisitSummary> hexEfforts,
    String? gpxXmlContent,
  }) async {
    String? gpxStoragePath;

    // Upload raw GPX 1.1 file to private `gpx-tracks` bucket if signed in
    try {
      final authUser = Supabase.instance.client.auth.currentUser;
      if (authUser != null && gpxXmlContent != null && gpxXmlContent.isNotEmpty) {
        final objectPath = '${authUser.id}/${session.sessionId}.gpx';
        await Supabase.instance.client.storage.from('gpx-tracks').uploadBinary(
              objectPath,
              utf8.encode(gpxXmlContent),
              fileOptions: const FileOptions(
                contentType: 'application/gpx+xml',
                upsert: true,
              ),
            );
        gpxStoragePath = objectPath;
      }
    } catch (_) {
      // Storage backup is optional; claim engine proceeds with cell aggregates.
    }

    final batchUuid = session.batchUuid ?? session.sessionId;
    final uri = Uri.parse('${AppEnv.mapApiBaseUrl}/sessions/sync');
    final res = await _http
        .post(
          uri,
          headers: _buildHeaders(),
          body: jsonEncode({
            'batch_uuid': batchUuid,
            'idempotency_key': 'sync_$batchUuid',
            'session_id': session.sessionId,
            'client_version': AppEnv.clientVersion,
            'cells': hexEfforts.map((h) => h.toClaimCellPayload()).toList(),
            'workout': {
              'title': session.title,
              'started_at': session.startTimeUtc.toIso8601String(),
              'ended_at': (session.endTimeUtc ?? DateTime.now().toUtc())
                  .toIso8601String(),
              'active_duration_ms': session.activeDurationMs,
              'elapsed_duration_ms': session.elapsedDurationMs,
              'measured_steps': session.totalMeasuredSteps,
              'estimated_steps': session.estimatedSteps,
              'distance_m': session.totalDistanceMeters.round(),
              'calories_kcal': double.parse(
                session.totalCaloriesKcal.toStringAsFixed(2),
              ),
              'cells_visited': hexEfforts.length,
              'gpx_storage_path': gpxStoragePath,
            },
          }),
        )
        .timeout(const Duration(seconds: 15));

    final parsed = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final receipt = parsed['receipt'] as Map<String, dynamic>?;
      final state = (receipt?['state'] ?? 'accepted').toString().toUpperCase();
      final mappedStatus = state == 'ACCEPTED'
          ? 'SYNCED'
          : state == 'PARTIAL'
              ? 'PARTIAL'
              : 'FLAGGED';

      await db.updateSessionSyncReceipt(
        sessionId: session.sessionId,
        syncStatus: mappedStatus,
        receipt: parsed,
      );
      return parsed;
    } else {
      throw StateError(
        (parsed['error']?['message'] ?? 'Sync failed (${res.statusCode})')
            .toString(),
      );
    }
  }
}
