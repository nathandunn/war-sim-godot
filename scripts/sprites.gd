extends SceneTree
##
## Generates `assets/soldiers.png`, the actor sprite sheet, from code.
##
##   godot --headless --script res://scripts/sprites.gd
##   godot --headless --script res://scripts/sprites.gd -- --preview /tmp/x.png
##   godot --headless --script res://scripts/sprites.gd -- --scene docs/palette-after.png
##   godot --headless --script res://scripts/sprites.gd -- --legacy --scene docs/palette-before.png
##
## `--legacy` composites the same scene under the colours the app shipped with,
## so the palette change has a before picture taken through the same lens as the
## after one. It changes nothing about the sheet, which is luminance only.
##
## Nothing is imported from outside this repo and no drawing API is used: the
## sheet is composed analytically into an `Image`, one shape at a time,
## supersampled SS x SS. That is deliberate — `--headless` runs on the dummy
## rendering driver, so a `SubViewport` produces no pixels and any generator
## built on `_draw` would only work on a machine with a GPU and a display,
## which the build host is not.
##
## The sheet stores *luminance*, not colour: the body is 0.78, the head 1.0 and
## the weapon 0.16, and the shader multiplies by the per-instance team shade.
## One sheet therefore serves both teams, every unit shade and the corpse tint,
## and the weapon stays dark under all of them.
##
## Poses are the same five the canvas build draws, in the same order and with
## the same proportions, so the two implementations look like each other:
## stand, crouch, lunge, ragdoll, corpse.
##

const R := 6.0                    # ACTOR_R: everything is proportional to it
const CELL_R := R * 2.6           # half-extent of a cell, in logical units
const CELL := 64                  # cell size in pixels
const POSES := ["stand", "crouch", "lunge", "ragdoll", "corpse"]
const SS := 4                     # supersampling factor per axis

const Palette := preload("res://scripts/palette.gd")

## The sheet's luminance levels. `scripts/palette.gd` owns them because the
## contrast bar is stated against the *body*, not against the team colour — a
## torso is 0.72 of the tint and checking the tint alone would pass a sprite
## whose body fails.
const BODY := Palette.LUM_BODY
const HEAD := Palette.LUM_HELMET
const WEAPON := 0.15
const LIMB := Palette.LUM_LIMB
## Drawn *under* a shape, one notch larger, to separate it from whatever it
## overlaps. Nearly black, so on the field's near-black background it costs
## nothing at the silhouette's outer edge and does all its work between the
## helmet and the shoulders — which at eighteen pixels is the whole difference
## between a man and a blob.
const OUTLINE := 0.06

## The pre-2026-09-11 colours, kept only so `--legacy` can draw the before shot:
## a near-black field, slate-blue sandbags on it, and an ember/cyan pair.
const LEGACY := {
	"field": Color(0.051, 0.063, 0.09),
	"grid": Color(0.078, 0.098, 0.141),
	"team": [Color(0.98, 0.55, 0.32), Color(0.36, 0.84, 0.90)],
	"dead": Color(0.26, 0.28, 0.34),
	"cover_fill": Color(0.137, 0.165, 0.22),
	"cover_bag": [Color(0.20, 0.239, 0.318), Color(0.169, 0.204, 0.267)],
	"cover_top": Color(0.275, 0.325, 0.427),
	"cover_foot": Color(0.102, 0.125, 0.161),
}

var _legacy := false
var _lum := PackedFloat32Array()
var _cov := PackedFloat32Array()


## A palette entry, or its pre-2026-09-11 counterpart under `--legacy`.
func _c(key: String) -> Color:
	if _legacy:
		return LEGACY[key]
	match key:
		"field": return Palette.FIELD
		"grid": return Palette.GRID
		"dead": return Palette.CORPSE
		"cover_fill": return Palette.COVER_FILL
		"cover_top": return Palette.COVER_TOP
		"cover_foot": return Palette.COVER_FOOT
	push_error("no palette entry %s" % key)
	return Palette.WHITE


func _team(i: int) -> Color:
	return LEGACY["team"][i] if _legacy else Palette.TEAM[i]


func _bag(i: int) -> Color:
	return LEGACY["cover_bag"][i] if _legacy else Palette.COVER_BAG[i]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var img := _sheet()
	var out := "res://assets/soldiers.png"
	var err := img.save_png(ProjectSettings.globalize_path(out))
	print("wrote %s  %dx%d  (%s)" % [out, img.get_width(), img.get_height(), error_string(err)])
	for i in range(args.size()):
		if args[i] == "--legacy":
			_legacy = true
	for i in range(args.size()):
		if args[i] == "--preview" and i + 1 < args.size():
			_preview(img, args[i + 1])
		elif args[i] == "--scene" and i + 1 < args.size():
			_scene(img, args[i + 1])
	quit(0 if err == OK else 1)


## The sheet: POSES cells side by side, each CELL x CELL, facing +x.
func _sheet() -> Image:
	var w := CELL * POSES.size()
	var img := Image.create(w, CELL, false, Image.FORMAT_RGBA8)
	img.fill(Palette.TRANSPARENT)
	for p in range(POSES.size()):
		_begin()
		_pose(p)
		_blit(img, p * CELL)
	return img


# ── the poses ─────────────────────────────────────────────────────
##
## Drawn in logical units about the origin, facing +x. Painter's order: the
## weapon goes down first so the shoulders overlap its butt end.
##
func _pose(p: int) -> void:
	var name: String = POSES[p]
	if name == "ragdoll" or name == "corpse":
		_fallen(name == "ragdoll")
		return
	#          along across helmet muzzle boots splay arm
	if name == "crouch":
		_soldier(0.46, 0.86, 0.28, 1.40, 0.00, 0.00, 0.72)
	elif name == "lunge":
		_soldier(0.62, 0.88, 0.30, 2.80, 1.25, 0.55, 1.35)
	else:
		_soldier(0.52, 1.00, 0.30, 2.15, 1.00, 0.24, 0.98)


##
## One soldier from above, facing +x.
##
## What makes eighteen pixels read as a man rather than a dot is, in order: the
## **rifle**, a dark bar reaching well past the head — thick stock, thin barrel,
## held to the right; the **arms**, two limbs making a V forward onto the grip,
## which is the shape nothing but a person makes; the **helmet**, small and the
## brightest thing on the sprite; and the **shoulders** it sits proud of. Boots
## trail behind so the facing is still legible when the rifle is edge-on.
##
## Everything is in units of R. `along`/`across` size the shoulders, `boots` how
## far the feet trail (0 when crouched — they are under you), `splay` how far
## apart they are, `arm` how far forward the hands reach.
##
func _soldier(along: float, across: float, helmet: float, muzzle: float,
		boots: float, splay: float, arm: float) -> void:
	var gun := R * 0.22                     # the rifle's offset to the right
	if boots > 0.0:
		_segment(-R * 0.50, -R * across * 0.42, -R * boots, -R * (across * 0.42 + splay), R * 0.24, LIMB)
		_segment(-R * 0.50, R * across * 0.42, -R * boots, R * (across * 0.42 + splay), R * 0.24, LIMB)
	# rifle: a stubby stock at the shoulder and a thin barrel out past the helmet
	_segment(-R * 0.85, gun * 0.75, R * 0.20, gun, R * 0.34, WEAPON)
	_segment(R * 0.20, gun, R * muzzle, gun * 1.1, R * 0.21, WEAPON)
	##
	## Order matters and cost a redraw to get right: shapes are opaque and
	## overwrite, so an outline laid down *after* the shoulders cuts a dark
	## gash across them. Every rim therefore goes down before the shape it
	## borders, and the shape covers the half of it that should not show.
	##
	for i in range(2):
		var sign := -1.0 if i == 0 else 1.0
		var ay0: float = sign * R * across * 0.62
		var ax1: float = R * (arm if sign > 0.0 else arm * 1.15)
		var ay1: float = gun * (1.5 if sign > 0.0 else -0.2)
		_segment(R * 0.05, ay0, ax1, ay1, R * 0.34, OUTLINE)
	_ellipse(0.0, 0.0, R * along + R * 0.10, R * across + R * 0.10, 0.0, OUTLINE)
	_ellipse(0.0, 0.0, R * along, R * across, 0.0, BODY)
	for i in range(2):
		var sign := -1.0 if i == 0 else 1.0
		var ay0: float = sign * R * across * 0.62
		var ax1: float = R * (arm if sign > 0.0 else arm * 1.15)
		var ay1: float = gun * (1.5 if sign > 0.0 else -0.2)
		_segment(R * 0.05, ay0, ax1, ay1, R * 0.22, BODY)
	# helmet, forward of the shoulder line and ringed so it reads as above them
	_circle(R * 0.42, 0.0, R * helmet + R * 0.12, OUTLINE)
	_circle(R * 0.42, 0.0, R * helmet, HEAD)


## A body on the ground: torso across the fall line, limbs anywhere, helmet off.
func _fallen(fresh: bool) -> void:
	var lum := BODY if fresh else BODY * 0.55
	var limb := LIMB if fresh else LIMB * 0.55
	_segment(-R * 0.15, -R * 0.15, R * 1.35, -R * 1.00, R * 0.26, limb)   # outflung arm
	_segment(-R * 0.20, R * 0.10, R * 1.00, R * 1.10, R * 0.26, limb)     # the other arm
	_segment(-R * 0.55, -R * 0.10, -R * 1.50, -R * 0.55, R * 0.28, limb)  # legs, folded
	_segment(-R * 0.55, R * 0.20, -R * 1.35, R * 0.90, R * 0.28, limb)
	_ellipse(0.0, 0.0, R * 1.02 + R * 0.1, R * 0.62 + R * 0.1, 0.42, OUTLINE)
	_ellipse(0.0, 0.0, R * 1.02, R * 0.62, 0.42, lum)
	_circle(R * 0.66, -R * 0.46, R * 0.40 + R * 0.11, OUTLINE)
	_circle(R * 0.66, -R * 0.46, R * 0.40, HEAD if fresh else HEAD * 0.5)
	if fresh:
		_segment(R * 0.6, R * 0.85, R * 1.9, R * 0.45, R * 0.22, WEAPON)  # dropped weapon


# ── an analytic rasteriser, SS x SS supersampled ──────────────────
##
## `_lum` is the luminance last written to a subsample and `_cov` its coverage.
## Shapes are opaque and painted in order, so a later shape simply overwrites —
## which is what a 2-D canvas `fill()` does, and it keeps the compositing to one
## comparison per subsample.
##
func _begin() -> void:
	var n := CELL * SS * CELL * SS
	if _lum.size() != n:
		_lum.resize(n)
		_cov.resize(n)
	_lum.fill(0.0)
	_cov.fill(0.0)


## Pixel-space (subsample) coordinates of a logical point.
func _to_px(v: float) -> float:
	return (v + CELL_R) / (CELL_R * 2.0) * float(CELL * SS)


func _paint(ix: int, iy: int, lum: float) -> void:
	var n := CELL * SS
	if ix < 0 or iy < 0 or ix >= n or iy >= n:
		return
	var k := iy * n + ix
	_lum[k] = lum
	_cov[k] = 1.0


func _ellipse(cx: float, cy: float, a: float, b: float, rot: float, lum: float) -> void:
	var n := CELL * SS
	var ca := cos(-rot)
	var sa := sin(-rot)
	var reach := maxf(a, b)
	var x0 := int(floor(_to_px(cx - reach)))
	var x1 := int(ceil(_to_px(cx + reach)))
	var y0 := int(floor(_to_px(cy - reach)))
	var y1 := int(ceil(_to_px(cy + reach)))
	for iy in range(maxi(y0, 0), mini(y1 + 1, n)):
		var wy := (float(iy) + 0.5) / float(n) * (CELL_R * 2.0) - CELL_R - cy
		for ix in range(maxi(x0, 0), mini(x1 + 1, n)):
			var wx := (float(ix) + 0.5) / float(n) * (CELL_R * 2.0) - CELL_R - cx
			var rx := wx * ca - wy * sa
			var ry := wx * sa + wy * ca
			if (rx * rx) / (a * a) + (ry * ry) / (b * b) <= 1.0:
				_paint(ix, iy, lum)


func _circle(cx: float, cy: float, r: float, lum: float) -> void:
	_ellipse(cx, cy, r, r, 0.0, lum)


## A capsule: every point within `width / 2` of the segment.
func _segment(x0: float, y0: float, x1: float, y1: float, width: float, lum: float) -> void:
	var n := CELL * SS
	var half := width / 2.0
	var lox := minf(x0, x1) - half
	var hix := maxf(x0, x1) + half
	var loy := minf(y0, y1) - half
	var hiy := maxf(y0, y1) + half
	var dx := x1 - x0
	var dy := y1 - y0
	var len2 := dx * dx + dy * dy
	if len2 < 1e-9:
		return
	for iy in range(maxi(int(floor(_to_px(loy))), 0), mini(int(ceil(_to_px(hiy))) + 1, n)):
		var wy := (float(iy) + 0.5) / float(n) * (CELL_R * 2.0) - CELL_R
		for ix in range(maxi(int(floor(_to_px(lox))), 0), mini(int(ceil(_to_px(hix))) + 1, n)):
			var wx := (float(ix) + 0.5) / float(n) * (CELL_R * 2.0) - CELL_R
			var t := clampf(((wx - x0) * dx + (wy - y0) * dy) / len2, 0.0, 1.0)
			var px := x0 + dx * t
			var py := y0 + dy * t
			if (wx - px) * (wx - px) + (wy - py) * (wy - py) <= half * half:
				_paint(ix, iy, lum)


## Average each SS x SS block down into one pixel: luminance in RGB, coverage
## in alpha. Premultiplication is not wanted here — the shader multiplies the
## tint into RGB and uses alpha as it is.
func _blit(img: Image, ox: int) -> void:
	var n := CELL * SS
	var inv := 1.0 / float(SS * SS)
	for y in range(CELL):
		for x in range(CELL):
			var lum := 0.0
			var cov := 0.0
			for sy in range(SS):
				for sx in range(SS):
					var k := (y * SS + sy) * n + (x * SS + sx)
					lum += _lum[k] * _cov[k]
					cov += _cov[k]
			cov *= inv
			if cov <= 0.0:
				continue
			lum = lum * inv / cov          # mean luminance over the covered part
			img.set_pixel(ox + x, y, Color(lum, lum, lum, cov))


##
## A magnified, tinted contact sheet, for looking at. Not committed and not
## loaded by the game — the only way to check a glyph reads as a soldier on a
## host with no display.
##
func _preview(sheet: Image, path: String) -> void:
	# Row scales chosen so the top row is roughly what a phone draws (a 12-unit
	# body inside a 31-unit cell, at about 1.5 device pixels per unit) and the
	# rest is for looking at the shapes.
	var rows := [
		{"zoom": 1, "tint": _team(0)},
		{"zoom": 2, "tint": _team(1)},
		{"zoom": 5, "tint": _team(0)},
		{"zoom": 5, "tint": _c("dead")},
	]
	var w := 0
	var h := 0
	for r in rows:
		w = maxi(w, CELL * POSES.size() * int(r["zoom"]))
		h += CELL * int(r["zoom"])
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(_c("field"), 1.0))
	var oy := 0
	for r in rows:
		var zoom := int(r["zoom"])
		var tint: Color = r["tint"]
		for y in range(CELL):
			for x in range(CELL * POSES.size()):
				var s := sheet.get_pixel(x, y)
				if s.a <= 0.0:
					continue
				var base := out.get_pixel(x * zoom, oy + y * zoom)
				var c := base.lerp(Color(s.r * tint.r, s.g * tint.g, s.b * tint.b), s.a)
				for dy in range(zoom):
					for dx in range(zoom):
						out.set_pixel(x * zoom + dx, oy + y * zoom + dy, c)
		oy += CELL * zoom
	out.save_png(path)
	print("preview -> %s  %dx%d  (poses: %s)" % [path, w, h, ", ".join(POSES)])


##
## A patch of field: sandbag cover, a squad crouched along it, others standing,
## one lunging, two down. Composited from the sheet exactly the way the game
## does it — rotate, tint, blend — so what this shows is what the page draws.
## The only way to look at the thing on a host with no display.
##
##   godot --headless --script res://scripts/sprites.gd -- --scene /tmp/x.png
##
func _scene(sheet: Image, path: String) -> void:
	var px := 3.0                                  # device pixels per logical unit
	var w := 520
	var h := 300
	var img := Image.create(int(w * px), int(h * px), false, Image.FORMAT_RGBA8)
	img.fill(Color(_c("field"), 1.0))
	_scene_grid(img, px, w, h)
	_scene_cover(img, px, Rect2(120, 60, 150, 70))
	_scene_cover(img, px, Rect2(120, 190, 150, 70))

	var orange: Color = _team(0)
	var cyan: Color = _team(1)
	var dead: Color = _c("dead")
	# crouched along the far face of the top wall, facing right
	for i in range(6):
		_scene_actor(img, sheet, px, 1, Vector2(132.0 + i * 26.0, 46.0), -0.15 + i * 0.05, cyan)
	# a firing line standing off, facing left
	for i in range(5):
		_scene_actor(img, sheet, px, 0, Vector2(410.0, 40.0 + i * 24.0), PI + 0.1 * i, orange)
	# advancing on the lower wall
	for i in range(4):
		_scene_actor(img, sheet, px, 0, Vector2(330.0 - i * 22.0, 205.0 + i * 9.0), PI - 0.2, orange)
	_scene_actor(img, sheet, px, 2, Vector2(292.0, 250.0), PI + 0.4, orange)          # lunging
	for i in range(3):
		_scene_actor(img, sheet, px, 1, Vector2(133.0 + i * 30.0, 275.0), 0.2 * i, cyan)
	_scene_actor(img, sheet, px, 3, Vector2(360.0, 150.0), 1.1, dead)                 # just fell
	_scene_actor(img, sheet, px, 4, Vector2(300.0, 130.0), 2.4, dead)                 # settled
	img.save_png(path)
	print("scene -> %s  %dx%d" % [path, img.get_width(), img.get_height()])


func _scene_grid(img: Image, px: float, w: int, h: int) -> void:
	var c := Color(_c("grid"), 1.0)
	var x := 0
	while x < w:
		for y in range(img.get_height()):
			img.set_pixel(int(x * px), y, c)
		x += 100
	var y2 := 0
	while y2 < h:
		for x2 in range(img.get_width()):
			img.set_pixel(x2, int(y2 * px), c)
		y2 += 75


## The same sandbag wall both renderers draw: a slab, a run of bags along each
## face, a lit top edge and a shadowed bottom one.
func _scene_cover(img: Image, px: float, r: Rect2) -> void:
	_fill_rect(img, px, r, Color(_c("cover_fill"), 1.0))
	var bag := 13.0
	for face in range(4):
		var horizontal := face < 2
		var span: float = r.size.x if horizontal else r.size.y
		var n := maxi(2, int(round(span / bag)))
		var step := span / float(n)
		for i in range(n):
			var t: float = (r.position.x if horizontal else r.position.y) + (float(i) + 0.5) * step
			var cx: float = t if horizontal else (r.position.x if face == 2 else r.position.x + r.size.x)
			var cy: float = (r.position.y if face == 0 else r.position.y + r.size.y) if horizontal else t
			var col := Color(_bag(0), 1.0) if i % 2 == 0 else Color(_bag(1), 1.0)
			_fill_ellipse(img, px, Vector2(cx, cy),
				Vector2(step * 0.56, 6.5) if horizontal else Vector2(6.5, step * 0.56), col)
	_fill_rect(img, px, Rect2(r.position.x, r.position.y - 2.0, r.size.x, 2.0), Color(_c("cover_top"), 1.0))
	_fill_rect(img, px, Rect2(r.position.x, r.position.y + r.size.y, r.size.x, 1.6), Color(_c("cover_foot"), 1.0))


func _fill_rect(img: Image, px: float, r: Rect2, c: Color) -> void:
	for y in range(maxi(int(r.position.y * px), 0), mini(int((r.position.y + r.size.y) * px), img.get_height())):
		for x in range(maxi(int(r.position.x * px), 0), mini(int((r.position.x + r.size.x) * px), img.get_width())):
			img.set_pixel(x, y, c)


func _fill_ellipse(img: Image, px: float, c: Vector2, r: Vector2, col: Color) -> void:
	for y in range(maxi(int((c.y - r.y) * px), 0), mini(int((c.y + r.y) * px) + 1, img.get_height())):
		for x in range(maxi(int((c.x - r.x) * px), 0), mini(int((c.x + r.x) * px) + 1, img.get_width())):
			var dx := (float(x) + 0.5) / px - c.x
			var dy := (float(y) + 0.5) / px - c.y
			if dx * dx / (r.x * r.x) + dy * dy / (r.y * r.y) <= 1.0:
				img.set_pixel(x, y, col)


## Blit one sheet cell, rotated about its centre and tinted, onto the scene.
func _scene_actor(img: Image, sheet: Image, px: float, pose: int, at: Vector2, rot: float, tint: Color) -> void:
	var half := CELL_R * px                       # the cell's half-extent in scene pixels
	var ca := cos(-rot)
	var sa := sin(-rot)
	var cx := at.x * px
	var cy := at.y * px
	var reach := int(ceil(half * 1.45))
	for y in range(maxi(int(cy) - reach, 0), mini(int(cy) + reach, img.get_height())):
		for x in range(maxi(int(cx) - reach, 0), mini(int(cx) + reach, img.get_width())):
			var dx := float(x) + 0.5 - cx
			var dy := float(y) + 0.5 - cy
			var lx := dx * ca - dy * sa
			var ly := dx * sa + dy * ca
			var u := (lx / half + 1.0) * 0.5
			var v := (ly / half + 1.0) * 0.5
			if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
				continue
			var s := sheet.get_pixel(pose * CELL + int(u * float(CELL)), int(v * float(CELL)))
			if s.a <= 0.02:
				continue
			var base := img.get_pixel(x, y)
			img.set_pixel(x, y, base.lerp(Color(s.r * tint.r, s.g * tint.g, s.b * tint.b), s.a))
