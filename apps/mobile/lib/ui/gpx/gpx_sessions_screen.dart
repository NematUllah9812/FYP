import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/app_database.dart';
import '../../data/remote/drive_asset_service.dart';
import '../../data/remote/map_api_client.dart';
import '../../services/gpx_file_service.dart';
import '../../services/workout_tracker_controller.dart';

/// Deliverable 1: Offline Drift Workout Sessions, Raw GPX 1.1 XML Inspector,
/// Share/Export & Google Drive Benchmark Importer.
class GpxSessionsScreen extends StatefulWidget {
  final AppDatabase db;
  final GpxFileService gpxService;
  final MapApiClient mapApi;
  final DriveAssetService driveService;
  final WorkoutTrackerController tracker;

  const GpxSessionsScreen({
    super.key,
    required this.db,
    required this.gpxService,
    required this.mapApi,
    required this.driveService,
    required this.tracker,
  });

  @override
  State<GpxSessionsScreen> createState() => _GpxSessionsScreenState();
}

class _GpxSessionsScreenState extends State<GpxSessionsScreen> {
  bool _busy = false;

  Future<void> _showRawGpxDialog(WorkoutSessionRecord session) async {
    final xml = await widget.gpxService.readSessionGpxXml(session.sessionId);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(
          'GPX 1.1 XML • ${session.title}',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(
              xml.length > 12000
                  ? '${xml.substring(0, 12000)}\n\n... [truncated preview — export full .gpx file]'
                  : xml,
              style: const TextStyle(
                fontFamily: 'monospace',
                color: Color(0xFF38BDF8),
                fontSize: 11.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              widget.gpxService.shareSessionGpx(session.sessionId);
            },
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('Export .gpx'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncSessionToSupabase(WorkoutSessionRecord session) async {
    setState(() => _busy = true);
    try {
      final hexes = await widget.db.getHexEffortsForSession(session.sessionId);
      final xml = await widget.gpxService.readSessionGpxXml(session.sessionId);
      final res = await widget.mapApi.submitWorkoutSession(
        session: session,
        hexEfforts: hexes,
        gpxXmlContent: xml,
      );
      if (!mounted) return;
      final state = res['receipt']?['state'] ?? 'accepted';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Referee Sync Outcome: ${state.toString().toUpperCase()}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync notice: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDriveBenchmarkSheet() async {
    final entries = await widget.driveService.loadManifest();
    final gpxEntries = entries
        .where((e) => e.category == 'gpx_benchmark_datasets' && e.name.endsWith('.gpx'))
        .toList();
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      builder: (ctx) => ListView(
        padding: const EdgeInsets.all(16),
        shrinkWrap: true,
        children: [
          const Text(
            'Import Heavy 1Hz GPX Benchmark from Google Drive',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Downloads directly from your TerraSteps Google Drive folder into Drift SQLite.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 12),
          ...gpxEntries.map(
            (entry) => ListTile(
              leading: const Icon(Icons.cloud_download, color: Color(0xFF38BDF8)),
              title: Text(
                entry.name,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: Text(
                '${entry.formattedSize} • Verdict: ${entry.metrics?['expected_verdict'] ?? 'N/A'}',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                setState(() => _busy = true);
                try {
                  final file = await widget.driveService.downloadAssetToCache(entry);
                  final xml = await file.readAsString();
                  await widget.gpxService.importGpxXmlToDatabase(
                    xmlContent: xml,
                    batchUuid: const Uuid().v4(),
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Imported ${entry.name} from Google Drive!')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Drive download failed: $e')),
                  );
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.tracker.recoverableSession != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E3A8A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.restore, color: Colors.white),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Interrupted session detected in SQLite — recover to GPX 1.1?',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => widget.tracker.recoverInterruptedSession(),
                  child: const Text('Recover GPX'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Offline Sessions & GPX 1.1 Exports',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openDriveBenchmarkSheet,
                icon: const Icon(Icons.add_to_drive, size: 16),
                label: const Text('Drive GPX'),
              ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: StreamBuilder<List<WorkoutSessionRecord>>(
            stream: widget.db.watchWorkoutSessions(),
            builder: (context, snapshot) {
              final sessions = snapshot.data ?? const [];
              if (sessions.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No workouts recorded yet. Start a walk or import a 1Hz benchmark GPX from Google Drive.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: sessions.length,
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  return Card(
                    color: const Color(0xFF0F172A),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              _statusChip(s.syncStatus),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${s.totalMeasuredSteps} steps • '
                            '${(s.totalDistanceMeters / 1000).toStringAsFixed(2)} km • '
                            '${s.totalCaloriesKcal.toStringAsFixed(1)} kcal • '
                            '${s.cellsVisited} H3 cells',
                            style: const TextStyle(
                              color: Color(0xFFCBD5E1),
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _showRawGpxDialog(s),
                                icon: const Icon(Icons.code, size: 15),
                                label: const Text('Inspect GPX XML'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    widget.gpxService.shareSessionGpx(s.sessionId),
                                icon: const Icon(Icons.ios_share, size: 15),
                                label: const Text('Export .gpx'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _syncSessionToSupabase(s),
                                icon: const Icon(Icons.cloud_upload, size: 15),
                                label: const Text('Sync Referee'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String status) {
    final color = status == 'SYNCED'
        ? const Color(0xFF10B981)
        : status == 'FLAGGED'
            ? const Color(0xFFEF4444)
            : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.bold),
      ),
    );
  }
}
