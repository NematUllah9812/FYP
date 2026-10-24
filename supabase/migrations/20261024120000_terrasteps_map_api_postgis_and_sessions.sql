-- =============================================================================
-- TerraSteps — 30% Milestone Migration
-- Map API (PostGIS Spatial Queries + Sanitized Projections), Masked Cells,
-- Private Workout Session Ledger, GPX Storage Bucket & Partition Rollforward
-- =============================================================================

SET search_path TO public, extensions;

-- 1. Ensure monthly partitions on claim_events cover late 2026 through Q1 2027
DO $$
DECLARE
  m date;
  v_next date;
  v_part text;
BEGIN
  FOREACH m IN ARRAY ARRAY[
    DATE '2026-11-01',
    DATE '2026-12-01',
    DATE '2027-01-01',
    DATE '2027-02-01',
    DATE '2027-03-01'
  ]
  LOOP
    v_next := (m + INTERVAL '1 month')::date;
    v_part := 'claim_events_' || to_char(m, 'YYYY_MM');
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = v_part
    ) THEN
      EXECUTE format(
        'CREATE TABLE public.%I PARTITION OF public.claim_events FOR VALUES FROM (%L) TO (%L)',
        v_part, m, v_next
      );
    END IF;
  END LOOP;
END $$;

-- 2. PostGIS GiST index on territories.center for sub-millisecond viewport bbox queries
CREATE INDEX IF NOT EXISTS territories_center_gist_idx
  ON public.territories USING gist (center);

-- 3. Safety-masked H3 cells (water, high_speed_road, restricted, reported_hazard)
--    Matches contracts/map-snapshot.schema.json §Cell.masked / §Cell.mask_reason
CREATE TABLE IF NOT EXISTS public.masked_cells (
  cell_id      text PRIMARY KEY CHECK (cell_id ~ '^[0-9a-f]{15,16}$'),
  resolution   smallint NOT NULL DEFAULT 9 CHECK (resolution = 9),
  parent_res5  text NOT NULL,
  mask_reason  text NOT NULL CHECK (mask_reason IN ('water', 'high_speed_road', 'restricted', 'reported_hazard')),
  center       extensions.geography(Point, 4326),
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS masked_cells_parent_idx ON public.masked_cells (parent_res5);
CREATE INDEX IF NOT EXISTS masked_cells_center_gist_idx ON public.masked_cells USING gist (center);

ALTER TABLE public.masked_cells ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'masked_cells' AND policyname = 'masked cells readable by all'
  ) THEN
    CREATE POLICY "masked cells readable by all"
      ON public.masked_cells FOR SELECT
      TO public
      USING (true);
  END IF;
END $$;

-- 4. Private Fitness Workout Sessions Ledger
--    Plan §19 / AGENTS.md: Fitness history is private by default; RLS enforces auth.uid() = user_id.
CREATE TABLE IF NOT EXISTS public.workout_sessions_log (
  session_id          uuid PRIMARY KEY,
  user_id             uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title               text NOT NULL DEFAULT 'Outdoor Walk',
  started_at          timestamptz NOT NULL,
  ended_at            timestamptz,
  active_duration_ms  bigint NOT NULL DEFAULT 0 CHECK (active_duration_ms >= 0),
  elapsed_duration_ms bigint NOT NULL DEFAULT 0 CHECK (elapsed_duration_ms >= 0),
  measured_steps      integer NOT NULL DEFAULT 0 CHECK (measured_steps >= 0),
  estimated_steps     integer NOT NULL DEFAULT 0 CHECK (estimated_steps >= 0),
  distance_m          integer NOT NULL DEFAULT 0 CHECK (distance_m >= 0),
  calories_kcal       numeric(9, 2) NOT NULL DEFAULT 0 CHECK (calories_kcal >= 0),
  avg_met             numeric(4, 2) NOT NULL DEFAULT 1.0 CHECK (avg_met >= 0),
  cells_visited       integer NOT NULL DEFAULT 0 CHECK (cells_visited >= 0),
  cells_claimed       integer NOT NULL DEFAULT 0 CHECK (cells_claimed >= 0),
  gpx_storage_path    text,
  gpx_sha256          text,
  drive_asset_id      text,
  batch_uuid          uuid,
  sync_state          text NOT NULL DEFAULT 'recorded'
                      CHECK (sync_state IN ('recorded', 'verified', 'partial', 'rejected')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workout_sessions_user_idx
  ON public.workout_sessions_log (user_id, started_at DESC);

ALTER TABLE public.workout_sessions_log ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'workout_sessions_log' AND policyname = 'users read own workouts'
  ) THEN
    CREATE POLICY "users read own workouts"
      ON public.workout_sessions_log FOR SELECT
      TO authenticated
      USING (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'workout_sessions_log' AND policyname = 'users insert own workouts'
  ) THEN
    CREATE POLICY "users insert own workouts"
      ON public.workout_sessions_log FOR INSERT
      TO authenticated
      WITH CHECK (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'workout_sessions_log' AND policyname = 'users update own workouts'
  ) THEN
    CREATE POLICY "users update own workouts"
      ON public.workout_sessions_log FOR UPDATE
      TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

-- 5. Private GPX Storage Bucket for optional encrypted/authenticated GPX cloud backup
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'gpx-tracks',
  'gpx-tracks',
  false,
  10485760,
  ARRAY['application/gpx+xml', 'application/xml', 'text/xml', 'text/plain']
)
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'users read own gpx tracks'
  ) THEN
    CREATE POLICY "users read own gpx tracks"
      ON storage.objects FOR SELECT
      TO authenticated
      USING (bucket_id = 'gpx-tracks' AND (storage.foldername(name))[1] = auth.uid()::text);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'users upload own gpx tracks'
  ) THEN
    CREATE POLICY "users upload own gpx tracks"
      ON storage.objects FOR INSERT
      TO authenticated
      WITH CHECK (bucket_id = 'gpx-tracks' AND (storage.foldername(name))[1] = auth.uid()::text);
  END IF;
END $$;

-- 6. Helper RPC: Upsert PostGIS geography centroids computed by h3-js in Edge Function
CREATE OR REPLACE FUNCTION public.upsert_territory_centroids(p_centroids jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  v_item jsonb;
  v_updated integer := 0;
  v_rows integer;
BEGIN
  IF current_setting('request.jwt.claims', true)::jsonb->>'role' NOT IN ('service_role', 'authenticated') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_centroids) AS t(value)
  LOOP
    UPDATE public.territories
       SET center = ST_SetSRID(
             ST_MakePoint(
               (v_item->>'lng')::double precision,
               (v_item->>'lat')::double precision
             ),
             4326
           )::extensions.geography
     WHERE cell_id = (v_item->>'cell_id')
       AND center IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_updated := v_updated + v_rows;
  END LOOP;

  RETURN v_updated;
END;
$$;

-- 7. Sanitized Map API RPC: Query owned & masked H3 cells by cell ID list OR region
--    Enforces Plan §19 privacy projection (never leaks raw owner UUIDs in public owner block;
--    formats score_micro as fixed-point digit string x 1e6 for bit-identical replay).
CREATE OR REPLACE FUNCTION public.get_map_snapshot_cells(
  p_cells text[] DEFAULT NULL,
  p_region_res5 text DEFAULT NULL,
  p_caller_id uuid DEFAULT NULL
)
RETURNS TABLE(
  h3_id text,
  parent_res5 text,
  nickname text,
  avatar_ref text,
  kingdom_name text,
  color text,
  influence numeric,
  score_micro text,
  version integer,
  masked boolean,
  mask_reason text,
  is_mine boolean,
  my_influence numeric,
  last_claim_at timestamptz,
  center_lat double precision,
  center_lng double precision
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
  WITH target_territories AS (
    SELECT
      t.cell_id,
      t.parent_res5,
      p.username AS nickname,
      p.avatar_url AS avatar_ref,
      t.name AS kingdom_name,
      COALESCE(t.color, p.faction_color, '#3B82F6') AS color,
      public.current_influence(t.owner_influence, t.influence_at) AS eff_inf,
      t.claim_count AS version,
      (t.owner_id = COALESCE(p_caller_id, auth.uid())) AS is_mine,
      t.last_claim_at,
      CASE WHEN t.center IS NOT NULL THEN ST_Y(t.center::extensions.geometry) ELSE NULL END AS center_lat,
      CASE WHEN t.center IS NOT NULL THEN ST_X(t.center::extensions.geometry) ELSE NULL END AS center_lng
    FROM public.territories t
    JOIN public.profiles p ON p.id = t.owner_id
    WHERE p.is_shadow_banned = false
      AND public.current_influence(t.owner_influence, t.influence_at) >= public.cfg('neutral_floor')
      AND (
        (p_cells IS NOT NULL AND t.cell_id = ANY(p_cells[1:5000]))
        OR (p_cells IS NULL AND p_region_res5 IS NOT NULL AND t.parent_res5 = p_region_res5)
      )
    LIMIT 5000
  ),
  target_masks AS (
    SELECT
      m.cell_id,
      m.parent_res5,
      m.mask_reason,
      CASE WHEN m.center IS NOT NULL THEN ST_Y(m.center::extensions.geometry) ELSE NULL END AS center_lat,
      CASE WHEN m.center IS NOT NULL THEN ST_X(m.center::extensions.geometry) ELSE NULL END AS center_lng
    FROM public.masked_cells m
    WHERE (p_cells IS NOT NULL AND m.cell_id = ANY(p_cells[1:5000]))
       OR (p_cells IS NULL AND p_region_res5 IS NOT NULL AND m.parent_res5 = p_region_res5)
    LIMIT 5000
  ),
  caller_inf AS (
    SELECT
      u.cell_id,
      public.current_influence(u.influence, u.influence_at) AS my_inf
    FROM public.user_cell_influence u
    WHERE u.user_id = COALESCE(p_caller_id, auth.uid())
      AND (
        (p_cells IS NOT NULL AND u.cell_id = ANY(p_cells[1:5000]))
        OR p_cells IS NULL
      )
  )
  SELECT
    COALESCE(tt.cell_id, tm.cell_id) AS h3_id,
    COALESCE(tt.parent_res5, tm.parent_res5) AS parent_res5,
    CASE WHEN tm.cell_id IS NOT NULL THEN NULL ELSE tt.nickname END AS nickname,
    CASE WHEN tm.cell_id IS NOT NULL THEN NULL ELSE tt.avatar_ref END AS avatar_ref,
    CASE WHEN tm.cell_id IS NOT NULL THEN NULL ELSE tt.kingdom_name END AS kingdom_name,
    CASE WHEN tm.cell_id IS NOT NULL THEN '#64748B' ELSE tt.color END AS color,
    CASE WHEN tm.cell_id IS NOT NULL THEN NULL ELSE tt.eff_inf END AS influence,
    CASE
      WHEN tm.cell_id IS NOT NULL OR tt.eff_inf IS NULL THEN NULL
      ELSE round(tt.eff_inf * 1000000)::bigint::text
    END AS score_micro,
    COALESCE(tt.version, 1) AS version,
    (tm.cell_id IS NOT NULL) AS masked,
    tm.mask_reason,
    COALESCE(tt.is_mine, false) AS is_mine,
    ci.my_inf AS my_influence,
    tt.last_claim_at,
    COALESCE(tt.center_lat, tm.center_lat) AS center_lat,
    COALESCE(tt.center_lng, tm.center_lng) AS center_lng
  FROM target_territories tt
  FULL OUTER JOIN target_masks tm ON tm.cell_id = tt.cell_id
  LEFT JOIN caller_inf ci ON ci.cell_id = COALESCE(tt.cell_id, tm.cell_id);
$$;

-- 8. PostGIS Bounding-Box Viewport Query (fast fallback for wide map zooms)
CREATE OR REPLACE FUNCTION public.get_map_hexes_bbox(
  p_min_lat double precision,
  p_min_lon double precision,
  p_max_lat double precision,
  p_max_lon double precision,
  p_caller_id uuid DEFAULT NULL
)
RETURNS TABLE(
  h3_id text,
  parent_res5 text,
  nickname text,
  avatar_ref text,
  kingdom_name text,
  color text,
  influence numeric,
  score_micro text,
  version integer,
  masked boolean,
  mask_reason text,
  is_mine boolean,
  last_claim_at timestamptz,
  center_lat double precision,
  center_lng double precision
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
  WITH bbox AS (
    SELECT ST_MakeEnvelope(p_min_lon, p_min_lat, p_max_lon, p_max_lat, 4326)::extensions.geography AS env
  )
  SELECT
    t.cell_id AS h3_id,
    t.parent_res5,
    p.username AS nickname,
    p.avatar_url AS avatar_ref,
    t.name AS kingdom_name,
    COALESCE(t.color, p.faction_color, '#3B82F6') AS color,
    public.current_influence(t.owner_influence, t.influence_at) AS influence,
    round(public.current_influence(t.owner_influence, t.influence_at) * 1000000)::bigint::text AS score_micro,
    t.claim_count AS version,
    false AS masked,
    NULL::text AS mask_reason,
    (t.owner_id = COALESCE(p_caller_id, auth.uid())) AS is_mine,
    t.last_claim_at,
    ST_Y(t.center::extensions.geometry) AS center_lat,
    ST_X(t.center::extensions.geometry) AS center_lng
  FROM public.territories t
  JOIN public.profiles p ON p.id = t.owner_id
  CROSS JOIN bbox
  WHERE t.center IS NOT NULL
    AND ST_Intersects(t.center, bbox.env)
    AND p.is_shadow_banned = false
    AND public.current_influence(t.owner_influence, t.influence_at) >= public.cfg('neutral_floor')
  UNION ALL
  SELECT
    m.cell_id AS h3_id,
    m.parent_res5,
    NULL::text AS nickname,
    NULL::text AS avatar_ref,
    NULL::text AS kingdom_name,
    '#64748B'::text AS color,
    NULL::numeric AS influence,
    NULL::text AS score_micro,
    1 AS version,
    true AS masked,
    m.mask_reason,
    false AS is_mine,
    m.created_at AS last_claim_at,
    ST_Y(m.center::extensions.geometry) AS center_lat,
    ST_X(m.center::extensions.geometry) AS center_lng
  FROM public.masked_cells m
  CROSS JOIN bbox
  WHERE m.center IS NOT NULL
    AND ST_Intersects(m.center, bbox.env)
  LIMIT 5000;
$$;

-- 9. Private Fitness Summary & User Stats RPC (strictly scoped to caller)
CREATE OR REPLACE FUNCTION public.get_my_fitness_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
  v_recent jsonb;
  v_kcal numeric;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT id, username, display_name, faction_color, cells_owned,
         total_steps, total_distance_m, total_effort,
         current_streak_d, longest_streak_d, home_region_h3
    INTO v_profile
    FROM public.profiles
   WHERE id = v_uid;

  SELECT COALESCE(SUM(calories_kcal), 0)
    INTO v_kcal
    FROM public.workout_sessions_log
   WHERE user_id = v_uid;

  SELECT COALESCE(jsonb_agg(row_to_json(w)), '[]'::jsonb)
    INTO v_recent
    FROM (
      SELECT session_id, title, started_at, ended_at, active_duration_ms,
             measured_steps, distance_m, calories_kcal, avg_met,
             cells_visited, cells_claimed, sync_state, gpx_storage_path
        FROM public.workout_sessions_log
       WHERE user_id = v_uid
       ORDER BY started_at DESC
       LIMIT 10
    ) w;

  RETURN jsonb_build_object(
    'ok', true,
    'profile', row_to_json(v_profile),
    'lifetime_calories_kcal', v_kcal,
    'recent_sessions', v_recent
  );
END;
$$;

-- 10. Seed active Abbottabad pilot territories & safety-masked hexes so the 30%
--     Milestone Map API & Mapbox SDK render rich multi-faction state immediately.
DO $$
DECLARE
  v_walker_a uuid := 'cda70d49-2d70-4776-bd5e-2d346f8a4170';
  v_walker_b uuid := 'cc017c6c-a83c-4a1f-b753-18d1345c1b85';
  v_walker_c uuid := '8dc6cdf3-7149-4a69-bc1c-3b5baf44ba57';
BEGIN
  -- Give distinct faction colors & display names to the 3 pilot profiles if still default
  UPDATE public.profiles
     SET display_name = COALESCE(display_name, 'Nemat (Pilot Walker)'),
         faction_color = '#10B981',
         home_region_h3 = '85209a0bfffffff'
   WHERE id = v_walker_a;

  UPDATE public.profiles
     SET display_name = COALESCE(display_name, 'Northern Vanguard'),
         faction_color = '#F97316',
         home_region_h3 = '85209a0bfffffff'
   WHERE id = v_walker_b;

  UPDATE public.profiles
     SET display_name = COALESCE(display_name, 'pine_strider'),
         faction_color = '#8B5CF6',
         home_region_h3 = '85209a0bfffffff'
   WHERE id = v_walker_c;

  -- Seed active territories around Abbottabad pilot grid (Res 9, parent 85209a0bfffffff)
  INSERT INTO public.territories
    (cell_id, resolution, parent_res5, owner_id, owner_influence, influence_at, name, color, claimed_at, last_claim_at, claim_count, center)
  VALUES
    ('89209a0aa73ffff', 9, '85209a0bfffffff', v_walker_a, 420.50, now() - INTERVAL '2 hours', 'Campus Citadel', '#10B981', now() - INTERVAL '3 days', now() - INTERVAL '2 hours', 6, ST_SetSRID(ST_MakePoint(73.259642, 34.158672), 4326)::extensions.geography),
    ('89209a0aa0fffff', 9, '85209a0bfffffff', v_walker_a, 315.20, now() - INTERVAL '4 hours', 'Pine Ridge Gate', '#10B981', now() - INTERVAL '2 days', now() - INTERVAL '4 hours', 3, ST_SetSRID(ST_MakePoint(73.259936, 34.161962), 4326)::extensions.geography),
    ('89209a0aa0bffff', 9, '85209a0bfffffff', v_walker_a, 248.00, now() - INTERVAL '6 hours', 'West Trailhead', '#10B981', now() - INTERVAL '1 day', now() - INTERVAL '6 hours', 2, ST_SetSRID(ST_MakePoint(73.256271, 34.160510), 4326)::extensions.geography),
    ('89209a0aa77ffff', 9, '85209a0bfffffff', v_walker_b, 380.75, now() - INTERVAL '3 hours', 'East Watchtower', '#F97316', now() - INTERVAL '2 days', now() - INTERVAL '3 hours', 4, ST_SetSRID(ST_MakePoint(73.263306, 34.160123), 4326)::extensions.geography),
    ('89209a0aa63ffff', 9, '85209a0bfffffff', v_walker_b, 275.40, now() - INTERVAL '5 hours', 'Creek Crossing', '#F97316', now() - INTERVAL '1 day', now() - INTERVAL '5 hours', 2, ST_SetSRID(ST_MakePoint(73.263012, 34.156833), 4326)::extensions.geography),
    ('89209a0aa6bffff', 9, '85209a0bfffffff', v_walker_c, 290.00, now() - INTERVAL '8 hours', 'South Orchard', '#8B5CF6', now() - INTERVAL '2 days', now() - INTERVAL '8 hours', 3, ST_SetSRID(ST_MakePoint(73.262718, 34.153542), 4326)::extensions.geography),
    ('89209a0aa47ffff', 9, '85209a0bfffffff', v_walker_c, 195.60, now() - INTERVAL '10 hours', 'Hilltop Steps', '#8B5CF6', now() - INTERVAL '1 day', now() - INTERVAL '10 hours', 1, ST_SetSRID(ST_MakePoint(73.255977, 34.157220), 4326)::extensions.geography)
  ON CONFLICT (cell_id) DO UPDATE
    SET owner_influence = EXCLUDED.owner_influence,
        influence_at = EXCLUDED.influence_at,
        last_claim_at = EXCLUDED.last_claim_at,
        center = EXCLUDED.center;

  -- Sync user_cell_influence rows so contenders & effort_to_capture match
  INSERT INTO public.user_cell_influence (user_id, cell_id, influence, influence_at, visits, last_seen)
  VALUES
    (v_walker_a, '89209a0aa73ffff', 420.50, now() - INTERVAL '2 hours', 6, now() - INTERVAL '2 hours'),
    (v_walker_a, '89209a0aa0fffff', 315.20, now() - INTERVAL '4 hours', 3, now() - INTERVAL '4 hours'),
    (v_walker_a, '89209a0aa0bffff', 248.00, now() - INTERVAL '6 hours', 2, now() - INTERVAL '6 hours'),
    (v_walker_b, '89209a0aa77ffff', 380.75, now() - INTERVAL '3 hours', 4, now() - INTERVAL '3 hours'),
    (v_walker_b, '89209a0aa63ffff', 275.40, now() - INTERVAL '5 hours', 2, now() - INTERVAL '5 hours'),
    (v_walker_c, '89209a0aa6bffff', 290.00, now() - INTERVAL '8 hours', 3, now() - INTERVAL '8 hours'),
    (v_walker_c, '89209a0aa47ffff', 195.60, now() - INTERVAL '10 hours', 1, now() - INTERVAL '10 hours')
  ON CONFLICT (user_id, cell_id) DO UPDATE
    SET influence = EXCLUDED.influence,
        influence_at = EXCLUDED.influence_at,
        last_seen = EXCLUDED.last_seen;

  -- Recompute cells_owned counts accurately
  UPDATE public.profiles p
     SET cells_owned = (SELECT count(*) FROM public.territories t WHERE t.owner_id = p.id)
   WHERE p.id IN (v_walker_a, v_walker_b, v_walker_c);

  -- Seed 2 safety-masked cells (high_speed_road & restricted) to demonstrate Plan §11 safety masking
  INSERT INTO public.masked_cells (cell_id, resolution, parent_res5, mask_reason, center, notes)
  VALUES
    ('89209a0aa57ffff', 9, '85209a0bfffffff', 'high_speed_road', ST_SetSRID(ST_MakePoint(73.252607, 34.159059), 4326)::extensions.geography, 'Karakoram Highway arterial corridor — excluded from pedestrian capture'),
    ('89209a081b7ffff', 9, '85209a0bfffffff', 'water', ST_SetSRID(ST_MakePoint(73.259054, 34.152091), 4326)::extensions.geography, 'Seasonal drainage channel — unsafe terrain mask')
  ON CONFLICT (cell_id) DO NOTHING;
END $$;
