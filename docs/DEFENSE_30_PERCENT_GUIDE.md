# TerraSteps — 30% FYP Defense Runbook & Panel Q&A Guide

## 1. Scope Clarity (Addressing Deliverable Focus)
During the 30% milestone defense, present the system clearly around the **three core engineering deliverables** while keeping heavy benchmark corpora in Google Drive:

1. **Deliverable 1 — GPX 1.1 File Creation, Filtering & Export** (`packages/terrasteps_gpx` + `apps/mobile/lib/services/gpx_file_service.dart`)
   - Captures live GPS fixes (`lat`, `lon`, `ele`, `speed`, `accuracy`, UTC `time`, `monotonic_ms`).
   - Rejects noisy fixes with horizontal `accuracy > 25m` and impossible GPS teleport jumps (`> 25 m/s`).
   - Samples adaptively every `>= 3s` OR `>= 5m` displacement to protect mobile battery while preserving loop geometry.
   - Crash-safe: every accepted point is immediately written to local **Drift SQLite** (`track_points` table) before serialization into valid **GPX 1.1 XML** (`http://www.topografix.com/GPX/1/1`) with `<ext:steps_delta>`, `<ext:speed_mps>`, `<ext:accuracy_m>`, `<ext:calories_delta_kcal>`, and `<ext:h3_index>`.

2. **Deliverable 2 — Local Step Counter, Dynamic MET Calories & Offline Persistence** (`packages/terrasteps_fitness` + `apps/mobile/lib/data/local/app_database.dart`)
   - Reads the OS cumulative hardware step counter (`TYPE_STEP_COUNTER` / `CMPedometer`) using baseline-offset subtraction (`session_steps = current_raw - baseline_steps`).
   - Handles **Pause/Resume** (re-anchors segment baseline so steps walked while paused are excluded) and **Device Reboot** (`raw < previous_raw` resets baseline without negative step spikes).
   - Keeps **hardware-measured steps** strictly separate from **GPS-estimated steps** (`distance_m / stride_m`).
   - Computes active calories using the ACSM/Compendium **Dynamic MET** formula:
     $$\text{kcal} = \frac{\text{MET} \times 3.5 \times \text{weight\_kg}}{200} \times \text{duration\_min}$$
     across 5 speed/cadence bands (`1.3`, `2.8`, `4.3`, `8.0`, `11.0` METs).

3. **Deliverable 3 — Mapbox + Uber H3 Resolution-9 Map API (`supabase/functions/map-api`)**
   - Mobile map rendered via **Mapbox Maps SDK for Flutter** (`mapbox_maps_flutter` `v2.18.0`) with GeoJSON polygon fill/extrusion + polyline trail sources.
   - Spatial indexing via **Uber H3 Resolution-9** (~`0.105 km²` hex area, ~`174 m` edge length) rolled up under Resolution-5 regional parents (`85209a0bfffffff` for Abbottabad).
   - Backend powered by **TypeScript on Supabase Edge Functions** + **PostgreSQL & PostGIS (`GiST` spatial index)**:
     - `GET /functions/v1/map-api/viewport` — PostGIS bounding-box query + H3 polygon boundary generation + lazy 7-day half-life influence decay (`score * 0.5^(elapsed / 604800)`).
     - `GET /functions/v1/map-api/cells/:cellId` — Detailed owner/challenger inspection and capture margin (`1.15x` takeover rule).
     - `POST /functions/v1/map-api/route-preview` — Walking route hex-conquest planner.
     - `POST /functions/v1/map-api/sessions/sync` — Authenticated transactional claim batch via PostgreSQL `claim_cells` RPC (`FOR UPDATE` row locking + `sync_receipts` idempotency).

---

## 2. Live 5-Minute Defense Demonstration Flow
1. **Show Live Map & PostGIS Hex State**:
   - Open the **TerraSteps Defense Workbench** (or Flutter mobile app on Android).
   - Pan over the **Abbottabad Pilot Grid (`34.1587°N, 73.2596°E`)** showing Emerald owned hexes, Orange/Violet rival hexes, and Slate safety-masked hexes fetched live from `https://iaoqwxcyjkpvpqwoszih.supabase.co/functions/v1/map-api/viewport`.
   - Click any owned hex to display live decayed influence and capture margin (`GET /map-api/cells/:cellId`).
2. **Start Valid Campus Walk & Inspect METs / Reboot Resilience**:
   - Click **Start Valid Walk**, adjust user weight (`kg`) and height (`cm`), and show live hardware step delta, Haversine distance, MET `4.3` kcal burn, and H3 claim progress (`120 steps / 80m / 90s`).
   - Click **Test Boot Reset** to demonstrate zero negative step spikes when the OS hardware counter resets.
3. **Export & Inspect Raw GPX 1.1 XML**:
   - Switch to **2. GPX 1.1 XML**, inspect the generated `<trkpt>` nodes with `<ext:h3_index>` and `<ext:steps_delta>`, and click **Download `.gpx`**.
4. **Demonstrate Rule-Based Referee Anti-Cheat (No Python / No ML)**:
   - Trigger **Test 48 km/h Car Spoof** (`13.4 m/s`) and show deterministic rejection (`implausible_speed` / `stride > 1.60m`).
5. **Show Google Drive Heavy Asset Offloading**:
   - Open **4. Drive Assets** to show the 12 heavy benchmark GPX files, 2,437-hex GeoJSON packs, high-res brand renders, and 47.5 MB debug APK hosted cleanly in Google Drive (`TerraSteps - FYP`).
