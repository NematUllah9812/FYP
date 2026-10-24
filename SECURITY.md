# Security & Secret Hygiene Policy — TerraSteps

1. **Never commit secrets or privileged tokens**:
   - Supabase `service_role` keys or `sb_secret_*` keys
   - Legacy `eyJ...` JWT keys
   - Mapbox secret (`sk.*`) download tokens
   - GitHub Personal Access Tokens (`ghp_*`, `github_pat_*`)
   - Android upload keystores (`*.jks`, `*.keystore`)

2. **Public client configuration**:
   - Only the RLS-enforced Supabase publishable key (`sb_publishable_*`) and public URL may appear in client defaults.
   - Inject Mapbox `pk.*` tokens at runtime or via `--dart-define=MAPBOX_ACCESS_TOKEN=...`.

3. **Shared Supabase Project Safety (`iaoqwxcyjkpvpqwoszih`)**:
   - All TerraSteps migrations are strictly additive (`IF NOT EXISTS` / `CREATE OR REPLACE`).
   - Unrelated tables and storage buckets in the shared database are never modified or dropped.

4. **Privacy & Safety Masking**:
   - Public Map API responses (`MapSnapshot`) strip raw internal user UUIDs unless `viewer_id` matches the caller (`owned_by_caller`), expose effort scores as fixed-point micro-unit strings (`score_micro`), and mask restricted cells (`masked_cells`).
