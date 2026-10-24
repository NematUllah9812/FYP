# Shared contracts

These four schemas are the **only** agreed interface between the three modules.
They exist so that three agents working in three separate sandboxes produce code
that actually fits together.

**This directory is read-only for Student A, B and C.** If a contract is wrong or
missing a field you need, open a PR that changes *only* `contracts/`, and stop
work until it is reviewed. Do not fork the shape into your own module.

## The four contracts

| File | Producer | Consumer | Plan section |
|---|---|---|---|
| `tracker-event.schema.json` | Student A (Kotlin) | Student B (Flutter) | §13, §14 |
| `evidence-batch.schema.json` | Student A (Kotlin) | Student C (ingest) | §16, §17 |
| `batch-receipt.schema.json` | Student C (server) | Student A + B (client) | §16, §17 |
| `map-snapshot.schema.json` | Student C (server) | Student B (Flutter) | §15, §19 |

## Verify before you build against them

```bash
python3 contracts/validate_contracts.py
```

That runs 19 cases: 6 valid payloads that must pass, and 13 defects that must be
rejected. Exit code 0 means every case behaved as expected. CI runs the same
command on every PR, so a change that weakens a contract fails the build.

The 13 rejected defects are not arbitrary. Each one is a real failure mode the
plan warns about:

- **H3 id as a JSON number** — JavaScript cannot hold a 64-bit integer safely (§15)
- **Score as a float** — replays stop being bit-identical (§9)
- **Owner object carrying a user id** — a nickname is not anonymity (§19)
- **Resolution 10 in a res-9 competition** — never mix resolutions (§11)
- **Local-time timestamp** — day boundaries and caps become gameable (§9)
- **Invented interruption reason** — silent gaps instead of honest notices (§13)
- **`accuracy_m` of 0** — uncertainty of zero is not a real measurement (§18)
- **Estimated steps in the measured field** — becomes a ranked-play exploit (§12)
- **Motion sample with no `boot_id`** — a counter reset after reboot goes unnoticed (§12)
- **Location sample with no accuracy** — no bound on how wrong the fix may be (§18)
- **Unbounded 500-sample batch** — no request-size limit (§16)
- **Rejection with no reason** — an unexplained failure the user cannot act on (§16)
- **Reason code leaking a detection threshold** — thresholds stay internal (§18)

## Two decisions worth knowing about

**Why `score_micro` is a string, not an integer.** JSON Schema's `integer` type
accepts `8.0`, because in JSON a number with zero fractional part *is* an integer.
The first version of this contract used `"type": "integer"` and a test with
`score_micro: 8.0` passed when it should have failed. Digit strings close that
hole, and they are the same reasoning that puts H3 ids on the wire as text.

**Why `reasons` is mandatory on `rejected` and `partial`.** A rejection the user
cannot understand is indistinguishable from a bug, and a rejection nobody can read
cannot be debugged. This is enforced with an `if`/`then`, not left to convention.
