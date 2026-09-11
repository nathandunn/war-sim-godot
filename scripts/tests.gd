extends SceneTree
##
## Headless test + benchmark harness.
##
##   godot --headless --script res://scripts/tests.gd
##   godot --headless --script res://scripts/tests.gd -- --perf
##   godot --headless --script res://scripts/tests.gd -- --sim 20 --map ruins
##
## There is no browser on the build host, so this is also the determinism proof
## and the frame-budget proof: the same code that runs in the exported page runs
## here, and `--sim` is the mode the deploy check leans on.
##

const World := preload("res://scripts/world.gd")
const Batch := preload("res://scripts/batch.gd")
const Geom := preload("res://scripts/geom.gd")
const WarRng := preload("res://scripts/rng.gd")
const D := preload("res://scripts/data.gd")
const Palette := preload("res://scripts/palette.gd")
const Field := preload("res://ui/field.gd")

var _pass := 0
var _fail := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--perf"):
		_perf()
	elif args.has("--sim"):
		_sim(args)
	else:
		_run_tests()
	quit(1 if _fail > 0 else 0)


# ── assertions ────────────────────────────────────────────────────
func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   ", name)
	else:
		_fail += 1
		print("  FAIL ", name, ("  " + detail) if detail != "" else "")


func _close(a: float, b: float, eps: float, name: String) -> void:
	_ok(absf(a - b) <= eps, name, "%.17f vs %.17f" % [a, b])


# ── standard armies ───────────────────────────────────────────────
## 500 actors: the configuration `specs/war-sim.md` measured the JS build on.
static func standard_units() -> Array:
	return [
		{"team": 0, "name": "Line", "count": 125, "personality": D.preset("line"), "weapon": D.WEAPONS["rifle"]},
		{"team": 0, "name": "Shock", "count": 125, "personality": D.preset("shock"), "weapon": D.WEAPONS["smg"]},
		{"team": 1, "name": "Guards", "count": 125, "personality": D.preset("guards"), "weapon": D.WEAPONS["rifle"]},
		{"team": 1, "name": "Skirmishers", "count": 125, "personality": D.preset("skirmishers"), "weapon": D.WEAPONS["marksman"]},
	]


static func small_units(a_preset: String, b_preset: String, count: int = 30) -> Array:
	return [
		{"team": 0, "name": "A", "count": count, "personality": D.preset(a_preset), "weapon": D.WEAPONS["rifle"]},
		{"team": 1, "name": "B", "count": count, "personality": D.preset(b_preset), "weapon": D.WEAPONS["rifle"]},
	]


static func opts(map_id: String, units: Array, seed_value: int, max_ticks: int = World.DEFAULT_MAX_TICKS) -> Dictionary:
	return {"map": D.map_by_id(map_id), "units": units, "seed": seed_value, "max_ticks": max_ticks}


# ── tests ─────────────────────────────────────────────────────────
func _run_tests() -> void:
	print("war-sim-godot tests  (", Engine.get_version_info()["string"], ")")
	_test_rng()
	_test_hitbox()
	_test_cover_angle()
	_test_geom()
	_test_determinism()
	_test_batch_slicing()
	_test_personality()
	_test_cover_use()
	_test_cover_capacity()
	_test_palette_contrast()
	print("\n%d passed, %d failed" % [_pass, _fail])


##
## Legibility, as a number.
##
## Every element a viewer has to pick out clears **WCAG 3:1** against the field
## — the bar for non-text graphical objects. The soldier rows are the ones that
## are easy to get wrong: a sprite is drawn from a luminance sheet and the team
## colour is multiplied in, so a torso is only `LUM_BODY` of the team colour.
## Checking the team colour alone would pass a sprite whose body fails, which is
## exactly what the pre-2026-09-11 palette did — ember and cyan both looked fine
## as swatches and both sank into the near-black field as men.
##
func _test_palette_contrast() -> void:
	print("\npalette (WCAG contrast against the field)")
	var bar := 3.0
	var ground := Palette.FIELD
	for e: Array in [
			["team A helmet", Palette.at_luminance(Palette.TEAM[0], Palette.LUM_HELMET)],
			["team A body", Palette.at_luminance(Palette.TEAM[0], Palette.LUM_BODY)],
			["team B helmet", Palette.at_luminance(Palette.TEAM[1], Palette.LUM_HELMET)],
			["team B body", Palette.at_luminance(Palette.TEAM[1], Palette.LUM_BODY)],
			["corpse", Palette.CORPSE],
			["sandbag", Palette.COVER_BAG[0]], ["sandbag alt", Palette.COVER_BAG[1]],
			["cover slab", Palette.COVER_FILL], ["cover top", Palette.COVER_TOP],
			["bullet", Palette.BULLET]]:
		var k: float = Palette.contrast(e[1], ground)
		_ok(k >= bar, "%s is %.2f:1 against the field (bar %.1f)" % [e[0], k, bar])

	# the two teams separate on hue, not on luminance, and that is deliberate:
	# blue against warm red is the colour-blind-safe opposition, and equal
	# luminance stops either side reading as the heavier
	var la := Palette.luminance(Palette.TEAM[0])
	var lb := Palette.luminance(Palette.TEAM[1])
	_ok(absf(la - lb) < 0.06, "neither team is the brighter (%.3f vs %.3f)" % [la, lb])
	_ok(Palette.TEAM[0].h < 0.10 or Palette.TEAM[0].h > 0.92, "team A is red")
	_ok(Palette.TEAM[1].h > 0.5 and Palette.TEAM[1].h < 0.72, "team B is blue")

	# the sheet's luminance levels are the palette's, not a second copy
	var src := FileAccess.get_file_as_string("res://scripts/sprites.gd")
	_ok(src.contains("Palette.LUM_BODY"), "sprites.gd takes its body level from the palette")

	# and the constants file is the only place a colour is named
	var re := RegEx.create_from_string("Color\\(\\s*[0-9]")
	for f: String in ["ui/field.gd", "ui/main.gd", "scripts/sprites.gd"]:
		var body := FileAccess.get_file_as_string("res://" + f)
		# the archived pre-2026-09-11 palette in sprites.gd is the one exception:
		# it exists so `--legacy` can draw the before picture
		var legacy := body.find("const LEGACY := {")
		var legacy_end := body.find("}", legacy) if legacy >= 0 else -1
		var hits := []
		for m in re.search_all(body):
			if legacy >= 0 and m.get_start() > legacy and m.get_start() < legacy_end:
				continue
			hits.push_back(body.count("\n", 0, m.get_start()) + 1)
		_ok(hits.is_empty(), "%s has no literal colours (lines %s)" % [f, str(hits)])


##
## The RNG is the load-bearing piece of cross-implementation comparability: if
## the streams differ, nothing downstream can be read against the JS build at
## all. These vectors were generated by sim-core's `Rng` under node.
##
func _test_rng() -> void:
	print("\nrng (sim-core mulberry32 parity)")
	# Compared as raw 32-bit words, not as printed decimals: `next()` returns
	# u / 2^32, which is exact in a double, so `v * 2^32` recovers the generator
	# word without any rounding to argue about.
	var vectors := {
		12345: [4207900869, 1317490944, 2079646450, 3513001552, 2187978186, 1492380277, 316786230, 3291647763],
		1: [2693262067, 11749833, 2265367787, 4213581821, 4159151403, 1207330352, 2632122864, 3095568220],
		20260909: [806440875, 453535163, 4202202606, 3870994068, 441748819, 218006328, 3860657134, 2655673430],
	}
	for seed_value in vectors:
		var expected: Array = vectors[seed_value]
		var r := WarRng.new(seed_value)
		var exact := true
		for i in range(expected.size()):
			var word := int(r.next() * 4294967296.0)
			if word != int(expected[i]):
				exact = false
				print("      seed %d draw %d: %d != %d" % [seed_value, i, word, expected[i]])
		_ok(exact, "seed %d reproduces the JS stream word for word" % seed_value)

	var r2 := WarRng.new(7)
	var lo := 1.0
	var hi := 0.0
	for i in range(20000):
		var v := r2.next()
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_ok(lo >= 0.0 and hi < 1.0, "20k draws stay in [0,1)")
	var buckets := PackedInt32Array()
	buckets.resize(10)
	var r3 := WarRng.new(99)
	for i in range(20000):
		buckets[r3.randi_below(10)] += 1
	var flat := true
	for b in buckets:
		if b < 1700 or b > 2300:
			flat = false
	_ok(flat, "randi_below(10) is roughly uniform over 20k draws", str(buckets))


func _test_hitbox() -> void:
	print("\nhitbox damage curve")
	var r := World.ACTOR_R
	_close(World.hit_damage(0.0, r, 100.0), 100.0, 1e-12, "dead centre is full damage")
	_close(World.hit_damage(r, r, 100.0), 0.0, 1e-12, "edge does nothing")
	_ok(World.hit_damage(r * 2.0, r, 100.0) == 0.0, "past the edge does nothing")
	var prev := 101.0
	var mono := true
	for i in range(0, 61):
		var d := r * float(i) / 60.0
		var v := World.hit_damage(d, r, 100.0)
		if v > prev:
			mono = false
		prev = v
	_ok(mono, "strictly decreasing in d")
	var k := 0.5
	_close(World.hit_damage(r * k, r, 100.0), 100.0 * (1.0 - k * k), 1e-12, "matches 1 - (d/R)^2")


func _test_cover_angle() -> void:
	print("\ncover angle bonus")
	var rects := PackedFloat64Array([700.0, 400.0, 100.0, 40.0])
	# target hugging the left face of the rect
	var tx := 690.0
	var ty := 420.0
	# perpendicular: straight in from the left, square into the face
	var perp := World.cover_bonus(300.0, 420.0, tx, ty, rects)
	# grazing: coming down the face from above, skimming along it
	var graze := World.cover_bonus(688.0, 100.0, tx, ty, rects)
	_ok(graze > perp, "grazing shot gets more cover than a perpendicular one", "%f vs %f" % [graze, perp])
	_ok(perp >= 0.0 and perp <= 1.0 and graze >= 0.0 and graze <= 1.0, "bonus stays in [0,1]")
	_close(World.cover_bonus(100.0, 100.0, 200.0, 200.0, PackedFloat64Array()), 0.0, 1e-12, "no cover -> 0")
	# a rect far from the target contributes nothing however the shot arrives
	_close(World.cover_bonus(100.0, 800.0, 200.0, 800.0, rects), 0.0, 1e-12, "distant rect -> 0")


func _test_geom() -> void:
	print("\ngeometry")
	_ok(Geom.seg_rect_t(0, 50, 200, 50, 100, 0, 20, 100) != INF, "segment crossing a rect hits")
	_ok(Geom.seg_rect_t(0, 50, 50, 50, 100, 0, 20, 100) == INF, "segment stopping short misses")
	_close(Geom.seg_rect_t(0, 50, 200, 50, 100, 0, 20, 100), 0.5, 1e-12, "hit parameter is the near face")
	_ok(not Geom.los_clear(0, 50, 200, 50, PackedFloat64Array([100, 0, 20, 100])), "cover blocks LOS")
	_ok(Geom.los_clear(0, 50, 200, 50, PackedFloat64Array([100, 200, 20, 100])), "cover elsewhere does not")
	var v := Geom.push_out_circle(105, 50, 6, 100, 0, 20, 100)
	_ok(Geom.rect_dist(v.x, v.y, 100, 0, 20, 100) >= 6.0 - 1e-3, "a circle inside a rect is pushed clear")
	_close(Geom.seg_point_dist(0, 0, 100, 0, 50, 20), 20.0, 1e-12, "segment-point distance")
	_close(Geom.seg_circle_t(0, 0, 100, 0, 50, 0, 10), 0.4, 1e-12, "segment-circle entry parameter")


##
## Determinism is the hard requirement: one seed, one battle. The foreign-seed
## run in between is the part that actually catches mistakes — it fails if any
## state leaked into a global (an engine RNG, a static scratch buffer).
##
func _test_determinism() -> void:
	print("\ndeterminism")
	for map_id in D.MAP_IDS:
		var o := opts(map_id, standard_units(), 4242, 60 * 20)
		var w1 := World.new(o)
		while not w1.finished():
			w1.step()
		var d1 := w1.digest()

		# a foreign run in between must change nothing
		var foreign := World.new(opts(map_id, standard_units(), 999, 60 * 5))
		for i in range(120):
			foreign.step()

		var w2 := World.new(opts(map_id, standard_units(), 4242, 60 * 20))
		while not w2.finished():
			w2.step()
		_ok(d1 == w2.digest(), "map %s: same seed -> identical run" % map_id, "%s vs %s" % [d1, w2.digest()])

		var w3 := World.new(opts(map_id, standard_units(), 4243, 60 * 20))
		while not w3.finished():
			w3.step()
		_ok(d1 != w3.digest(), "map %s: a different seed -> a different run" % map_id)

	# stepping one tick at a time must equal running straight through
	var a := World.new(opts("ruins", small_units("shock", "guards"), 77, 60 * 30))
	while not a.finished():
		a.step()
	var b := World.new(opts("ruins", small_units("shock", "guards"), 77, 60 * 30))
	for i in range(60 * 30):
		if b.finished():
			break
		b.step()
	_ok(a.digest() == b.digest(), "tick-at-a-time equals run-to-completion")


func _test_batch_slicing() -> void:
	print("\nbatch (simulate mode)")
	var o := opts("open", small_units("line", "militia", 24), 0, 60 * 30)
	var whole := Batch.run_batch(o, 6, 1000)
	var sliced: Array = []
	for chunk in range(3):
		for i in range(2):
			var oo := o.duplicate(true)
			oo["seed"] = 1000 + chunk * 2 + i
			sliced.append(Batch.run_battle(oo))
	var same := true
	for i in range(6):
		if whole[i]["winner"] != sliced[i]["winner"] or whole[i]["ticks"] != sliced[i]["ticks"]:
			same = false
	_ok(same, "a batch run in chunks matches one run in a single pass")
	var s := Batch.summarize(whole)
	_ok(absf(float(s["winRateA"]) + float(s["winRateB"]) + float(s["draws"]) / 6.0 - 1.0) < 1e-9,
		"win rates and draws account for every trial")
	_ok(float(s["meanTicks"]) > 0.0, "time-to-decision is reported")


##
## The sliders have to actually move the outcome, or the team builder is
## decoration. These two mirror the JS suite's assertions run for run — same
## presets, same seeds, same tick caps, same measure — so a disagreement here
## is a porting bug rather than a different experiment.
##
func _test_personality() -> void:
	print("\npersonality -> behaviour")
	# aggression closes the distance: measure how far team 0's survivors still
	# have to travel, exactly as the JS test does
	var gap_hi := _gap(0.95)
	var gap_lo := _gap(0.05)
	_ok(gap_hi < gap_lo, "aggressive units end up further forward", "%.1f vs %.1f" % [gap_hi, gap_lo])

	# meleePreference produces melee kills, and its absence does not. Identical
	# units and weapons on both sides: the only difference is whether team A
	# would rather be in contact.
	var hot := _melee_kills(1.0)
	var cold := _melee_kills(0.0)
	_ok(hot > 0, "a melee-hungry unit reaches contact", "%d melee kills" % hot)
	_ok(hot > cold * 3, "and does so far more than one that would rather shoot",
		"%d vs %d" % [hot, cold])


##
## The cover fix, mirroring `war-sim`'s suite run for run — same presets, same
## seeds, same tick caps, same measure. See `specs/war-sim-cover.md` there for
## the diagnosis these replaced; the numbers below are the JS build's acceptance
## bars, applied unchanged.
##
func _test_cover_use() -> void:
	print("\ncover")

	# risk decides whether an actor uses cover at all. Measured on cover
	# *seeking*, not on proximity to a rect: `_step_actor` slides along rects,
	# so on Ruins any unit advancing through the map brushes walls for much of
	# the march, and that statistic reads the map rather than the personality.
	for seed_value in [3, 9]:
		var timid := _cover_seeking(0.05, seed_value)
		var reckless := _cover_seeking(0.95, seed_value)
		_ok(timid > 0.08, "seed %d: a low-risk unit spends real time on cover (%.1f%%)" % [seed_value, 100.0 * timid])
		_ok(reckless < 0.02, "seed %d: a high-risk unit ignores cover (%.1f%%)" % [seed_value, 100.0 * reckless])
		_ok(timid > reckless * 5.0, "seed %d: risk dominates the choice" % seed_value,
			"%.3f vs %.3f" % [timid, reckless])

	# the acceptance number: a low-risk unit under fire on Ruins ends at least
	# 60% of its actor-ticks in cover, counting from the tick it first came
	# under fire, and the berserkers it is fighting still ignore cover
	for seed_value in [2, 3, 4]:
		var r := _guards_under_fire(seed_value)
		_ok(r[0] >= 0.6, "seed %d: guards under fire stay in cover (%.1f%%)" % [seed_value, 100.0 * r[0]])
		_ok(r[1] < 0.05, "seed %d: berserkers still ignore cover (%.1f%%)" % [seed_value, 100.0 * r[1]])

	# the spot an actor is sent to is itself cover, and not on top of the rect.
	# Ridge is the map whose 60x200 walls broke the old max(w,h)/2 offset.
	var m := D.map_by_id("ridge")
	var rects: PackedFloat64Array = D.cover_of(m)
	var w := World.new(opts("ridge", [
		{"team": 0, "name": "A", "count": 50, "personality": D.preset("shock"), "weapon": D.WEAPONS["smg"]},
		{"team": 1, "name": "B", "count": 50, "personality": D.preset("guards"), "weapon": D.WEAPONS["rifle"]},
	], 6, 1200))
	var picks := 0
	var bad_far := 0
	var bad_inside := 0
	while not w.finished():
		w.step()
		for id in range(w.n_actors):
			if w.a_alive[id] == 0 or w.a_state[id] != D.SEEK_COVER or w.a_cover_x[id] < 0.0:
				continue
			picks += 1
			var hug := INF
			var i := 0
			while i < rects.size():
				var d := Geom.rect_dist(w.a_cover_x[id], w.a_cover_y[id],
					rects[i], rects[i + 1], rects[i + 2], rects[i + 3])
				if d < hug:
					hug = d
				i += 4
			if hug > World.ACTOR_R + World.COVER_HUG:
				bad_far += 1
			if hug < World.ACTOR_R - 1e-6:
				bad_inside += 1
	_ok(picks > 200, "the scenario produces cover picks", "%d" % picks)
	_ok(bad_far == 0, "every cover point is itself in cover", "%d of %d were not" % [bad_far, picks])
	_ok(bad_inside == 0, "no cover point is inside a rect", "%d of %d were" % [bad_inside, picks])

	# discipline buys time out of cover: the peek window widens with it
	var open_lo := _peek_share(0.0)
	var open_mid := _peek_share(0.5)
	var open_hi := _peek_share(1.0)
	_ok(open_hi > open_mid and open_mid > open_lo, "the peek window widens with discipline",
		"%.2f / %.2f / %.2f" % [open_lo, open_mid, open_hi])
	_ok(open_lo > 0.2 and open_hi < 1.0, "even the panicky fire, even the disciplined duck")
	var together := 0
	for id in range(4):
		if World.peek_open(0, id, 0.5):
			together += 1
	_ok(together > 0 and together < 4, "peek phase differs between actors")


## Share of a unit's actor-ticks spent in a cover state.
func _cover_seeking(risk: float, seed_value: int) -> float:
	var units := [
		{"team": 0, "name": "A", "count": 70,
			"personality": _tweak("line", {"risk": risk, "discipline": 0.7}), "weapon": D.WEAPONS["rifle"]},
		{"team": 1, "name": "B", "count": 70, "personality": D.preset("line"), "weapon": D.WEAPONS["rifle"]},
	]
	var w := World.new(opts("ruins", units, seed_value, 1500))
	var ticks := 0
	var seeking := 0
	while not w.finished():
		w.step()
		for id in range(w.n_actors):
			if w.a_alive[id] == 0 or w.a_team[id] != 0:
				continue
			ticks += 1
			if w.a_state[id] == D.SEEK_COVER or w.a_state[id] == D.HOLD_COVER:
				seeking += 1
	return float(seeking) / float(maxi(ticks, 1))


## [guards in cover after first being shot at, berserker cover-state share].
func _guards_under_fire(seed_value: int) -> Array:
	var units := [
		{"team": 0, "name": "Berserkers", "count": 80,
			"personality": D.preset("berserkers"), "weapon": D.WEAPONS["rifle"]},
		{"team": 1, "name": "Guards", "count": 60,
			"personality": D.preset("guards"), "weapon": D.WEAPONS["rifle"]},
	]
	var w := World.new(opts("ruins", units, seed_value, 3600))
	var shot_at := {}
	var post := 0
	var covered := 0
	var wild_ticks := 0
	var wild_cover := 0
	while not w.finished():
		w.step()
		for id in range(w.n_actors):
			if w.a_alive[id] == 0:
				continue
			if w.a_team[id] == 0:
				wild_ticks += 1
				if w.a_state[id] == D.SEEK_COVER or w.a_state[id] == D.HOLD_COVER:
					wild_cover += 1
				continue
			if w.a_under_fire[id] > 0:
				shot_at[id] = true
			if not shot_at.has(id):
				continue
			post += 1
			if w.a_covered[id] == 1:
				covered += 1
	return [float(covered) / float(maxi(post, 1)), float(wild_cover) / float(maxi(wild_ticks, 1))]


func _peek_share(discipline: float) -> float:
	var open_ticks := 0
	for t in range(World.PEEK_CYCLE * 4):
		if World.peek_open(t, 0, discipline):
			open_ticks += 1
	return float(open_ticks) / float(World.PEEK_CYCLE * 4)


## Mean distance team 0's survivors still have to travel.
func _gap(aggression: float) -> float:
	var units := [
		{"team": 0, "name": "Line", "count": 60,
			"personality": _tweak("line", {"aggression": aggression, "meleePreference": 0.0}),
			"weapon": D.WEAPONS["rifle"]},
		{"team": 1, "name": "Guards", "count": 60,
			"personality": D.preset("guards"), "weapon": D.WEAPONS["rifle"]},
	]
	var w := World.new(opts("open", units, 5, 700))
	while not w.finished():
		w.step()
	var sum := 0.0
	var n := 0
	for id in range(w.n_actors):
		if w.a_team[id] == 0 and w.a_alive[id] == 1:
			sum += D.FIELD_W - w.ax[id]
			n += 1
	return INF if n == 0 else sum / float(n)


func _melee_kills(melee_preference: float) -> int:
	var k := 0
	for seed_value in [6, 7, 8]:
		var units := [
			{"team": 0, "name": "A", "count": 80,
				"personality": _tweak("line", {"meleePreference": melee_preference, "aggression": 0.9}),
				"weapon": D.WEAPONS["smg"]},
			{"team": 1, "name": "B", "count": 80,
				"personality": _tweak("line", {"meleePreference": 0.0, "aggression": 0.9}),
				"weapon": D.WEAPONS["smg"]},
		]
		var r := Batch.run_battle(opts("open", units, seed_value, 2400))
		k += int(r["teams"][0]["meleeKills"])
	return k


func _tweak(preset_id: String, over: Dictionary) -> Dictionary:
	var p := D.preset(preset_id)
	for k in over:
		p[k] = over[k]
	return p


## The per-actor cover list is a fixed-stride slice; if a map ever puts more
## rects in reach than it holds, movement silently starts ignoring one.
func _test_cover_capacity() -> void:
	print("\ncover list capacity")
	for map_id in D.MAP_IDS:
		var w := World.new(opts(map_id, standard_units(), 5, 60 * 10))
		while not w.finished():
			w.step()
		_ok(w.near_cover_overflow == 0, "map %s never overflows MAX_NEAR_COVER" % map_id,
			str(w.near_cover_overflow))


# ── benchmark ─────────────────────────────────────────────────────
##
## 500 actors, mean over 400 ticks after a 200-tick warm-up — the same
## measurement `specs/war-sim.md` reports for the JS build, so the two numbers
## are comparable.
##
func _perf() -> void:
	print("war-sim-godot benchmark  (", Engine.get_version_info()["string"], ")")
	print("500 actors, mean over 400 ticks after a 200-tick warm-up\n")
	print("map          mean      p50       p95       max")
	var budget_ms := 1000.0 / float(World.SIM_HZ)
	var worst := 0.0
	for map_id in D.MAP_IDS:
		var w := World.new(opts(map_id, standard_units(), 20260909, 60 * 600))
		for i in range(200):
			w.step()
		var samples := PackedFloat64Array()
		for i in range(400):
			var t0 := Time.get_ticks_usec()
			w.step()
			samples.push_back(float(Time.get_ticks_usec() - t0) / 1000.0)
		var mean := 0.0
		for s in samples:
			mean += s
		mean /= float(samples.size())
		var sorted_s := samples.duplicate()
		sorted_s.sort()
		var p50 := sorted_s[sorted_s.size() / 2]
		var p95 := sorted_s[int(float(sorted_s.size()) * 0.95)]
		var mx := sorted_s[sorted_s.size() - 1]
		worst = maxf(worst, mean)
		print("%-12s %6.2f ms %6.2f ms %6.2f ms %6.2f ms" % [map_id, mean, p50, p95, mx])
	print("\n60 Hz frame budget: %.2f ms. Worst mean: %.2f ms." % [budget_ms, worst])
	if worst >= budget_ms:
		print("OVER BUDGET")
		_fail += 1


# ── --sim: headless N runs, the stats table simulate mode shows ───
func _sim(args: PackedStringArray) -> void:
	var n := 20
	var map_id := "open"
	var seed_base := 1
	for i in range(args.size()):
		if args[i] == "--sim" and i + 1 < args.size():
			n = int(args[i + 1])
		elif args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
		elif args[i] == "--seed" and i + 1 < args.size():
			seed_base = int(args[i + 1])
	var o := opts(map_id, standard_units(), seed_base)
	var t0 := Time.get_ticks_msec()
	var rs := Batch.run_batch(o, n, seed_base)
	var s := Batch.summarize(rs)
	print("map=%s trials=%d seed_base=%d  (%.1f s wall)" % [map_id, n, seed_base, float(Time.get_ticks_msec() - t0) / 1000.0])
	print("  win rate A %.3f   win rate B %.3f   draws %d   capped %d" % [s["winRateA"], s["winRateB"], s["draws"], s["capped"]])
	print("  casualties A %.1f   B %.1f" % [s["casualtiesA"], s["casualtiesB"]])
	print("  time-to-decision  mean %.0f ticks (%.1f s)   median %.0f ticks" % [s["meanTicks"], s["meanSeconds"], s["medianTicks"]])
	print("  hit rate %.3f   melee kills/run %.1f" % [s["hitRate"], s["meleeKills"]])
	print("\nseed      winner  ticks  casA  casB")
	for r in rs:
		print("%-9d %-7s %5d  %4d  %4d" % [r["seed"], r["winner"], r["ticks"],
			r["teams"][0]["casualties"], r["teams"][1]["casualties"]])
