extends RefCounted
##
## Headless batch runs: `simulate` mode's engine, and the harness the
## determinism and performance checks drive.
##
## The JS build gets its trial loop from `@precog/agent-forge` (`runBatch`,
## `sweepTrait`). There is no agent-forge for GDScript and porting one was out
## of scope, so the two things War Sim actually asks of it live here: seeded
## trials (`seedBase + i`, exactly as agent-forge numbers them) and a
## single-trait sweep over 11 points. Same seeds in, same trials out.
##

const World := preload("res://scripts/world.gd")
const D := preload("res://scripts/data.gd")


## One battle to its conclusion.
static func run_battle(opts: Dictionary) -> Dictionary:
	var w := World.new(opts)
	while not w.finished():
		w.step()
	return w.result()


##
## `n` trials, trial *i* on `seed_base + i` — agent-forge's numbering, so a
## batch here lines up trial-for-trial with a batch there.
##
## `on_trial`, if given, is called as `on_trial(i, n, result)` after each run;
## the UI uses it to slice the loop across frames. Slicing never touches the
## seeds, so results are timing-independent.
##
static func run_batch(opts: Dictionary, n: int, seed_base: int, on_trial: Callable = Callable()) -> Array:
	var out: Array = []
	for i in range(n):
		var o := opts.duplicate(true)
		o["seed"] = seed_base + i
		var r := run_battle(o)
		out.append(r)
		if on_trial.is_valid():
			on_trial.call(i, n, r)
	return out


## Win rate / casualties / time-to-decision over a set of trial results.
static func summarize(results: Array) -> Dictionary:
	var n := results.size()
	if n == 0:
		return {"trials": 0}
	var wins_a := 0
	var wins_b := 0
	var draws := 0
	var capped := 0
	var cas_a := 0.0
	var cas_b := 0.0
	var ticks := 0.0
	var tick_list := PackedFloat64Array()
	var shots := 0
	var hits := 0
	var melee_kills := 0
	for r in results:
		match r["winner"]:
			"A": wins_a += 1
			"B": wins_b += 1
			_: draws += 1
		if r["capped"]:
			capped += 1
		cas_a += float(r["teams"][0]["casualties"])
		cas_b += float(r["teams"][1]["casualties"])
		ticks += float(r["ticks"])
		tick_list.push_back(float(r["ticks"]))
		shots += int(r["teams"][0]["shots"]) + int(r["teams"][1]["shots"])
		hits += int(r["teams"][0]["hits"]) + int(r["teams"][1]["hits"])
		melee_kills += int(r["teams"][0]["meleeKills"]) + int(r["teams"][1]["meleeKills"])
	var sorted_ticks := tick_list.duplicate()
	sorted_ticks.sort()
	return {
		"trials": n,
		"winRateA": float(wins_a) / float(n),
		"winRateB": float(wins_b) / float(n),
		"draws": draws,
		"capped": capped,
		"casualtiesA": cas_a / float(n),
		"casualtiesB": cas_b / float(n),
		"meanTicks": ticks / float(n),
		"medianTicks": sorted_ticks[n / 2],
		"meanSeconds": ticks / float(n) / float(World.SIM_HZ),
		"hitRate": (float(hits) / float(shots)) if shots > 0 else 0.0,
		"meleeKills": float(melee_kills) / float(n),
	}


##
## Sweep one trait of one side's units across 11 points in [0,1], `trials` runs
## each. Returns a row per point.
##
static func sweep(opts: Dictionary, team: int, trait_name: String, trials: int,
		seed_base: int, points: int = 11) -> Array:
	var out: Array = []
	for k in range(points):
		var v := float(k) / float(points - 1)
		var o := opts.duplicate(true)
		for u in o["units"]:
			if int(u["team"]) == team:
				u["personality"][trait_name] = v
		var rs := run_batch(o, trials, seed_base)
		var s := summarize(rs)
		s["value"] = v
		out.append(s)
	return out
