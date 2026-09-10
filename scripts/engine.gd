extends RefCounted
##
## `utilityDecide`, ported from sim-core `engine.ts`.
##
## The TS signature takes candidates whose considerations are a
## `Record<string, number>` and sums them by walking `Object.entries`. War Sim
## always builds those objects with the same five keys in the same order, so
## the sum order is fixed — and it has to be, because floating-point addition
## is not associative and the whole run hangs off the result. Here that order
## is made explicit: considerations are a flat array of
## `ACTIONS x TRAIT_ORDER` weights, summed in `TRAIT_ORDER`.
##
## `personality.traits[k] ?? 0.5` in the original has no counterpart: all five
## keys are always present in War Sim's candidates.
##

## The order the JS build's consideration objects are constructed in, and
## therefore the order the weighted sum accumulates in.
const TRAIT_ORDER := ["aggression", "risk", "cohesion", "discipline", "meleePreference"]
const TRAITS := 5


##
## Pick an action.
##
## `bases` is one float per action. `cons` is `n_actions * TRAITS` weights in
## TRAIT_ORDER. `traits` is the *actor's* five resolved (jittered) values in the
## same order — never the unit's. `inertia_action` gets `inertia_bonus` added,
## which is how the TS caller expresses "0.10 for repeating what you were
## already doing".
##
## Returns the chosen action index. `out_probs`, if given, is filled with the
## softmax probabilities (the UI's action-mix readout; nothing on the hot path
## asks for it).
##
## Scratch for the scores/weights, reused across calls: `decide` runs ~80 times
## a tick and a fresh Packed array each time showed up as GC churn.
static var _scores := PackedFloat64Array()


static func decide(bases: PackedFloat64Array, cons: PackedFloat64Array,
		traits: PackedFloat64Array, randomness: float, rng: RefCounted,
		inertia_action: int = -1, inertia_bonus: float = 0.0,
		out_probs: PackedFloat64Array = PackedFloat64Array()) -> int:
	# written through `_scores` directly, never aliased into a local: Packed
	# arrays are copy-on-write, so `var s := _scores` then writing to `s` would
	# copy the buffer on every call and defeat the point of keeping it.
	var n := bases.size()
	if _scores.size() != n:
		_scores.resize(n)
	var best := -INF
	for i in range(n):
		var s := bases[i]
		var o := i * TRAITS
		for k in range(TRAITS):
			s += traits[k] * cons[o + k]
		if i == inertia_action:
			s += inertia_bonus
		_scores[i] = s
		if s > best:
			best = s
	var t := 0.02 + randomness * 1.5
	var z := 0.0
	for i in range(n):
		var w: float = exp((_scores[i] - best) / t)
		_scores[i] = w
		z += w
	var r: float = rng.next()
	if not out_probs.is_empty():
		for i in range(n):
			out_probs[i] = _scores[i] / z
	var idx := 0
	while idx < n - 1:
		r -= _scores[idx] / z
		if r <= 0.0:
			break
		idx += 1
	return idx
