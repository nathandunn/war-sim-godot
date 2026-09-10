extends RefCounted
##
## Uniform-grid broadphase, ported from sim-core `spatial.ts`.
##
## One structural change from the TS version, forced by the language: the JS
## hash hands neighbours to a callback. In GDScript a `Callable.call()` per
## candidate is the single most expensive thing on the tick — at ~1100 queries
## a tick over 500 actors it dominated everything else in the first cut.
##
## So instead of buckets-as-arrays-of-arrays plus a callback, this builds a
## counting-sorted CSR layout: `cell_start[c] .. cell_start[c+1]` is the slice
## of `items` living in cell `c`. Callers iterate that slice inline, with no
## call at all.
##
## The ordering guarantee is unchanged and still load-bearing: ids are placed
## in ascending order within a cell and cells are visited row-major, so two
## runs from the same state visit neighbours in the same sequence — which is
## what keeps floating-point accumulation (separation pushes) reproducible.
##

var cell: float
var cols: int
var rows: int

## CSR offsets, length cols*rows + 1. Read-only to callers.
var cell_start := PackedInt32Array()
##
## Per cell, the index in `items` where team 1 starts — so `[cell_start[c],
## cell_mid[c])` is that cell's team-0 ids and `[cell_mid[c], cell_start[c+1])`
## its team-1 ids.
##
## This is free rather than clever: actor ids are handed out team by team at
## spawn, so every team-0 id is below every team-1 id, and a slice that is
## already ascending by id is already partitioned by team. Recording where the
## seam falls lets perception, melee and bullet collision — all of which only
## ever want the *other* team — skip their own side without touching it, and
## without reordering anything. In the approach phase that is the difference
## between scanning 250 friendlies per decision and scanning none.
##
var cell_mid := PackedInt32Array()
## Actor ids, grouped by cell, ascending within each cell. Read-only to callers.
var items := PackedInt32Array()
## Insert positions, indexed by actor id.
var xs := PackedFloat64Array()
var ys := PackedFloat64Array()

var _count := PackedInt32Array()
var _cursor := PackedInt32Array()
var _pend_id := PackedInt32Array()
var _pend_cell := PackedInt32Array()
var _count_lo := PackedInt32Array()
var _n := 0
var _cells: int
## First actor id belonging to team 1.
var split_id: int


func _init(width: float, height: float, cell_size: float = 96.0, capacity: int = 0,
		team1_first_id: int = 0x7FFFFFFF) -> void:
	cell = cell_size
	cols = maxi(1, int(ceil(width / cell_size)))
	rows = maxi(1, int(ceil(height / cell_size)))
	_cells = cols * rows
	split_id = team1_first_id
	cell_start.resize(_cells + 1)
	cell_mid.resize(_cells + 1)
	_count.resize(_cells + 1)
	_count_lo.resize(_cells + 1)
	_cursor.resize(_cells + 1)
	if capacity > 0:
		xs.resize(capacity)
		ys.resize(capacity)
		_pend_id.resize(capacity)
		_pend_cell.resize(capacity)


func index_of(x: float, y: float) -> int:
	var cx := clampi(int(floor(x / cell)), 0, cols - 1)
	var cy := clampi(int(floor(y / cell)), 0, rows - 1)
	return cy * cols + cx


func begin() -> void:
	# `fill` is one native memset; the equivalent GDScript loop over a few
	# thousand cells was costing more than the rest of the rebuild put together.
	_count.fill(0)
	_count_lo.fill(0)
	_n = 0


## Record an id at a position. Call in ascending id order.
func add(id: int, x: float, y: float) -> void:
	var c := index_of(x, y)
	_pend_id[_n] = id
	_pend_cell[_n] = c
	_n += 1
	_count[c] += 1
	if id < split_id:
		_count_lo[c] += 1
	xs[id] = x
	ys[id] = y


## Prefix-sum the counts and place the ids. Call once per rebuild, after `add`.
func build() -> void:
	var running := 0
	for c in range(_cells):
		cell_start[c] = running
		cell_mid[c] = running + _count_lo[c]
		_cursor[c] = running
		running += _count[c]
	cell_start[_cells] = running
	cell_mid[_cells] = running
	if items.size() != running:
		items.resize(running)
	for k in range(_n):
		var c := _pend_cell[k]
		items[_cursor[c]] = _pend_id[k]
		_cursor[c] += 1


## Ids within `radius` of (x,y), as an array. Convenience for cold paths and
## tests; the hot paths in `world.gd` walk the CSR slices directly.
func near(x: float, y: float, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x0 := clampi(int(floor((x - radius) / cell)), 0, cols - 1)
	var x1 := clampi(int(floor((x + radius) / cell)), 0, cols - 1)
	var y0 := clampi(int(floor((y - radius) / cell)), 0, rows - 1)
	var y1 := clampi(int(floor((y + radius) / cell)), 0, rows - 1)
	var r2 := radius * radius
	for cy in range(y0, y1 + 1):
		var row := cy * cols
		for cx in range(x0, x1 + 1):
			var b := row + cx
			for k in range(cell_start[b], cell_start[b + 1]):
				var id := items[k]
				var dx := xs[id] - x
				var dy := ys[id] - y
				if dx * dx + dy * dy <= r2:
					out.push_back(id)
	return out
