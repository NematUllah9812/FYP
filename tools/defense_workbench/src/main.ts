import "maplibre-gl/dist/maplibre-gl.css";
import "./style.css";
import maplibregl from "maplibre-gl";
import * as h3 from "h3-js";
import driveManifest from "../../../drive_assets_manifest.json";

const SUPABASE_URL = "https://iaoqwxcyjkpvpqwoszih.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_sNduqq3F-AmpOI1olS2zkA_2zIouLeP";
const MAP_API_BASE = `${SUPABASE_URL}/functions/v1/map-api`;
const PILOT_WALKER_ID = "cda70d49-2d70-4776-bd5e-2d346f8a4170";
const PILOT_CENTER: [number, number] = [73.259642, 34.158672]; // [lng, lat] Abbottabad

interface TrackPoint {
  seq: number;
  lat: number;
  lon: number;
  ele: number;
  isoUtc: string;
  monotonicMs: number;
  stepsDelta: number;
  cumSteps: number;
  cadenceSpm: number;
  speedMps: number;
  accuracyM: number;
  kcalDelta: number;
  h3Index: string;
  parentRes5: string;
}

interface HexBucket {
  h3Index: string;
  parentRes5: string;
  steps: number;
  distanceM: number;
  activeDwellS: number;
  fixCount: number;
  maxSpeedMps: number;
}

// State
let activeTab: "fitness" | "gpx" | "mapapi" | "drive" = "fitness";
let mapboxToken = localStorage.getItem("terrasteps_mapbox_token") ?? "";
let weightKg = 72;
let heightCm = 174;
let dailyGoal = 8000;

let simTimer: number | null = null;
let isPaused = false;
let simMode: "walk" | "run" | "vehicle" = "walk";
let rawBootSensorSteps = 48210; // Simulates Android TYPE_STEP_COUNTER since device boot
let baselineSteps: number | null = null;
let lastRawSteps: number | null = null;
let measuredSteps = 0;
let distanceMeters = 0;
let activeDurationMs = 0;
let elapsedDurationMs = 0;
let caloriesKcal = 0;
let currentSpeedMps = 0;
let currentMet = 1.3;
let currentCadenceSpm = 0;
let bootResetCount = 0;

let cursorLat = PILOT_CENTER[1];
let cursorLon = PILOT_CENTER[0];
let headingRad = 0.45;
let currentH3Cell = h3.latLngToCell(cursorLat, cursorLon, 9);

const trackPoints: TrackPoint[] = [];
const hexBuckets = new Map<string, HexBucket>();
let lastApiStatus = "Connecting to Supabase Edge Function map-api...";
let lastApiJsonPreview = "";
let selectedCellDetailJson = "";

// Render root shell
const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <header class="topbar">
    <div class="brand">
      <img src="/assets/app_icon.png" alt="TerraSteps" />
      <div>
        <h1>TerraSteps <span class="badge">30% FYP Defense</span> <span class="badge cyan">H3 Res-9 + PostGIS</span></h1>
        <div class="muted">Flutter (Drift SQLite + Mapbox SDK) • Supabase Edge Functions • Google Drive Heavy Assets</div>
      </div>
    </div>
    <div class="topbar-controls">
      <input id="mapboxTokenInput" type="password" placeholder="Optional Mapbox pk.* token for Mapbox tiles" style="width: 255px;" value="${mapboxToken}" />
      <button id="applyTokenBtn">Apply Map Style</button>
      <button id="flyPilotBtn">Abbottabad Pilot</button>
      <button id="planRouteBtn">Route Hex Preview</button>
    </div>
  </header>

  <main class="workspace">
    <section class="map-pane">
      <div id="map"></div>
      <div class="map-overlay-top">
        <div class="map-pill legend">
          <span><i class="dot" style="background:#10b981"></i>Owned (Me)</span>
          <span><i class="dot" style="background:#f97316"></i>Rival Faction</span>
          <span><i class="dot" style="background:#38bdf8"></i>Conquering Live</span>
          <span><i class="dot" style="background:#64748b"></i>Safety Masked</span>
        </div>
        <div class="map-pill" id="apiStatusPill">${lastApiStatus}</div>
      </div>

      <div class="map-overlay-bottom" id="activeHexHud"></div>
    </section>

    <aside class="side-pane">
      <nav class="tabs">
        <button class="tab-btn active" data-tab="fitness">1. Step & METs</button>
        <button class="tab-btn" data-tab="gpx">2. GPX 1.1 XML</button>
        <button class="tab-btn" data-tab="mapapi">3. Map API</button>
        <button class="tab-btn" data-tab="drive">4. Drive Assets</button>
      </nav>
      <div id="tabContent"></div>
    </aside>
  </main>
`;

function getMapStyle(token: string): string | maplibregl.StyleSpecification {
  if (token.trim().startsWith("pk.")) {
    // Render real Mapbox Raster/Vector Dark Tiles via Mapbox v4 Tiles API
    return {
      version: 8,
      sources: {
        "mapbox-dark": {
          type: "raster",
          tiles: [
            `https://api.mapbox.com/styles/v1/mapbox/dark-v11/tiles/256/{z}/{x}/{y}@2x?access_token=${encodeURIComponent(token.trim())}`,
          ],
          tileSize: 256,
          attribution: "© Mapbox © OpenStreetMap",
        },
      },
      layers: [{ id: "mapbox-dark-layer", type: "raster", source: "mapbox-dark" }],
    };
  }
  return "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json";
}

const map = new maplibregl.Map({
  container: "map",
  style: getMapStyle(mapboxToken),
  center: PILOT_CENTER,
  zoom: 14.5,
  pitch: 28,
});
map.addControl(new maplibregl.NavigationControl(), "bottom-right");

function ensureMapLayers() {
  if (!map.getSource("h3-hexes")) {
    map.addSource("h3-hexes", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] },
    });
    map.addLayer({
      id: "h3-hexes-fill",
      type: "fill",
      source: "h3-hexes",
      paint: {
        "fill-color": ["get", "fill_color"],
        "fill-opacity": ["get", "fill_opacity"],
      },
    });
    map.addLayer({
      id: "h3-hexes-line",
      type: "line",
      source: "h3-hexes",
      paint: {
        "line-color": ["get", "stroke_color"],
        "line-width": 1.6,
      },
    });
  }

  if (!map.getSource("route-preview")) {
    map.addSource("route-preview", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] },
    });
    map.addLayer({
      id: "route-preview-line",
      type: "line",
      source: "route-preview",
      paint: {
        "line-color": "#facc15",
        "line-width": 3.5,
        "line-dasharray": [2, 1.5],
      },
    });
  }

  if (!map.getSource("live-trail")) {
    map.addSource("live-trail", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] },
    });
    map.addLayer({
      id: "live-trail-line",
      type: "line",
      source: "live-trail",
      paint: {
        "line-color": "#38bdf8",
        "line-width": 4.5,
      },
    });
  }
}

let cachedViewportGeoJson: GeoJSON.FeatureCollection = {
  type: "FeatureCollection",
  features: [],
};

const OFFLINE_SEEDED_OWNERS: Record<
  string,
  { state: string; fill: string; stroke: string; opacity: number; influence: number }
> = {
  "89209a0aa73ffff": { state: "owned_me", fill: "#10B981", stroke: "#059669", opacity: 0.44, influence: 340 },
  "89209a0aa0fffff": { state: "owned_me", fill: "#10B981", stroke: "#059669", opacity: 0.4, influence: 265 },
  "89209a0aa0bffff": { state: "owned_me", fill: "#10B981", stroke: "#059669", opacity: 0.36, influence: 210 },
  "89209a0aa77ffff": { state: "owned_rival", fill: "#F97316", stroke: "#EA580C", opacity: 0.38, influence: 295 },
  "89209a0aa63ffff": { state: "owned_rival", fill: "#F97316", stroke: "#EA580C", opacity: 0.35, influence: 230 },
  "89209a0aa6bffff": { state: "owned_rival", fill: "#8B5CF6", stroke: "#7C3AED", opacity: 0.38, influence: 310 },
  "89209a0aa47ffff": { state: "owned_rival", fill: "#8B5CF6", stroke: "#7C3AED", opacity: 0.34, influence: 195 },
  "89209a0aa57ffff": { state: "masked", fill: "#334155", stroke: "#64748B", opacity: 0.45, influence: 0 },
  "89209a081b7ffff": { state: "masked", fill: "#334155", stroke: "#64748B", opacity: 0.45, influence: 0 },
};

function buildLocalFallbackHexes(minLat: number, minLon: number, maxLat: number, maxLon: number): GeoJSON.FeatureCollection {
  const cCell = h3.latLngToCell((minLat + maxLat) / 2, (minLon + maxLon) / 2, 9);
  const disk = h3.gridDisk(cCell, 3);
  return {
    type: "FeatureCollection",
    features: disk.map((cid) => {
      const ring = h3.cellToBoundary(cid, true);
      ring.push([ring[0][0], ring[0][1]]);
      const seeded = OFFLINE_SEEDED_OWNERS[cid];
      return {
        type: "Feature",
        id: cid,
        properties: {
          h3_id: cid,
          state: seeded?.state ?? "neutral",
          fill_color: seeded?.fill ?? "#475569",
          stroke_color: seeded?.stroke ?? "#64748b",
          fill_opacity: seeded?.opacity ?? 0.08,
          influence: seeded?.influence ?? 0,
        },
        geometry: { type: "Polygon", coordinates: [ring] },
      };
    }),
  };
}

async function refreshViewportHexes() {
  const b = map.getBounds();
  const qs = new URLSearchParams({
    min_lat: b.getSouth().toFixed(6),
    min_lon: b.getWest().toFixed(6),
    max_lat: b.getNorth().toFixed(6),
    max_lon: b.getEast().toFixed(6),
    res: "9",
    include_neutral: String(map.getZoom() >= 13.0),
    viewer_id: PILOT_WALKER_ID,
  });

  try {
    const res = await fetch(`${MAP_API_BASE}/viewport?${qs.toString()}`, {
      headers: { apikey: SUPABASE_PUBLISHABLE_KEY },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    cachedViewportGeoJson = data.geojson;
    lastApiStatus = `Live Supabase map-api • ${data.meta?.occupied_or_masked_count ?? 0} active / ${data.meta?.total_features ?? 0} H3 cells`;
    lastApiJsonPreview = JSON.stringify(data.snapshot, null, 2);
  } catch (_err) {
    cachedViewportGeoJson = buildLocalFallbackHexes(
      b.getSouth(),
      b.getWest(),
      b.getNorth(),
      b.getEast(),
    );
    lastApiStatus = `Offline H3 Engine Mode (${cachedViewportGeoJson.features.length} hexes)`;
  }

  const pill = document.getElementById("apiStatusPill");
  if (pill) pill.textContent = lastApiStatus;
  paintHexSource();
  if (activeTab === "mapapi") renderSideTab();
}

function paintHexSource() {
  const src = map.getSource("h3-hexes") as maplibregl.GeoJSONSource | undefined;
  if (!src) return;
  const clone: GeoJSON.FeatureCollection = JSON.parse(JSON.stringify(cachedViewportGeoJson));
  for (const f of clone.features) {
    if (f.properties && f.properties.h3_id === currentH3Cell && simTimer !== null) {
      f.properties.fill_color = "#38bdf8";
      f.properties.stroke_color = "#7dd3fc";
      f.properties.fill_opacity = 0.52;
    }
  }
  src.setData(clone);
}

function paintLiveTrail() {
  const src = map.getSource("live-trail") as maplibregl.GeoJSONSource | undefined;
  if (!src || trackPoints.length < 2) return;
  src.setData({
    type: "FeatureCollection",
    features: [
      {
        type: "Feature",
        properties: {},
        geometry: {
          type: "LineString",
          coordinates: trackPoints.map((p) => [p.lon, p.lat]),
        },
      },
    ],
  });
}

map.on("load", () => {
  ensureMapLayers();
  refreshViewportHexes();
});

map.on("moveend", () => {
  refreshViewportHexes();
});

map.on("click", async (e) => {
  const clickedCell = h3.latLngToCell(e.lngLat.lat, e.lngLat.lng, 9);
  try {
    const res = await fetch(`${MAP_API_BASE}/cells/${clickedCell}`, {
      headers: { apikey: SUPABASE_PUBLISHABLE_KEY },
    });
    const detail = await res.json();
    selectedCellDetailJson = JSON.stringify(detail, null, 2);
    const owner = detail?.detail?.owner;
    new maplibregl.Popup()
      .setLngLat(e.lngLat)
      .setHTML(
        `<div style="color:#0f172a;font-size:12px;">
          <strong>H3: ${clickedCell}</strong><br/>
          ${
            owner
              ? `Owner: <b>${owner.username}</b> (${owner.name ?? "Territory"})<br/>Influence: ${owner.influence} pts<br/>Capture Margin: ${detail?.detail?.effort_to_capture ?? 0} pts`
              : "Neutral H3 Res-9 Hex<br/>Claim Floor: 120 steps • 80m • 90s"
          }
        </div>`,
      )
      .addTo(map);
    if (activeTab === "mapapi") renderSideTab();
  } catch (_err) {
    // ignore offline popup errors
  }
});

// MET & Step Counter Simulation Logic (Mirrors packages/terrasteps_fitness)
function classifyMet(speedMps: number, cadence: number): number {
  if (speedMps < 0.4 && cadence < 35) return 1.3;
  const kmh = speedMps * 3.6;
  if (kmh < 4.0) return 2.8;
  if (kmh <= 6.5) return 4.3;
  if (kmh <= 10.0) return 8.0;
  return 11.0;
}

function stepWorkoutTick() {
  if (isPaused) return;
  const dtMs = 3000;
  elapsedDurationMs += dtMs;

  const targetSpeed =
    simMode === "walk" ? 1.46 : simMode === "run" ? 2.58 : 13.4; // 13.4 m/s = 48.2 km/h car spoof
  currentSpeedMps = Number((targetSpeed * (0.94 + Math.random() * 0.12)).toFixed(2));

  // Hardware cumulative sensor simulation
  const strideM = (heightCm * (simMode === "run" ? 0.45 : 0.415)) / 100;
  const distDelta = currentSpeedMps * (dtMs / 1000);
  const rawIncrement =
    simMode === "vehicle" ? (trackPoints.length % 5 === 0 ? 1 : 0) : Math.max(1, Math.round(distDelta / strideM));

  rawBootSensorSteps += rawIncrement;
  let stepDelta = 0;
  if (baselineSteps === null || lastRawSteps === null) {
    baselineSteps = rawBootSensorSteps;
    lastRawSteps = rawBootSensorSteps;
  } else if (rawBootSensorSteps < lastRawSteps) {
    // Reboot reset protection
    bootResetCount++;
    baselineSteps = rawBootSensorSteps;
    lastRawSteps = rawBootSensorSteps;
  } else {
    stepDelta = rawBootSensorSteps - lastRawSteps;
    lastRawSteps = rawBootSensorSteps;
    measuredSteps += stepDelta;
  }

  currentCadenceSpm = Math.round((stepDelta / (dtMs / 1000)) * 60);
  currentMet = simMode === "vehicle" ? 1.3 : classifyMet(currentSpeedMps, currentCadenceSpm);

  let kcalDelta = 0;
  if (currentSpeedMps >= 0.4) {
    activeDurationMs += dtMs;
    kcalDelta = ((currentMet * 3.5 * weightKg) / 200) * (dtMs / 60000);
    caloriesKcal += kcalDelta;
  }

  headingRad += Math.sin(trackPoints.length / 8) * 0.09;
  cursorLat += (distDelta * Math.cos(headingRad)) / 111320;
  cursorLon += (distDelta * Math.sin(headingRad)) / (111320 * Math.cos((cursorLat * Math.PI) / 180));
  distanceMeters += distDelta;

  currentH3Cell = h3.latLngToCell(cursorLat, cursorLon, 9);
  const parent5 = h3.cellToParent(currentH3Cell, 5);

  const bucket = hexBuckets.get(currentH3Cell) ?? {
    h3Index: currentH3Cell,
    parentRes5: parent5,
    steps: 0,
    distanceM: 0,
    activeDwellS: 0,
    fixCount: 0,
    maxSpeedMps: 0,
  };
  bucket.steps += stepDelta;
  bucket.distanceM += distDelta;
  if ((currentSpeedMps >= 0.4 && currentSpeedMps <= 6.5) || currentCadenceSpm > 40) {
    bucket.activeDwellS += 3;
  }
  bucket.fixCount += 1;
  bucket.maxSpeedMps = Math.max(bucket.maxSpeedMps, currentSpeedMps);
  hexBuckets.set(currentH3Cell, bucket);

  trackPoints.push({
    seq: trackPoints.length,
    lat: cursorLat,
    lon: cursorLon,
    ele: Number((1256.4 + 4.5 * Math.sin(trackPoints.length / 7)).toFixed(2)),
    isoUtc: new Date().toISOString(),
    monotonicMs: elapsedDurationMs,
    stepsDelta: stepDelta,
    cumSteps: measuredSteps,
    cadenceSpm: currentCadenceSpm,
    speedMps: currentSpeedMps,
    accuracyM: 4.4,
    kcalDelta,
    h3Index: currentH3Cell,
    parentRes5: parent5,
  });

  paintLiveTrail();
  paintHexSource();
  renderActiveHexHud();
  renderSideTab();
}

function buildLiveGpxXml(): string {
  const startIso = trackPoints[0]?.isoUtc ?? new Date().toISOString();
  const ptsXml = trackPoints
    .map(
      (p) => `      <trkpt lat="${p.lat.toFixed(7)}" lon="${p.lon.toFixed(7)}">
        <ele>${p.ele.toFixed(2)}</ele>
        <time>${p.isoUtc}</time>
        <extensions>
          <ext:steps_delta>${p.stepsDelta}</ext:steps_delta>
          <ext:cumulative_steps>${p.cumSteps}</ext:cumulative_steps>
          <ext:cadence_spm>${p.cadenceSpm}</ext:cadence_spm>
          <ext:speed_mps>${p.speedMps.toFixed(2)}</ext:speed_mps>
          <ext:accuracy_m>${p.accuracyM.toFixed(2)}</ext:accuracy_m>
          <ext:calories_delta_kcal>${p.kcalDelta.toFixed(4)}</ext:calories_delta_kcal>
          <ext:h3_index>${p.h3Index}</ext:h3_index>
          <ext:parent_res5>${p.parentRes5}</ext:parent_res5>
          <ext:monotonic_ms>${p.monotonicMs}</ext:monotonic_ms>
        </extensions>
      </trkpt>`,
    )
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="TerraStepsFYP/0.3.0"
  xmlns="http://www.topografix.com/GPX/1/1"
  xmlns:ext="https://hexfyp.local/gpx/extensions/v1"
  xmlns:terrasteps="https://terrasteps.app/gpx/extensions/v1">
  <metadata>
    <name>Session_${startIso}</name>
    <time>${startIso}</time>
    <extensions>
      <terrasteps:h3_resolution>9</terrasteps:h3_resolution>
      <terrasteps:measured_steps>${measuredSteps}</terrasteps:measured_steps>
      <terrasteps:total_distance_m>${distanceMeters.toFixed(1)}</terrasteps:total_distance_m>
      <terrasteps:total_calories_kcal>${caloriesKcal.toFixed(2)}</terrasteps:total_calories_kcal>
      <terrasteps:unique_h3_cells>${hexBuckets.size}</terrasteps:unique_h3_cells>
    </extensions>
  </metadata>
  <trk>
    <name>TerraSteps ${simMode.toUpperCase()} Session</name>
    <trkseg>
${ptsXml}
    </trkseg>
  </trk>
</gpx>`;
}

function renderActiveHexHud() {
  const hud = document.getElementById("activeHexHud")!;
  const b = hexBuckets.get(currentH3Cell);
  const effort = b
    ? Math.min(600, 1.0 * b.steps + 0.35 * Math.round(b.distanceM) + 0.05 * b.activeDwellS)
    : 0;
  const pct = b
    ? Math.min(
        100,
        Math.round(
          ((Math.min(1, b.steps / 120) +
            Math.min(1, b.distanceM / 80) +
            Math.min(1, b.activeDwellS / 90) +
            Math.min(1, b.fixCount / 5)) /
            4) *
            100,
        ),
      )
    : 0;

  let refereeNote = "Ready to start workout";
  if (b) {
    const ratio = b.distanceM / Math.max(1, b.steps);
    if (b.maxSpeedMps > 8.0 || ratio > 1.6) {
      refereeNote = "REFEREE WARNING: Vehicle/Spoof Speed Detected (Rejected for Conquest)";
    } else if (pct >= 100) {
      refereeNote = "CLAIM ELIGIBLE — Exceeds all PostgreSQL Referee R1–R8 floors!";
    } else {
      refereeNote = `Conquering Hex (${pct}% of claim floors)`;
    }
  }

  hud.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;font-size:0.8rem;">
      <span><strong>Active H3 Cell:</strong> <code>${currentH3Cell}</code></span>
      <span style="color:var(--emerald);font-weight:700;">Effort: ${effort.toFixed(1)} pts (score_micro: ${Math.round(effort * 1e6)})</span>
    </div>
    <div class="progress-track"><div class="progress-fill" style="width:${pct}%"></div></div>
    <div style="display:flex;justify-content:space-between;font-size:0.73rem;color:var(--muted);">
      <span>Steps: ${b?.steps ?? 0}/120 • Dist: ${(b?.distanceM ?? 0).toFixed(0)}/80m • Active Dwell: ${b?.activeDwellS ?? 0}/90s • Fixes: ${b?.fixCount ?? 0}/5</span>
      <span style="color:${refereeNote.includes("WARNING") ? "var(--danger)" : "var(--cyan)"}">${refereeNote}</span>
    </div>
  `;
}

function renderSideTab() {
  const container = document.getElementById("tabContent")!;

  if (activeTab === "fitness") {
    const estSteps = Math.round(distanceMeters / ((heightCm * 0.415) / 100));
    container.innerHTML = `
      <div class="card">
        <h3>Workout & Sensor Simulator <span>${simTimer ? (isPaused ? "PAUSED" : "LIVE") : "IDLE"}</span></h3>
        <div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px;">
          <button class="primary" id="startWalkBtn">Start Valid Walk</button>
          <button id="startRunBtn">Start Brisk Run (MET 8.0)</button>
          <button class="warn" id="startVehicleBtn">Test 48 km/h Car Spoof</button>
          <button id="pauseResumeBtn">${isPaused ? "Resume" : "Pause"}</button>
          <button id="rebootTestBtn" title="Simulates OS step counter resetting to 0 on reboot">Test Boot Reset</button>
          <button class="danger" id="resetSimBtn">Reset</button>
        </div>
        <div class="metrics-grid">
          <div class="metric-box">
            <div class="label">Measured Hardware Steps</div>
            <div class="val" style="color:var(--emerald)">${measuredSteps} <span class="muted">/ ${dailyGoal}</span></div>
            <div class="muted">Sensor raw: ${rawBootSensorSteps} (resets: ${bootResetCount})</div>
          </div>
          <div class="metric-box">
            <div class="label">Active MET Calories</div>
            <div class="val" style="color:var(--orange)">${caloriesKcal.toFixed(2)} kcal</div>
            <div class="muted">Current MET: ${currentMet.toFixed(1)}</div>
          </div>
          <div class="metric-box">
            <div class="label">Haversine Distance</div>
            <div class="val">${(distanceMeters / 1000).toFixed(3)} km</div>
            <div class="muted">GPS Est. Steps (separate): ${estSteps}</div>
          </div>
          <div class="metric-box">
            <div class="label">Speed & Cadence</div>
            <div class="val" style="color:var(--cyan)">${(currentSpeedMps * 3.6).toFixed(1)} km/h</div>
            <div class="muted">${currentCadenceSpm} spm • ${(activeDurationMs / 1000).toFixed(0)}s active</div>
          </div>
        </div>
      </div>

      <div class="card">
        <h3>Profile & MET Calibration</h3>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;">
          <label class="muted">Weight (kg)<br/><input id="weightInp" type="number" value="${weightKg}" style="width:100%;margin-top:4px;"/></label>
          <label class="muted">Height (cm)<br/><input id="heightInp" type="number" value="${heightCm}" style="width:100%;margin-top:4px;"/></label>
          <label class="muted">Daily Goal<br/><input id="goalInp" type="number" value="${dailyGoal}" style="width:100%;margin-top:4px;"/></label>
        </div>
      </div>
    `;

    document.getElementById("startWalkBtn")?.addEventListener("click", () => startSim("walk"));
    document.getElementById("startRunBtn")?.addEventListener("click", () => startSim("run"));
    document.getElementById("startVehicleBtn")?.addEventListener("click", () => startSim("vehicle"));
    document.getElementById("pauseResumeBtn")?.addEventListener("click", () => {
      isPaused = !isPaused;
      renderSideTab();
    });
    document.getElementById("rebootTestBtn")?.addEventListener("click", () => {
      rawBootSensorSteps = 3; // Simulate Android rebooting hardware counter back near 0
      stepWorkoutTick();
    });
    document.getElementById("resetSimBtn")?.addEventListener("click", resetSim);
    document.getElementById("weightInp")?.addEventListener("change", (e) => {
      weightKg = Number((e.target as HTMLInputElement).value) || 72;
    });
    document.getElementById("heightInp")?.addEventListener("change", (e) => {
      heightCm = Number((e.target as HTMLInputElement).value) || 174;
    });
    document.getElementById("goalInp")?.addEventListener("change", (e) => {
      dailyGoal = Number((e.target as HTMLInputElement).value) || 8000;
      renderSideTab();
    });
  } else if (activeTab === "gpx") {
    const xml = buildLiveGpxXml();
    container.innerHTML = `
      <div class="card">
        <h3>Deliverable 1: GPX 1.1 Serializer (${trackPoints.length} trackpoints)
          <button class="primary" id="downloadGpxBtn">Download .gpx</button>
        </h3>
        <p class="muted" style="margin-bottom:8px;">
          Valid GPX 1.1 XML binding GPS fixes, H3 Resolution-9 cell IDs, step deltas, speed, and MET calories for Referee verification.
        </p>
        <div class="code-view" id="gpxXmlPreview"></div>
      </div>
    `;
    document.getElementById("gpxXmlPreview")!.textContent = xml;
    document.getElementById("downloadGpxBtn")?.addEventListener("click", () => {
      const blob = new Blob([xml], { type: "application/gpx+xml" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = `terrasteps_${simMode}_${Date.now()}.gpx`;
      a.click();
    });
  } else if (activeTab === "mapapi") {
    container.innerHTML = `
      <div class="card">
        <h3>Deliverable 3: Live Supabase Edge Function (<code>map-api</code>)
          <button id="refreshApiBtn">Query Viewport</button>
        </h3>
        <p class="muted" style="margin-bottom:8px;">
          Endpoint: <code>${MAP_API_BASE}/viewport</code><br/>
          Sanitized <code>MapSnapshot</code> contract (H3 IDs as TEXT, fixed-point <code>score_micro</code> digit strings, zero leaked UUIDs):
        </p>
        <div class="code-view" id="snapshotPreview"></div>
      </div>
      <div class="card">
        <h3>Tapped Hex Detail (Click any hex on map)</h3>
        <div class="code-view" id="cellDetailPreview"></div>
      </div>
    `;
    document.getElementById("snapshotPreview")!.textContent =
      lastApiJsonPreview || "Move map or click Query Viewport...";
    document.getElementById("cellDetailPreview")!.textContent =
      selectedCellDetailJson || "Click any hexagon on the map to call GET /map-api/cells/:cellId";
    document.getElementById("refreshApiBtn")?.addEventListener("click", refreshViewportHexes);
  } else if (activeTab === "drive") {
    const rows = driveManifest.assets
      .map(
        (a) => `
        <div class="asset-row">
          <div>
            <strong>${a.name}</strong>
            <div class="muted">${a.category} • ${(a.size_bytes / (1024 * 1024)).toFixed(2)} MB</div>
          </div>
          <a href="${a.view_url}" target="_blank" rel="noreferrer">Open in Drive ↗</a>
        </div>`,
      )
      .join("");

    container.innerHTML = `
      <div class="card">
        <h3>Google Drive Heavy Storage
          <a href="${driveManifest.drive_root_folder.url}" target="_blank" rel="noreferrer" style="color:var(--emerald);font-size:0.76rem;">Open Root Folder ↗</a>
        </h3>
        <p class="muted" style="margin-bottom:8px;">
          Heavy 1Hz GPX benchmark corpora, 2,437-hex H3 GeoJSON packs, high-res artwork, and the 47.5 MB APK live in Google Drive while Git stays lean.
        </p>
        ${rows}
      </div>
    `;
  }
}

function startSim(mode: "walk" | "run" | "vehicle") {
  simMode = mode;
  isPaused = false;
  if (simTimer === null) {
    stepWorkoutTick();
    simTimer = window.setInterval(stepWorkoutTick, 1800);
  }
  renderSideTab();
}

function resetSim() {
  if (simTimer !== null) {
    clearInterval(simTimer);
    simTimer = null;
  }
  isPaused = false;
  baselineSteps = null;
  lastRawSteps = null;
  measuredSteps = 0;
  distanceMeters = 0;
  activeDurationMs = 0;
  elapsedDurationMs = 0;
  caloriesKcal = 0;
  currentSpeedMps = 0;
  currentMet = 1.3;
  currentCadenceSpm = 0;
  cursorLat = PILOT_CENTER[1];
  cursorLon = PILOT_CENTER[0];
  currentH3Cell = h3.latLngToCell(cursorLat, cursorLon, 9);
  trackPoints.length = 0;
  hexBuckets.clear();
  const src = map.getSource("live-trail") as maplibregl.GeoJSONSource | undefined;
  src?.setData({ type: "FeatureCollection", features: [] });
  paintHexSource();
  renderActiveHexHud();
  renderSideTab();
}

// Topbar buttons
document.getElementById("applyTokenBtn")?.addEventListener("click", () => {
  const val = (document.getElementById("mapboxTokenInput") as HTMLInputElement).value.trim();
  mapboxToken = val;
  localStorage.setItem("terrasteps_mapbox_token", val);
  map.setStyle(getMapStyle(mapboxToken));
  map.once("styledata", () => {
    ensureMapLayers();
    paintHexSource();
    paintLiveTrail();
  });
});

document.getElementById("flyPilotBtn")?.addEventListener("click", () => {
  map.flyTo({ center: PILOT_CENTER, zoom: 14.6, pitch: 28 });
});

document.getElementById("planRouteBtn")?.addEventListener("click", async () => {
  try {
    const res = await fetch(`${MAP_API_BASE}/route-preview`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_PUBLISHABLE_KEY,
      },
      body: JSON.stringify({
        origin: [cursorLat, cursorLon],
        destination: [cursorLat + 0.0065, cursorLon + 0.0058],
        weight_kg: weightKg,
        height_cm: heightCm,
        mapbox_token: mapboxToken,
      }),
    });
    const data = await res.json();
    if (data?.route_geojson) {
      const rSrc = map.getSource("route-preview") as maplibregl.GeoJSONSource | undefined;
      rSrc?.setData({ type: "FeatureCollection", features: [data.route_geojson] });
      lastApiJsonPreview = JSON.stringify(data.summary, null, 2);
      activeTab = "mapapi";
      updateTabButtons();
      renderSideTab();
    }
  } catch (_e) {
    // ignore offline error
  }
});

function updateTabButtons() {
  document.querySelectorAll<HTMLButtonElement>(".tab-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === activeTab);
  });
}

document.querySelectorAll<HTMLButtonElement>(".tab-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    activeTab = (btn.dataset.tab as typeof activeTab) ?? "fitness";
    updateTabButtons();
    renderSideTab();
  });
});

renderActiveHexHud();
renderSideTab();
