extends RefCounted
##
## Seeded RNG — a direct port of sim-core's `Rng` (mulberry32), not Godot's
## `RandomNumberGenerator`.
##
## Two reasons it is hand-ported rather than delegated to the engine:
##
##  * Godot's `RandomNumberGenerator` is PCG32. Seeding it identically to the
##    JS build would still produce a different stream, so the two
##    implementations could never be compared run-for-run.
##  * Determinism is a hard requirement here, and the only way to get it is one
##    stream consumed in a fixed order. A global `randf()` picks up draws from
##    anything else in the engine that happens to want a random number.
##
## The JS original works on 32-bit words via `Math.imul` and `>>>`. GDScript
## ints are 64-bit two's-complement, so every step is masked back to 32 bits;
## multiplication may overflow int64 on the way, which is harmless because the
## low 32 bits of a product are the same either way.
##

const MASK := 0xFFFFFFFF

var _s: int


func _init(seed_value: int) -> void:
	_s = seed_value & MASK


## Uniform in [0, 1). Bit-for-bit the same sequence as sim-core's `Rng.next()`.
func next() -> float:
	_s = (_s + 0x6D2B79F5) & MASK
	var t: int = _s
	t = ((t ^ (t >> 15)) * (t | 1)) & MASK
	t = (t ^ (t + ((t ^ (t >> 7)) * (t | 61)))) & MASK
	return float((t ^ (t >> 14)) & MASK) / 4294967296.0


## Uniform integer in [0, n).
func randi_below(n: int) -> int:
	return int(floor(next() * float(n)))
