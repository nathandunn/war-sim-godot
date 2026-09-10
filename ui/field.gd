extends Node2D
##
## The field renderer: terrain in `_draw` (static, redrawn only when the map
## changes) and everything that moves in two MultiMeshes.
##
## 500 actors is past the point where a Node2D each is sensible — that is 500
## canvas items to cull, sort and batch every frame. One MultiMesh is one draw
## call, and the per-instance cost is two setter calls.
##
## Actors are chevrons rather than circles so the facing tick the spec asks for
## comes free with the instance transform instead of costing a second mesh.
##

const D := preload("res://scripts/data.gd")
const ACTOR_R := 6.0

const TEAM_COLOR := [Color(0.35, 0.66, 1.0), Color(1.0, 0.48, 0.42)]
const DEAD_COLOR := Color(0.24, 0.25, 0.30, 0.85)
const BULLET_COLOR := Color(1.0, 0.93, 0.66, 0.95)
const COVER_FILL := Color(0.16, 0.18, 0.23)
const COVER_EDGE := Color(0.30, 0.34, 0.42)
const FIELD_FILL := Color(0.075, 0.083, 0.105)
const SPAWN_TINT := [Color(0.35, 0.66, 1.0, 0.05), Color(1.0, 0.48, 0.42, 0.05)]

var cover: PackedFloat64Array = PackedFloat64Array()

var _actors: MultiMeshInstance2D
var _bullets: MultiMeshInstance2D
var _am: MultiMesh
var _bm: MultiMesh
## Per-unit shade, so a unit reads as a block rather than as loose dots.
var _unit_color: PackedColorArray = PackedColorArray()


func _ready() -> void:
	_actors = MultiMeshInstance2D.new()
	_am = MultiMesh.new()
	_am.transform_format = MultiMesh.TRANSFORM_2D
	_am.use_colors = true
	_am.mesh = _chevron_mesh()
	_actors.multimesh = _am
	add_child(_actors)

	_bullets = MultiMeshInstance2D.new()
	_bm = MultiMesh.new()
	_bm.transform_format = MultiMesh.TRANSFORM_2D
	_bm.use_colors = true
	_bm.mesh = _quad_mesh(2.6, 1.4)
	_bullets.multimesh = _bm
	add_child(_bullets)


static func _chevron_mesh() -> ArrayMesh:
	var r := ACTOR_R
	var verts := PackedVector3Array([
		Vector3(r * 1.15, 0, 0),
		Vector3(-r * 0.85, r * 0.85, 0),
		Vector3(-r * 0.35, 0, 0),
		Vector3(r * 1.15, 0, 0),
		Vector3(-r * 0.35, 0, 0),
		Vector3(-r * 0.85, -r * 0.85, 0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func _quad_mesh(w: float, h: float) -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-w, -h, 0), Vector3(w, -h, 0), Vector3(w, h, 0),
		Vector3(-w, -h, 0), Vector3(w, h, 0), Vector3(-w, h, 0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Called when the world is replaced: resize the instance buffers and work out
## each unit's shade once.
func bind(world: RefCounted) -> void:
	cover = world.cover
	_unit_color.resize(world.n_units)
	var per_team := [0, 0]
	var count_team := [0, 0]
	for u in range(world.n_units):
		count_team[world.u_team[u]] += 1
	for u in range(world.n_units):
		var team: int = world.u_team[u]
		var n: int = maxi(count_team[team], 1)
		var k: float = float(per_team[team]) / float(n)
		per_team[team] += 1
		_unit_color[u] = TEAM_COLOR[team].lerp(Color(1, 1, 1), k * 0.45)
	_am.instance_count = world.n_actors
	_bm.instance_count = maxi(world.n_actors * 2, 64)
	queue_redraw()


func sync(world: RefCounted) -> void:
	for id in range(world.n_actors):
		var alive: bool = world.a_alive[id] == 1
		var facing: float = world.a_facing[id] if alive else 0.0
		_am.set_instance_transform_2d(id, Transform2D(facing, Vector2(world.ax[id], world.ay[id])))
		_am.set_instance_color(id, _unit_color[world.a_unit[id]] if alive else DEAD_COLOR)
	var n: int = mini(world.b_count, _bm.instance_count)
	for i in range(n):
		var v := Vector2(world.b_vx[i], world.b_vy[i])
		_bm.set_instance_transform_2d(i, Transform2D(v.angle(), Vector2(world.b_x[i], world.b_y[i])))
		_bm.set_instance_color(i, BULLET_COLOR)
	_bm.visible_instance_count = n


func _draw() -> void:
	draw_rect(Rect2(0, 0, D.FIELD_W, D.FIELD_H), FIELD_FILL)
	draw_rect(D.SPAWN_A, SPAWN_TINT[0])
	draw_rect(D.SPAWN_B, SPAWN_TINT[1])
	var i := 0
	while i < cover.size():
		var r := Rect2(cover[i], cover[i + 1], cover[i + 2], cover[i + 3])
		draw_rect(r, COVER_FILL)
		draw_rect(r, COVER_EDGE, false, 1.5)
		i += 4
	draw_rect(Rect2(0, 0, D.FIELD_W, D.FIELD_H), Color(0.22, 0.25, 0.31), false, 2.0)
