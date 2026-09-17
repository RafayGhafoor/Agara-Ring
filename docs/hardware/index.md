# Ring hardware

One ring family ships in this app: the **Agara Ring**, a Veepoo/TK20 ring (the vendor app is
`cn.hring.veepoo`, sold elsewhere as "H Ring"). Everything the app supports is described here and in the
canonical protocol spec.

| | |
|---|---|
| Protocol spec (canonical, both apps) | [`docs/ring/veepoo-protocol.md`](../../../docs/ring/veepoo-protocol.md) |
| Hardware page | [Veepoo / Agara Ring](veepoo.md) |
| Test rig (emulator, captures, BLE probes) | [`docs/ring/ring-emulator.md`](../../../docs/ring/ring-emulator.md) |

The other families this fork once carried (jring/56ff, Colmi/Yawell, LuckRing, RWfit, CRP, YCBT/TK5,
R10M, simsonlab) were **removed**, not disabled — see Rule 3 in [`AGENTS.md`](../../AGENTS.md). Their
protocols live on in git history if they are ever needed again.
