import 'gpx_models.dart';

/// Serializes workout trackpoints into strict GPX 1.1 XML (`http://www.topografix.com/GPX/1/1`)
/// with TerraSteps fitness and H3 Resolution-9 extensions.
///
/// Compatible with both:
/// - Milestone spec `xmlns:ext="https://hexfyp.local/gpx/extensions/v1"`
/// - Extended `xmlns:terrasteps="https://terrasteps.app/gpx/extensions/v1"`
class GpxSerializer {
  static const String creator = 'TerraStepsFYP/0.3.0';
  static const String gpxNamespace = 'http://www.topografix.com/GPX/1/1';
  static const String extNamespace = 'https://hexfyp.local/gpx/extensions/v1';
  static const String terrastepsNamespace =
      'https://terrasteps.app/gpx/extensions/v1';

  const GpxSerializer();

  String serialize({
    required GpxSessionMetadata metadata,
    required List<GpxTrackPoint> points,
  }) {
    final buffer = StringBuffer();
    final bounds = computeBounds(points);

    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln(
      '<gpx version="1.1" creator="$creator" '
      'xmlns="$gpxNamespace" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xmlns:ext="$extNamespace" '
      'xmlns:terrasteps="$terrastepsNamespace" '
      'xsi:schemaLocation="$gpxNamespace http://www.topografix.com/GPX/1/1/gpx.xsd">',
    );

    // <metadata>
    buffer.writeln('  <metadata>');
    buffer.writeln('    <name>${_escapeXml(metadata.name)}</name>');
    buffer.writeln(
      '    <desc>${_escapeXml(_buildDescription(metadata, points.length))}</desc>',
    );
    buffer.writeln('    <time>${_utcIso(metadata.createdAtUtc)}</time>');
    if (bounds != null) {
      buffer.writeln(
        '    <bounds '
        'minlat="${bounds.minLat.toStringAsFixed(7)}" '
        'minlon="${bounds.minLon.toStringAsFixed(7)}" '
        'maxlat="${bounds.maxLat.toStringAsFixed(7)}" '
        'maxlon="${bounds.maxLon.toStringAsFixed(7)}"/>',
      );
    }
    buffer.writeln('    <extensions>');
    buffer.writeln(
      '      <terrasteps:session_id>${_escapeXml(metadata.sessionId)}</terrasteps:session_id>',
    );
    buffer.writeln(
      '      <terrasteps:h3_resolution>${metadata.h3Resolution}</terrasteps:h3_resolution>',
    );
    buffer.writeln(
      '      <terrasteps:measured_steps>${metadata.totalMeasuredSteps}</terrasteps:measured_steps>',
    );
    buffer.writeln(
      '      <terrasteps:estimated_steps>${metadata.totalEstimatedSteps}</terrasteps:estimated_steps>',
    );
    buffer.writeln(
      '      <terrasteps:total_distance_m>${metadata.totalDistanceMeters.toStringAsFixed(2)}</terrasteps:total_distance_m>',
    );
    buffer.writeln(
      '      <terrasteps:total_calories_kcal>${metadata.totalCaloriesKcal.toStringAsFixed(2)}</terrasteps:total_calories_kcal>',
    );
    buffer.writeln(
      '      <terrasteps:active_duration_ms>${metadata.activeDurationMs}</terrasteps:active_duration_ms>',
    );
    buffer.writeln(
      '      <terrasteps:unique_h3_cells>${metadata.uniqueH3Cells}</terrasteps:unique_h3_cells>',
    );
    buffer.writeln('    </extensions>');
    buffer.writeln('  </metadata>');

    // <trk>
    buffer.writeln('  <trk>');
    buffer.writeln('    <name>${_escapeXml(metadata.trackName)}</name>');
    buffer.writeln('    <type>${_escapeXml(metadata.activityType)}</type>');
    buffer.writeln('    <trkseg>');

    for (final pt in points) {
      buffer.writeln(
        '      <trkpt lat="${pt.latitude.toStringAsFixed(7)}" '
        'lon="${pt.longitude.toStringAsFixed(7)}">',
      );
      if (pt.elevationMeters != null) {
        buffer.writeln('        <ele>${pt.elevationMeters!.toStringAsFixed(2)}</ele>');
      }
      buffer.writeln('        <time>${_utcIso(pt.timestampUtc)}</time>');
      buffer.writeln('        <extensions>');
      buffer.writeln('          <ext:steps_delta>${pt.stepsDelta}</ext:steps_delta>');
      buffer.writeln(
        '          <ext:cumulative_steps>${pt.cumulativeSteps}</ext:cumulative_steps>',
      );
      buffer.writeln('          <ext:cadence_spm>${pt.cadenceSpm}</ext:cadence_spm>');
      buffer.writeln(
        '          <ext:speed_mps>${pt.speedMps.toStringAsFixed(2)}</ext:speed_mps>',
      );
      buffer.writeln(
        '          <ext:accuracy_m>${pt.accuracyMeters.toStringAsFixed(2)}</ext:accuracy_m>',
      );
      buffer.writeln(
        '          <ext:calories_delta_kcal>${pt.caloriesDeltaKcal.toStringAsFixed(4)}</ext:calories_delta_kcal>',
      );
      buffer.writeln(
        '          <ext:h3_index>${_escapeXml(pt.h3Index)}</ext:h3_index>',
      );
      if (pt.parentRes5 != null && pt.parentRes5!.isNotEmpty) {
        buffer.writeln(
          '          <ext:parent_res5>${_escapeXml(pt.parentRes5!)}</ext:parent_res5>',
        );
      }
      buffer.writeln(
        '          <ext:sampling_state>${_escapeXml(pt.samplingState)}</ext:sampling_state>',
      );
      buffer.writeln('          <ext:monotonic_ms>${pt.monotonicMs}</ext:monotonic_ms>');
      buffer.writeln('        </extensions>');
      buffer.writeln('      </trkpt>');
    }

    buffer.writeln('    </trkseg>');
    buffer.writeln('  </trk>');
    buffer.writeln('</gpx>');
    return buffer.toString();
  }

  static GpxBounds? computeBounds(List<GpxTrackPoint> points) {
    if (points.isEmpty) return null;
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLon = points.first.longitude;
    var maxLon = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return GpxBounds(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
    );
  }

  static String _utcIso(DateTime dt) {
    final u = dt.toUtc();
    return u.toIso8601String();
  }

  static String _buildDescription(GpxSessionMetadata m, int count) {
    return 'TerraSteps Workout (${m.totalMeasuredSteps} measured steps, '
        '${m.totalDistanceMeters.toStringAsFixed(1)}m, '
        '${m.totalCaloriesKcal.toStringAsFixed(1)} kcal, '
        '${m.uniqueH3Cells} H3 res-${m.h3Resolution} cells, '
        '$count trackpoints)';
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
