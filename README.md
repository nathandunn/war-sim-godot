# war-sim-godot

War Sim in **Godot 4 / GDScript**, exported to Web (WASM).

A second, independent implementation of [`nathandunn/war-sim`](https://github.com/nathandunn/war-sim):
500 personality-driven actors on a 1600x900 field, unit-level personalities with
per-actor jitter, simulated ballistics, cover with grazing-angle miss bumps,
hitbox damage falloff and melee. Same design spec (`specs/war-sim.md`), same
numbers, different language and different engine. The JS build is untouched.

Live: <https://war-godot.apps.precogsoftwareservices.com>

## Build

```sh
scripts/godot-install.sh      # in nathandunn/hub-orchestrator - Godot 4.7.2 + web templates
./build.sh                    # headless export into build/
./test.sh                     # 38 assertions, headless
./test.sh --perf              # 500-actor tick benchmark
./test.sh --sim 20 --map ruins   # headless N runs + the simulate-mode stats table
```

## Layout

| file | what |
|---|---|
| `scripts/rng.gd` | sim-core's mulberry32, ported word for word |
| `scripts/geom.gd` | segment/rect/circle geometry, line of sight, cover incidence |
| `scripts/spatial.gd` | uniform-grid broadphase, CSR layout, per-cell team split |
| `scripts/engine.gd` | `utilityDecide` — softmax over trait-weighted action scores |
| `scripts/data.gd` | field, maps, weapons, unit presets |
| `scripts/world.gd` | the tick: perceive, decide, move, separate, melee, fire, projectiles |
| `scripts/batch.gd` | `simulate` mode — seeded trials and the stats table |
| `scripts/tests.gd` | headless tests, benchmark, `--sim` |
| `ui/` | Control-node UI, MultiMesh field renderer |

## Determinism

One seed, one battle. The RNG is a hand port of sim-core's rather than Godot's
`RandomNumberGenerator`, and it is consumed in one fixed order: spawn jitter,
then per-tick decisions in actor-id order, then melee rolls in (i, j) order,
then aim error in actor-id order. The broadphase is filled in actor-id order and
scanned in a fixed cell order, so neighbour iteration — and therefore
floating-point accumulation — is reproducible. No wall clock, no engine RNG.

`./test.sh` asserts this on all three maps, including that an unrelated battle
run in between changes nothing.

## Formula divergences from the JS build

The design intent was that the two implementations produce *comparable*
statistics, not identical ones. Every formula is the same; these are the places
where the two cannot agree bit for bit, and the one place the model differs.

1. **Transcendental functions.** `exp` (softmax), `sin`/`asin` (cover
   incidence, charge weave), `atan2` (aim) come from V8 in the browser and from
   the platform libm here. Both are correctly rounded to within an ulp or so of
   each other, but not identically, so two runs on the same seed diverge —
   slowly at first, then completely, because the softmax draw is a threshold on
   an accumulated probability. This is the fundamental one; nothing below
   matters next to it.
2. **`Math.hypot` vs `sqrt(x*x + y*y)`.** V8's `Math.hypot` uses overflow-safe
   scaling and is more precise than the naive form. Nothing on a 1600x900 field
   comes near overflow, so the formula is the same one, computed the plain way.
3. **Broadphase resolution.** The JS build runs one 96-unit grid. This one runs
   two — 96 for perception, 48 for separation and melee — because separation
   reaches 16 units and perception reaches 430, and one grid cannot be good at
   both without missing the frame budget (see "Performance"). The *set* of pairs
   found is identical; the order they are visited in is not, so the accumulated
   separation pushes differ in the last bits.
4. **The RNG is exact.** `scripts/rng.gd` reproduces sim-core's stream word for
   word, asserted against reference vectors from node in `test.sh`. Spawn
   positions and jittered personalities are therefore identical for a given
   seed; the divergence is entirely downstream of the first `exp`.
5. **Personality shape.** A preset here is the seven properties War Sim reads.
   The JS preset also carries `caution`, `cooperation`, `patience` and `focus`,
   derived from those seven — but only so that a War Sim personality still
   validates against sim-core's schema and still means something inside Battle
   Bots. Nothing in either simulator reads them, so there is no schema here and
   they are not carried.
6. **No agent-forge.** `simulate` mode's trial loop and trait sweep are in
   `scripts/batch.gd` rather than imported from `@precog/agent-forge`. Trial *i*
   gets `seedBase + i` and a sweep is 11 points over [0,1], which is
   agent-forge's numbering, so batches line up trial for trial.

Behaviourally the two agree where the JS suite makes a testable claim:
`test.sh` mirrors its personality assertions run for run — same presets, same
seeds, same tick caps, same measure.

### Measured against the JS build

Six trials, Ruins, seeds 20260909-14, 125 Line + 125 Shock against 125 Guards +
125 Skirmishers — the same configuration `specs/war-sim.md` reports on. Both
implementations run headless.

| | Godot | JS | |
|---|---|---|---|
| win rate B | 1.000 | 1.000 | same winner on every seed |
| casualties A (mean) | 250.0 | 250.0 | A is wiped out either way |
| casualties B (mean) | 91.7 | 81.7 | +12% |
| time to decision (mean) | 1661 ticks | 1602 ticks | +4% |
| hit rate | 0.574 | 0.559 | +3% |
| melee kills / run | 14.8 | 15.8 | -6% |

Individual seeds do not match — divergence 1 above guarantees they cannot — but
they track: every seed resolves the same way, and the spread of tick counts
overlaps. Comparable statistics, which was the goal; identical replays, which
was never available.

## Performance

500 actors, mean over 400 ticks after a 200-tick warm-up, on the hub
(t3.medium, 2 vCPU), `./test.sh --perf`:

| map | mean | p50 | p95 |
|---|---|---|---|
| Open Field | 8.67 ms | 7.62 ms | 13.96 ms |
| Ruins | 9.35 ms | 8.41 ms | 13.70 ms |
| Ridge | 8.85 ms | 7.69 ms | 14.42 ms |

Against a 16.67 ms budget at 60 Hz. The JS build measures 2.7-3.3 ms on the same
host and the same configuration; the gap is the GDScript interpreter against a
JIT, and closing it further would mean leaving GDScript.

These are native numbers. **There is no browser on the build host, so the
in-browser figure has not been measured** — WASM will be slower, by how much
depends on the device. Two things are built in for that: the frame loop runs
whole 60 Hz ticks from an accumulator with a hard cap of 4 catch-up ticks, so a
slow device runs the battle in slow motion rather than diverging or spiralling;
and the live stats line shows the actual ms/tick, so the real cost on the real
device is on screen. Unit counts are sliders — halving the army roughly halves
the tick.
