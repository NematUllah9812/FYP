import 'package:flutter/material.dart';

import '../../data/local/app_database.dart';
import '../../data/remote/drive_asset_service.dart';
import '../../data/remote/map_api_client.dart';
import '../../services/gpx_file_service.dart';
import '../../services/workout_tracker_controller.dart';
import '../gpx/gpx_sessions_screen.dart';
import '../map/mapbox_conquest_screen.dart';
import '../profile/profile_settings_screen.dart';
import '../workout/fitness_tracker_screen.dart';

class TerraStepsHomeShell extends StatefulWidget {
  final AppDatabase db;
  final WorkoutTrackerController tracker;
  final GpxFileService gpxService;
  final MapApiClient mapApi;
  final DriveAssetService driveService;

  const TerraStepsHomeShell({
    super.key,
    required this.db,
    required this.tracker,
    required this.gpxService,
    required this.mapApi,
    required this.driveService,
  });

  @override
  State<TerraStepsHomeShell> createState() => _TerraStepsHomeShellState();
}

class _TerraStepsHomeShellState extends State<TerraStepsHomeShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      MapboxConquestScreen(tracker: widget.tracker, mapApi: widget.mapApi),
      FitnessTrackerScreen(tracker: widget.tracker),
      GpxSessionsScreen(
        db: widget.db,
        gpxService: widget.gpxService,
        mapApi: widget.mapApi,
        driveService: widget.driveService,
        tracker: widget.tracker,
      ),
      ProfileSettingsScreen(
        tracker: widget.tracker,
        driveService: widget.driveService,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF090D16),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 28,
                height: 28,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'TerraSteps',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '30% FYP',
                style: TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(child: pages[_selectedIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.hexagon_outlined),
            selectedIcon: Icon(Icons.hexagon),
            label: 'Hex Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_run_outlined),
            selectedIcon: Icon(Icons.directions_run),
            label: 'Tracker',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: 'GPX Logs',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
