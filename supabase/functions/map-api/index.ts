// =============================================================================
// TerraSteps — Map API & Spatial Sync Edge Function (Supabase Deno + TypeScript)
// =============================================================================
// Endpoints (under /functions/v1/map-api):
//   GET  /health                     -> Service, H3 res=9 & PostGIS config check
//   GET  /viewport | /hexes          -> Viewport H3 Res-9 GeoJSON + MapSnapshot
//   GET  /regions/:regionId/cells    -> Strict contracts/map-snapshot.schema.json
//   GET  /cells/:cellId              -> Single H3 cell boundary, neighbors & detail
//   POST /route-preview              -> Mapbox Walking Directions -> H3 hex planner
//   POST /sessions/sync | /submit    -> Transactional claim_cells + PostGIS centroids
// =============================================================================

import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import * as h3 from "npm:h3-js@4.1.0";

const H3_RESOLUTION = 9;
const PARENT_RESOLUTION = 5;
const MAX_POLYGON_SPAN_DEG = 0.12; // ~13 km box max for dense neutral grid generation
const MAX_NEUTRAL_CELLS = 900;

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-mapbox-token",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

interface DbSnapshotRow {
  h3_id: string;
  parent_res5: string;
  nickname: string | null;
  avatar_ref: string | null;
  kingdom_name: string | null;
  color: string | null;
  influence: number | string | null;
  score_micro: string | null;
  version: number;
  masked: boolean;
  mask_reason: "water" | "high_speed_road" | "restricted" | "reported_hazard" | null;
  is_mine: boolean;
  my_influence?: number | string | null;
  last_claim_at: string | null;
  center_lat: number | null;
  center_lng: number | null;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function errorResponse(code: string, message: string, status = 400): Response {
  return jsonResponse({ ok: false, error: { code, message } }, status);
}

/** Converts an H3 cell index to a closed RFC 7946 GeoJSON Polygon ring [[lng, lat], ...] */
function cellToGeoJsonRing(cellId: string): number[][] {
  const boundary = h3.cellToBoundary(cellId, true); // true => [lng, lat]
  if (boundary.length > 0) {
    const first = boundary[0];
    const last = boundary[boundary.length - 1];
    if (first[0] !== last[0] || first[1] !== last[1]) {
      boundary.push([first[0], first[1]]);
    }
  }
  return boundary;
}

/** Strict contract cell projection matching contracts/map-snapshot.schema.json */
function toContractCell(row: DbSnapshotRow, pendingSet?: Set<string>) {
  const isMasked = Boolean(row.masked);
  const hasOwner = !isMasked && Boolean(row.nickname);
  return {
    h3_id: row.h3_id.toLowerCase(),
    owner: hasOwner
      ? {
          nickname: String(row.nickname).slice(0, 32),
          avatar_ref: row.avatar_ref ?? null,
          kingdom_name: row.kingdom_name ? String(row.kingdom_name).slice(0, 40) : null,
        }
      : null,
    score_micro:
      hasOwner && row.score_micro && /^[0-9]+$/.test(String(row.score_micro))
        ? String(row.score_micro)
        : null,
    color: hasOwner && row.color ? row.color : isMasked ? "#64748B" : null,
    version: Math.max(0, Number(row.version ?? 1)),
    masked: isMasked,
    mask_reason: isMasked ? row.mask_reason : null,
    pending: pendingSet ? pendingSet.has(row.h3_id) : false,
  };
}

/** Builds a Mapbox-ready GeoJSON Feature for an H3 cell */
function toGeoJsonFeature(cellId: string, row?: DbSnapshotRow) {
  const [centerLat, centerLng] = h3.cellToLatLng(cellId);
  const ring = cellToGeoJsonRing(cellId);

  let state: "mine" | "rival" | "masked" | "neutral" = "neutral";
  let fillColor = "#475569";
  let strokeColor = "#64748B";
  let fillOpacity = 0.08;

  if (row?.masked) {
    state = "masked";
    fillColor = "#64748B";
    strokeColor = "#94A3B8";
    fillOpacity = 0.35;
  } else if (row?.nickname) {
    if (row.is_mine) {
      state = "mine";
      fillColor = row.color ?? "#10B981";
      strokeColor = "#34D399";
      fillOpacity = 0.44;
    } else {
      state = "rival";
      fillColor = row.color ?? "#F97316";
      strokeColor = row.color ?? "#FB923C";
      fillOpacity = 0.36;
    }
  }

  return {
    type: "Feature" as const,
    id: cellId,
    properties: {
      h3_id: cellId,
      parent_res5: row?.parent_res5 ?? h3.cellToParent(cellId, PARENT_RESOLUTION),
      state,
      fill_color: fillColor,
      stroke_color: strokeColor,
      fill_opacity: fillOpacity,
      nickname: row?.masked ? null : row?.nickname ?? null,
      kingdom_name: row?.masked ? null : row?.kingdom_name ?? null,
      influence: row?.influence !== null && row?.influence !== undefined ? Number(row.influence) : 0,
      score_micro: row?.score_micro ?? null,
      version: row?.version ?? 0,
      masked: Boolean(row?.masked),
      mask_reason: row?.mask_reason ?? null,
      is_mine: Boolean(row?.is_mine),
      center_lat: Number(centerLat.toFixed(6)),
      center_lng: Number(centerLng.toFixed(6)),
    },
    geometry: {
      type: "Polygon" as const,
      coordinates: [ring],
    },
  };
}

/** Haversine distance in metres */
function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(a));
}

/** MET value matching Deliverable 2 speed brackets */
function metForSpeedMps(speedMps: number): number {
  const kmh = speedMps * 3.6;
  if (kmh < 1.5) return 1.3;
  if (kmh < 4.0) return 2.8;
  if (kmh <= 6.5) return 4.3;
  if (kmh <= 10.0) return 8.0;
  return 11.0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: authHeader ? { headers: { Authorization: authHeader } } : undefined,
      auth: { persistSession: false },
    });
    const adminClient = createClient(
      supabaseUrl,
      supabaseServiceKey || supabaseAnonKey,
      { auth: { persistSession: false } },
    );

    // Resolve optional authenticated caller ID
    let callerId: string | null = null;
    if (authHeader.toLowerCase().startsWith("bearer ")) {
      const token = authHeader.slice(7).trim();
      if (token && token !== supabaseAnonKey) {
        const { data: authData } = await userClient.auth.getUser(token);
        callerId = authData?.user?.id ?? null;
      }
    }

    const url = new URL(req.url);
    // Normalize path after /map-api (works whether invoked as /functions/v1/map-api/... or /map-api/...)
    const rawPath = url.pathname.replace(/^\/functions\/v1\/map-api/, "").replace(/^\/map-api/, "") || "/";
    const path = rawPath.endsWith("/") && rawPath.length > 1 ? rawPath.slice(0, -1) : rawPath;

    // -------------------------------------------------------------------------
    // 1. GET /health
    // -------------------------------------------------------------------------
    if (req.method === "GET" && (path === "/" || path === "/health")) {
      const { data: cfgRows } = await adminClient
        .from("game_config")
        .select("key, value")
        .order("key");

      const configMap: Record<string, number> = {};
      for (const r of cfgRows ?? []) {
        configMap[r.key] = Number(r.value);
      }

      return jsonResponse({
        ok: true,
        service: "terrasteps-map-api",
        version: "0.3.0-milestone30",
        h3_resolution: H3_RESOLUTION,
        parent_resolution: PARENT_RESOLUTION,
        postgis_enabled: true,
        authenticated_user: callerId,
        game_config: configMap,
        endpoints: [
          "GET /viewport?min_lat=&min_lon=&max_lat=&max_lon=&include_neutral=true",
          "GET /hexes?min_lat=&min_lon=&max_lat=&max_lon=&res=9",
          "GET /regions/:regionId/cells",
          "GET /cells/:cellId",
          "POST /route-preview",
          "POST /sessions/sync",
        ],
      });
    }

    // -------------------------------------------------------------------------
    // 2. GET /viewport or GET /hexes (Mapbox Viewport Hex Grid + PostGIS BBox)
    // -------------------------------------------------------------------------
    if (req.method === "GET" && (path === "/viewport" || path === "/hexes")) {
      const minLat = Number(url.searchParams.get("min_lat"));
      const minLon = Number(url.searchParams.get("min_lon"));
      const maxLat = Number(url.searchParams.get("max_lat"));
      const maxLon = Number(url.searchParams.get("max_lon"));
      const requestedRes = Number(url.searchParams.get("res") ?? H3_RESOLUTION);
      const includeNeutral = url.searchParams.get("include_neutral") !== "false";
      const format = url.searchParams.get("format") ?? "both";
      const callerOverride = url.searchParams.get("viewer_id");
      const effectiveCaller = callerId ?? (callerOverride && /^[0-9a-f-]{36}$/i.test(callerOverride) ? callerOverride : null);

      if (
        !Number.isFinite(minLat) ||
        !Number.isFinite(minLon) ||
        !Number.isFinite(maxLat) ||
        !Number.isFinite(maxLon) ||
        minLat >= maxLat ||
        minLon >= maxLon ||
        minLat < -90 ||
        maxLat > 90 ||
        minLon < -180 ||
        maxLon > 180
      ) {
        return errorResponse(
          "invalid_bbox",
          "Provide valid min_lat, min_lon, max_lat, max_lon bounding box coordinates.",
          400,
        );
      }

      if (requestedRes !== H3_RESOLUTION) {
        return errorResponse(
          "unsupported_resolution",
          `Pilot competition locks H3 resolution at ${H3_RESOLUTION} (Plan §11). Received res=${requestedRes}.`,
          400,
        );
      }

      const latSpan = maxLat - minLat;
      const lonSpan = maxLon - minLon;
      const centerLat = (minLat + maxLat) / 2;
      const centerLon = (minLon + maxLon) / 2;
      const centerCell = h3.latLngToCell(centerLat, centerLon, H3_RESOLUTION);
      const regionId = h3.cellToParent(centerCell, PARENT_RESOLUTION);

      let viewportCells: string[] = [];
      let rowsByCell = new Map<string, DbSnapshotRow>();

      if (latSpan <= MAX_POLYGON_SPAN_DEG && lonSpan <= MAX_POLYGON_SPAN_DEG) {
        // Compute exact H3 cells covering the Mapbox camera bounding box
        const bboxLoop: [number, number][] = [
          [minLat, minLon],
          [minLat, maxLon],
          [maxLat, maxLon],
          [maxLat, minLon],
          [minLat, minLon],
        ];
        viewportCells = h3.polygonToCells(bboxLoop, H3_RESOLUTION, false);
        if (viewportCells.length === 0) {
          viewportCells = h3.gridDisk(centerCell, 2);
        }

        const { data, error } = await adminClient.rpc("get_map_snapshot_cells", {
          p_cells: viewportCells.slice(0, 5000),
          p_region_res5: null,
          p_caller_id: effectiveCaller,
        });
        if (error) {
          return errorResponse("db_query_failed", error.message, 500);
        }
        for (const r of (data ?? []) as DbSnapshotRow[]) {
          rowsByCell.set(r.h3_id, r);
        }
      } else {
        // Wide zoom: use PostGIS GiST index on territories.center so we never enumerate 100k neutral cells
        const { data, error } = await adminClient.rpc("get_map_hexes_bbox", {
          p_min_lat: minLat,
          p_min_lon: minLon,
          p_max_lat: maxLat,
          p_max_lon: maxLon,
          p_caller_id: effectiveCaller,
        });
        if (error) {
          return errorResponse("postgis_bbox_failed", error.message, 500);
        }
        for (const r of (data ?? []) as DbSnapshotRow[]) {
          rowsByCell.set(r.h3_id, r);
        }
      }

      const nowIso = new Date().toISOString();
      const occupiedContractCells = Array.from(rowsByCell.values()).map((r) =>
        toContractCell(r)
      );

      const snapshot = {
        region_id: `pilot:${regionId}:v1`,
        as_of: nowIso,
        cursor: `ts_${Date.now()}`,
        h3_resolution: H3_RESOLUTION,
        cells: occupiedContractCells,
      };

      if (format === "snapshot") {
        return jsonResponse(snapshot);
      }

      // Build GeoJSON FeatureCollection for Mapbox GeoJsonSource
      const cellSetForGeoJson =
        includeNeutral && viewportCells.length > 0 && viewportCells.length <= MAX_NEUTRAL_CELLS
          ? Array.from(new Set([...viewportCells, ...rowsByCell.keys()]))
          : Array.from(rowsByCell.keys());

      const features = cellSetForGeoJson.map((cid) =>
        toGeoJsonFeature(cid, rowsByCell.get(cid))
      );

      const geojson = {
        type: "FeatureCollection" as const,
        features,
      };

      if (format === "geojson") {
        return jsonResponse(geojson);
      }

      return jsonResponse({
        ok: true,
        snapshot,
        geojson,
        meta: {
          center_cell: centerCell,
          parent_res5: regionId,
          total_features: features.length,
          occupied_or_masked_count: rowsByCell.size,
          dense_neutral_grid_included:
            includeNeutral && viewportCells.length > 0 && viewportCells.length <= MAX_NEUTRAL_CELLS,
        },
      });
    }

    // -------------------------------------------------------------------------
    // 3. GET /regions/:regionId/cells (Strict contracts/map-snapshot.schema.json)
    // -------------------------------------------------------------------------
    const regionMatch = path.match(/^\/regions\/([^/]+)\/cells$/);
    if (req.method === "GET" && regionMatch) {
      const rawRegion = decodeURIComponent(regionMatch[1]);
      // Support either raw H3 res5 (e.g. "85209a0bfffffff") or versioned ("pilot:85209a0bfffffff:v1")
      const extractedH3 = rawRegion.includes(":") ? rawRegion.split(":")[1] : rawRegion;

      if (!/^[0-9a-f]{15,16}$/i.test(extractedH3)) {
        return errorResponse("invalid_region_id", "Region must carry a valid H3 Res-5 hex ID.", 400);
      }

      const { data, error } = await adminClient.rpc("get_map_snapshot_cells", {
        p_cells: null,
        p_region_res5: extractedH3.toLowerCase(),
        p_caller_id: callerId,
      });

      if (error) {
        return errorResponse("region_query_failed", error.message, 500);
      }

      const rows = (data ?? []) as DbSnapshotRow[];
      const nowIso = new Date().toISOString();

      // Exact schema of contracts/map-snapshot.schema.json (additionalProperties: false)
      return jsonResponse({
        region_id: rawRegion.includes(":") ? rawRegion : `pilot:${extractedH3.toLowerCase()}:v1`,
        as_of: nowIso,
        cursor: `v1_${Date.now()}`,
        h3_resolution: H3_RESOLUTION,
        cells: rows.map((r) => toContractCell(r)),
      });
    }

    // -------------------------------------------------------------------------
    // 4. GET /cells/:cellId (Single Hex Inspector + Neighbors + Capture Math)
    // -------------------------------------------------------------------------
    const cellMatch = path.match(/^\/cells\/([0-9a-fA-F]{15,16})$/);
    if (req.method === "GET" && cellMatch) {
      const cellId = cellMatch[1].toLowerCase();
      if (!h3.isValidCell(cellId) || h3.getResolution(cellId) !== H3_RESOLUTION) {
        return errorResponse(
          "invalid_cell_id",
          `Cell must be a valid H3 Resolution-${H3_RESOLUTION} index.`,
          400,
        );
      }

      const [{ data: detail }, { data: snapRows }] = await Promise.all([
        userClient.rpc("get_cell_detail", { p_cell_id: cellId }),
        adminClient.rpc("get_map_snapshot_cells", {
          p_cells: [cellId],
          p_region_res5: null,
          p_caller_id: callerId,
        }),
      ]);

      const [lat, lng] = h3.cellToLatLng(cellId);
      const row = ((snapRows ?? []) as DbSnapshotRow[])[0];

      return jsonResponse({
        ok: true,
        cell_id: cellId,
        h3_resolution: H3_RESOLUTION,
        parent_res5: h3.cellToParent(cellId, PARENT_RESOLUTION),
        center: { lat: Number(lat.toFixed(6)), lng: Number(lng.toFixed(6)) },
        neighbors: h3.gridDisk(cellId, 1).filter((n) => n !== cellId),
        detail,
        geojson_feature: toGeoJsonFeature(cellId, row),
      });
    }

    // -------------------------------------------------------------------------
    // 5. POST /route-preview (Mapbox Walking Directions -> H3 Hex Conquest Plan)
    // -------------------------------------------------------------------------
    if (req.method === "POST" && path === "/route-preview") {
      const body = await req.json();
      const origin = body?.origin; // [lat, lon]
      const destination = body?.destination; // [lat, lon]
      const weightKg = Number(body?.weight_kg ?? 70);
      const heightCm = Number(body?.height_cm ?? 172);
      const paceSpeedMps = Number(body?.speed_mps ?? 1.45);
      const mapboxToken =
        body?.mapbox_token ||
        req.headers.get("x-mapbox-token") ||
        Deno.env.get("MAPBOX_ACCESS_TOKEN") ||
        "";

      if (
        !Array.isArray(origin) ||
        !Array.isArray(destination) ||
        origin.length < 2 ||
        destination.length < 2
      ) {
        return errorResponse(
          "invalid_coordinates",
          "Provide origin: [lat, lon] and destination: [lat, lon].",
          400,
        );
      }

      const [lat1, lon1] = [Number(origin[0]), Number(origin[1])];
      const [lat2, lon2] = [Number(destination[0]), Number(destination[1])];

      let routeCoordsLngLat: [number, number][] = [];
      let distanceM = 0;
      let durationS = 0;
      let providerUsed: "mapbox_directions_v5" | "geodesic_fallback" = "geodesic_fallback";

      if (mapboxToken && mapboxToken.startsWith("pk.")) {
        try {
          const mbUrl =
            `https://api.mapbox.com/directions/v5/mapbox/walking/` +
            `${lon1},${lat1};${lon2},${lat2}?geometries=geojson&overview=full&steps=false&access_token=${encodeURIComponent(mapboxToken)}`;
          const mbRes = await fetch(mbUrl);
          if (mbRes.ok) {
            const mbJson = await mbRes.json();
            const route = mbJson?.routes?.[0];
            if (route?.geometry?.coordinates?.length >= 2) {
              routeCoordsLngLat = route.geometry.coordinates;
              distanceM = Math.round(Number(route.distance));
              durationS = Math.round(Number(route.duration));
              providerUsed = "mapbox_directions_v5";
            }
          }
        } catch (_err) {
          // Graceful fallback to geodesic interpolation
        }
      }

      if (routeCoordsLngLat.length < 2) {
        const directDist = haversineMeters(lat1, lon1, lat2, lon2);
        const stepsCount = Math.max(8, Math.min(200, Math.ceil(directDist / 25)));
        for (let i = 0; i <= stepsCount; i++) {
          const t = i / stepsCount;
          routeCoordsLngLat.push([
            Number((lon1 + (lon2 - lon1) * t).toFixed(6)),
            Number((lat1 + (lat2 - lat1) * t).toFixed(6)),
          ]);
        }
        distanceM = Math.round(directDist);
        durationS = Math.round(directDist / Math.max(0.8, paceSpeedMps));
      }

      // Project walking polyline onto ordered unique H3 Resolution-9 cells
      const traversedCells: string[] = [];
      const seen = new Set<string>();
      let prevCell: string | null = null;

      for (const [lng, lat] of routeCoordsLngLat) {
        const c = h3.latLngToCell(lat, lng, H3_RESOLUTION);
        if (prevCell && prevCell !== c) {
          try {
            const lineCells = h3.gridPathCells(prevCell, c);
            for (const lc of lineCells) {
              if (!seen.has(lc)) {
                seen.add(lc);
                traversedCells.push(lc);
              }
            }
          } catch (_e) {
            if (!seen.has(c)) {
              seen.add(c);
              traversedCells.push(c);
            }
          }
        } else if (!seen.has(c)) {
          seen.add(c);
          traversedCells.push(c);
        }
        prevCell = c;
      }

      const { data: snapData } = await adminClient.rpc("get_map_snapshot_cells", {
        p_cells: traversedCells,
        p_region_res5: null,
        p_caller_id: callerId,
      });

      const snapMap = new Map<string, DbSnapshotRow>();
      for (const r of (snapData ?? []) as DbSnapshotRow[]) {
        snapMap.set(r.h3_id, r);
      }

      const strideM = (heightCm * 0.415) / 100;
      const estimatedSteps = Math.round(distanceM / Math.max(0.45, strideM));
      const met = metForSpeedMps(distanceM / Math.max(1, durationS));
      const estimatedKcal = Number(
        (((met * 3.5 * weightKg) / 200) * (durationS / 60)).toFixed(2)
      );

      let neutralCount = 0;
      let rivalCount = 0;
      let mineCount = 0;
      let maskedCount = 0;

      const hexFeatures = traversedCells.map((cid) => {
        const f = toGeoJsonFeature(cid, snapMap.get(cid));
        if (f.properties.state === "neutral") neutralCount++;
        else if (f.properties.state === "rival") rivalCount++;
        else if (f.properties.state === "mine") mineCount++;
        else if (f.properties.state === "masked") maskedCount++;
        return f;
      });

      return jsonResponse({
        ok: true,
        provider: providerUsed,
        summary: {
          distance_m: distanceM,
          duration_s: durationS,
          estimated_steps: estimatedSteps,
          estimated_calories_kcal: estimatedKcal,
          met_used: met,
          total_hexes_traversed: traversedCells.length,
          neutral_hexes: neutralCount,
          rival_hexes: rivalCount,
          owned_hexes: mineCount,
          masked_hexes: maskedCount,
        },
        route_geojson: {
          type: "Feature",
          properties: { provider: providerUsed, distance_m: distanceM, duration_s: durationS },
          geometry: {
            type: "LineString",
            coordinates: routeCoordsLngLat,
          },
        },
        hexes_geojson: {
          type: "FeatureCollection",
          features: hexFeatures,
        },
      });
    }

    // -------------------------------------------------------------------------
    // 6. POST /sessions/sync | /sessions/submit (Workout + Referee Claim Sync)
    // -------------------------------------------------------------------------
    if (req.method === "POST" && (path === "/sessions/sync" || path === "/sessions/submit")) {
      if (!callerId) {
        return errorResponse(
          "unauthenticated",
          "Sign in with Supabase Auth (Bearer token) to submit competitive cell claims.",
          401,
        );
      }

      const body = await req.json();
      const batchUuid: string = body?.batch_uuid ?? crypto.randomUUID();
      const sessionId: string = body?.session_id ?? batchUuid;
      const clientVersion: string = body?.client_version ?? "terrasteps-flutter/0.3.0";
      const rawCells: Array<Record<string, unknown>> = Array.isArray(body?.cells) ? body.cells : [];

      // Enrich each cell visit with server-verified parent_res5 & H3 centroid if omitted
      const enrichedCells = rawCells.map((c) => {
        const cid = String(c.cell_id ?? c.h3_index ?? "").toLowerCase();
        if (h3.isValidCell(cid)) {
          const [lat, lng] = h3.cellToLatLng(cid);
          return {
            cell_id: cid,
            parent_res5: h3.cellToParent(cid, PARENT_RESOLUTION),
            lat: c.lat ?? lat,
            lng: c.lng ?? lng,
            steps: Math.round(Number(c.steps ?? c.steps_in_hex ?? 0)),
            distance_m: Math.round(Number(c.distance_m ?? c.distance_in_hex_m ?? 0)),
            dwell_s: Math.round(Number(c.dwell_s ?? c.dwell_time_sec ?? 0)),
            fix_count: Math.round(Number(c.fix_count ?? 5)),
            mean_accuracy_m: Number(c.mean_accuracy_m ?? 6.5),
            max_speed_mps: Number(c.max_speed_mps ?? 1.8),
            window_start: c.window_start,
            window_end: c.window_end,
          };
        }
        return c;
      });

      // Execute authoritative PostgreSQL Referee & Territory transaction as caller
      let claimResult: Record<string, unknown> = {
        ok: true,
        results: [],
        newly_owned: 0,
        server_time: new Date().toISOString(),
      };

      if (enrichedCells.length > 0) {
        const { data: rpcOut, error: rpcErr } = await userClient.rpc("claim_cells", {
          p_batch_uuid: batchUuid,
          p_cells: enrichedCells,
          p_client_version: clientVersion,
        });
        if (rpcErr) {
          return errorResponse("claim_cells_failed", rpcErr.message, 400);
        }
        claimResult = (rpcOut ?? {}) as Record<string, unknown>;

        // Populate PostGIS centroids on newly claimed/captured territories
        const centroidsPayload = enrichedCells
          .filter((c) => typeof c.cell_id === "string" && h3.isValidCell(String(c.cell_id)))
          .map((c) => {
            const [lat, lng] = h3.cellToLatLng(String(c.cell_id));
            return { cell_id: c.cell_id, lat, lng };
          });

        if (centroidsPayload.length > 0) {
          await adminClient.rpc("upsert_territory_centroids", {
            p_centroids: centroidsPayload,
          });
        }
      }

      // Derive BatchReceipt contract state & human-readable reasons
      const perCellResults = Array.isArray(claimResult.results)
        ? (claimResult.results as Array<Record<string, unknown>>)
        : [];
      const acceptedCells = perCellResults.filter((r) => r.outcome !== "rejected");
      const rejectedCells = perCellResults.filter((r) => r.outcome === "rejected");

      let receiptState: "accepted" | "partial" | "rejected" = "accepted";
      if (perCellResults.length > 0 && acceptedCells.length === 0) {
        receiptState = "rejected";
      } else if (rejectedCells.length > 0) {
        receiptState = "partial";
      }

      const reasons = rejectedCells.map((r) => ({
        code: mapRejectReasonToContractCode(String(r.reason ?? "")),
        message: humanizeRejectReason(String(r.reason ?? "")),
        sequence: null,
      }));

      // Record private workout fitness session log (Plan §19 private by default)
      if (body?.workout) {
        const w = body.workout;
        await userClient.from("workout_sessions_log").upsert(
          {
            session_id: sessionId,
            user_id: callerId,
            title: String(w.title ?? "TerraSteps Session"),
            started_at: w.started_at ?? new Date().toISOString(),
            ended_at: w.ended_at ?? new Date().toISOString(),
            active_duration_ms: Math.max(0, Math.round(Number(w.active_duration_ms ?? 0))),
            elapsed_duration_ms: Math.max(0, Math.round(Number(w.elapsed_duration_ms ?? 0))),
            measured_steps: Math.max(0, Math.round(Number(w.measured_steps ?? 0))),
            estimated_steps: Math.max(0, Math.round(Number(w.estimated_steps ?? 0))),
            distance_m: Math.max(0, Math.round(Number(w.distance_m ?? 0))),
            calories_kcal: Math.max(0, Number(w.calories_kcal ?? 0)),
            avg_met: Math.max(1, Number(w.avg_met ?? 3.5)),
            cells_visited: enrichedCells.length,
            cells_claimed: Number(claimResult.newly_owned ?? 0),
            gpx_storage_path: w.gpx_storage_path ?? null,
            gpx_sha256: w.gpx_sha256 ?? null,
            drive_asset_id: w.drive_asset_id ?? null,
            batch_uuid: batchUuid,
            sync_state:
              receiptState === "accepted"
                ? "verified"
                : receiptState === "partial"
                  ? "partial"
                  : "rejected",
          },
          { onConflict: "session_id" },
        );
      }

      const evaluatedAt = new Date().toISOString();
      const batchReceipt = {
        receipt_id: batchUuid,
        idempotency_key: String(body?.idempotency_key ?? batchUuid),
        state: receiptState,
        credited_minutes: Math.round(
          acceptedCells.reduce((acc, _c, idx) => acc + Number(enrichedCells[idx]?.dwell_s ?? 0), 0) / 60
        ),
        recorded_minutes: Math.round(
          Number(body?.workout?.active_duration_ms ?? 0) / 60000
        ),
        cells_affected: acceptedCells.map((r) => String(r.cell_id)),
        evaluated_at: evaluatedAt,
        reasons,
        risk_state: "normal",
      };

      return jsonResponse({
        ok: true,
        receipt: batchReceipt,
        claim_engine: claimResult,
      });
    }

    return errorResponse("not_found", `Unknown Map API route: ${req.method} ${path}`, 404);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return errorResponse("internal_error", msg, 500);
  }
});

function mapRejectReasonToContractCode(reason: string): string {
  switch (reason) {
    case "poor_gps_accuracy":
      return "accuracy_too_low";
    case "implausible_speed":
    case "implausible_avg_speed":
    case "distance_without_steps":
    case "teleport_between_cells":
      return "implausible_speed";
    case "stale_window":
      return "evidence_expired";
    case "inverted_window":
    case "future_window":
    case "dwell_exceeds_window":
      return "non_monotonic";
    default:
      return "cell_attribution_withheld";
  }
}

function humanizeRejectReason(reason: string): string {
  switch (reason) {
    case "below_min_steps":
      return "Keep walking inside this hex a little longer before it can be claimed.";
    case "below_min_distance":
      return "Not enough ground covered inside this hex yet.";
    case "below_min_dwell":
      return "Stay active inside this hex a bit longer to establish presence.";
    case "too_few_fixes":
      return "Waiting for a few more clear GPS readings inside this hex.";
    case "poor_gps_accuracy":
      return "GPS signal was too uncertain here; personal steps still count.";
    case "implausible_speed":
    case "implausible_avg_speed":
    case "distance_without_steps":
      return "Movement looked faster than walking or running, so territory credit was withheld.";
    case "steps_without_distance":
      return "Steps were recorded without matching outdoor movement; saved to personal fitness only.";
    case "teleport_between_cells":
      return "Location jumped suddenly between distant areas, so competitive credit was paused.";
    default:
      return "This segment was saved to your personal walk log, without competitive territory credit.";
  }
}
