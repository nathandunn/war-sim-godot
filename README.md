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
./test.sh                     # 56 assertions, headless
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

## What it looks like

Actors are soldiers, not chevrons: `assets/soldiers.png` is a five-cell sheet -
standing, crouched in cover, lunging in melee, freshly fallen, settled - and the
pose index rides in each instance's custom data, which `ui/actors.gdshader`
turns into a UV offset. Five poses therefore still cost **one** MultiMesh and
one draw call, and facing still comes free with the instance transform. The
second MultiMesh carries bullets *and* muzzle flashes, so the two-MultiMesh
budget holds.

The sheet stores luminance rather than colour - body 0.72, helmet 1.0, weapon
0.15 - and the instance colour multiplies in, so one sheet serves both teams,
every unit shade and the corpse tint, and the rifle stays dark under all of
them. Cover rects are drawn as sandbag emplacements with a lit top edge.

### Colour

Reworked 2026-09-11, after a phone report that the sim apps were unreadable in
daylight. The whole palette is `scripts/palette.gd` and nothing else may name a
colour - `_test_palette_contrast` greps `ui/` and `scripts/sprites.gd` for a
literal `Color(...)` and fails on one.

Every element clears **WCAG 3:1** against the field, the bar for non-text
graphical objects, and the suite asserts it rather than the README claiming it:

| | hex | vs field |
|---|---|---|
| field | `#2b3140` | - |
| team A helmet / body | `#ffa88c` | 6.95 : 1 / 3.68 : 1 |
| team B helmet / body | `#8cc0ff` | 6.87 : 1 / 3.64 : 1 |
| sandbags | `#d9bd8a` `#c4a875` | 7.18 : 1 / 5.70 : 1 |
| sandbag top edge | `#f5e4bf` | 10.35 : 1 |
| corpse | `#9aa3b5` | 5.12 : 1 |
| bullets | `#fff0c0` | 11.43 : 1 |

The **body** rows are the ones that matter and the ones that were wrong before:
a soldier is a luminance sprite with the team colour multiplied in, so the torso
is 0.72 of the tint. Ember and cyan both looked fine as swatches and both sank
into a near-black field as men. The test checks the body, not the swatch.

**Team A is red and team B is blue, in that order, and `war-sim` now matches.**
The two builds had drifted - this one had A blue and B red, the canvas one had A
ember and B cyan - which is a bad property for two implementations of one spec
meant to be read side by side. Red against blue rather than red against cyan
because it is the standard colour-blind-safe opposition, and the two sit at
nearly equal luminance (0.512 vs 0.505, asserted) so neither side reads as the
heavier.

Before and after, composited by `sprites.gd --scene` through the same lens:
`docs/palette-before.png` and `docs/palette-after.png`.

**Not affected by the deadfall/camera fixes** that went into `pack-hunt-3d` and
`pack-hunt-brains` the same day: this renderer is 2D throughout - `Node2D`,
`MultiMeshInstance2D`, `_draw` - so there is no mesh winding to get wrong, no
`StandardMaterial3D` to cull, no `DirectionalLight3D`, and no 3D frustum AABB to
go stale. It was checked for all four and has none of them.

`scripts/sprites.gd` generates the sheet from code and is committed with it:

```sh
godot --headless --script res://scripts/sprites.gd
godot --headless --script res://scripts/sprites.gd -- --preview /tmp/p.png --scene /tmp/s.png
godot --headless --script res://scripts/sprites.gd -- --legacy --scene docs/palette-before.png
```

It composes the image analytically rather than through any drawing API, because
`--headless` runs on the dummy rendering driver and a `SubViewport` produces no
pixels there. `--preview` writes a magnified contact sheet and `--scene` a patch
of field - a sandbag wall with a squad along it - which is the only way to look
at the result on a host with no display. Nothing is imported from outside this
repo.

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

Two things are compared, and they behave differently.

**The cover model agrees closely.** These are aggregate measures over whole
battles, on the same maps, presets and seeds as `war-sim`'s suite, and both
suites assert them:

| Ruins | Godot | JS |
|---|---|---|
| guards in cover after first coming under fire, seed 2 | 71.1% | 71.2% |
| ...seed 3 | 67.2% | 63.4% |
| ...seed 4 | 75.3% | 77.8% |
| berserkers in a cover state (the control) | 0.9-1.2% | 0.9-1.1% |
| risk-0.05 line unit in a cover state, seed 3 / 9 | 13.6% / 13.3% | 13.4% / 12.1% |
| risk-0.95, same | 0.5% / 0.4% | 0.5% / 0.4% |

**Battle outcomes agree on an open map and diverge on a closed one.** Six
trials, seeds 20260909-14, 125 Line + 125 Shock against 125 Guards + 125
Skirmishers - the configuration `specs/war-sim.md` reports on. Both headless.

| Open Field | Godot | JS | |
|---|---|---|---|
| win rate B | 1.000 | 1.000 | same winner on every seed |
| casualties A (mean) | 250.0 | 250.0 | A is wiped out either way |
| casualties B (mean) | 139.0 | 133.7 | +4% |
| time to decision (mean) | 2122 ticks | 2099 ticks | +1% |
| hit rate | 0.462 | 0.455 | +2% |
| melee kills / run | 8.5 | 9.2 | -8% |

| Ruins | Godot | JS | |
|---|---|---|---|
| win rate B | 0.500 | 1.000 | 4 of 6 seeds agree |
| casualties A (mean) | 247.0 | 249.5 | -1% |
| casualties B (mean) | 190.8 | 134.5 | +42% |
| time to decision (mean, decided runs) | 2544 ticks | 2016 ticks | +26% |
| hit rate | 0.393 | 0.460 | -15% |
| runs stopped by the 90-second cap | 2 of 6 | 1 of 6 | |

Open Field is *tighter* than the pre-cover-fix table was (+4% against +12% on
casualties). Ruins is much looser, and the reason is in the last row: with both
sides using cover a Ruins battle now runs two to three times as long, and a
third of the runs finish at or near the tick cap. A capped run's casualties are
whatever the clock happened to catch, so a divergence that would once have shown
up as a hundred ticks of difference now shows up as fifty extra bodies - and
divergence 1 above guarantees the two runs separate eventually. Where the clock
is not the arbiter, they still track.

## Performance

500 actors, mean over 400 ticks after a 200-tick warm-up, on the hub
(t3.medium, 2 vCPU), `./test.sh --perf`:

| map | mean | p50 | p95 |
|---|---|---|---|
| Open Field | 9.63 ms | 8.89 ms | 14.08 ms |
| Ruins | 10.45 ms | 9.64 ms | 14.97 ms |
| Ridge | 9.80 ms | 8.86 ms | 15.69 ms |

Before the cover work these were 8.67 / 9.35 / 8.85 ms. The extra is
`_pick_cover`, which runs only for an actor that has decided to take cover and
scores eight standing spots on each of the five nearest rects.

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
