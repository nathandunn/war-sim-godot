extends RefCounted
##
## The War Sim world in GDScript: 60 Hz fixed timestep, 500+ actors,
## deterministic from a seed.
##
## This is a port of `nathandunn/war-sim`'s `sim.ts`, formula for formula. The
## tick order, the constants, the utility weights and the combat maths are the
## same; what changed is everything the language forced:
##
##  * **Structure of arrays.** The TS version keeps an array of `Actor`
##    objects. In GDScript every one of those property reads is a hashed
##    lookup, and at 500 actors x 60 Hz that alone missed the frame budget. All
##    actor state lives in flat Packed arrays indexed by actor id.
##  * **No callbacks in the broadphase.** See `spatial.gd`: neighbour slices
##    are walked inline.
##  * **Own RNG.** See `rng.gd`.
##
## Determinism contract, unchanged from the original: one `Rng`, consumed in a
## fixed order (spawn jitter -> per-tick decisions in actor-id order -> melee
## rolls in (i,j) order -> aim error in actor-id order). The hash is filled in
## actor-id order and scanned in a fixed cell order, so neighbour iteration —
## and therefore floating-point accumulation — is reproducible. No wall clock,
## no engine RNG.
##

const Geom := preload("res://scripts/geom.gd")
const SpatialHash := preload("res://scripts/spatial.gd")
const UtilityEngine := preload("res://scripts/engine.gd")
const WarRng := preload("res://scripts/rng.gd")
const D := preload("res://scripts/data.gd")

# ── constants ─────────────────────────────────────────────────────
const SIM_HZ := 60
const MAX_HP := 100.0
const ACTOR_R := 6.0
const MOVE_SPEED := 0.95            # logical units per tick (57 u/s)
const VISION := 430.0
const SEPARATION := ACTOR_R * 2.05
const MELEE_RANGE := ACTOR_R * 3.2
const MELEE_COOLDOWN := 26
const MELEE_DMG := 46.0
const CHARGE_REACH := 240.0         # meleePreference only bites inside this
## A charge is a sprint. Without this a charging actor crosses the last 200
## units at walking pace under aimed fire and simply dies, so meleePreference
## buys nothing and melee never happens on any map.
const CHARGE_SPEED := 1.6
const DECIDE_EVERY := 6             # staggered by actor id
const DEFAULT_MAX_TICKS := SIM_HZ * 90
const COVER_NEAR := 46.0            # a rect this close to the target is the target's cover
const COVER_SPREAD := 0.075         # extra 1 sigma at full grazing cover
const MOVE_SPREAD := 1.7            # spread multiplier while moving
const MIN_HIT_CHANCE := 0.55        # discipline scales this fire-control floor
const UNDER_FIRE_TICKS := 90
const NEAR_MISS := 22.0
const PREF_FAR := 330.0             # preferred engagement range at aggression 0
const PREF_SPAN := 250.0            # ...minus this at aggression 1
const JITTER_SCALE := 0.5
const HASH_CELL := 96.0
##
## A second, finer broadphase for the two short-range passes.
##
## Separation reaches 16 units and melee 23, but perception reaches 430, and one
## grid cannot be good at both: sized for perception (96) the short-range passes
## scan a 96x96 neighbourhood to find contacts a body-width away, and in a dense
## clump that was a third of the whole tick. Sized for contact, perception's
## outer ring becomes a thousand cell probes. So there are two, rebuilt from the
## same positions in the same actor-id order.
##
const FINE_CELL := 48.0
const SEPARATION2 := SEPARATION * SEPARATION
const ACTOR_R2 := ACTOR_R * ACTOR_R
## Broadphase queries run against the hash built at the top of the tick, but
## separation and melee run after movement, so both actors may have closed by up
## to a full (sprinting) step each since. Query with that slack or a pair that is
## genuinely in contact gets filtered out by its stale position — which is
## exactly how melee quietly stops happening.
const QUERY_MARGIN := MOVE_SPEED * CHARGE_SPEED * 2.0 + 1.0

const NEAR_COVER_MARGIN := 52.0
## Most rects any actor can be within NEAR_COVER_MARGIN of on the shipped maps
## is 4. The cap keeps the per-actor cover list a fixed-stride slice; overflow
## would silently drop a rect, so it is counted and asserted in the tests.
const MAX_NEAR_COVER := 8

const PERCEIVE_RINGS := [150.0, 300.0, VISION]
const PERCEIVE_K := 4
## `advance` still being the last thing you did is worth this much, per the TS
## caller's `inertiaBonus`.
const INERTIA := 0.10

## Nobody in this simulation leads their aim, so a bullet spends
## `dist / projectileSpeed` ticks in the air while the target keeps walking.
## LEAD is below 1 because a target's motion is only sometimes across the line
## of fire.
const LEAD := 0.35
## Ticks of tracking lag: how far behind a moving target the shooter's aim sits.
## Multiplied by the target's speed this is a roughly constant lateral error of
## about one body width — the reason a sprinting actor at ten paces is not a
## free kill.
const REACTION_TICKS := 5.0


# ── pure combat maths (the tests pin these curves) ────────────────

## Hitbox falloff. `d` is the projectile's closest approach to the actor centre.
## Dead centre is full damage — with the rifle that is exactly MAX_HP, so a
## centre hit kills — decaying to nothing at the edge of the circle.
static func hit_damage(d: float, radius: float, damage: float) -> float:
	if d >= radius:
		return 0.0
	var k := d / radius
	return damage * (1.0 - k * k)


## How much cover the target is getting from this particular shot, 0..1.
##
## Only rects hugging the *target* count, and only the face the shot passes.
## The bonus is `1 - sin(theta)` for incidence angle theta: a shot arriving
## square into the face gets nothing, a shot skimming along it (the grazing
## case) gets the lot. Grazing angle = more cover.
static func cover_bonus(x0: float, y0: float, x1: float, y1: float,
		rects: PackedFloat64Array) -> float:
	var dx := x1 - x0
	var dy := y1 - y0
	var l := Geom.hyp(dx, dy)
	if l < 1e-9:
		return 0.0
	var ux := dx / l
	var uy := dy / l
	var best := 0.0
	var n := rects.size()
	var i := 0
	while i < n:
		var rx := rects[i]
		var ry := rects[i + 1]
		var rw := rects[i + 2]
		var rh := rects[i + 3]
		i += 4
		if Geom.rect_dist(x1, y1, rx, ry, rw, rh) > COVER_NEAR:
			continue
		# ignore rects sitting behind the shooter rather than around the target
		if Geom.seg_point_t(x0, y0, x1, y1, rx + rw / 2.0, ry + rh / 2.0) < 0.35:
			continue
		var px := clampf(x1, rx, rx + rw)
		var py := clampf(y1, ry, ry + rh)
		var bonus := 1.0 - sin(Geom.face_incidence(ux, uy, px, py, rx, ry, rw, rh))
		if bonus > best:
			best = bonus
	return best


## Aim error, 1 sigma radians. Spread scales with actor randomness and movement.
static func aim_sigma(base_spread: float, randomness: float, moving: bool, cover: float) -> float:
	return base_spread * (1.0 + randomness) * (MOVE_SPREAD if moving else 1.0) + COVER_SPREAD * cover


## Aim error from failing to track a moving target, in radians.
static func track_sigma(dist: float, target_speed: float) -> float:
	if target_speed <= 0.0:
		return 0.0
	return (REACTION_TICKS * target_speed) / maxf(dist, 1.0)


static func aim_drift(dist: float, projectile_speed: float, target_moving: bool) -> float:
	return (LEAD * MOVE_SPEED * dist) / projectile_speed if target_moving else 0.0


## Estimated chance of connecting: the actor's radius against the spread the
## shot will have grown to by the time it arrives, plus the drift above.
## Monotonic in every argument, which is all fire control needs of it.
static func hit_chance(dist: float, sigma: float, drift: float = 0.0) -> float:
	return clampf(ACTOR_R / (dist * sigma + drift + 1e-6), 0.0, 1.0)


## Willingness to take long shots scales with risk.
static func fire_range(weapon_range: float, risk: float) -> float:
	return weapon_range * (0.55 + 0.45 * risk)


## Preferred engagement range. Aggressive actors want to be close, and an actor
## that would rather be in melee wants to be closer still — the other half of
## "meleePreference vs distance decides charge/shoot": without it a melee unit
## parks at shooting range and the charge utility never gets its chance.
static func pref_range(aggression: float, melee_preference: float = 0.0) -> float:
	return (PREF_FAR - aggression * PREF_SPAN) * (1.0 - 0.75 * melee_preference)


## The distance at which this actor's own fire control would finally let it
## shoot. An actor whose preferred range sits outside this stands and stares,
## which is how a disciplined unit talks itself into a stalemate, so `advance`
## closes to whichever is nearer.
static func engage_range(spread: float, randomness: float, discipline: float,
		weapon_range: float, risk: float, projectile_speed: float) -> float:
	var sigma := aim_sigma(spread, randomness, false, 0.0)
	var need := MIN_HIT_CHANCE * discipline
	if need <= 0.0:
		return fire_range(weapon_range, risk) * 0.9
	# solve hit_chance(d) = need against a walking target: spread and drift grow
	# with distance, tracking error does not
	var per_unit := sigma + (LEAD * MOVE_SPEED) / projectile_speed
	var budget := ACTOR_R / need - REACTION_TICKS * MOVE_SPEED
	var usable := 0.0 if budget <= 0.0 else budget / per_unit
	return minf(fire_range(weapon_range, risk) * 0.9, maxf(usable * 0.85, MELEE_RANGE * 2.0))


## Melee power for the contested roll — aggression and discipline.
static func melee_power(aggression: float, discipline: float, hp_frac: float, roll: float) -> float:
	return (0.4 + 0.9 * aggression) * (0.6 + 0.6 * discipline) * (0.5 + 0.5 * hp_frac) * (0.5 + roll)


# ── world state ───────────────────────────────────────────────────
var map_def: Dictionary
var cover: PackedFloat64Array
var seed_value: int
var max_ticks: int
var tick := 0
var capped := false
var n_actors := 0
var n_units := 0
## Living actors per team.
var team_alive := PackedInt32Array([0, 0])
var team_size := PackedInt32Array([0, 0])
## Set if any actor ever had more than MAX_NEAR_COVER rects in reach; a
## non-zero value means the cover list silently truncated somewhere.
var near_cover_overflow := 0

# actors, structure-of-arrays
var ax := PackedFloat64Array()
var ay := PackedFloat64Array()
var a_facing := PackedFloat64Array()
var a_hp := PackedFloat64Array()
var a_cover_x := PackedFloat64Array()
var a_cover_y := PackedFloat64Array()
var a_engage := PackedFloat64Array()
var a_aggression := PackedFloat64Array()
var a_risk := PackedFloat64Array()
var a_randomness := PackedFloat64Array()
var a_cohesion := PackedFloat64Array()
var a_discipline := PackedFloat64Array()
var a_melee_pref := PackedFloat64Array()
var a_damage_dealt := PackedFloat64Array()
var a_damage_taken := PackedFloat64Array()

var a_unit := PackedInt32Array()
var a_team := PackedInt32Array()
var a_state := PackedInt32Array()
var a_target := PackedInt32Array()
var a_cooldown := PackedInt32Array()
var a_melee_cd := PackedInt32Array()
var a_under_fire := PackedInt32Array()
var a_flank_sign := PackedInt32Array()
var a_avoid_sign := PackedInt32Array()
var a_shots := PackedInt32Array()
var a_hits := PackedInt32Array()
var a_kills := PackedInt32Array()
var a_melee_kills := PackedInt32Array()
var a_alive_ticks := PackedInt32Array()
var a_ticks_in_cover := PackedInt32Array()

var a_alive := PackedByteArray()
var a_moving := PackedByteArray()
var a_covered := PackedByteArray()

## Cover rects within reach of each actor, refreshed with its decision, as a
## fixed-stride slice of rect indices. The margin covers the worst drift between
## refreshes (DECIDE_EVERY ticks of movement plus separation shoves), so
## movement and pushout only ever test the 0-4 rects that can matter instead of
## the whole map.
var _near_cover := PackedInt32Array()
var _near_count := PackedInt32Array()

# units
var u_team := PackedInt32Array()
var u_alive := PackedInt32Array()
var u_size := PackedInt32Array()
var u_first := PackedInt32Array()
var u_cx := PackedFloat64Array()
var u_cy := PackedFloat64Array()
var u_w_speed := PackedFloat64Array()
var u_w_spread := PackedFloat64Array()
var u_w_damage := PackedFloat64Array()
var u_w_range := PackedFloat64Array()
var u_w_radius := PackedFloat64Array()
var u_w_cooldown := PackedInt32Array()
var u_name: Array[String] = []
var u_weapon_name: Array[String] = []
var u_personality: Array = []

# bullets
var b_x := PackedFloat64Array()
var b_y := PackedFloat64Array()
var b_vx := PackedFloat64Array()
var b_vy := PackedFloat64Array()
var b_damage := PackedFloat64Array()
var b_radius := PackedFloat64Array()
var b_team := PackedInt32Array()
var b_shooter := PackedInt32Array()
var b_count := 0
var _b_cap := 0

var _rng: WarRng
var _hash: SpatialHash
var _fine: SpatialHash
# read-only mirrors of the hash's CSR arrays, refreshed after every rebuild
var _hs := PackedInt32Array()
var _hm := PackedInt32Array()
var _hi := PackedInt32Array()
var _hx := PackedFloat64Array()
var _hy := PackedFloat64Array()
var _hcols := 0
var _hrows := 0
var _hcell := 96.0
var _fs := PackedInt32Array()
var _fm := PackedInt32Array()
var _fi := PackedInt32Array()
var _fcols := 0
var _frows := 0
var _fcell := 48.0
##
## Bounding box of each team's living actors, over the same positions the hash
## was filled with. Every broadphase query in this file is a query for *the
## other team*, so clipping the cell box to the enemy's extent first is exact —
## an actor outside the box cannot be inside the query — and in the approach
## phase, before the two sides are anywhere near each other, it takes the
## 430-unit perception ring from about a hundred cell probes to none.
##
var _team_min_x := PackedFloat64Array([0.0, 0.0])
var _team_max_x := PackedFloat64Array([0.0, 0.0])
var _team_min_y := PackedFloat64Array([0.0, 0.0])
var _team_max_y := PackedFloat64Array([0.0, 0.0])

## Where a team marches before it has seen anybody: the centre of the enemy
## spawn. Steering toward the unit's own centroid instead looks reasonable and
## is not — actors ahead of the centroid walk backwards into it, so the block
## compresses and the army creeps forward at a fraction of its speed, which on
## a 1600-wide field means the two sides never meet at all.
var _obj_x := PackedFloat64Array([0.0, 0.0])
var _obj_y := PackedFloat64Array([0.0, 0.0])

# decision scratch, reused every decision
var _bases := PackedFloat64Array()
var _cons := PackedFloat64Array()
var _dec_traits := PackedFloat64Array()
var _per_ids := PackedInt32Array()
var _per_d2 := PackedFloat64Array()
var _per_target := 0
var _per_dist := 0.0
var _per_visible := false
var _per_unit_dist := 0.0
var _per_in_cover := false
## Heading probes for `_step_actor`, reused rather than reallocated per call.
var _angles := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])


##
## `opts` is `{map: <data.gd MAPS entry>, units: [UnitDef], seed: int,
## max_ticks: int}`, where a UnitDef is
## `{team, name, count, personality: {the seven War traits}, weapon: <WEAPONS entry>}`.
##
func _init(opts: Dictionary) -> void:
	map_def = opts["map"]
	cover = D.cover_of(map_def)
	seed_value = int(opts["seed"])
	max_ticks = int(opts.get("max_ticks", DEFAULT_MAX_TICKS))
	_rng = WarRng.new(seed_value)
	_bases.resize(6)
	_cons.resize(30)
	_dec_traits.resize(5)
	_per_ids.resize(PERCEIVE_K)
	_per_d2.resize(PERCEIVE_K)
	var a: Rect2 = D.SPAWN_A
	var b: Rect2 = D.SPAWN_B
	_obj_x[0] = b.position.x + b.size.x / 2.0
	_obj_y[0] = b.position.y + b.size.y / 2.0
	_obj_x[1] = a.position.x + a.size.x / 2.0
	_obj_y[1] = a.position.y + a.size.y / 2.0
	_spawn(opts["units"])


# ── spawn ─────────────────────────────────────────────────────────
func _spawn(defs: Array) -> void:
	# count first so every Packed array is sized once
	var total_actors := 0
	for d in defs:
		if int(d["count"]) > 0:
			total_actors += int(d["count"])
	_resize_actors(total_actors)
	# ids are handed out team 0 first, then team 1 — an invariant `spatial.gd`
	# leans on to partition each cell by team for free
	var team1_first := 0
	for d in defs:
		if int(d["team"]) == 0 and int(d["count"]) > 0:
			team1_first += int(d["count"])
	_hash = SpatialHash.new(D.FIELD_W, D.FIELD_H, HASH_CELL, maxi(total_actors, 1), team1_first)
	_fine = SpatialHash.new(D.FIELD_W, D.FIELD_H, FINE_CELL, maxi(total_actors, 1), team1_first)

	for team in [0, 1]:
		var mine: Array = []
		for d in defs:
			if int(d["team"]) == team and int(d["count"]) > 0:
				mine.append(d)
		var total := 0
		for d in mine:
			total += int(d["count"])
		if total == 0:
			total = 1
		var zone: Rect2 = D.SPAWN_A if team == 0 else D.SPAWN_B
		var band_y: float = zone.position.y
		for udef in mine:
			var count := int(udef["count"])
			var p: Dictionary = udef["personality"]
			var w: Dictionary = udef["weapon"]
			var uid := n_units
			n_units += 1
			u_team.push_back(team)
			u_alive.push_back(0)
			u_size.push_back(count)
			u_first.push_back(n_actors)
			u_cx.push_back(zone.position.x + zone.size.x / 2.0)
			u_cy.push_back(band_y)
			u_w_speed.push_back(float(w["projectileSpeed"]))
			u_w_spread.push_back(float(w["spread"]))
			u_w_damage.push_back(float(w["damage"]))
			u_w_range.push_back(float(w["range"]))
			u_w_radius.push_back(float(w["bulletRadius"]))
			u_w_cooldown.push_back(int(w["cooldown"]))
			u_name.append(String(udef["name"]))
			u_weapon_name.append(String(w["name"]))
			u_personality.append(p)

			var band_h: float = (zone.size.y * float(count)) / float(total)
			# pack the unit into a block inside its band; wider bands get more columns
			var cols := maxi(1, mini(6, int(ceil(sqrt((float(count) * zone.size.x) / maxf(band_h, 1.0))))))
			var rows := int(ceil(float(count) / float(cols)))
			var jitter: float = float(p.get("jitter", 0.15))
			for i in range(count):
				var c := i % cols
				var r := i / cols
				# RNG draw order below is load-bearing: it is the order the TS
				# object literal evaluates its properties in.
				var x: float = zone.position.x + ((float(c) + 0.5) * zone.size.x) / float(cols) + (_rng.next() - 0.5) * 8.0
				var y: float = band_y + ((float(r) + 0.5) * band_h) / float(rows) + (_rng.next() - 0.5) * 6.0
				var id := n_actors
				n_actors += 1
				ax[id] = clampf(x, ACTOR_R, D.FIELD_W - ACTOR_R)
				ay[id] = clampf(y, ACTOR_R, D.FIELD_H - ACTOR_R)
				a_facing[id] = 0.0 if team == 0 else PI
				a_hp[id] = MAX_HP
				a_alive[id] = 1
				a_state[id] = D.ADVANCE
				a_target[id] = -1
				a_cooldown[id] = int(_rng.randi_below(int(w["cooldown"])))
				a_melee_cd[id] = 0
				a_under_fire[id] = 0
				a_cover_x[id] = -1.0
				a_cover_y[id] = -1.0
				a_moving[id] = 0
				a_covered[id] = 0
				var fr: float = _rng.next()
				a_flank_sign[id] = 1 if fr < 0.5 else -1
				var ar: float = _rng.next()
				a_avoid_sign[id] = 1 if ar < 0.5 else -1
				a_aggression[id] = _jitter_trait(float(p["aggression"]), jitter)
				a_risk[id] = _jitter_trait(float(p["risk"]), jitter)
				a_randomness[id] = _jitter_trait(float(p["randomness"]), jitter)
				a_cohesion[id] = _jitter_trait(float(p["cohesion"]), jitter)
				a_discipline[id] = _jitter_trait(float(p["discipline"]), jitter)
				a_melee_pref[id] = _jitter_trait(float(p["meleePreference"]), jitter)
				a_unit[id] = uid
				a_team[id] = team
				a_engage[id] = engage_range(
					float(w["spread"]), a_randomness[id], a_discipline[id],
					float(w["range"]), a_risk[id], float(w["projectileSpeed"]))
				u_alive[uid] += 1
				team_alive[team] += 1
				team_size[team] += 1
			band_y += band_h

	# pull anyone spawned inside cover back out (spawn strips are clear, but a
	# hand-authored map could change that and silently pin a unit)
	for id in range(n_actors):
		_refresh_near_cover(id)
		_resolve_cover(id)


## Per-actor deviation from the unit: a triangular sample scaled by the unit's
## `jitter`. `jitter` itself is never jittered.
func _jitter_trait(base: float, jitter: float) -> float:
	var t: float = _rng.next() + _rng.next() - 1.0
	return clampf(base + t * jitter * JITTER_SCALE, 0.0, 1.0)


func _resize_actors(n: int) -> void:
	ax.resize(n); ay.resize(n); a_facing.resize(n); a_hp.resize(n)
	a_cover_x.resize(n); a_cover_y.resize(n); a_engage.resize(n)
	a_aggression.resize(n); a_risk.resize(n); a_randomness.resize(n)
	a_cohesion.resize(n); a_discipline.resize(n); a_melee_pref.resize(n)
	a_damage_dealt.resize(n); a_damage_taken.resize(n)
	a_unit.resize(n); a_team.resize(n); a_state.resize(n); a_target.resize(n)
	a_cooldown.resize(n); a_melee_cd.resize(n); a_under_fire.resize(n)
	a_flank_sign.resize(n); a_avoid_sign.resize(n)
	a_shots.resize(n); a_hits.resize(n); a_kills.resize(n); a_melee_kills.resize(n)
	a_alive_ticks.resize(n); a_ticks_in_cover.resize(n)
	a_alive.resize(n); a_moving.resize(n); a_covered.resize(n)
	_near_cover.resize(n * MAX_NEAR_COVER)
	_near_count.resize(n)
	_grow_bullets(256)


func _grow_bullets(cap: int) -> void:
	if cap <= _b_cap:
		return
	_b_cap = cap
	b_x.resize(cap); b_y.resize(cap); b_vx.resize(cap); b_vy.resize(cap)
	b_damage.resize(cap); b_radius.resize(cap)
	b_team.resize(cap); b_shooter.resize(cap)


##
## The three functions below open-code point-to-rect distance and circle
## pushout instead of calling `geom.gd`. They are the difference between a
## comfortable tick and a marginal one on the cover-heavy maps — between them
## they run some thousands of times a tick, the arithmetic is a handful of
## operations, and a cross-script static call in GDScript costs more than that.
## `geom.gd` stays the readable reference and the tests pin these against it.
##
func _refresh_near_cover(id: int) -> void:
	var base := id * MAX_NEAR_COVER
	var count := 0
	var x := ax[id]
	var y := ay[id]
	var reach := ACTOR_R + NEAR_COVER_MARGIN
	var reach2 := reach * reach
	var n := cover.size()
	var i := 0
	while i < n:
		var rx := cover[i]
		var ry := cover[i + 1]
		var dx := maxf(maxf(rx - x, 0.0), x - (rx + cover[i + 2]))
		var dy := maxf(maxf(ry - y, 0.0), y - (ry + cover[i + 3]))
		if dx * dx + dy * dy < reach2:
			if count < MAX_NEAR_COVER:
				_near_cover[base + count] = i
				count += 1
			else:
				near_cover_overflow += 1
		i += 4
	_near_count[id] = count


func _resolve_cover(id: int) -> void:
	var cnt := _near_count[id]
	var x := ax[id]
	var y := ay[id]
	if cnt > 0:
		var base := id * MAX_NEAR_COVER
		for _pass in range(2):
			for k in range(cnt):
				var i := _near_cover[base + k]
				var rx := cover[i]
				var ry := cover[i + 1]
				var rw := cover[i + 2]
				var rh := cover[i + 3]
				var dx := x - clampf(x, rx, rx + rw)
				var dy := y - clampf(y, ry, ry + rh)
				if dx * dx + dy * dy >= ACTOR_R2:
					continue          # clear of this rect, nothing to resolve
				var v := Geom.push_out_circle(x, y, ACTOR_R, rx, ry, rw, rh)
				x = v.x
				y = v.y
	ax[id] = clampf(x, ACTOR_R, D.FIELD_W - ACTOR_R)
	ay[id] = clampf(y, ACTOR_R, D.FIELD_H - ACTOR_R)


func _in_cover(id: int) -> bool:
	var cnt := _near_count[id]
	if cnt == 0:
		return false
	var base := id * MAX_NEAR_COVER
	var x := ax[id]
	var y := ay[id]
	var reach := ACTOR_R + 16.0
	var reach2 := reach * reach
	for k in range(cnt):
		var i := _near_cover[base + k]
		var rx := cover[i]
		var ry := cover[i + 1]
		var dx := maxf(maxf(rx - x, 0.0), x - (rx + cover[i + 2]))
		var dy := maxf(maxf(ry - y, 0.0), y - (ry + cover[i + 3]))
		if dx * dx + dy * dy <= reach2:
			return true
	return false


# ── the tick ──────────────────────────────────────────────────────
func finished() -> bool:
	return team_alive[0] == 0 or team_alive[1] == 0 or tick >= max_ticks


func step() -> void:
	if finished():
		if tick >= max_ticks:
			capped = true
		return
	var t := tick
	var late := maxf(0.0, (float(t) - float(max_ticks) * 0.5) / (float(max_ticks) * 0.5))

	_rebuild_hash()
	_refresh_units()

	# 1. decide (staggered) — 2. move
	for id in range(n_actors):
		if a_alive[id] == 0:
			continue
		# Strictly staggered: every actor decides within the first DECIDE_EVERY
		# ticks and every DECIDE_EVERY ticks after. (An "or when it has no
		# target" clause here is a trap — before the two sides are in sight of
		# each other that is *everybody*, and the whole approach runs at 6x the
		# decision cost for no behavioural gain.)
		if (t + id) % DECIDE_EVERY == 0:
			_refresh_near_cover(id)
			_decide(id, late)
		_move(id)
		a_alive_ticks[id] += 1
		var cov := _in_cover(id)
		a_covered[id] = 1 if cov else 0
		if cov:
			a_ticks_in_cover[id] += 1
		if a_under_fire[id] > 0:
			a_under_fire[id] -= 1

	_separate()
	_melee()
	_fire()
	_advance_bullets()

	tick += 1
	if tick >= max_ticks and team_alive[0] > 0 and team_alive[1] > 0:
		capped = true


func _rebuild_hash() -> void:
	_hash.begin()
	_fine.begin()
	for t in [0, 1]:
		_team_min_x[t] = INF
		_team_max_x[t] = -INF
		_team_min_y[t] = INF
		_team_max_y[t] = -INF
	for id in range(n_actors):
		if a_alive[id] == 1:
			var x := ax[id]
			var y := ay[id]
			_hash.add(id, x, y)
			_fine.add(id, x, y)
			var t := a_team[id]
			if x < _team_min_x[t]: _team_min_x[t] = x
			if x > _team_max_x[t]: _team_max_x[t] = x
			if y < _team_min_y[t]: _team_min_y[t] = y
			if y > _team_max_y[t]: _team_max_y[t] = y
	_hash.build()
	_fine.build()
	_hs = _hash.cell_start
	_hm = _hash.cell_mid
	_hi = _hash.items
	_hx = _hash.xs
	_hy = _hash.ys
	_hcols = _hash.cols
	_hrows = _hash.rows
	_hcell = _hash.cell
	_fs = _fine.cell_start
	_fm = _fine.cell_mid
	_fi = _fine.items
	_fcols = _fine.cols
	_frows = _fine.rows
	_fcell = _fine.cell


func _refresh_units() -> void:
	for u in range(n_units):
		u_cx[u] = 0.0
		u_cy[u] = 0.0
		u_alive[u] = 0
	for id in range(n_actors):
		if a_alive[id] == 0:
			continue
		var u := a_unit[id]
		u_cx[u] += ax[id]
		u_cy[u] += ay[id]
		u_alive[u] += 1
	for u in range(n_units):
		if u_alive[u] > 0:
			u_cx[u] /= float(u_alive[u])
			u_cy[u] /= float(u_alive[u])


##
## Line of sight against the map's cover.
##
## Identical in result to `Geom.los_clear`, but the rects are walked here with
## a bounding-box reject in front of the slab test. This is the single hottest
## call in the simulation — every perception candidate pays for it — and in
## GDScript the cross-script static call alone cost more than the arithmetic
## it was guarding.
##
func _los_clear(x0: float, y0: float, x1: float, y1: float) -> bool:
	var lox := x0 if x0 < x1 else x1
	var hix := x1 if x0 < x1 else x0
	var loy := y0 if y0 < y1 else y1
	var hiy := y1 if y0 < y1 else y0
	var n := cover.size()
	var i := 0
	while i < n:
		var rx := cover[i]
		var ry := cover[i + 1]
		var rw := cover[i + 2]
		var rh := cover[i + 3]
		i += 4
		if hix < rx or lox > rx + rw or hiy < ry or loy > ry + rh:
			continue
		if Geom.seg_rect_t(x0, y0, x1, y1, rx, ry, rw, rh) != INF:
			return false
	return true


# ── perception + decision ─────────────────────────────────────────
##
## Expanding-ring nearest-enemy search with a hard cap on line-of-sight tests.
## A full VISION-radius scan with a LOS test per candidate is what makes the
## naive version quadratic-ish; in a dense battle the 150-unit ring almost
## always answers.
##
## Results land in the `_per_*` fields — the caller consumes them immediately
## and nothing stores them.
##
func _perceive(id: int) -> void:
	var px := ax[id]
	var py := ay[id]
	var my_team := a_team[id]
	var best_id := -1
	var best_d := INF
	var best_visible := false
	for radius in PERCEIVE_RINGS:
		var found := _collect_enemies(px, py, radius, my_team)
		if found == 0:
			continue
		var hit := false
		for k in range(found):
			var g: int = _per_ids[k]
			if not _los_clear(px, py, ax[g], ay[g]):
				continue
			best_id = g
			best_d = sqrt(_per_d2[k])
			best_visible = true
			hit = true
			break
		if hit:
			break
		# nothing in this ring has a lane: remember the nearest anyway and widen
		best_id = _per_ids[0]
		best_d = sqrt(_per_d2[0])
	var u := a_unit[id]
	_per_target = best_id
	_per_dist = VISION if best_id == -1 else best_d
	_per_visible = best_visible
	_per_unit_dist = Geom.hyp(u_cx[u] - px, u_cy[u] - py)
	_per_in_cover = a_covered[id] == 1


## Top-K nearest living enemies inside `radius`, into `_per_ids` / `_per_d2`.
## Ties break on the lower id so bucket order cannot decide a target.
func _collect_enemies(px: float, py: float, radius: float, my_team: int) -> int:
	var count := 0
	var foe := 1 - my_team
	if _team_min_x[foe] > _team_max_x[foe]:
		return 0                                  # the other side is gone
	var cx0 := maxi(clampi(int(floor((px - radius) / _hcell)), 0, _hcols - 1),
		int(floor(_team_min_x[foe] / _hcell)))
	var cx1 := mini(clampi(int(floor((px + radius) / _hcell)), 0, _hcols - 1),
		int(floor(_team_max_x[foe] / _hcell)))
	var cy0 := maxi(clampi(int(floor((py - radius) / _hcell)), 0, _hrows - 1),
		int(floor(_team_min_y[foe] / _hcell)))
	var cy1 := mini(clampi(int(floor((py + radius) / _hcell)), 0, _hrows - 1),
		int(floor(_team_max_y[foe] / _hcell)))
	if cx0 > cx1 or cy0 > cy1:
		return 0
	var r2 := radius * radius
	for cy in range(cy0, cy1 + 1):
		var row := cy * _hcols
		for cx in range(cx0, cx1 + 1):
			var b := row + cx
			# Only the other side is ever a target, and the cell's ids are
			# already partitioned by team. No liveness check: the hash was
			# filled with the living at the top of this tick and nothing dies
			# until melee, which runs after every decision.
			var k0 := _hm[b] if my_team == 0 else _hs[b]
			var k1 := _hs[b + 1] if my_team == 0 else _hm[b]
			for k in range(k0, k1):
				var gid: int = _hi[k]
				var dx: float = _hx[gid] - px
				var dy: float = _hy[gid] - py
				var d2 := dx * dx + dy * dy
				if d2 > r2:
					continue
				var slot := count if count < PERCEIVE_K else -1
				var lim := count if count < PERCEIVE_K else PERCEIVE_K
				for i in range(lim):
					if d2 < _per_d2[i] or (d2 == _per_d2[i] and gid < _per_ids[i]):
						slot = i
						break
				if slot < 0:
					continue
				var start := count if count < PERCEIVE_K else PERCEIVE_K - 1
				var i2 := start
				while i2 > slot:
					_per_d2[i2] = _per_d2[i2 - 1]
					_per_ids[i2] = _per_ids[i2 - 1]
					i2 -= 1
				_per_d2[slot] = d2
				_per_ids[slot] = gid
				if count < PERCEIVE_K:
					count += 1
	return count


##
## Fill the shared candidate arrays for one actor. Consideration weights
## multiply the *actor's* trait values — the jittered ones, not the unit's.
##
func _build_candidates(id: int, late: float) -> void:
	var dn := clampf(_per_dist / VISION, 0.0, 1.0)         # 0 = contact, 1 = edge of vision
	var near := 1.0 - clampf(_per_dist / CHARGE_REACH, 0.0, 1.0)  # 1 = in charging distance
	var hurt := 1.0 - a_hp[id] / MAX_HP
	var strayed := clampf(_per_unit_dist / 260.0, 0.0, 1.0)
	var uf := 1.0 if a_under_fire[id] > 0 else 0.0

	# advance — close to preferred range and fight there
	_bases[0] = 0.20 + 0.45 * dn + late * 0.55
	_cons[0] = 0.40; _cons[1] = 0.05; _cons[2] = 0.15; _cons[3] = 0.0; _cons[4] = 0.0

	# charge — only interesting once the enemy is genuinely close
	_bases[1] = -0.25 + near * 0.50 + late * 0.45 - hurt * 0.2
	_cons[5] = 0.55 * near; _cons[6] = 0.2 * near; _cons[7] = 0.0
	_cons[8] = -0.35; _cons[9] = 2.2 * near

	# hold — stand and shoot the lane you already have
	_bases[2] = 0.10 - 0.30 * dn + (0.20 if _per_visible else -0.55) + (0.15 if _per_in_cover else 0.0) - late * 0.5
	_cons[10] = -0.40; _cons[11] = 0.0; _cons[12] = 0.0; _cons[13] = 0.85; _cons[14] = -0.2

	# flank — arc around through open ground
	_bases[3] = 0.16 - 0.10 * dn
	_cons[15] = 0.10; _cons[16] = 0.70; _cons[17] = -0.45; _cons[18] = -0.20; _cons[19] = 0.0

	# seekCover — high risk ignores cover entirely, low risk runs for it under fire
	_bases[4] = -0.15 + uf * 0.45 + hurt * 0.30 + (-0.25 if _per_in_cover else 0.10) - late * 0.5
	_cons[20] = -0.45; _cons[21] = -1.30 - 0.6 * uf; _cons[22] = 0.0
	_cons[23] = 0.25; _cons[24] = -0.2

	# regroup — fall back on the unit
	_bases[5] = -0.55 + strayed * 0.35
	_cons[25] = -0.35; _cons[26] = -0.2; _cons[27] = 1.25 * strayed
	_cons[28] = 0.1; _cons[29] = 0.0


func _decide(id: int, late: float) -> void:
	_perceive(id)
	a_target[id] = _per_target
	_build_candidates(id, late)
	_dec_traits[0] = a_aggression[id]
	_dec_traits[1] = a_risk[id]
	_dec_traits[2] = a_cohesion[id]
	_dec_traits[3] = a_discipline[id]
	_dec_traits[4] = a_melee_pref[id]
	var prev := a_state[id]
	a_state[id] = UtilityEngine.decide(
		_bases, _cons, _dec_traits, a_randomness[id], _rng, prev, INERTIA)
	if a_state[id] == D.SEEK_COVER:
		_pick_cover(id, _per_target)


## Nearest cover point that breaks line of sight from the threat.
func _pick_cover(id: int, threat: int) -> void:
	var has_threat := threat >= 0
	var tx: float = ax[threat] if has_threat else D.FIELD_W / 2.0
	var ty: float = ay[threat] if has_threat else D.FIELD_H / 2.0
	var bx := ax[id]
	var by := ay[id]
	var best := INF
	var n := cover.size()
	var i := 0
	while i < n:
		var rx := cover[i]
		var ry := cover[i + 1]
		var rw := cover[i + 2]
		var rh := cover[i + 3]
		i += 4
		var cx := rx + rw / 2.0
		var cy := ry + rh / 2.0
		var dx := cx - tx
		var dy := cy - ty
		var l := Geom.hyp(dx, dy)
		if l == 0.0:
			l = 1.0
		dx /= l
		dy /= l
		var px := clampf(cx + dx * (maxf(rw, rh) / 2.0 + ACTOR_R + 5.0), ACTOR_R, D.FIELD_W - ACTOR_R)
		var py := clampf(cy + dy * (maxf(rw, rh) / 2.0 + ACTOR_R + 5.0), ACTOR_R, D.FIELD_H - ACTOR_R)
		var d := Geom.hyp(px - ax[id], py - ay[id])
		var score := d
		if has_threat and not _los_clear(px, py, tx, ty):
			score -= 260.0
		if score < best:
			best = score
			bx = px
			by = py
	a_cover_x[id] = bx
	a_cover_y[id] = by


# ── movement ──────────────────────────────────────────────────────
func _move(id: int) -> void:
	var t := a_target[id]
	var has_t := t >= 0 and a_alive[t] == 1
	var team := a_team[id]
	var u := a_unit[id]
	var tx: float = ax[t] if has_t else _obj_x[team]
	var ty: float = ay[t] if has_t else _obj_y[team]
	var myx := ax[id]
	var myy := ay[id]
	var ddx := tx - myx
	var ddy := ty - myy
	var dist := sqrt(ddx * ddx + ddy * ddy)
	if dist == 0.0:
		dist = 1.0
	var dx := 0.0
	var dy := 0.0

	var st := a_state[id]
	if st == D.ADVANCE:
		var want := minf(pref_range(a_aggression[id], a_melee_pref[id]), a_engage[id])
		if dist > want:
			dx = ddx; dy = ddy
		elif dist < want * 0.6:
			dx = -ddx; dy = -ddy
	elif st == D.CHARGE:
		# serpentine so a charge is not a free target; weave shrinks with discipline
		var weave := (0.55 - 0.35 * a_discipline[id]) * sin(float(tick + id * 7) * 0.09)
		dx = ddx / dist - (ddy / dist) * weave
		dy = ddy / dist + (ddx / dist) * weave
	elif st == D.FLANK:
		var fs := float(a_flank_sign[id])
		dx = (-ddy / dist) * fs + (ddx / dist) * 0.35
		dy = (ddx / dist) * fs + (ddy / dist) * 0.35
	elif st == D.SEEK_COVER:
		dx = a_cover_x[id] - myx
		dy = a_cover_y[id] - myy
		if sqrt(dx * dx + dy * dy) < 5.0:
			dx = 0.0; dy = 0.0
	elif st == D.REGROUP:
		dx = u_cx[u] - myx
		dy = u_cy[u] - myy
		if sqrt(dx * dx + dy * dy) < 20.0:
			dx = 0.0; dy = 0.0
	# D.HOLD: stand still and shoot the lane you already have

	# cohesion pull, on every state that is already moving
	if (dx != 0.0 or dy != 0.0) and a_cohesion[id] > 0.0:
		var ux := u_cx[u] - myx
		var uy := u_cy[u] - myy
		var ud := sqrt(ux * ux + uy * uy)
		if ud > 70.0:
			var l := sqrt(dx * dx + dy * dy)
			if l == 0.0:
				l = 1.0
			var pull := a_cohesion[id] * 0.5
			dx = dx / l + (ux / ud) * pull
			dy = dy / l + (uy / ud) * pull

	a_facing[id] = atan2(ddy, ddx)
	if dx == 0.0 and dy == 0.0:
		a_moving[id] = 0
		return
	_step_actor(id, dx, dy)
	var mvx := ax[id] - myx
	var mvy := ay[id] - myy
	var moved := sqrt(mvx * mvx + mvy * mvy)
	a_moving[id] = 1 if moved > MOVE_SPEED * 0.25 else 0
	if a_state[id] == D.FLANK and moved < MOVE_SPEED * 0.3:
		a_flank_sign[id] = -a_flank_sign[id]


## Step in a direction, sliding around cover; probe rotated headings if pinned.
func _step_actor(id: int, dir_x: float, dir_y: float) -> void:
	var l := sqrt(dir_x * dir_x + dir_y * dir_y)
	if l < 1e-9:
		return
	dir_x /= l
	dir_y /= l
	var speed := MOVE_SPEED * CHARGE_SPEED if a_state[id] == D.CHARGE else MOVE_SPEED
	var base := id * MAX_NEAR_COVER
	var cnt := _near_count[id]
	if cnt == 0:
		# Nothing to slide around: the un-rotated heading is the answer unless
		# the field edge clamps it short, in which case fall through and let
		# the probe loop try rotated headings exactly as it otherwise would.
		var fx := clampf(ax[id] + dir_x * speed, ACTOR_R, D.FIELD_W - ACTOR_R)
		var fy := clampf(ay[id] + dir_y * speed, ACTOR_R, D.FIELD_H - ACTOR_R)
		var fdx := fx - ax[id]
		var fdy := fy - ay[id]
		if sqrt(fdx * fdx + fdy * fdy) > speed * 0.45:
			ax[id] = fx
			ay[id] = fy
			return
	var s := float(a_avoid_sign[id])
	_angles[0] = 0.0
	_angles[1] = 0.7 * s
	_angles[2] = -0.7 * s
	_angles[3] = 1.4 * s
	_angles[4] = -1.4 * s
	var best_moved := -1.0
	var bx := ax[id]
	var by := ay[id]
	for probe in range(5):
		var ang := _angles[probe]
		var ca: float = cos(ang)
		var sa: float = sin(ang)
		var ux := dir_x * ca - dir_y * sa
		var uy := dir_x * sa + dir_y * ca
		var nx := clampf(ax[id] + ux * speed, ACTOR_R, D.FIELD_W - ACTOR_R)
		var ny := clampf(ay[id] + uy * speed, ACTOR_R, D.FIELD_H - ACTOR_R)
		for _pass in range(2):
			for k in range(cnt):
				var i := _near_cover[base + k]
				var rx := cover[i]
				var ry := cover[i + 1]
				var rw := cover[i + 2]
				var rh := cover[i + 3]
				var px := nx - clampf(nx, rx, rx + rw)
				var py := ny - clampf(ny, ry, ry + rh)
				if px * px + py * py >= ACTOR_R2:
					continue
				var v := Geom.push_out_circle(nx, ny, ACTOR_R, rx, ry, rw, rh)
				nx = v.x
				ny = v.y
		nx = clampf(nx, ACTOR_R, D.FIELD_W - ACTOR_R)
		ny = clampf(ny, ACTOR_R, D.FIELD_H - ACTOR_R)
		var free := true
		var min_free := ACTOR_R - 1e-3
		var min_free2 := min_free * min_free
		for k in range(cnt):
			var i := _near_cover[base + k]
			var rx := cover[i]
			var ry := cover[i + 1]
			var qx := maxf(maxf(rx - nx, 0.0), nx - (rx + cover[i + 2]))
			var qy := maxf(maxf(ry - ny, 0.0), ny - (ry + cover[i + 3]))
			if qx * qx + qy * qy < min_free2:
				free = false
				break
		if not free:
			continue
		var pdx := nx - ax[id]
		var pdy := ny - ay[id]
		var moved := sqrt(pdx * pdx + pdy * pdy)
		if moved > speed * 0.45:
			ax[id] = nx
			ay[id] = ny
			return
		if moved > best_moved:
			best_moved = moved
			bx = nx
			by = ny
	ax[id] = bx
	ay[id] = by
	if best_moved < speed * 0.2:
		a_avoid_sign[id] = -a_avoid_sign[id]


## Keep bodies apart. Each pair is visited once, in ascending id order.
func _separate() -> void:
	var radius := SEPARATION + QUERY_MARGIN
	var r2 := radius * radius
	for id in range(n_actors):
		if a_alive[id] == 0:
			continue
		var px := ax[id]
		var py := ay[id]
		# The query box is fixed at the pre-scan position, but the pushes below
		# move this actor as they go, so its live position is carried in mx/my
		# and written back once instead of round-tripping the array per pair.
		var mx := px
		var my := py
		var cx0 := clampi(int(floor((px - radius) / _fcell)), 0, _fcols - 1)
		var cx1 := clampi(int(floor((px + radius) / _fcell)), 0, _fcols - 1)
		var cy0 := clampi(int(floor((py - radius) / _fcell)), 0, _frows - 1)
		var cy1 := clampi(int(floor((py + radius) / _fcell)), 0, _frows - 1)
		for cy in range(cy0, cy1 + 1):
			var row := cy * _fcols
			for cx in range(cx0, cx1 + 1):
				var b := row + cx
				for k in range(_fs[b], _fs[b + 1]):
					var gid: int = _fi[k]
					if gid <= id:
						continue
					var hdx: float = _hx[gid] - px
					var hdy: float = _hy[gid] - py
					if hdx * hdx + hdy * hdy > r2:
						continue
					if a_alive[gid] == 0:
						continue
					var dx: float = ax[gid] - mx
					var dy: float = ay[gid] - my
					var d2 := dx * dx + dy * dy
					if d2 >= SEPARATION2:
						continue
					var d := sqrt(d2)
					if d < 1e-6:
						dx = 1.0
						dy = 0.0
					else:
						dx /= d
						dy /= d
					var push := (SEPARATION - d) / 2.0
					mx -= dx * push
					my -= dy * push
					ax[gid] += dx * push
					ay[gid] += dy * push
		ax[id] = mx
		ay[id] = my
	for id in range(n_actors):
		if a_alive[id] == 1:
			_resolve_cover(id)


##
## Contested roll between enemies in contact, when at least one of them wants
## it. `meleePreference` decides who closes; aggression and discipline decide
## who wins.
##
func _melee() -> void:
	var radius := MELEE_RANGE + QUERY_MARGIN
	var r2 := radius * radius
	for id in range(n_actors):
		if a_alive[id] == 0:
			continue
		if a_melee_cd[id] > 0:
			a_melee_cd[id] -= 1
			continue
		var px := ax[id]
		var py := ay[id]
		var my_team := a_team[id]
		var foe := 1 - my_team
		if _team_min_x[foe] > _team_max_x[foe]:
			continue
		var cx0 := maxi(clampi(int(floor((px - radius) / _fcell)), 0, _fcols - 1),
			int(floor(_team_min_x[foe] / _fcell)))
		var cx1 := mini(clampi(int(floor((px + radius) / _fcell)), 0, _fcols - 1),
			int(floor(_team_max_x[foe] / _fcell)))
		var cy0 := maxi(clampi(int(floor((py - radius) / _fcell)), 0, _frows - 1),
			int(floor(_team_min_y[foe] / _fcell)))
		var cy1 := mini(clampi(int(floor((py + radius) / _fcell)), 0, _frows - 1),
			int(floor(_team_max_y[foe] / _fcell)))
		for cy in range(cy0, cy1 + 1):
			var row := cy * _fcols
			for cx in range(cx0, cx1 + 1):
				var b := row + cx
				var k0 := _fm[b] if my_team == 0 else _fs[b]
				var k1 := _fs[b + 1] if my_team == 0 else _fm[b]
				for k in range(k0, k1):
					var gid: int = _fi[k]
					if gid <= id:
						continue
					var hdx: float = _hx[gid] - px
					var hdy: float = _hy[gid] - py
					if hdx * hdx + hdy * hdy > r2:
						continue
					# a fight earlier in this same query can have put the actor
					# on cooldown or killed it
					if a_alive[id] == 0 or a_melee_cd[id] > 0:
						continue
					if a_alive[gid] == 0 or a_melee_cd[gid] > 0:
						continue
					var mdx := ax[gid] - ax[id]
					var mdy := ay[gid] - ay[id]
					if sqrt(mdx * mdx + mdy * mdy) > MELEE_RANGE:
						continue
					var wants := a_state[id] == D.CHARGE or a_state[gid] == D.CHARGE \
						or a_melee_pref[id] > 0.65 or a_melee_pref[gid] > 0.65
					if not wants:
						continue
					var pa: float = melee_power(a_aggression[id], a_discipline[id], a_hp[id] / MAX_HP, _rng.next())
					var pb: float = melee_power(a_aggression[gid], a_discipline[gid], a_hp[gid] / MAX_HP, _rng.next())
					var win := id if pa >= pb else gid    # exact ties go to the lower id
					var lose := gid if pa >= pb else id
					var dmg := minf(MELEE_DMG, a_hp[lose])
					a_hp[lose] -= dmg
					a_damage_taken[lose] += dmg
					a_damage_dealt[win] += dmg
					a_melee_cd[id] = MELEE_COOLDOWN
					a_melee_cd[gid] = MELEE_COOLDOWN
					a_under_fire[lose] = UNDER_FIRE_TICKS
					if a_hp[lose] <= 0.0:
						_kill(lose, win, true)


func _kill(victim: int, killer: int, by_melee: bool) -> void:
	a_alive[victim] = 0
	a_hp[victim] = 0.0
	u_alive[a_unit[victim]] -= 1
	team_alive[a_team[victim]] -= 1
	if killer >= 0:
		a_kills[killer] += 1
		if by_melee:
			a_melee_kills[killer] += 1


# ── fire control ──────────────────────────────────────────────────
func _fire() -> void:
	for id in range(n_actors):
		if a_alive[id] == 0:
			continue
		if a_cooldown[id] > 0:
			a_cooldown[id] -= 1
			continue
		var t := a_target[id]
		if t < 0 or a_alive[t] == 0:
			continue
		var u := a_unit[id]
		var fdx := ax[t] - ax[id]
		var fdy := ay[t] - ay[id]
		var dist := sqrt(fdx * fdx + fdy * fdy)
		if dist > fire_range(u_w_range[u], a_risk[id]):
			continue

		var lane := _los_clear(ax[id], ay[id], ax[t], ay[t])
		if not lane:
			# discipline is fire control: the disciplined hold, the rest waste
			# rounds on the wall
			var roll: float = _rng.next()
			if roll > (1.0 - a_discipline[id]) * 0.22:
				continue
		var cov := cover_bonus(ax[id], ay[id], ax[t], ay[t], cover)
		var t_speed := 0.0
		if a_moving[t] == 1:
			t_speed = MOVE_SPEED * CHARGE_SPEED if a_state[t] == D.CHARGE else MOVE_SPEED
		var sigma := aim_sigma(u_w_spread[u], a_randomness[id], a_moving[id] == 1, cov) + track_sigma(dist, t_speed)
		var drift := aim_drift(dist, u_w_speed[u], a_moving[t] == 1)
		if lane and hit_chance(dist, sigma, drift) < MIN_HIT_CHANCE * a_discipline[id]:
			continue

		var err: float = (_rng.next() + _rng.next() - 1.0) * sigma
		var ang: float = atan2(ay[t] - ay[id], ax[t] - ax[id]) + err
		a_facing[id] = ang
		_spawn_bullet(ax[id], ay[id], cos(ang) * u_w_speed[u], sin(ang) * u_w_speed[u],
			a_team[id], id, u_w_damage[u], u_w_radius[u])
		a_cooldown[id] = u_w_cooldown[u]
		a_shots[id] += 1


func _spawn_bullet(x: float, y: float, vx: float, vy: float, team: int, shooter: int,
		damage: float, radius: float) -> void:
	if b_count >= _b_cap:
		_grow_bullets(_b_cap * 2)
	b_x[b_count] = x; b_y[b_count] = y
	b_vx[b_count] = vx; b_vy[b_count] = vy
	b_team[b_count] = team; b_shooter[b_count] = shooter
	b_damage[b_count] = damage; b_radius[b_count] = radius
	b_count += 1


# ── projectiles ───────────────────────────────────────────────────
## Swept segment per projectile, nearest of {cover rect, enemy actor}. The
## survivors are compacted in place, which preserves their order.
func _advance_bullets() -> void:
	if b_count == 0:
		return
	var write := 0
	for bi in range(b_count):
		var x0 := b_x[bi]
		var y0 := b_y[bi]
		var nx := x0 + b_vx[bi]
		var ny := y0 + b_vy[bi]
		var lox := minf(x0, nx)
		var hix := maxf(x0, nx)
		var loy := minf(y0, ny)
		var hiy := maxf(y0, ny)

		var best_t := INF
		var n := cover.size()
		var i := 0
		while i < n:
			var rx := cover[i]
			var ry := cover[i + 1]
			var rw := cover[i + 2]
			var rh := cover[i + 3]
			i += 4
			if hix < rx or lox > rx + rw or hiy < ry or loy > ry + rh:
				continue
			var ct := Geom.seg_rect_t(x0, y0, nx, ny, rx, ry, rw, rh)
			if ct < best_t:
				best_t = ct

		var rr := ACTOR_R + b_radius[bi]
		var margin := rr + QUERY_MARGIN
		var team := b_team[bi]
		var hit_id := -1
		var foe := 1 - team
		var cx0 := maxi(clampi(int(floor((lox - margin) / _hcell)), 0, _hcols - 1),
			int(floor(_team_min_x[foe] / _hcell)))
		var cx1 := mini(clampi(int(floor((hix + margin) / _hcell)), 0, _hcols - 1),
			int(floor(_team_max_x[foe] / _hcell)))
		var cy0 := maxi(clampi(int(floor((loy - margin) / _hcell)), 0, _hrows - 1),
			int(floor(_team_min_y[foe] / _hcell)))
		var cy1 := mini(clampi(int(floor((hiy + margin) / _hcell)), 0, _hrows - 1),
			int(floor(_team_max_y[foe] / _hcell)))
		for cy in range(cy0, cy1 + 1):
			var row := cy * _hcols
			for cx in range(cx0, cx1 + 1):
				var b := row + cx
				var k0 := _hm[b] if team == 0 else _hs[b]
				var k1 := _hs[b + 1] if team == 0 else _hm[b]
				for k in range(k0, k1):
					var fid: int = _hi[k]
					if a_alive[fid] == 0:
						continue
					var st := Geom.seg_circle_t(x0, y0, nx, ny, ax[fid], ay[fid], rr)
					if st < best_t:
						best_t = st
						hit_id = fid
					elif st == INF and Geom.seg_point_dist(x0, y0, nx, ny, ax[fid], ay[fid]) < NEAR_MISS:
						a_under_fire[fid] = UNDER_FIRE_TICKS   # a round went past your ear

		if best_t != INF:
			if hit_id >= 0:
				var d := Geom.seg_point_dist(x0, y0, nx, ny, ax[hit_id], ay[hit_id])
				var raw := hit_damage(d, rr, b_damage[bi])
				var dmg := minf(raw, a_hp[hit_id])
				var shooter := b_shooter[bi]
				if dmg > 0.0:
					a_hp[hit_id] -= dmg
					a_damage_taken[hit_id] += dmg
					a_damage_dealt[shooter] += dmg
				a_hits[shooter] += 1
				a_under_fire[hit_id] = UNDER_FIRE_TICKS
				if a_hp[hit_id] <= 0.0:
					_kill(hit_id, shooter, false)
			continue                                  # spent, on flesh or on stone
		if nx < 0.0 or nx > D.FIELD_W or ny < 0.0 or ny > D.FIELD_H:
			continue
		b_x[write] = nx; b_y[write] = ny
		b_vx[write] = b_vx[bi]; b_vy[write] = b_vy[bi]
		b_damage[write] = b_damage[bi]; b_radius[write] = b_radius[bi]
		b_team[write] = b_team[bi]; b_shooter[write] = b_shooter[bi]
		write += 1
	b_count = write


# ── results ───────────────────────────────────────────────────────
func unit_stats() -> Array:
	var out: Array = []
	for u in range(n_units):
		var first := u_first[u]
		var size := u_size[u]
		var shots := 0
		var hits := 0
		var dealt := 0.0
		var taken := 0.0
		var alive := 0
		var kills := 0
		var mkills := 0
		var in_cover := 0
		var hp_left := 0.0
		for id in range(first, first + size):
			shots += a_shots[id]
			hits += a_hits[id]
			dealt += a_damage_dealt[id]
			taken += a_damage_taken[id]
			kills += a_kills[id]
			mkills += a_melee_kills[id]
			in_cover += a_ticks_in_cover[id]
			if a_alive[id] == 1:
				alive += 1
				hp_left += a_hp[id]
		out.append({
			"id": u, "team": u_team[u], "name": u_name[u], "weapon": u_weapon_name[u],
			"size": size, "alive": alive, "losses": size - alive,
			"shots": shots, "hits": hits, "hitRate": (float(hits) / float(shots)) if shots > 0 else 0.0,
			"damageDealt": dealt, "damageTaken": taken,
			"kills": kills, "meleeKills": mkills,
			"efficiency": dealt / maxf(taken, 1.0),
			"ticksInCover": in_cover, "hpLeft": hp_left,
		})
	return out


func team_stats(team: int) -> Dictionary:
	var actors := 0
	var alive := 0
	var shots := 0
	var hits := 0
	var dealt := 0.0
	var taken := 0.0
	var kills := 0
	var mkills := 0
	var hp_left := 0.0
	for id in range(n_actors):
		if a_team[id] != team:
			continue
		actors += 1
		shots += a_shots[id]
		hits += a_hits[id]
		dealt += a_damage_dealt[id]
		taken += a_damage_taken[id]
		kills += a_kills[id]
		mkills += a_melee_kills[id]
		if a_alive[id] == 1:
			alive += 1
			hp_left += a_hp[id]
	return {
		"actors": actors, "alive": alive, "casualties": actors - alive,
		"shots": shots, "hits": hits, "damageDealt": dealt, "damageTaken": taken,
		"kills": kills, "meleeKills": mkills, "hpLeft": hp_left,
	}


func result() -> Dictionary:
	var a := team_stats(0)
	var b := team_stats(1)
	var winner := "draw"
	if a["alive"] == 0 and b["alive"] == 0:
		winner = "draw"
	elif a["alive"] == 0:
		winner = "B"
	elif b["alive"] == 0:
		winner = "A"
	elif a["alive"] != b["alive"]:
		winner = "A" if a["alive"] > b["alive"] else "B"   # capped: most bodies standing
	else:
		winner = "draw" if a["hpLeft"] == b["hpLeft"] else ("A" if a["hpLeft"] > b["hpLeft"] else "B")
	return {
		"winner": winner, "capped": capped, "ticks": tick,
		"seed": seed_value, "map": map_def["id"],
		"teams": [a, b], "units": unit_stats(),
	}


## A short stable string that changes if anything about the run changes — the
## determinism test compares these rather than whole result dictionaries.
func digest() -> String:
	var a := team_stats(0)
	var b := team_stats(1)
	var acc := 0
	for id in range(n_actors):
		acc = (acc * 31 + int(round(ax[id] * 1000.0))) & 0x7FFFFFFF
		acc = (acc * 31 + int(round(ay[id] * 1000.0))) & 0x7FFFFFFF
		acc = (acc * 31 + int(round(a_hp[id] * 1000.0))) & 0x7FFFFFFF
		acc = (acc * 31 + a_shots[id] + a_hits[id] * 7 + a_kills[id] * 13) & 0x7FFFFFFF
	return "t%d|A%d/%d|B%d/%d|s%d|h%d|x%08x" % [
		tick, a["alive"], a["actors"], b["alive"], b["actors"],
		a["shots"] + b["shots"], a["hits"] + b["hits"], acc,
	]
