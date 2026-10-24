import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';

import '../../config/app_env.dart';
import '../../data/remote/map_api_client.dart';
import '../../services/workout_tracker_controller.dart';

/// Deliverable 3: Interactive Mapbox SDK H3 Hex-Conquest Map Screen.
///
/// Renders:
/// - Base Mapbox Dark vector tiles (`MapboxStyles.DARK`)
/// - H3 Resolution-9 GeoJSON hexagonal polygon overlays from Supabase `map-api`
///   (Neutral, Owned by Me, Owned by Rivals, Safety Masked, Active Conquering)
/// - Live recorded GPS polyline trail (`live_trail_source`)
/// - Walking route preview polyline (`route_preview_source`)
class MapboxConquestScreen extends StatefulWidget {
  final WorkoutTrackerController tracker;
  final MapApiClient mapApi;

  const MapboxConquestScreen({
    super.key,
    required this.tracker,
    required this.mapApi,
  });

  @override
  State<MapboxConquestScreen> createState() => _MapboxConquestScreenState();
}

class _MapboxConquestScreenState extends State<MapboxConquestScreen> {
  static const String _hexSourceId = 'terrasteps_h3_source';
  static const String _hexFillLayerId = 'terrasteps_h3_fill';
  static const String _hexLineLayerId = 'terrasteps_h3_outline';
  static const String _trailSourceId = 'terrasteps_live_trail_source';
  static const String _trailLayerId = 'terrasteps_live_trail_layer';
  static const String _routeSourceId = 'terrasteps_route_preview_source';
  static const String _routeLayerId = 'terrasteps_route_preview_layer';

  MapboxMap? _mapboxMap;
  bool _styleReady = false;
  bool _loadingHexes = false;
  bool _offlineCacheActive = false;
  int _loadedFeatureCount = 0;
  RoutePreviewResult? _routePreview;
  List<Map<String, dynamic>> _currentFeatures = const [];

  @override
  void initState() {
    super.initState();
    if (AppEnv.hasMapboxToken) {
      MapboxOptions.setAccessToken(AppEnv.mapboxAccessToken);
    }
    widget.tracker.addListener(_onTrackerUpdated);
    // Pre-fetch pilot viewport hexes immediately even before style finishes loading
    _refreshPilotViewportFallback();
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onTrackerUpdated);
    super.dispose();
  }

  void _onTrackerUpdated() {
    if (!mounted) return;
    _pushLiveTrailToMapbox();
    setState(() {});
  }

  Future<void> _refreshPilotViewportFallback() async {
    setState(() => _loadingHexes = true);
    final lat = widget.tracker.currentLat;
    final lon = widget.tracker.currentLon;
    final res = await widget.mapApi.fetchViewportHexes(
      minLat: lat - 0.014,
      minLon: lon - 0.016,
      maxLat: lat + 0.014,
      maxLon: lon + 0.016,
      includeNeutral: true,
    );
    if (!mounted) return;
    setState(() {
      _loadingHexes = false;
      _offlineCacheActive = res.fromOfflineCache;
      _currentFeatures = res.features;
      _loadedFeatureCount = _currentFeatures.length;
    });
    await _pushHexesToMapbox(res.geojson);
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    await mapboxMap.location.updateSettings(
      LocationComponentSettings(
        enabled: true,
        pulsingEnabled: true,
      ),
    );
  }

  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    final map = _mapboxMap;
    if (map == null) return;

    final emptyFc = jsonEncode({'type': 'FeatureCollection', 'features': []});

    await map.style.addSource(GeoJsonSource(id: _hexSourceId, data: emptyFc));
    await map.style.addLayer(
      FillLayer(
        id: _hexFillLayerId,
        sourceId: _hexSourceId,
        fillColorExpression: const ['get', 'fill_color'],
        fillOpacityExpression: const ['get', 'fill_opacity'],
      ),
    );
    await map.style.addLayer(
      LineLayer(
        id: _hexLineLayerId,
        sourceId: _hexSourceId,
        lineColorExpression: const ['get', 'stroke_color'],
        lineWidth: 1.5,
      ),
    );

    await map.style.addSource(GeoJsonSource(id: _routeSourceId, data: emptyFc));
    await map.style.addLayer(
      LineLayer(
        id: _routeLayerId,
        sourceId: _routeSourceId,
        lineColor: 0xFFFACC15,
        lineWidth: 3.5,
        lineDasharray: const [2.0, 1.5],
      ),
    );

    await map.style.addSource(GeoJsonSource(id: _trailSourceId, data: emptyFc));
    await map.style.addLayer(
      LineLayer(
        id: _trailLayerId,
        sourceId: _trailSourceId,
        lineJoin: LineJoin.ROUND,
        lineCap: LineCap.ROUND,
        lineColor: 0xFF38BDF8,
        lineWidth: 4.8,
      ),
    );

    _styleReady = true;
    await _refreshViewportFromCamera();
    await _pushLiveTrailToMapbox();
  }

  Future<void> _refreshViewportFromCamera() async {
    final map = _mapboxMap;
    if (map == null || !_styleReady) return;

    try {
      final cameraState = await map.getCameraState();
      final bounds = await map.coordinateBoundsForCamera(
        CameraOptions(
          center: cameraState.center,
          zoom: cameraState.zoom,
          bearing: cameraState.bearing,
          pitch: cameraState.pitch,
        ),
      );

      final sw = bounds.southwest.coordinates;
      final ne = bounds.northeast.coordinates;

      setState(() => _loadingHexes = true);
      final resp = await widget.mapApi.fetchViewportHexes(
        minLat: sw.lat.toDouble(),
        minLon: sw.lng.toDouble(),
        maxLat: ne.lat.toDouble(),
        maxLon: ne.lng.toDouble(),
        includeNeutral: cameraState.zoom >= 13.2,
      );
      if (!mounted) return;

      setState(() {
        _loadingHexes = false;
        _offlineCacheActive = resp.fromOfflineCache;
        _currentFeatures = resp.features;
        _loadedFeatureCount = _currentFeatures.length;
      });
      await _pushHexesToMapbox(resp.geojson);
    } catch (_) {
      if (mounted) setState(() => _loadingHexes = false);
    }
  }

  Future<void> _pushHexesToMapbox(Map<String, dynamic> geojson) async {
    final map = _mapboxMap;
    if (map == null || !_styleReady) return;

    // Highlight currently active conquering hex in pulsing cyan
    final activeCell = widget.tracker.currentH3Cell;
    if (widget.tracker.lifecycle == WorkoutLifecycleState.recording &&
        activeCell.isNotEmpty) {
      final features =
          (geojson['features'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
          [];
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>?;
        if (props != null && props['h3_id'] == activeCell && props['masked'] != true) {
          props['fill_color'] = '#38BDF8';
          props['stroke_color'] = '#7DD3FC';
          props['fill_opacity'] = 0.55;
        }
      }
    }

    await map.style.setStyleSourceProperty(
      _hexSourceId,
      'data',
      jsonEncode(geojson),
    );
  }

  Future<void> _pushLiveTrailToMapbox() async {
    final map = _mapboxMap;
    if (map == null || !_styleReady) return;

    final coords = widget.tracker.liveTrailLngLat;
    if (coords.length < 2) return;

    final lineGeoJson = {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {
            'type': 'LineString',
            'coordinates': coords,
          },
        },
      ],
    };

    await map.style.setStyleSourceProperty(
      _trailSourceId,
      'data',
      jsonEncode(lineGeoJson),
    );
  }

  Future<void> _planSampleConquestRoute() async {
    final originLat = widget.tracker.currentLat;
    final originLon = widget.tracker.currentLon;
    final preview = await widget.mapApi.fetchRoutePreview(
      originLat: originLat,
      originLon: originLon,
      destLat: originLat + 0.0068,
      destLon: originLon + 0.0054,
      profile: widget.tracker.profile,
    );
    if (!mounted || preview == null) return;
    setState(() => _routePreview = preview);

    if (_mapboxMap != null && _styleReady) {
      await _mapboxMap!.style.setStyleSourceProperty(
        _routeSourceId,
        'data',
        jsonEncode({
          'type': 'FeatureCollection',
          'features': [preview.routeGeoJson],
        }),
      );
    }
  }

  Future<void> _inspectHexByCellId(String cellId) async {
    final detail = await widget.mapApi.fetchCellDetail(cellId);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final d = (detail?['detail'] as Map<String, dynamic>?) ?? const {};
        final owner = d['owner'] as Map<String, dynamic>?;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.hexagon, color: Color(0xFF10B981)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'H3 Cell $cellId',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                owner != null
                    ? 'Owner: ${owner['username']} • ${owner['name'] ?? 'Unnamed Territory'}'
                    : 'Status: Neutral / Unclaimed Territory',
                style: const TextStyle(color: Color(0xFFCBD5E1)),
              ),
              const SizedBox(height: 6),
              Text(
                owner != null
                    ? 'Current Decayed Influence: ${owner['influence']} pts • Effort to Capture: ${d['effort_to_capture'] ?? 0} pts'
                    : 'Claim Floors: 120 steps • 80m distance • 90s active dwell • 5 GPS fixes',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
              const SizedBox(height: 14),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeHex = widget.tracker.activeHexSummary;

    return Stack(
      children: [
        if (AppEnv.hasMapboxToken)
          MapWidget(
            key: const ValueKey('terrasteps_mapbox_widget'),
            styleUri: MapboxStyles.DARK,
            cameraOptions: CameraOptions(
              center: Point(
                coordinates: Position(
                  widget.tracker.currentLon,
                  widget.tracker.currentLat,
                ),
              ),
              zoom: 14.8,
              pitch: 28.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: _onStyleLoaded,
            onTapListener: (MapContentGestureContext ctx) {
              final tappedCell = widget.tracker.h3Service.latLonToCell(
                ctx.point.coordinates.lat.toDouble(),
                ctx.point.coordinates.lng.toDouble(),
              );
              _inspectHexByCellId(tappedCell);
            },
          )
        else
          _buildTokenFallbackHexList(),

        // Top Map Status Pill & Controls
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xDD0F172A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _offlineCacheActive ? Icons.cloud_off : Icons.hexagon_outlined,
                      size: 16,
                      color: _offlineCacheActive
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF10B981),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _offlineCacheActive
                          ? 'Offline Hex Cache ($_loadedFeatureCount)'
                          : 'H3 Res-9 • $_loadedFeatureCount Hexes',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_loadingHexes) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
              const Spacer(),
              IconButton.filledTonal(
                tooltip: 'Plan Walking Route',
                onPressed: _planSampleConquestRoute,
                icon: const Icon(Icons.alt_route),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Refresh Map API Viewport',
                onPressed: AppEnv.hasMapboxToken
                    ? _refreshViewportFromCamera
                    : _refreshPilotViewportFallback,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),

        if (_routePreview != null)
          Positioned(
            top: 64,
            left: 12,
            right: 12,
            child: Card(
              color: const Color(0xEE0F172A),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.directions_walk, color: Color(0xFFFACC15)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Route Plan: ${_routePreview!.distanceMeters}m • '
                        '~${_routePreview!.estimatedSteps} steps • '
                        '${_routePreview!.estimatedCaloriesKcal.toStringAsFixed(0)} kcal • '
                        '${_routePreview!.totalHexesTraversed} hexes '
                        '(${_routePreview!.neutralHexes} neutral, ${_routePreview!.rivalHexes} rival)',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.white70),
                      onPressed: () => setState(() => _routePreview = null),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Bottom Active Conquest Effort Card
        Positioned(
          left: 12,
          right: 12,
          bottom: 14,
          child: _buildActiveHexHud(activeHex),
        ),
      ],
    );
  }

  Widget _buildTokenFallbackHexList() {
    return Container(
      color: const Color(0xFF090D16),
      padding: const EdgeInsets.fromLTRB(16, 68, 16, 130),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF38BDF8)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mapbox SDK Ready — Pass MAPBOX_ACCESS_TOKEN at Run/Build',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Run with --dart-define=MAPBOX_ACCESS_TOKEN=pk.eyJ... to render interactive Mapbox Dark vector tiles. Live Supabase Map API hex data is displayed below:',
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: _currentFeatures.length,
              itemBuilder: (context, index) {
                final f = _currentFeatures[index];
                final props = (f['properties'] as Map<String, dynamic>?) ?? const {};
                final h3Id = (props['h3_id'] ?? '').toString();
                final state = (props['state'] ?? 'neutral').toString();
                final nick = props['nickname']?.toString();
                final kName = props['kingdom_name']?.toString();
                final inf = props['influence'] ?? 0;
                return Card(
                  color: const Color(0xFF0F172A),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.hexagon,
                      color: state == 'mine'
                          ? const Color(0xFF10B981)
                          : state == 'rival'
                              ? const Color(0xFFF97316)
                              : state == 'masked'
                                  ? const Color(0xFF64748B)
                                  : const Color(0xFF334155),
                    ),
                    title: Text(
                      kName ?? h3Id,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    subtitle: Text(
                      nick != null
                          ? 'Owner: $nick • Influence: $inf pts'
                          : state == 'masked'
                              ? 'Safety Masked (${props['mask_reason']})'
                              : 'Neutral H3 Res-9 Cell ($h3Id)',
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                    onTap: () => _inspectHexByCellId(h3Id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveHexHud(HexVisitSummary? hex) {
    final snap = widget.tracker.liveSnapshot;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xEE0F172A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location, size: 16, color: Color(0xFF38BDF8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.tracker.currentH3Cell.isNotEmpty
                      ? 'Active Cell: ${widget.tracker.currentH3Cell}'
                      : 'Acquiring H3 Cell...',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              Text(
                hex != null
                    ? 'Effort: ${hex.serverAuthoritativeEffort.toStringAsFixed(1)} pts'
                    : '${snap.measuredSteps} steps • ${snap.caloriesBurnedKcal.toStringAsFixed(1)} kcal',
                style: const TextStyle(
                  color: Color(0xFF10B981),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (hex != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: hex.claimReadinessProgress,
              backgroundColor: const Color(0xFF1E293B),
              color: hex.isClaimEligible
                  ? const Color(0xFF10B981)
                  : const Color(0xFF38BDF8),
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 6),
            Text(
              'Steps ${hex.stepsInHex}/120 • Dist ${hex.distanceInHexMeters.toStringAsFixed(0)}/80m • '
              'Active Dwell ${hex.activeDwellSeconds}/90s • '
              '${hex.isClaimEligible ? "READY TO CLAIM" : "Conquering..."}',
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
