# AGENTS.md — Agara Ring iOS

**Read these first.**

1. **Plan first, then wait for approval.** No code, config change, commit or push before the plan is
   approved. Read-only recon (read, grep, run the emulator, query a database) is always fine.
   Workflow: [`../docs/process/plan-first.md`](../docs/process/plan-first.md).
2. **Agara only.** One ring family: the Veepoo/TK20 **Agara Ring**. Other families were removed; never
   add one back, and no vendor names ("H Ring", "Colmi", …) in the catalog, pairing UI or docs.
3. **Keep both apps in sync.** Any behaviour change here must be ported to Android in the same piece of
   work, or recorded as an intentional platform difference with a reason — in the parity matrix:
   [`../docs/apps/parity-matrix.md`](../docs/apps/parity-matrix.md). The ring protocol is identical on
   both platforms ([`../docs/ring/veepoo-protocol.md`](../docs/ring/veepoo-protocol.md)).
4. **Centralised docs.** Protocol, emulator, cloud, per-app notes and runbooks live in `../docs/`.
   Do not copy them here; link instead.
5. **Shared brand copy is generated.** `PulseLoop/Generated/AgaraCopy.swift` comes from
   `../docs/strings/brand.yaml` via `python3 ../tools/gen_strings.py` (verify with `--check`).
   Never hand-edit it. See [`../docs/apps/shared-strings.md`](../docs/apps/shared-strings.md).
6. **Verify with evidence, then record it** — store rows, a screenshot, a byte-comparison against a
   real capture, or a test that fails when the logic breaks. Update the parity matrix in the same change.
7. **Testing without hardware** uses the shared ring emulator (`../ring-emulator/`): BLE when the app
   runs on another device, the debug socket transport when it runs on the same machine.
8. **No secrets, ever** — no credentials, tokens, account data or signing material in code, docs, logs
   or commits. Redact in diagnostics.
