extends RefCounted
##
## 2-D geometry, ported from sim-core `geom.ts`.
##
## Cover rectangles are carried as a flat `PackedFloat64Array` of
## `[x, y, w, h, ...]` rather than an array of objects: these functions run
## hundreds of thousands of times a second and GDScript charges for every
## Dictionary/Object lookup on the way. `Rect2` would be tidier but boxes the
## four floats into a Variant on each read.
##
## `hypot()` here is `sqrt(x*x + y*y)`. The JS build calls `Math.hypot`, which
## V8 implements with overflow-safe scaling and which can differ from the naive
## form in the last bit or two. Nothing on this field comes close to overflow,
## so the formula is the same one; see README "Formula divergences".
##


static func hyp(x: float, y: float) -> float:
	return sqrt(x * x + y * y)


## First hit parameter t in [0,1] of a segment against an AABB, or INF.
static func seg_rect_t(x0: float, y0: float, x1: float, y1: float,
		rx: float, ry: float, rw: float, rh: float) -> float:
	var dx := x1 - x0
	var dy := y1 - y0
	var tmin := 0.0
	var tmax := 1.0
	if absf(dx) < 1e-12:
		if x0 < rx or x0 > rx + rw:
			return INF
	else:
		var t1 := (rx - x0) / dx
		var t2 := (rx + rw - x0) / dx
		if t1 > t2:
			var s := t1; t1 = t2; t2 = s
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return INF
	if absf(dy) < 1e-12:
		if y0 < ry or y0 > ry + rh:
			return INF
	else:
		var t1 := (ry - y0) / dy
		var t2 := (ry + rh - y0) / dy
		if t1 > t2:
			var s := t1; t1 = t2; t2 = s
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return INF
	return tmin


## First hit parameter t in [0,1] of a segment against a circle, or INF.
## A segment that starts inside the circle returns 0.
static func seg_circle_t(x0: float, y0: float, x1: float, y1: float,
		cx: float, cy: float, r: float) -> float:
	var dx := x1 - x0
	var dy := y1 - y0
	var fx := x0 - cx
	var fy := y0 - cy
	var a := dx * dx + dy * dy
	if a < 1e-12:
		return 0.0 if fx * fx + fy * fy <= r * r else INF
	var b := 2.0 * (fx * dx + fy * dy)
	var c := fx * fx + fy * fy - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return INF
	var sq := sqrt(disc)
	var t1 := (-b - sq) / (2.0 * a)
	if t1 >= 0.0 and t1 <= 1.0:
		return t1
	var t2 := (-b + sq) / (2.0 * a)
	if t2 >= 0.0 and t2 <= 1.0:
		return 0.0
	return INF


## Closest-approach parameter t in [0,1] of a segment to a point.
static func seg_point_t(x0: float, y0: float, x1: float, y1: float,
		px: float, py: float) -> float:
	var dx := x1 - x0
	var dy := y1 - y0
	var len2 := dx * dx + dy * dy
	if len2 < 1e-12:
		return 0.0
	return clampf(((px - x0) * dx + (py - y0) * dy) / len2, 0.0, 1.0)


## Distance from a segment's closest approach to a point.
static func seg_point_dist(x0: float, y0: float, x1: float, y1: float,
		px: float, py: float) -> float:
	var t := seg_point_t(x0, y0, x1, y1, px, py)
	var qx := x0 + (x1 - x0) * t - px
	var qy := y0 + (y1 - y0) * t - py
	return hyp(qx, qy)


## Distance from a point to an AABB (0 when inside).
static func rect_dist(x: float, y: float, rx: float, ry: float, rw: float, rh: float) -> float:
	var dx := maxf(maxf(rx - x, 0.0), x - (rx + rw))
	var dy := maxf(maxf(ry - y, 0.0), y - (ry + rh))
	return sqrt(dx * dx + dy * dy)


## Push a circle at (x,y) out of an AABB; returns the resolved centre.
## A circle whose centre is inside the rect exits along the shallowest axis.
## (The JS version returns through module globals to dodge an allocation.
## `Vector2` is a value type in Godot, so returning one costs nothing.)
static func push_out_circle(x: float, y: float, r: float,
		rx: float, ry: float, rw: float, rh: float) -> Vector2:
	var cx := clampf(x, rx, rx + rw)
	var cy := clampf(y, ry, ry + rh)
	var dx := x - cx
	var dy := y - cy
	var d2 := dx * dx + dy * dy
	if d2 >= r * r:
		return Vector2(x, y)
	if d2 > 1e-9:
		var d := sqrt(d2)
		var k := (r - d) / d + 1e-6
		return Vector2(x + dx * k, y + dy * k)
	var left := x - rx
	var right := rx + rw - x
	var top := y - ry
	var bot := ry + rh - y
	var m := minf(minf(left, right), minf(top, bot))
	if m == left:
		return Vector2(rx - r - 1e-6, y)
	if m == right:
		return Vector2(rx + rw + r + 1e-6, y)
	if m == top:
		return Vector2(x, ry - r - 1e-6)
	return Vector2(x, ry + rh + r + 1e-6)


## True when nothing in the flat rect array interrupts the segment.
static func los_clear(x0: float, y0: float, x1: float, y1: float,
		rects: PackedFloat64Array) -> bool:
	var n := rects.size()
	var i := 0
	while i < n:
		if seg_rect_t(x0, y0, x1, y1, rects[i], rects[i + 1], rects[i + 2], rects[i + 3]) != INF:
			return false
		i += 4
	return true


## Incidence angle in radians between a direction and the AABB face nearest to
## the boundary point (px,py). 0 = travelling along the face (grazing),
## PI/2 = square into it.
static func face_incidence(dir_x: float, dir_y: float, px: float, py: float,
		rx: float, ry: float, rw: float, rh: float) -> float:
	var left := absf(px - rx)
	var right := absf(rx + rw - px)
	var top := absf(py - ry)
	var bot := absf(ry + rh - py)
	var m := minf(minf(left, right), minf(top, bot))
	# normal of the nearest face: vertical faces -> (+-1,0), horizontal -> (0,+-1)
	var nx := 1.0 if (m == left or m == right) else 0.0
	var ny := 0.0 if nx == 1.0 else 1.0
	var l := hyp(dir_x, dir_y)
	if l == 0.0:
		l = 1.0
	var dot := absf((dir_x * nx + dir_y * ny) / l)
	return asin(clampf(dot, 0.0, 1.0))
