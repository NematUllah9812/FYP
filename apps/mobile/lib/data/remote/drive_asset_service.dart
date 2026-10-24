import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DriveAssetEntry {
  final String key;
  final String category;
  final String name;
  final String fileId;
  final String mimeType;
  final int sizeBytes;
  final String downloadUrl;
  final String viewUrl;
  final Map<String, dynamic>? metrics;

  const DriveAssetEntry({
    required this.key,
    required this.category,
    required this.name,
    required this.fileId,
    required this.mimeType,
    required this.sizeBytes,
    required this.downloadUrl,
    required this.viewUrl,
    this.metrics,
  });

  String get formattedSize {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
  }

  factory DriveAssetEntry.fromJson(Map<String, dynamic> j) {
    return DriveAssetEntry(
      key: j['key'] as String,
      category: j['category'] as String,
      name: j['name'] as String,
      fileId: j['file_id'] as String,
      mimeType: j['mime_type'] as String,
      sizeBytes: (j['size_bytes'] as num).round(),
      downloadUrl: j['download_url'] as String,
      viewUrl: j['view_url'] as String,
      metrics: j['metrics'] as Map<String, dynamic>?,
    );
  }
}

/// Downloads heavy files hosted in the project's Google Drive (`TerraSteps - FYP`)
/// — such as 1Hz GPX benchmark walks, anti-cheat test tracks, and 2,437-hex
/// offline H3 GeoJSON packs — into the app's local documents cache on demand.
class DriveAssetService {
  final http.Client _http;
  List<DriveAssetEntry>? _cachedManifest;
  String? _driveRootUrl;

  DriveAssetService({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  String? get driveRootUrl => _driveRootUrl;

  Future<List<DriveAssetEntry>> loadManifest() async {
    if (_cachedManifest != null) return _cachedManifest!;
    final raw = await rootBundle.loadString('assets/drive_assets_manifest.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _driveRootUrl =
        (decoded['drive_root_folder'] as Map<String, dynamic>?)?['url'] as String?;
    final list = (decoded['assets'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(DriveAssetEntry.fromJson)
        .toList();
    _cachedManifest = list;
    return list;
  }

  Future<File> downloadAssetToCache(DriveAssetEntry entry) async {
    final docs = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(docs.path, 'drive_assets', entry.category));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final file = File(p.join(cacheDir.path, entry.name));
    if (await file.exists() && await file.length() > 128) {
      return file;
    }

    final response = await _http
        .get(Uri.parse(entry.downloadUrl))
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download Drive asset ${entry.name} (HTTP ${response.statusCode})',
      );
    }

    await file.writeAsBytes(response.bodyBytes, flush: true);
    return file;
  }
}
