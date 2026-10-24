import 'gpx_models.dart';
import 'gpx_serializer.dart';

/// Lightweight, dependency-free GPX 1.1 parser for importing benchmark `.gpx`
/// tracks from local storage or Google Drive and replaying them through the
/// TerraSteps fitness & Referee pipeline.
class GpxParser {
  const GpxParser();

  GpxDocument parse(String xmlContent) {
    if (!xmlContent.contains('<gpx')) {
      throw const FormatException('Invalid GPX 1.1 document: missing <gpx> root element.');
    }

    final metadataBlock = _extractFirstTagBlock(xmlContent, 'metadata') ?? '';
    final sessionName = _extractTagText(metadataBlock, 'name') ?? 'Imported_GPX_Session';
    final timeStr = _extractTagText(metadataBlock, 'time');
    final createdAt = timeStr != null
        ? DateTime.parse(timeStr).toUtc()
        : DateTime.now().toUtc();

    final sessionId =
        _extractNamespacedTag(metadataBlock, 'session_id') ??
        'imported_${createdAt.millisecondsSinceEpoch}';
    final h3Res = int.tryParse(
          _extractNamespacedTag(metadataBlock, 'h3_resolution') ?? '9',
        ) ??
        9;

    final trkBlock = _extractFirstTagBlock(xmlContent, 'trk') ?? xmlContent;
    final trackName = _extractTagText(trkBlock, 'name') ?? sessionName;
    final activityType = _extractTagText(trkBlock, 'type') ?? 'walking';

    final trkptRegex = RegExp(
      r'<trkpt\s+([^>]+)>([\s\S]*?)<\/trkpt>',
      multiLine: true,
    );
    final attrLatRegex = RegExp(r'lat="([^"]+)"');
    final attrLonRegex = RegExp(r'lon="([^"]+)"');

    final points = <GpxTrackPoint>[];
    final visitedCells = <String>{};
    var seq = 0;
    var runningSteps = 0;
    var runningKcal = 0.0;
    DateTime? firstTimestamp;

    for (final match in trkptRegex.allMatches(trkBlock)) {
      final attrs = match.group(1) ?? '';
      final inner = match.group(2) ?? '';

      final lat = double.tryParse(attrLatRegex.firstMatch(attrs)?.group(1) ?? '');
      final lon = double.tryParse(attrLonRegex.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lon == null) continue;

      final ele = double.tryParse(_extractTagText(inner, 'ele') ?? '');
      final ptTimeStr = _extractTagText(inner, 'time');
      final ptTime = ptTimeStr != null
          ? DateTime.parse(ptTimeStr).toUtc()
          : createdAt.add(Duration(seconds: seq));
      firstTimestamp ??= ptTime;

      final stepsDelta =
          int.tryParse(_extractNamespacedTag(inner, 'steps_delta') ?? '0') ?? 0;
      runningSteps += stepsDelta;
      final cumSteps = int.tryParse(
            _extractNamespacedTag(inner, 'cumulative_steps') ?? '',
          ) ??
          runningSteps;
      final cadence =
          int.tryParse(_extractNamespacedTag(inner, 'cadence_spm') ?? '0') ?? 0;
      final speedMps =
          double.tryParse(_extractNamespacedTag(inner, 'speed_mps') ?? '0') ?? 0.0;
      final accuracyM =
          double.tryParse(_extractNamespacedTag(inner, 'accuracy_m') ?? '5.0') ??
          5.0;
      final kcalDelta = double.tryParse(
            _extractNamespacedTag(inner, 'calories_delta_kcal') ?? '0',
          ) ??
          0.0;
      runningKcal += kcalDelta;

      final h3Idx =
          (_extractNamespacedTag(inner, 'h3_index') ?? '000000000000000')
              .toLowerCase();
      if (h3Idx != '000000000000000') {
        visitedCells.add(h3Idx);
      }
      final parent5 = _extractNamespacedTag(inner, 'parent_res5');
      final samplingState =
          _extractNamespacedTag(inner, 'sampling_state') ?? 'moving';
      final monoMs = int.tryParse(
            _extractNamespacedTag(inner, 'monotonic_ms') ?? '',
          ) ??
          ptTime.difference(firstTimestamp).inMilliseconds;

      points.add(
        GpxTrackPoint(
          sequence: seq++,
          latitude: lat,
          longitude: lon,
          elevationMeters: ele,
          timestampUtc: ptTime,
          monotonicMs: monoMs < 0 ? 0 : monoMs,
          stepsDelta: stepsDelta,
          cumulativeSteps: cumSteps,
          cadenceSpm: cadence,
          speedMps: speedMps,
          accuracyMeters: accuracyM <= 0 ? 5.0 : accuracyM,
          caloriesDeltaKcal: kcalDelta,
          h3Index: h3Idx,
          parentRes5: parent5,
          samplingState: samplingState,
        ),
      );
    }

    final totalSteps = int.tryParse(
          _extractNamespacedTag(metadataBlock, 'measured_steps') ??
              _extractNamespacedTag(metadataBlock, 'total_steps') ??
              '',
        ) ??
        runningSteps;

    final totalDist = double.tryParse(
          _extractNamespacedTag(metadataBlock, 'total_distance_m') ?? '',
        ) ??
        0.0;

    final totalKcal = double.tryParse(
          _extractNamespacedTag(metadataBlock, 'total_calories_kcal') ?? '',
        ) ??
        runningKcal;

    final activeMs = int.tryParse(
          _extractNamespacedTag(metadataBlock, 'active_duration_ms') ?? '',
        ) ??
        (points.isNotEmpty ? points.last.monotonicMs : 0);

    final metadata = GpxSessionMetadata(
      sessionId: sessionId,
      name: _unescapeXml(sessionName),
      trackName: _unescapeXml(trackName),
      activityType: _unescapeXml(activityType),
      createdAtUtc: createdAt,
      h3Resolution: h3Res,
      totalMeasuredSteps: totalSteps,
      totalDistanceMeters: totalDist,
      totalCaloriesKcal: totalKcal,
      activeDurationMs: activeMs,
      uniqueH3Cells: visitedCells.length,
    );

    return GpxDocument(
      metadata: metadata,
      points: points,
      bounds: GpxSerializer.computeBounds(points),
    );
  }

  static String? _extractFirstTagBlock(String source, String tag) {
    final re = RegExp('<$tag(?:\\s[^>]*)?>([\\s\\S]*?)<\\/$tag>');
    return re.firstMatch(source)?.group(1);
  }

  static String? _extractTagText(String source, String tag) {
    final re = RegExp('<$tag>([^<]*)<\\/$tag>');
    return re.firstMatch(source)?.group(1)?.trim();
  }

  static String? _extractNamespacedTag(String source, String localName) {
    final re = RegExp('<(?:[a-zA-Z0-9_]+:)?$localName>([^<]*)<\\/(?:[a-zA-Z0-9_]+:)?$localName>');
    return re.firstMatch(source)?.group(1)?.trim();
  }

  static String _unescapeXml(String input) {
    return input
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&gt;', '>')
        .replaceAll('&lt;', '<')
        .replaceAll('&amp;', '&');
  }
}
