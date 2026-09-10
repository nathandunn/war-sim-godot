extends RefCounted
##
## Field, maps, weapons and unit presets — the same numbers as
## `nathandunn/war-sim`, so a run of either can be read against the other.
##
## What is deliberately *not* here is the sim-core `Personality` schema. In the
## JS build a preset carries eleven traits: the seven War Sim reads, plus
## `caution` / `cooperation` / `patience` / `focus`, which exist only because
## sim-core's `validate()` requires the six core traits and a War Sim
## personality should still mean something if it is dropped into Battle Bots.
## There is no sim-core here and nothing to validate against, so a preset is
## the seven properties the simulator actually reads. See README, "Formula
## divergences".
##

const FIELD_W := 1600.0
const FIELD_H := 900.0

const ACTIONS := ["advance", "charge", "hold", "flank", "seekCover", "regroup"]
const ADVANCE := 0
const CHARGE := 1
const HOLD := 2
const FLANK := 3
const SEEK_COVER := 4
const REGROUP := 5

## The seven War Sim personality properties, in the order the UI shows them.
const WAR_TRAITS := [
	"aggression", "risk", "randomness", "cohesion", "discipline", "meleePreference", "jitter",
]

const TRAIT_BLURB := {
	"aggression": "Close the distance, press the attack, hit harder in melee.",
	"risk": "Take long shots and cross open ground. High risk ignores cover entirely.",
	"randomness": "Noise in every decision, and a looser aim.",
	"cohesion": "Stay with the unit. Low cohesion scatters across the field.",
	"discipline": "Fire control: hold the shot until it is worth taking.",
	"meleePreference": "Charge into contact instead of shooting.",
	"jitter": "How far individual actors drift from the unit's own numbers.",
}

##
## Three weapons, differing in the two things that were asked to be
## configurable — projectile speed and spread — plus the cadence/damage/range
## that make those differences readable on the field. The rifle's damage equals
## MAX_HP, so a dead-centre hit kills and an edge graze does almost nothing.
##
const WEAPONS := {
	"rifle": {
		"id": "rifle", "name": "Rifle",
		"projectileSpeed": 10.0, "spread": 0.034, "cooldown": 42,
		"damage": 100.0, "range": 420.0, "bulletRadius": 1.6,
	},
	"smg": {
		"id": "smg", "name": "SMG",
		"projectileSpeed": 7.0, "spread": 0.105, "cooldown": 12,
		"damage": 40.0, "range": 200.0, "bulletRadius": 1.4,
	},
	"marksman": {
		"id": "marksman", "name": "Marksman",
		"projectileSpeed": 16.0, "spread": 0.020, "cooldown": 120,
		"damage": 110.0, "range": 560.0, "bulletRadius": 1.8,
	},
}

const WEAPON_IDS := ["rifle", "smg", "marksman"]

const PRESETS := {
	"line": {
		"name": "Line Infantry",
		"aggression": 0.50, "risk": 0.35, "randomness": 0.12,
		"cohesion": 0.85, "discipline": 0.75, "meleePreference": 0.15, "jitter": 0.12,
	},
	"guards": {
		"name": "Guards",
		"aggression": 0.25, "risk": 0.15, "randomness": 0.08,
		"cohesion": 0.90, "discipline": 0.95, "meleePreference": 0.10, "jitter": 0.06,
	},
	"shock": {
		"name": "Shock Troops",
		"aggression": 0.90, "risk": 0.80, "randomness": 0.22,
		"cohesion": 0.55, "discipline": 0.40, "meleePreference": 0.75, "jitter": 0.20,
	},
	"skirmishers": {
		"name": "Skirmishers",
		"aggression": 0.45, "risk": 0.75, "randomness": 0.35,
		"cohesion": 0.20, "discipline": 0.55, "meleePreference": 0.20, "jitter": 0.35,
	},
	"militia": {
		"name": "Militia",
		"aggression": 0.55, "risk": 0.50, "randomness": 0.60,
		"cohesion": 0.35, "discipline": 0.20, "meleePreference": 0.40, "jitter": 0.60,
	},
	"berserkers": {
		"name": "Berserkers",
		"aggression": 1.00, "risk": 0.95, "randomness": 0.30,
		"cohesion": 0.25, "discipline": 0.10, "meleePreference": 1.00, "jitter": 0.25,
	},
}

const PRESET_IDS := ["line", "guards", "shock", "skirmishers", "militia", "berserkers"]

##
## Three handmade cover layouts on the 1600x900 field. Cover is static and
## axis-aligned; the spawn strips at either end stay clear of it. Rects keep a
## gap of at least three body widths from each other so a single pushout always
## resolves an actor cleanly.
##
## `cover` is flat [x, y, w, h, ...] — the form the geometry and the tick want.
##
const SPAWN_A := Rect2(20, 60, 150, FIELD_H - 120)
const SPAWN_B := Rect2(FIELD_W - 170, 60, 150, FIELD_H - 120)

const MAPS := [
	{
		"id": "open",
		"name": "Open Field",
		"blurb": "Four sparse blocks. Almost nowhere to hide - aggression and long-range fire decide it.",
		"cover": [
			460.0, 150.0, 150.0, 70.0,
			460.0, 680.0, 150.0, 70.0,
			990.0, 150.0, 150.0, 70.0,
			990.0, 680.0, 150.0, 70.0,
			740.0, 405.0, 120.0, 90.0,
		],
	},
	{
		"id": "ruins",
		"name": "Ruins",
		"blurb": "A broken urban grid around a central plaza. Rewards cover discipline and punishes blind charges.",
		"cover": [
			330.0, 90.0, 130.0, 130.0,
			330.0, 380.0, 130.0, 140.0,
			330.0, 680.0, 130.0, 130.0,
			620.0, 200.0, 150.0, 110.0,
			620.0, 590.0, 150.0, 110.0,
			830.0, 200.0, 150.0, 110.0,
			830.0, 590.0, 150.0, 110.0,
			1140.0, 90.0, 130.0, 130.0,
			1140.0, 380.0, 130.0, 140.0,
			1140.0, 680.0, 130.0, 130.0,
		],
	},
	{
		"id": "ridge",
		"name": "Ridge",
		"blurb": "Two long walls with three gaps. Somebody has to cross first.",
		"cover": [
			520.0, 60.0, 60.0, 200.0,
			520.0, 350.0, 60.0, 200.0,
			520.0, 640.0, 60.0, 200.0,
			1020.0, 60.0, 60.0, 200.0,
			1020.0, 350.0, 60.0, 200.0,
			1020.0, 640.0, 60.0, 200.0,
			760.0, 200.0, 80.0, 110.0,
			760.0, 590.0, 80.0, 110.0,
		],
	},
]

const MAP_IDS := ["open", "ruins", "ridge"]


static func map_by_id(id: String) -> Dictionary:
	for m in MAPS:
		if m["id"] == id:
			return m
	return MAPS[0]


static func cover_of(m: Dictionary) -> PackedFloat64Array:
	return PackedFloat64Array(m["cover"])


## The five behavioural values `engine.decide` weighs, in TRAIT_ORDER.
static func decision_traits(p: Dictionary) -> PackedFloat64Array:
	return PackedFloat64Array([
		p["aggression"], p["risk"], p["cohesion"], p["discipline"], p["meleePreference"],
	])


static func preset(id: String) -> Dictionary:
	var p: Dictionary = PRESETS.get(id, PRESETS["line"])
	var out := {"name": p["name"], "id": id}
	for t in WAR_TRAITS:
		out[t] = p[t]
	return out
