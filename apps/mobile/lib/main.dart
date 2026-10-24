import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_env.dart';
import 'data/local/app_database.dart';
import 'data/remote/drive_asset_service.dart';
import 'data/remote/map_api_client.dart';
import 'services/gpx_file_service.dart';
import 'services/h3_spatial_service.dart';
import 'services/workout_tracker_controller.dart';
import 'ui/shell/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(
      url: AppEnv.supabaseUrl,
      anonKey: AppEnv.supabaseKey,
    );
  } catch (_) {
    // Offline-first startup: app continues seamlessly even without network.
  }

  final db = AppDatabase();
  final h3Service = H3SpatialService();
  final gpxService = GpxFileService(db: db);
  final mapApi = MapApiClient(db: db);
  final driveService = DriveAssetService();
  final tracker = WorkoutTrackerController(
    db: db,
    h3Service: h3Service,
    gpxFileService: gpxService,
  );
  await tracker.initialize();

  runApp(
    TerraStepsApp(
      db: db,
      tracker: tracker,
      gpxService: gpxService,
      mapApi: mapApi,
      driveService: driveService,
    ),
  );
}

class TerraStepsApp extends StatelessWidget {
  final AppDatabase db;
  final WorkoutTrackerController tracker;
  final GpxFileService gpxService;
  final MapApiClient mapApi;
  final DriveAssetService driveService;

  const TerraStepsApp({
    super.key,
    required this.db,
    required this.tracker,
    required this.gpxService,
    required this.mapApi,
    required this.driveService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TerraSteps',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          brightness: Brightness.dark,
        ),
      ),
      home: TerraStepsHomeShell(
        db: db,
        tracker: tracker,
        gpxService: gpxService,
        mapApi: mapApi,
        driveService: driveService,
      ),
    );
  }
}
