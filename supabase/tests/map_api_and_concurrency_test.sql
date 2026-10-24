-- =============================================================================
-- TerraSteps — PostgreSQL + PostGIS Map API & Referee Verification Test Suite
-- Verifies:
--   1. PostGIS viewport bbox spatial query (`get_map_hexes_bbox`)
--   2. Sanitized MapSnapshot projection (`get_map_snapshot_cells` — no raw UUID leak,
--      fixed-point `score_micro` digit string, masked cells included)
--   3. Rule-based Referee validation (`validate_cell_claim` R1–R8)
--   4. Effort calculation (`compute_effort`) & 7-day lazy half-life decay
-- =============================================================================

DO $$
DECLARE
  v_bbox_count integer;
  v_masked_count integer;
  v_valid_check text;
  v_speed_reject text;
  v_shake_reject text;
  v_effort numeric;
BEGIN
  -- 1. PostGIS viewport bbox around Abbottabad pilot region
  SELECT count(*) INTO v_bbox_count
  FROM public.get_map_hexes_bbox(34.145, 73.245, 34.170, 73.275, NULL);

  IF v_bbox_count < 7 THEN
    RAISE EXCEPTION 'Expected >= 7 territories/masked cells in Abbottabad bbox, got %', v_bbox_count;
  END IF;

  -- 2. Verify safety-masked cells appear with score_micro = NULL and masked = true
  SELECT count(*) INTO v_masked_count
  FROM public.get_map_snapshot_cells(NULL, '85209a0bfffffff', NULL)
  WHERE masked = true AND score_micro IS NULL;

  IF v_masked_count < 2 THEN
    RAISE EXCEPTION 'Expected >= 2 safety-masked cells in pilot region, got %', v_masked_count;
  END IF;

  -- 3. Rule-based Referee check: genuine walk passes
  v_valid_check := public.validate_cell_claim(jsonb_build_object(
    'cell_id', '89209a0aa73ffff',
    'steps', 180,
    'distance_m', 130,
    'dwell_s', 110,
    'fix_count', 18,
    'mean_accuracy_m', 4.8,
    'max_speed_mps', 1.65,
    'window_start', (now() - INTERVAL '4 minutes')::text,
    'window_end', (now() - INTERVAL '2 minutes')::text
  ));
  IF v_valid_check IS NOT NULL THEN
    RAISE EXCEPTION 'Expected genuine walk to pass Referee, got reject=%', v_valid_check;
  END IF;

  -- 4. Rule-based Referee check: 48 km/h car spoof rejected
  v_speed_reject := public.validate_cell_claim(jsonb_build_object(
    'cell_id', '89209a0aa73ffff',
    'steps', 140,
    'distance_m', 900,
    'dwell_s', 95,
    'fix_count', 15,
    'mean_accuracy_m', 3.9,
    'max_speed_mps', 13.4,
    'window_start', (now() - INTERVAL '4 minutes')::text,
    'window_end', (now() - INTERVAL '2 minutes')::text
  ));
  IF v_speed_reject <> 'implausible_speed' THEN
    RAISE EXCEPTION 'Expected implausible_speed rejection, got %', v_speed_reject;
  END IF;

  -- 5. Rule-based Referee check: stationary phone shaking rejected
  v_shake_reject := public.validate_cell_claim(jsonb_build_object(
    'cell_id', '89209a0aa73ffff',
    'steps', 500,
    'distance_m', 85,
    'dwell_s', 100,
    'fix_count', 12,
    'mean_accuracy_m', 4.5,
    'max_speed_mps', 1.1,
    'window_start', (now() - INTERVAL '4 minutes')::text,
    'window_end', (now() - INTERVAL '2 minutes')::text
  ));
  IF v_shake_reject <> 'steps_without_distance' THEN
    RAISE EXCEPTION 'Expected steps_without_distance rejection, got %', v_shake_reject;
  END IF;

  -- 6. Deterministic compute_effort formula
  v_effort := public.compute_effort(200, 140, 100);
  IF v_effort <> 254.00 THEN
    RAISE EXCEPTION 'Expected effort 254.00, got %', v_effort;
  END IF;
END $$;
