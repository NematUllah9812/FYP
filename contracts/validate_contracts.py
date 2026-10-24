#!/usr/bin/env python3
"""Validate the Terrastep shared contracts.

Checks two things:
  1. Every schema is a legal JSON Schema (Draft 2020-12).
  2. Realistic valid payloads pass, and the specific defects these contracts
     exist to prevent actually fail.

Run:  python3 contracts/validate_contracts.py
Exit: 0 if every case behaved as expected, 1 otherwise.
"""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

CONTRACTS = Path(__file__).parent

def load(name):
    with open(CONTRACTS / name) as f:
        return json.load(f)

schemas = {}
for name in [
    "tracker-event.schema.json",
    "evidence-batch.schema.json",
    "batch-receipt.schema.json",
    "map-snapshot.schema.json",
]:
    s = load(name)
    Draft202012Validator.check_schema(s)
    schemas[name] = Draft202012Validator(s)
print(f"[ok] 4 schemas are legal Draft 2020-12 JSON Schema")

# ---------------------------------------------------------------- valid cases
VALID = [
    ("tracker-event.schema.json", "session_started", {
        "type": "session_started",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "started_at": "2026-10-09T18:00:00Z",
        "elapsed_ms": 1000,
        "rule_version": "v1",
        "step_counter_baseline": 48210,
        "boot_id": "b9f1c2",
    }),
    ("tracker-event.schema.json", "location_sample", {
        "type": "location_sample",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 11000,
        "captured_at": "2026-10-09T18:00:10Z",
        "latitude": 34.1463,
        "longitude": 73.2116,
        "accuracy_m": 6.4,
        "sampling_state": "moving",
        "provider": "fused",
        "speed_mps": 1.35,
    }),
    ("tracker-event.schema.json", "tracking_interrupted (honest failure)", {
        "type": "tracking_interrupted",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 45000,
        "reason": "os_killed_service",
        "recoverable": False,
        "user_message": "Tracking stopped when the system closed the app. Your walk up to that point is saved.",
    }),
    ("evidence-batch.schema.json", "well-formed batch", {
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "installation_id": "inst-8821",
        "sequence_start": 0,
        "sequence_end": 1,
        "rule_version": "v1",
        "time_anchor": {"elapsed_ms": 1000, "utc": "2026-10-09T18:00:00Z"},
        "samples": [
            {"sequence": 0, "elapsed_ms": 1000, "kind": "location",
             "latitude": 34.1463, "longitude": 73.2116, "accuracy_m": 6.4,
             "provider": "fused"},
            {"sequence": 1, "elapsed_ms": 1000, "kind": "motion",
             "step_delta": 0, "boot_id": "b9f1c2", "motion_class": "still"},
        ],
        "integrity": None,
    }),
    ("batch-receipt.schema.json", "accepted with cap reason", {
        "receipt_id": "814e-9bfe-e80c-a0a033e70001",
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "state": "partial",
        "evaluated_at": "2026-10-09T18:01:05Z",
        "credited_minutes": 6,
        "recorded_minutes": 31,
        "cells_affected": ["8928308280fffff"],
        "reasons": [{"code": "daily_cell_cap_reached",
                     "message": "You have earned the maximum for this area today. "
                                "Your walk still counts toward your fitness history.",
                     "sequence": None}],
        "risk_state": "normal",
    }),
    ("map-snapshot.schema.json", "sparse snapshot with a masked cell", {
        "region_id": "abbottabad-pilot-v1",
        "as_of": "2026-10-09T17:30:00Z",
        "cursor": "cursor-000123",
        "h3_resolution": 9,
        "cells": [
            {"h3_id": "8928308280fffff", "version": 4,
             "owner": {"nickname": "HillWalker", "avatar_ref": None, "kingdom_name": None},
             "score_micro": "8000000", "color": "#4C7EF3", "masked": False,
             "mask_reason": None, "pending": False},
            {"h3_id": "8928308283fffff", "version": 0,
             "owner": None, "score_micro": None, "color": None,
             "masked": True, "mask_reason": "high_speed_road", "pending": False},
        ],
    }),
]

# -------------------------------------------------------------- invalid cases
# Each one is a defect the contracts exist to prevent. If any of these passes,
# the contract is not doing its job.
INVALID = [
    ("map-snapshot.schema.json", "H3 id sent as a JSON number (breaks JS clients)", {
        "region_id": "abbottabad-pilot-v1", "as_of": "2026-10-09T17:30:00Z",
        "cursor": "c1", "h3_resolution": 9,
        "cells": [{"h3_id": 617700169958293503, "version": 1}],
    }),
    ("map-snapshot.schema.json", "score as a float (breaks replay determinism)", {
        "region_id": "r", "as_of": "2026-10-09T17:30:00Z", "cursor": "c1",
        "h3_resolution": 9,
        "cells": [{"h3_id": "8928308280fffff", "version": 1, "score_micro": 8.0}],
    }),
    ("map-snapshot.schema.json", "owner exposes a user id (privacy leak)", {
        "region_id": "r", "as_of": "2026-10-09T17:30:00Z", "cursor": "c1",
        "h3_resolution": 9,
        "cells": [{"h3_id": "8928308280fffff", "version": 1,
                   "owner": {"nickname": "HillWalker", "user_id": "3f4886fa"}}],
    }),
    ("map-snapshot.schema.json", "resolution 10 in a res-9 competition", {
        "region_id": "r", "as_of": "2026-10-09T17:30:00Z", "cursor": "c1",
        "h3_resolution": 10, "cells": [],
    }),
    ("tracker-event.schema.json", "local-time timestamp instead of UTC", {
        "type": "location_sample", "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 1000, "captured_at": "2026-10-09T23:00:00+05:00",
        "latitude": 34.1, "longitude": 73.2, "accuracy_m": 5.0,
        "sampling_state": "moving",
    }),
    ("tracker-event.schema.json", "invented interruption reason (silent gap)", {
        "type": "tracking_interrupted", "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 1000, "reason": "user_walked_away", "recoverable": True,
    }),
    ("tracker-event.schema.json", "accuracy_m of 0 (not a real uncertainty)", {
        "type": "location_sample", "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 1000, "captured_at": "2026-10-09T18:00:00Z",
        "latitude": 34.1, "longitude": 73.2, "accuracy_m": 0,
        "sampling_state": "moving",
    }),
    ("tracker-event.schema.json", "estimated steps placed in the measured field", {
        "type": "session_finished", "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "elapsed_ms": 1000, "finished_at": "2026-10-09T18:30:00Z", "durable": True,
        "totals": {"elapsed_s": 1800, "moving_s": 1700, "paused_s": 100,
                   "distance_m": 2400.5, "steps": 3120.7},
    }),
    ("evidence-batch.schema.json", "motion sample with no boot_id (counter reset invisible)", {
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "installation_id": "inst-1", "sequence_start": 0, "sequence_end": 0,
        "rule_version": "v1",
        "samples": [{"sequence": 0, "elapsed_ms": 10, "kind": "motion", "step_delta": 500}],
    }),
    ("evidence-batch.schema.json", "location sample missing accuracy (no uncertainty bound)", {
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "installation_id": "inst-1", "sequence_start": 0, "sequence_end": 0,
        "rule_version": "v1",
        "samples": [{"sequence": 0, "elapsed_ms": 10, "kind": "location",
                     "latitude": 34.1, "longitude": 73.2}],
    }),
    ("evidence-batch.schema.json", "unbounded batch of 500 samples (no size limit)", {
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "session_id": "3f4886fa-6bfe-81a2-9c3d-f346af5d1225",
        "installation_id": "inst-1", "sequence_start": 0, "sequence_end": 499,
        "rule_version": "v1",
        "samples": [{"sequence": i, "elapsed_ms": i * 10, "kind": "motion",
                     "step_delta": 1, "boot_id": "b1"} for i in range(500)],
    }),
    ("batch-receipt.schema.json", "rejected with no reason (unexplained failure)", {
        "receipt_id": "814e-9bfe-e80c-a0a033e70002",
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "state": "rejected", "evaluated_at": "2026-10-09T18:01:05Z",
        "reasons": [],
    }),
    ("batch-receipt.schema.json", "reason that leaks a detection threshold", {
        "receipt_id": "814e-9bfe-e80c-a0a033e70003",
        "idempotency_key": "b7e0-4d1e-8815-5ce6df9e482c",
        "state": "rejected", "evaluated_at": "2026-10-09T18:01:05Z",
        "reasons": [{"code": "you_are_definitely_cheating", "message": "flagged"}],
    }),
]

failures = 0

print("\n-- valid payloads must be accepted --")
for schema, label, doc in VALID:
    errs = sorted(schemas[schema].iter_errors(doc), key=lambda e: e.path)
    if errs:
        failures += 1
        print(f"[FAIL] {label}\n       {schema}: {errs[0].message}")
    else:
        print(f"[ok]   {label}")

print("\n-- defects must be rejected --")
for schema, label, doc in INVALID:
    errs = list(schemas[schema].iter_errors(doc))
    if errs:
        print(f"[ok]   rejected: {label}")
    else:
        failures += 1
        print(f"[FAIL] ACCEPTED a defect: {label}  ({schema})")

print()
total = len(VALID) + len(INVALID)
print(f"{total - failures}/{total} cases behaved as expected")
sys.exit(1 if failures else 0)
