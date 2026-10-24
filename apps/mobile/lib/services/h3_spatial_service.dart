import 'package:h3_flutter/h3_flutter.dart';
import '../config/app_env.dart';

/// Uber H3 Spatial Indexing Service locked at pilot Resolution 9 (Plan §11).
///
/// Lazy-loads `h3_flutter`'s native C library so unit tests and startup never
/// block before the first coordinate arrives, and formats every H3 index as
/// lowercase TEXT (`AGENTS.md` §15).
class H3SpatialService {
  H3? _h3;
  final int resolution;
  final int parentResolution;

  H3SpatialService({
    this.resolution = AppEnv.h3Resolution,
    this.parentResolution = AppEnv.parentResolution,
  });

  H3 get _engine => _h3 ??= const H3Factory().load();

  /// Maps `(lat, lon)` to a lowercase 15-char H3 Resolution-9 hex index string.
  String latLonToCell(double lat, double lon) {
    final cell = _engine.geoToCell(GeoCoord(lat: lat, lon: lon), resolution);
    return _formatHex(cell);
  }

  /// Computes the Resolution-5 regional parent cell (`parent_res5`) for Realtime & snapshots.
  String cellToParentRes5(String cellId) {
    final parent = _engine.cellToParent(_parseHex(cellId), parentResolution);
    return _formatHex(parent);
  }

  /// Returns closed `[lng, lat]` GeoJSON polygon ring coordinates for Mapbox rendering.
  List<List<double>> cellToGeoJsonRing(String cellId) {
    final boundary = _engine.cellToBoundary(_parseHex(cellId));
    final ring = boundary.map((g) => <double>[g.lon, g.lat]).toList();
    if (ring.isNotEmpty) {
      ring.add(<double>[ring.first[0], ring.first[1]]);
    }
    return ring;
  }

  /// Returns k-ring neighbor H3 cell IDs around [cellId].
  List<String> gridDisk(String cellId, int k) {
    return _engine.gridDisk(_parseHex(cellId), k).map(_formatHex).toList();
  }

  static String _formatHex(BigInt cell) =>
      cell.toRadixString(16).toLowerCase().padLeft(15, '0');

  static BigInt _parseHex(String cellId) =>
      BigInt.parse(cellId.trim(), radix: 16);
}
