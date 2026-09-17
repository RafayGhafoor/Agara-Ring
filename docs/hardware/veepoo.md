# TK20 / Veepoo (H Ring)

[:material-tag-outline: Family:](index.md) `veepoo` &nbsp;·&nbsp; [:material-cellphone: App:](index.md) **H Ring** (`cn.hring.veepoo`)

The **TK20** is sold with the *H Ring* app. It speaks the **Veepoo** BLE stack
(`VeepooBleSDK 2.0.43.15`) — a wire protocol that shares nothing with the other
families this fork used to carry: its own GATT topology,
its own session handshake, and its own DF/E0 history transfer.

The full byte-level reference lives in
[`tasks/veepoo-protocol.md`](../../tasks/veepoo-protocol.md). This page is the
PulseLoop implementation note.

## At a glance

| | |
|---|---|
| Wireless | BLE |
| Command channel | `F0080001-0451-4000-B000-000000000000` (write `F0080003`, notify `F0080002`) |
| Password notify | `F0020002-0451-4000-B000-000000000000` |
| Legacy service | `FEE7` (carries the `FEA1` live-step notification) |
| Auth | `A1` session frame (local wall-clock), answered once — everything else is silence before it |
| History | `E0 <day>` sleep pages; `DF 01 <day> 00` daily records |
| Tested unit | `41:42:34:33:00:3B`, firmware `00.12.09.00` |

## How it was verified

PulseLoop's decoder is a port of the standalone BLE harness this project built
against the real ring (in `tools/`, run from a Bluetooth-authorized Terminal —
CoreBluetooth access over SSH is denied, so a signed `.app` wrapper is used for
headless runs; see the lab-workflow section of `tasks/veepoo-protocol.md`).

Verified live on the ring, with the H Ring app closed:

- auth (`A1` → ack), battery (`A0` → 76 %), today's totals (`D8` → 835 steps /
  0.706 km / 41.1 kcal)
- offset-0 daily history: 107 records, HR 60/75.1/96, SpO₂ 96/97.0/99, HRV
  44/91/138, BP avg 115.6/83.3, stress 9/19.9/51, glucose 4.38, cholesterol 4.90,
  triglycerides 1.70, HDL 0.94, LDL 3.11, uric acid 218.9
- offset-0 sleep: Sep 11 00:41–05:24, 283 min, deep 60 / light 160 / awake 0 /
  other 63
- offsets 3–6 (sleep) and 1–6 (daily) returned no data — the ring clears older
  samples after sync, which is also what makes the day loop terminate reliably

The same capture established the two load-bearing frame facts the driver/engine
layout follows:

1. **DF bytes 1–2 are a big-endian 16-bit record index**, not a day offset. It
   matters for full 288-record days. Do not regress it back to treating byte 2
   as the offset.
2. **History replies do not echo the requested day offset** — so the frames must
   be grouped under the day the engine is currently requesting. That is why the
   sync engine (which issues the queries) owns the E0/DF reassembly, and the
   driver forwards those frames through as `unknown`.

## Capabilities

Baseline (all hardware-verified, enabled unconditionally):

- **Steps** — `D8` today-total reads (polled every 30 s once authenticated, ratcheting the day's
  steps/distance/calories) and the ~1 Hz `FEA1` live stream
  (`01 <steps u16 LE> 00`, cumulative) → the live tile, powered by the
  monotonic-max ratchet so it never double-counts today's history slots
- **Sleep** — `E0` pages → A3 summary (start/end, deep/light/awake/other minutes, quality/efficiency/deep scores) → per-minute timeline
- **Battery** — `A0` (in-band, not GATT), polled every 60 s alongside the step poll
- **History vitals** from the `DF` TLV records: HR (B4), SpO₂ (B9 · first five
  bytes only), HRV (B7 · 255=absent), BP (B8), stress (C1), glucose (BE ·
  mmol/L×100 → mg/dL) — including `.spo2History` (the all-day SpO₂ rides the
  daily records)

Deliberately **not** implemented, because no verified command/decode exists for
them on this channel:

- find-device, power-off, measurement interval, step goal
- fatigue (0x81) and breathing-rate (0x82) tests — SDK commands exist and the
  python client sends them, but no reply byte-map is pinned yet; the harness
  raw-dumps those streams until a live run defines one
- MET (`BF`), the C2 lipid panel (cholesterol/triglycerides/HDL/LDL/uric acid)
  and B2 sport codes — decoded by the `tools/` harness, but there is no
  `MeasurementKind`/UI for them in the app, so they are not promised

## Measurements (one-shot)

Start/stop frames from the SDK's per-test builders, verified against the ring
via `tools/veepoo_live.py --measure` (HR and BP fully pinned; SpO₂ byte 4
read constant at 100 on the confirming run, so it rides at partial confidence).

| Metric | Start | Stop | Reply stream |
|---|---|---|---|
| Heart rate | `D0 01` | `D0 00` | `D0 <bpm>` 1 Hz, 0 while warming up |
| SpO₂ | `80 01 02` | `80 02 02` | `80 01 00 00 <spo2> 00 …` |
| Blood pressure | `90 01 00` | `90 00 00` | progress % at byte 3 (4 %/s, ~25 s), then `90 <sys> <dia> 64 00 01 …` |

## Wire mappings (verified)

| Field | Meaning |
|---|---|
| DF `B1` | month/day/hour/minute (no year — decoded into the current year, rolled back one if future) |
| DF `B2` | steps / sport / distance-m / calories×10 (BE u16 pairs) |
| DF `B4` | five one-minute HR values per 5-minute slot |
| DF `B7` | HRV values, 255 = absent |
| DF `B8` | systolic / diastolic |
| DF `B9` | first five bytes SpO₂; the tail is metadata, never oxygen |
| DF `BE` | glucose ×100, LE u16 |
| DF `BF` | MET (not ingested by the app) |
| DF `C1` | stress |
| DF `C2` | cholesterol/triglycerides/HDL/LDL ×100, uric acid ×10, LE (not ingested) |
| `E0` A3 | start M/D/HH/MM @0–3, end @4–7, deep score @10, efficiency @11, quality @15, deep/light/other/total minutes LE u16 @19–27; awake = total − deep − light − other |

## Known limitations

- The **minute-by-minute sleep ordering** is not recoverable from the A3
  payload — the harness verified the *counts*, and the engine expands them in
  deep → light → awake → other order. `persistSleepTimeline` dedups by block
  start, so re-syncs stay idempotent.
- A ring that goes **silent mid-transfer** (no completion marker) stalls at that
  day; the next connect or `syncHistory()` re-runs the loop. No transfer timers
  exist in the engine.
- By default the loop reads **7 days** (offsets 0–6). The ring answers no-data
  past what it retains, so the loop terminates on its own.
- Intraslot HR/SpO₂/HRV samples are stamped at slot + i minutes — the per-slot
  count is verified, the intra-slot distribution is inferred from the 5-minute
  slot shape (288 records/day).