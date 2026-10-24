/// Publishable runtime configuration for TerraSteps.
///
/// Security policy (`SECURITY.md`):
/// - `sb_publishable_...` is safe to commit (Row Level Security protects all data).
/// - Never commit raw `eyJ...` JWTs or `sb_secret_...` keys.
/// - Pass your Mapbox public token at build/run time:
///     `flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.eyJ...`
class AppEnv {
  static const String supabaseUrl = 'https://iaoqwxcyjkpvpqwoszih.supabase.co';
  static const String supabaseProjectRef = 'iaoqwxcyjkpvpqwoszih';

  /// Publishable API key (RLS-enforced). Override via `--dart-define=SUPABASE_KEY=...` if needed.
  static const String supabaseKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_sNduqq3F-AmpOI1olS2zkA_2zIouLeP',
  );

  /// Edge Function base URL for Deliverable 3 Map API (`map-api`).
  static const String mapApiBaseUrl =
      '$supabaseUrl/functions/v1/map-api';

  /// Mapbox public token (`pk.*`) supplied via `--dart-define=MAPBOX_ACCESS_TOKEN=pk...`.
  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );

  static bool get hasMapboxToken => mapboxAccessToken.trim().startsWith('pk.');

  /// Pilot competition grid constants (Abbottabad Res-5 region `85209a0bfffffff`).
  static const int h3Resolution = 9;
  static const int parentResolution = 5;
  static const double pilotCenterLat = 34.158672;
  static const double pilotCenterLng = 73.259642;
  static const String pilotRegionRes5 = '85209a0bfffffff';
  static const String clientVersion = 'terrasteps-flutter/0.3.0+30';
}
