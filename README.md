# TerraSteps — Gamified H3 Hex-Conquest Fitness App (30% FYP Milestone)

**TerraSteps** transforms real-world walking and running into territorial conquest on an **Uber H3 Resolution-9** hexagonal map (~0.105 km² per hex). Built with **Flutter (Dart + Drift SQLite + Mapbox SDK)** on the client and **TypeScript on Supabase Edge Functions + PostgreSQL/PostGIS** on the backend.

---

## 30% Milestone Deliverables Implemented

| # | Deliverable | Implementation | Key Capabilities |
|---|---|---|---|
| **1** | **GPX 1.1 File Creation & Export** | `packages/terrasteps_gpx/`<br>`apps/mobile/lib/services/gpx_file_service.dart` | Accuracy filter (`<= 25m`), adaptive sampling (`>= 3s` or `>= 5m`), teleport spike rejection (`> 25 m/s`), crash-safe Drift SQLite point logging, valid GPX 1.1 XML serializer & parser with `<ext:steps_delta>`, `<ext:speed_mps>`, `<ext:accuracy_m>`, `<ext:calories_delta_kcal>`, `<ext:h3_index>`, and OS share sheet export. |
| **2** | **Step Count, MET Calories & Offline Persistence** | `packages/terrasteps_fitness/`<br>`apps/mobile/lib/data/local/app_database.dart` | Cumulative hardware step counter (`TYPE_STEP_COUNTER` / `CMPedometer`) baseline-offset engine with pause/resume & device-reboot reset protection, separate measured vs. GPS-estimated step reporting, 5-tier dynamic MET calorie calculator (`MET * 3.5 * weight_kg / 200 * duration_min`), and offline-first **Drift SQLite** schema (`user_profiles`, `workout_sessions`, `track_points`, `local_hex_efforts`). |
| **3** | **Mapbox + H3 Map API & Transactional Conquest** | `apps/mobile/lib/ui/map/mapbox_conquest_screen.dart`<br>`supabase/functions/map-api/index.ts`<br>`supabase/migrations/` | **Mapbox Maps SDK** (`v2.18.0`) hex polygon + polyline rendering, **PostgreSQL + PostGIS** `GiST` spatial bbox queries, lazy 7-day half-life decay, deterministic rule-based SQL Referee (`R1–R8`, zero Python/ML), `FOR UPDATE` row-locked transactional hex takeover (`1.15x` margin), idempotent `sync_receipts`, and route hex preview. |

---

## Repository Structure

```text
├── apps/mobile/                     # Flutter mobile client (Drift SQLite + Mapbox SDK + Pedometer + Geolocator)
│   ├── assets/                      # Lightweight UI thumbnails & drive_assets_manifest.json (<250 KB total)
│   ├── lib/
│   │   ├── config/app_env.dart      # Runtime --dart-define config (Mapbox token, Supabase publishable key)
│   │   ├── data/local/              # Offline-first Drift SQLite database (4 tables + crash recovery)
│   │   ├── data/remote/             # Supabase Map API client & on-demand Google Drive asset fetcher
│   │   ├── services/                # Pure-Dart H3 spatial math, GPX 1.1 file exporter, Workout controller
│   │   └── ui/                      # 4-tab dark tactical UI (Conquest Map, Fitness HUD, GPX Vault, Profile)
│   └── test/app_smoke_test.dart     # End-to-end Flutter smoke test across all 3 deliverables
├── packages/
│   ├── terrasteps_gpx/              # Pure-Dart GPX 1.1 filter, serializer, parser & unit tests
│   └── terrasteps_fitness/          # Pure-Dart step offset, reboot handler, MET kcal & H3 effort engine
├── supabase/
│   ├── config.toml                  # Supabase project config (iaoqwxcyjkpvpqwoszih)
│   ├── migrations/                  # PostGIS GiST index, partitions, RPCs, workout_sessions_log, Storage RLS
│   ├── functions/map-api/index.ts   # Deployed TypeScript Edge Function (/viewport, /hexes, /cells, /route-preview, /sessions/sync)
│   └── tests/                       # Live-verified PostgreSQL + PostGIS + Referee SQL assertions
├── contracts/                       # Draft 2020-12 JSON Schemas (ClaimBatch, MapSnapshot, GPX, GameConfig) + validator
├── tools/defense_workbench/         # Interactive browser workbench for live 30% defense demos (Vite + TS + H3)
├── scripts/
│   ├── fetch_drive_assets.py        # Downloads heavy GPX/GeoJSON/artwork/APK from Google Drive with SHA-256 check
│   └── patch_android_manifest.sh    # Injects GPS, ACTIVITY_RECOGNITION & Foreground Service permissions on Android
├── docs/DEFENSE_30_PERCENT_GUIDE.md # 5-minute 30% defense walkthrough & panel Q&A guide
└── drive_assets_manifest.json       # Registry of heavy files stored in Google Drive ("TerraSteps - FYP")
```

---

## Google Drive Heavy Asset Storage

Heavy files (high-resolution 1024px/1536px brand artwork, 1Hz multi-hour GPX benchmark corpora, 2,437-hex H3 Resolution-9 GeoJSON packs for Abbottabad & South Holland, and the 47.5 MB Android debug APK) are stored in Google Drive so Git remains fast and clean:

- **Google Drive Root Folder (`TerraSteps - FYP`)**: <https://drive.google.com/drive/folders/1bK6ZDWU1f8YV1edsHKMjzwSwm5a5OjEa>
- Pull assets locally on demand into `.drive_cache/` (gitignored):
  ```bash
  python3 scripts/fetch_drive_assets.py --list
  python3 scripts/fetch_drive_assets.py --category gpx_datasets
  python3 scripts/fetch_drive_assets.py --all
  ```

---

## Quick Start

### 1. Run the Flutter Mobile App (`Flutter 3.27.4`)
```bash
# Run pure-Dart domain unit tests
(cd packages/terrasteps_gpx && flutter test)
(cd packages/terrasteps_fitness && flutter test)

# Bootstrap platform runners on a clean checkout & patch Android permissions
cd apps/mobile
flutter create --platforms=android,ios .
../../scripts/patch_android_manifest.sh

# Analyze, test, and build APK with your public Mapbox token
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --dart-define=MAPBOX_ACCESS_TOKEN=pk.YOUR_MAPBOX_PUBLIC_TOKEN
```

### 2. Run the Interactive 30% Defense Workbench
```bash
cd tools/defense_workbench
npm install
npm test
npm run dev
```

### 3. Validate Cross-Layer JSON Contracts
```bash
python3 contracts/validate_contracts.py
```
