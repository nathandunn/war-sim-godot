# War Sim — design spec v0.1

Large-field, many-unit battle simulator. Forked in spirit (not in code) from Battle Bots:
same suite, same libraries, a different scale of problem. Battle Bots is 20 fighters where
the *team* is a personality. War Sim is 500 actors where the **unit** is a personality and
every actor is that personality plus seeded jitter.

Source handoff: `HANDOFF-2026-09-08-war-sim.md`.
Repo: `nathandunn/war-sim` (public). Deploys to `war.precogsoftwareservices.com`.

---

## 1. Non-negotiables

| Constraint | Value |
|---|---|
| Field | 1600 × 900 logical units, responsive render |
| Sim rate | fixed 60 Hz, integer ticks, render decoupled |
| Scale | 500+ actors, spatial hash broadphase, tick < 8 ms |
| Determinism | one seed → one battle, bit-identical, in browser and in node |
| Actors | dots. Team colour, unit id, facing tick. No sprites |
| Reuse | `@precog/sim-core` (RNG, utility engine, personality schema), `@precog/agent-forge` (batch + sweep) |
| No copy-paste | shared geometry/broadphase moves *into* sim-core; War Sim writes its own loop |

---

## 2. Data model

### 2.1 Personality (extends the sim-core schema, backward compatible)

The seven properties the handoff calls for map onto the existing schema without breaking it:

| Property | Where it lives | Notes |
|---|---|---|
| `aggression` | sim-core core trait | already in `CORE_TRAITS` |
| `risk` | sim-core core trait | already in `CORE_TRAITS` |
| `randomness` | sim-core top-level field | already drives `utilityDecide` temperature |
| `cohesion` | **new** extended trait | stick to the unit |
| `discipline` | **new** extended trait | fire control |
| `meleePreference` | **new** extended trait | charge vs shoot |
| `jitter` | **new** extended trait | per-actor deviation from the unit |

sim-core gains `EXTENDED_TRAITS`, `EXTENDED_DEFAULTS`, `withExtended()` and a safe
`traitOf()` accessor. `CORE_TRAITS` and `validate()` are untouched, so Battle Bots,
Pack Hunt, Card Table and Dino Poop keep validating exactly as before — the schema
already allowed extra trait keys (`Traits = Record<CoreTrait, number> & Record<string, number>`),
this only names and defaults the four War Sim adds.

All values 0..1, clamped by `normalize()`.

### 2.2 Unit and actor

```ts
type ActorKind = "infantry";              // hook only — tanks/artillery deliberately unimplemented

interface Weapon {
  id: string; name: string;
  projectileSpeed: number;                // logical units per tick
  spread: number;                         // base 1σ aim error, radians
  cooldown: number;                       // ticks between shots
  damage: number;                         // damage at a dead-centre hit
  range: number;                          // max engagement distance
  bulletRadius: number;
}

interface Unit {
  id: number; team: 0 | 1; name: string;
  kind: ActorKind;                        // hook
  personality: Personality;               // the unit IS the personality
  weapon: Weapon;
  actors: number[];                       // actor ids
}

interface Actor {
  id: number; unit: number; team: 0 | 1;
  x: number; y: number; facing: number;   // radians
  hp: number; alive: boolean;
  state: ActionId; cooldown: number; meleeCooldown: number;
  target: number;                         // actor id, -1 none
  underFire: number;                      // ticks-since-hit counter, decays
  coverX: number; coverY: number;
  // per-actor personality = unit personality + seeded jitter, resolved once at spawn
  aggression, risk, randomness, cohesion, discipline, meleePreference: number;
  // stats
  shots, hits, damageDealt, damageTaken, kills, meleeKills, aliveTicks, ticksInCover: number;
}
```

**Jitter rule.** At spawn, for actor `a` of unit `u`:
`t_a = clamp01(t_u + (rng() + rng() - 1) * jitter_u * JITTER_SCALE)` for each of the six
behavioural properties (`jitter` itself is not jittered). `JITTER_SCALE = 0.5`, so a unit at
`jitter = 1` spreads its actors ±0.5 around the unit value on a triangular distribution.

### 2.3 Map

```ts
interface CoverRect { x, y, w, h: number }
interface MapDef { id, name: string; cover: CoverRect[]; spawnA, spawnB: SpawnZone }
```

Three handmade layouts: **Open Field** (four sparse blocks), **Ruins** (dense urban grid,
nine blocks + a central plaza), **Ridge** (two long horizontal walls with gaps — a
"cross the gap" map). Cover is static and axis-aligned.

---

## 3. Tick order

One tick = 1/60 s. Everything below runs in this exact order, over actors in ascending id,
consuming a single `Rng` stream, so a seed replays exactly.

1. **Broadphase rebuild** — clear and refill the spatial hash (cell 96 u) with living actors.
2. **Decide** — actor `a` re-decides when `(tick + a.id) % DECIDE_EVERY == 0` (`DECIDE_EVERY = 6`,
   staggered so the cost spreads across ticks). Perception (spatial query, ≤ 2 rings) →
   candidates → `utilityDecide` from sim-core → `state`. `seekCover` also picks a cover point.
3. **Move** — desired direction from `state`, integrate at `MOVE_SPEED`, slide out of cover
   rects, clamp to field.
4. **Separate** — spatial-hash neighbour pairs, symmetric push apart at `SEPARATION`.
5. **Melee** — enemy pairs within `MELEE_RANGE` where at least one wants melee: contested roll.
6. **Fire** — cooldown ready + target in range + fire control passes → spawn a projectile.
7. **Projectiles** — swept segment per projectile, nearest of {cover rect, enemy actor};
   hitbox falloff on hit; expire off-field.
8. **Bookkeeping** — deaths, per-actor and per-unit stats, `underFire` decay, victory check.

Before either side has seen anybody, actors march on the **centre of the enemy spawn**, not
on their own unit centroid: steering at your own centroid makes everyone ahead of it walk
backwards into it, so the formation compresses and the army creeps forward at a fraction of
its speed — on a 1600-wide field the two sides then never meet.

Broadphase queries in steps 4-7 run against the hash built in step 1, so they are widened by
`QUERY_MARGIN` (two sprinting steps): a pair that is genuinely in contact would otherwise be
filtered out by its stale position, which silently switches melee off.

Determinism notes: the hash is filled in actor-id order, so bucket contents and therefore
every query result are a pure function of state. Target choice ties break on lower actor id.
No wall-clock, no `Math.random`, no iteration over object key order.

---

## 4. Personality → behaviour

`utilityDecide` scores six actions per decision. `score = base + Σ trait·weight`, softmax
temperature from `randomness`.

| Action | Meaning | Driven up by | Driven down by |
|---|---|---|---|
| `advance` | close to preferred range | aggression, cohesion | — |
| `charge` | run into melee | meleePreference (× closeness), aggression | discipline |
| `hold` | stand and shoot | discipline | aggression |
| `flank` | arc around the target through open ground | risk | cohesion, discipline |
| `seekCover` | break line of sight | (1 − risk) × underFire | risk, aggression |
| `regroup` | fall back on the unit centroid | cohesion (× distance from unit) | aggression |

Beyond action choice:

- **aggression** — preferred engagement range `PREF_FAR − aggression·PREF_SPAN`; weight in the
  melee roll; charge threshold distance.
- **risk** — long-shot willingness: fire range = `weapon.range · (0.55 + 0.45·risk)`; high risk
  suppresses `seekCover` entirely (handoff: "high risk actors ignore cover"); low risk actors
  under fire seek the nearest cover point.
- **randomness** — softmax temperature *and* an aim-spread multiplier: `σ ·= (1 + randomness)`.
- **discipline** (fire control) — minimum acceptable hit chance before pulling the trigger
  (`MIN_HIT_CHANCE · discipline`), refuses shots with no clear lane, weight in the melee roll.
  Low discipline burns ammo into cover.
- **meleePreference** — `charge` utility scales with `meleePreference · (1 − d/CHARGE_REACH)`,
  so it only fires when the enemy is actually close.
- **cohesion** — centroid pull applied to every movement vector; `regroup` utility.
- **jitter** — spawn-time spread of all of the above across the unit's actors.

---

## 5. Combat model

### 5.1 Ballistics

Projectiles are simulated entities (no hitscan): `{x, y, vx, vy, team, shooter, unit, damage, radius}`,
integrated one tick at a time and tested as a swept segment.

Aim error is a triangular sample (`rng()+rng()−1`) times σ:

```
σ = weapon.spread
  × (1 + randomness)                      // handoff: spread scaled by actor randomness
  × (moving ? MOVE_SPREAD : 1)            // handoff: … and movement
  + COVER_SPREAD × coverBonus(shot)       // §5.3
  + trackSigma(dist, targetSpeed)         // §5.5
```

### 5.2 Hitbox

Circle of radius `ACTOR_R`. For a swept segment, `d` = closest approach to the actor centre:

```
damage = weapon.damage × (1 − (d / ACTOR_R)²)
```

`d = 0` (dead centre) = full damage = a kill at full HP with the rifle (`damage = MAX_HP`);
`d → ACTOR_R` grazes for almost nothing. The projectile is consumed on any `d ≤ ACTOR_R`.

### 5.3 Cover

Cover blocks projectiles physically (swept segment vs AABB, nearest hit wins), and it
degrades *aim* before the shot is even taken:

```
coverBonus(shooter → target) ∈ [0,1]
  = max over cover rects the shot passes within COVER_NEAR of, of (1 − sin θ)
```

where θ is the incidence angle between the shot direction and the face being passed.
A shot crossing a face head-on (θ = 90°) gets no bonus; a shot skimming along a face
(θ → 0, the *grazing* case) gets the full bonus — "grazing angle = more cover", exactly as
the handoff specifies. Bonus enters as extra spread, i.e. a miss-probability bump.

If cover fully blocks the segment, there is no lane: a disciplined actor holds fire, an
undisciplined one may shoot the wall.

### 5.5 Tracking lag and lead

Nobody in this simulation leads their aim, so two range-dependent errors fall out and
both are modelled explicitly:

- **Drift** — the round spends `dist / projectileSpeed` ticks in the air while the target
  keeps walking. Grows with distance, shrinks with muzzle velocity. This one is physical:
  the projectile is a real entity, so it happens whether or not fire control knows about it.
- **Tracking lag** — `REACTION_TICKS × targetSpeed / dist` radians, i.e. a roughly constant
  *lateral* error of about one body width against anything that is moving. Added to σ.

The second term is load-bearing rather than decorative. Without it, close-range fire is
near-perfect, every actor that charges dies at 40 units, and the melee system in §5.4 is
unreachable dead code on every map. With it, a sprinting actor at ten paces is a hard
target, which is both true and what makes `meleePreference` mean anything.

Fire control (`discipline`) uses the same estimate, so a disciplined actor holds fire on a
distant moving target and closes instead — `engageRange()` inverts the estimate to find the
distance at which the actor would finally shoot, and `advance` closes to the nearer of that
and its preferred range. An actor whose preferred range sits outside its own fire-control
threshold just stands and stares; that is how a disciplined unit talks itself into a
stalemate.

### 5.4 Melee

A charge is a **sprint**: `charge` moves at `MOVE_SPEED × CHARGE_SPEED`. At walking pace the
last 200 units of an assault under aimed fire are simply fatal, and no charge ever arrives.

Within `MELEE_RANGE`, if either actor's state is `charge` (or both are pinned together),
a contested roll runs every `MELEE_COOLDOWN` ticks, in ascending (i, j) order:

```
power(a) = (0.4 + 0.9·aggression) × (0.6 + 0.6·discipline) × (0.5 + 0.5·hpFrac) × (0.5 + rng())
```

Higher power wins; the loser takes `MELEE_DMG`. Ties (exact) go to the lower id.

---

## 6. Modes

### 6.1 `single`

One battle, live. `requestAnimationFrame` drives an accumulator that runs whole 60 Hz ticks
(max 4 catch-up ticks per frame, so a slow frame drops sim time rather than diverging);
rendering reads the live world. Live stats: alive per side, casualties, shots/hits, elapsed
sim seconds, per-unit table.

### 6.2 `simulate`

Headless N runs over personality distributions.

- Trial loop: `runBatch` from agent-forge — trial *i* gets `seedBase + i`. No new batch loop.
- Sweep: `sweepTrait` / `sweepAll` from agent-forge, over the War Sim trait set
  (the four extended traits included — see §7).
- Metrics per configuration: **win rate**, **casualties** (both sides), **time-to-decision**
  (ticks to a resolved battle, capped runs flagged), **per-unit efficiency**
  (damage dealt ÷ damage taken, kills, hit rate, alive ticks).
- Runs in sliced chunks off the main thread's critical path (K trials per macrotask) so the
  page stays responsive; slicing never touches the seeds, so results are timing-independent.

Same seed and same configuration → identical stats in both modes.

---

## 7. Library changes

### sim-core (additive, v0.2.0)

- `personality.ts`: `EXTENDED_TRAITS`, `EXTENDED_DEFAULTS`, `withExtended()`, `traitOf()`.
- `geom.ts` (new): `clamp`, `segRectT`, `segCircleT`, `segCircleClosest`, `rectDist`,
  `pushOutCircle`, `losClear` — the geometry Battle Bots wrote privately, now shared.
  Battle Bots is **not** modified (out of scope); it can adopt these later for free.
- `spatial.ts` (new): `SpatialHash` — uniform grid broadphase, insert in id order,
  `queryCircle`/`forEachNear` with no per-query allocation.

### agent-forge (additive)

`sweep.ts` currently types `TraitKey = CoreTrait | "randomness"` and `sweepAll` walks
`ALL_TRAITS`. War Sim needs to sweep `cohesion` / `discipline` / `meleePreference` / `jitter`,
which are not core traits. Change: widen `TraitKey` to any trait name and add an explicit
trait-list parameter to `sweepAll`. `ALL_TRAITS` and the existing one- and two-argument call
shapes keep their current meaning, so Card Table and Pack Hunt compile and behave unchanged.

---

## 8. Tests (all in `node --test`, no browser)

| Test | Assertion |
|---|---|
| determinism | same seed → identical result digest; a foreign-seed run in between changes nothing |
| determinism (sliced) | batch run in one pass == batch run in chunks |
| hitbox curve | `dmg(0) = damage`, `dmg(R) = 0`, strictly decreasing, matches `1 − (d/R)²` |
| cover angle | grazing shot bonus > perpendicular bonus; no cover → 0; bonus ∈ [0,1] |
| performance | 500 actors, mean tick < 8 ms on the hub |
| personality | high aggression closes distance more than low; high meleePreference produces more melee kills |
| sweep | sweeping an extended trait returns 11 points and a classified shape |

## 9. Measured

500 actors (125 Line + 125 Shock vs 125 Guards + 125 Skirmishers), mean over 400 ticks after
a 200-tick warm-up, on the hub (t3.medium, node 22):

| map | mean | p50 | p95 |
|---|---|---|---|
| Open Field | 3.27 ms | 2.54 ms | 6.82 ms |
| Ruins | 2.71 ms | 2.52 ms | 3.88 ms |
| Ridge | 2.71 ms | 2.55 ms | 3.84 ms |

Comfortably inside the 8 ms budget and inside a 60 Hz frame. The outliers above the mean are
GC, not simulation cost.

## 9b. Notes from implementation

Deltas from the design above, all found by running it:

1. **Decision staggering must be strict.** An "…or when the actor has no target" clause in
   the decide condition looks harmless and is not: before the sides are in sight of each
   other that is *everybody*, so the whole approach phase runs at 6× the decision cost. It
   was the difference between 12 ms and 3 ms a tick.
2. **March on the enemy, not on yourself** (§3).
3. **Charging is sprinting** (§5.4) and **tracking lag exists** (§5.5) — without both,
   melee is unreachable.
4. **Broadphase queries need a stale-position margin** (§3).
5. `prefRange` takes `meleePreference` as well as `aggression`: a melee unit that parks at
   shooting range never gets to use the charge utility.

## 9c. Definition of done

`war.precogsoftwareservices.com` live, both modes usable on a phone, 500 dots stable and
seed-deterministic, sliders visibly change outcomes, tests green, `apps.json` entry `live`.
