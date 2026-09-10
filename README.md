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
