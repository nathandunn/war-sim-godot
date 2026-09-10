extends Control
##
## The app: a field, a setup drawer, and two modes.
##
## `single` watches one battle at a fixed 60 Hz with a live stats overlay.
## `simulate` runs N seeded battles headless and shows the table. Both are the
## same `World` — simulate just runs it as fast as the frame budget allows and
## never draws it.
##
## The whole UI is built in code. It is one screen of controls that has to work
## on a phone and on a desktop without a second layout, and a hand-authored
## .tscn for that is a lot of coordinates to keep in sync with the code that
## reads them back.
##
## The "<- Apps" link is deliberately *not* here: it is a plain anchor in the
## export shell (`web/shell.html`), so it is a real link with real
## middle-click/long-press behaviour rather than a canvas button that calls
## `OS.shell_open`. The top bar keeps its left edge clear for it.
##

const World := preload("res://scripts/world.gd")
const Batch := preload("res://scripts/batch.gd")
const D := preload("res://scripts/data.gd")
const Field := preload("res://ui/field.gd")

## Room for the export shell's floating "<- Apps" pill.
const BACK_LINK_GUTTER := 118.0
const TOP_BAR_H := 46.0
const DRAWER_W := 340.0
## Slice budget for simulate mode: how long a frame may spend stepping trials.
const SIM_SLICE_MS := 9.0
## The spec's catch-up cap. A slow frame drops sim time rather than diverging.
const MAX_CATCHUP := 4

var _mode := "single"
var _map_id := "open"
var _seed := 20260909
var _units: Array = []
var _world: RefCounted
var _accum := 0.0
var _running := true
var _tick_ms := 0.0

# simulate-mode state
var _sim_active := false
var _sim_trials := 5
var _sim_done: Array = []
var _sim_world: RefCounted
var _sim_index := 0
var _sim_opts: Dictionary = {}

# nodes
var _field_holder: Control
var _field: Node2D
var _drawer: PanelContainer
var _drawer_open := false
var _scrim: ColorRect
var _unit_box: VBoxContainer
var _stats_panel: PanelContainer
var _stats_head: Label
var _stats_grid: GridContainer
var _sim_panel: PanelContainer
var _sim_status: Label
var _sim_grid: GridContainer
var _sim_bar: ProgressBar
var _play_btn: Button
var _mode_btn: Button
var _seed_spin: SpinBox
var _map_btn: OptionButton
var _setup_btn: Button


func _ready() -> void:
	_apply_theme()
	_default_army()
	_build_field()
	_build_top_bar()
	_build_stats()
	_build_sim_panel()
	_build_drawer()
	_reset_world()
	get_viewport().size_changed.connect(_layout_field)
	_layout_field()


# ── theme ─────────────────────────────────────────────────────────
func _apply_theme() -> void:
	var t := Theme.new()
	t.default_font_size = 15
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.14, 0.16, 0.21)
	btn.border_color = Color(1, 1, 1, 0.14)
	btn.set_border_width_all(1)
	btn.set_corner_radius_all(7)
	btn.content_margin_left = 12; btn.content_margin_right = 12
	btn.content_margin_top = 8; btn.content_margin_bottom = 8
	var hov := btn.duplicate() as StyleBoxFlat
	hov.bg_color = Color(0.20, 0.23, 0.30)
	var prs := btn.duplicate() as StyleBoxFlat
	prs.bg_color = Color(0.25, 0.42, 0.66)
	for cls in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", cls, btn)
		t.set_stylebox("hover", cls, hov)
		t.set_stylebox("pressed", cls, prs)
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_color("font_color", cls, Color(0.90, 0.92, 0.96))
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.055, 0.063, 0.086, 0.94)
	panel.border_color = Color(1, 1, 1, 0.11)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(10)
	panel.set_content_margin_all(12)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_color("font_color", "Label", Color(0.84, 0.87, 0.92))
	theme = t


# ── army ──────────────────────────────────────────────────────────
##
## 125 + 125 a side. The same 500-actor configuration the JS build's
## measurements were taken on, so the two are comparable out of the box.
##
func _default_army() -> void:
	_units = [
		_mk_unit(0, "line", 125, "rifle"),
		_mk_unit(0, "shock", 125, "smg"),
		_mk_unit(1, "guards", 125, "rifle"),
		_mk_unit(1, "skirmishers", 125, "marksman"),
	]


func _mk_unit(team: int, preset_id: String, count: int, weapon_id: String) -> Dictionary:
	return {
		"team": team, "preset": preset_id, "count": count, "weapon": weapon_id,
		"traits": D.preset(preset_id), "open": false,
	}


## The shape `world.gd` wants.
func _unit_defs() -> Array:
	var out: Array = []
	for u in _units:
		if int(u["count"]) <= 0:
			continue
		out.append({
			"team": int(u["team"]),
			"name": String(D.PRESETS[u["preset"]]["name"]),
			"count": int(u["count"]),
			"personality": (u["traits"] as Dictionary).duplicate(),
			"weapon": D.WEAPONS[u["weapon"]],
		})
	return out


func _actor_total() -> int:
	var n := 0
	for u in _units:
		n += int(u["count"])
	return n


# ── field ─────────────────────────────────────────────────────────
func _build_field() -> void:
	_field_holder = Control.new()
	_field_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_field_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_field_holder.clip_contents = true
	add_child(_field_holder)
	_field = Field.new()
	_field_holder.add_child(_field)


func _layout_field() -> void:
	var avail := Vector2(size.x, size.y - TOP_BAR_H)
	if avail.x <= 0.0 or avail.y <= 0.0:
		return
	var s: float = minf(avail.x / D.FIELD_W, avail.y / D.FIELD_H)
	_field.scale = Vector2(s, s)
	_field.position = Vector2(
		(avail.x - D.FIELD_W * s) * 0.5,
		TOP_BAR_H + (avail.y - D.FIELD_H * s) * 0.5)


# ── top bar ───────────────────────────────────────────────────────
func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = TOP_BAR_H
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 1, 1, 0.10)
	sb.border_width_bottom = 1
	sb.content_margin_left = BACK_LINK_GUTTER      # keep clear of the shell's back link
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	bar.add_theme_stylebox_override("panel", sb)
	add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bar.add_child(row)

	_setup_btn = Button.new()
	_setup_btn.text = "Setup"
	_setup_btn.pressed.connect(_toggle_drawer)
	row.add_child(_setup_btn)

	_mode_btn = Button.new()
	_mode_btn.text = "Mode: Single"
	_mode_btn.tooltip_text = "Single watches one battle. Simulate runs N seeded battles headless."
	_mode_btn.pressed.connect(_toggle_mode)
	row.add_child(_mode_btn)

	_map_btn = OptionButton.new()
	for i in range(D.MAPS.size()):
		_map_btn.add_item(String(D.MAPS[i]["name"]), i)
	_map_btn.item_selected.connect(func(i: int) -> void:
		_map_id = String(D.MAPS[i]["id"])
		_reset_world())
	row.add_child(_map_btn)

	var seed_label := Label.new()
	seed_label.text = "Seed"
	row.add_child(seed_label)
	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = 2147483647
	_seed_spin.step = 1
	_seed_spin.value = _seed
	_seed_spin.custom_minimum_size.x = 120
	_seed_spin.value_changed.connect(func(v: float) -> void:
		_seed = int(v)
		_reset_world())
	row.add_child(_seed_spin)

	var dice := Button.new()
	dice.text = "Roll"
	dice.pressed.connect(func() -> void:
		# the *choice* of seed may be random; the battle it produces is not
		_seed_spin.value = float(randi() % 1000000))
	row.add_child(dice)

	_play_btn = Button.new()
	_play_btn.text = "Pause"
	_play_btn.pressed.connect(func() -> void:
		_running = not _running
		_play_btn.text = "Pause" if _running else "Play")
	row.add_child(_play_btn)

	var again := Button.new()
	again.text = "Restart"
	again.pressed.connect(_reset_world)
	row.add_child(again)


func _toggle_mode() -> void:
	_mode = "simulate" if _mode == "single" else "single"
	_mode_btn.text = "Mode: Single" if _mode == "single" else "Mode: Simulate"
	_stats_panel.visible = _mode == "single"
	_sim_panel.visible = _mode == "simulate"
	_field_holder.modulate = Color(1, 1, 1, 1.0 if _mode == "single" else 0.25)
	_play_btn.visible = _mode == "single"
	if _mode == "simulate":
		_sim_active = false
		_sim_status.text = "%d trials from seed %d. Ready." % [_sim_trials, _seed]
	else:
		_reset_world()
	_rebuild_unit_editor()


# ── live stats (single mode) ──────────────────────────────────────
func _build_stats() -> void:
	_stats_panel = PanelContainer.new()
	_stats_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_stats_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_stats_panel.offset_top = TOP_BAR_H + 10
	_stats_panel.offset_right = -10
	_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stats_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_stats_panel.add_child(v)
	_stats_head = Label.new()
	_stats_head.add_theme_font_size_override("font_size", 14)
	v.add_child(_stats_head)
	_stats_grid = GridContainer.new()
	_stats_grid.columns = 6
	_stats_grid.add_theme_constant_override("h_separation", 12)
	v.add_child(_stats_grid)


func _refresh_stats() -> void:
	if _world == null:
		return
	var a: Dictionary = _world.team_stats(0)
	var b: Dictionary = _world.team_stats(1)
	var secs := float(_world.tick) / float(World.SIM_HZ)
	var verdict := ""
	if _world.finished():
		var r: Dictionary = _world.result()
		verdict = "  —  %s" % ("A holds the field" if r["winner"] == "A"
			else ("B holds the field" if r["winner"] == "B" else "draw"))
		if r["capped"]:
			verdict += " (time)"
	_stats_head.text = "%5.1f s   A %d/%d   B %d/%d   %.1f ms/tick%s" % [
		secs, a["alive"], a["actors"], b["alive"], b["actors"], _tick_ms, verdict]
	_fill_grid(_stats_grid, ["unit", "alive", "kills", "melee", "hits/shots", "dmg +/-"],
		_unit_rows())


func _unit_rows() -> Array:
	var rows: Array = []
	for u in _world.unit_stats():
		rows.append([
			"%s %s" % ["A" if u["team"] == 0 else "B", u["name"]],
			"%d/%d" % [u["alive"], u["size"]],
			str(u["kills"]),
			str(u["meleeKills"]),
			"%d/%d" % [u["hits"], u["shots"]],
			"%.0f/%.0f" % [u["damageDealt"], u["damageTaken"]],
		])
	return rows


## Rebuild a GridContainer as a header row plus data rows.
func _fill_grid(grid: GridContainer, head: Array, rows: Array) -> void:
	for c in grid.get_children():
		c.queue_free()
	grid.columns = head.size()
	for h in head:
		var l := Label.new()
		l.text = String(h)
		l.add_theme_color_override("font_color", Color(0.55, 0.60, 0.70))
		l.add_theme_font_size_override("font_size", 12)
		grid.add_child(l)
	for r in rows:
		for i in range(head.size()):
			var l := Label.new()
			l.text = String(r[i])
			l.add_theme_font_size_override("font_size", 13)
			if i == 0:
				l.add_theme_color_override("font_color",
					Field.TEAM_COLOR[0] if String(r[0]).begins_with("A") else Field.TEAM_COLOR[1])
			grid.add_child(l)


# ── simulate panel ────────────────────────────────────────────────
func _build_sim_panel() -> void:
	_sim_panel = PanelContainer.new()
	_sim_panel.set_anchors_preset(Control.PRESET_CENTER)
	_sim_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sim_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_sim_panel.visible = false
	add_child(_sim_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_sim_panel.add_child(v)

	var title := Label.new()
	title.text = "Simulate — N seeded battles, headless"
	title.add_theme_font_size_override("font_size", 16)
	v.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var tl := Label.new()
	tl.text = "Trials"
	row.add_child(tl)
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = 200
	spin.value = _sim_trials
	spin.value_changed.connect(func(x: float) -> void:
		_sim_trials = int(x)
		if not _sim_active:
			_sim_status.text = "%d trials from seed %d. Ready." % [_sim_trials, _seed])
	row.add_child(spin)
	var go := Button.new()
	go.text = "Run"
	go.pressed.connect(_start_simulate)
	row.add_child(go)
	var stop := Button.new()
	stop.text = "Stop"
	stop.pressed.connect(func() -> void:
		_sim_active = false
		_sim_status.text = "Stopped after %d trials." % _sim_done.size()
		_refresh_sim_table())
	row.add_child(stop)

	_sim_bar = ProgressBar.new()
	_sim_bar.custom_minimum_size = Vector2(420, 10)
	_sim_bar.show_percentage = false
	v.add_child(_sim_bar)

	_sim_status = Label.new()
	_sim_status.text = "Ready."
	v.add_child(_sim_status)

	_sim_grid = GridContainer.new()
	_sim_grid.add_theme_constant_override("h_separation", 16)
	v.add_child(_sim_grid)


func _start_simulate() -> void:
	_sim_opts = {"map": D.map_by_id(_map_id), "units": _unit_defs(), "seed": _seed}
	_sim_done = []
	_sim_index = 0
	_sim_world = null
	_sim_active = true
	_sim_bar.max_value = float(_sim_trials)
	_sim_bar.value = 0
	_sim_status.text = "Running trial 1 of %d…" % _sim_trials


##
## One frame's worth of trial. Trials are stepped in slices so the page keeps
## responding; slicing never touches the seeds, so the table is the same one a
## single blocking loop would produce (`test.sh` asserts that).
##
func _simulate_slice() -> void:
	var deadline := Time.get_ticks_usec() + int(SIM_SLICE_MS * 1000.0)
	while _sim_active and Time.get_ticks_usec() < deadline:
		if _sim_world == null:
			if _sim_index >= _sim_trials:
				_sim_active = false
				_sim_status.text = "%d trials complete." % _sim_done.size()
				_refresh_sim_table()
				return
			var o := _sim_opts.duplicate(true)
			o["seed"] = _seed + _sim_index          # agent-forge's trial numbering
			_sim_world = World.new(o)
		for i in range(24):
			if _sim_world.finished():
				break
			_sim_world.step()
		if _sim_world.finished():
			_sim_done.append(_sim_world.result())
			_sim_world = null
			_sim_index += 1
			_sim_bar.value = float(_sim_index)
			_sim_status.text = "Running trial %d of %d…" % [mini(_sim_index + 1, _sim_trials), _sim_trials]
			_refresh_sim_table()


func _refresh_sim_table() -> void:
	if _sim_done.is_empty():
		_fill_grid(_sim_grid, ["metric", "value"], [])
		return
	var s: Dictionary = Batch.summarize(_sim_done)
	_fill_grid(_sim_grid, ["metric", "value"], [
		["trials", str(s["trials"])],
		["win rate A", "%.1f%%" % (float(s["winRateA"]) * 100.0)],
		["win rate B", "%.1f%%" % (float(s["winRateB"]) * 100.0)],
		["draws", str(s["draws"])],
		["decided on time cap", str(s["capped"])],
		["casualties A (mean)", "%.1f" % s["casualtiesA"]],
		["casualties B (mean)", "%.1f" % s["casualtiesB"]],
		["time to decision (mean)", "%.1f s" % s["meanSeconds"]],
		["time to decision (median)", "%.0f ticks" % s["medianTicks"]],
		["hit rate", "%.1f%%" % (float(s["hitRate"]) * 100.0)],
		["melee kills / run", "%.1f" % s["meleeKills"]],
	])


# ── setup drawer ──────────────────────────────────────────────────
func _build_drawer() -> void:
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.45)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.visible = false
	_scrim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_toggle_drawer())
	add_child(_scrim)

	_drawer = PanelContainer.new()
	_drawer.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_drawer.offset_top = TOP_BAR_H
	_drawer.offset_right = DRAWER_W
	_drawer.visible = false
	add_child(_drawer)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_drawer.add_child(scroll)
	_unit_box = VBoxContainer.new()
	_unit_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_unit_box)
	_rebuild_unit_editor()


func _toggle_drawer() -> void:
	_drawer_open = not _drawer_open
	_drawer.visible = _drawer_open
	_scrim.visible = _drawer_open
	_setup_btn.text = "Close" if _drawer_open else "Setup"
	if _drawer_open:
		_rebuild_unit_editor()


func _rebuild_unit_editor() -> void:
	if _unit_box == null:
		return
	for c in _unit_box.get_children():
		c.queue_free()

	var head := Label.new()
	head.text = "Order of battle — %d actors" % _actor_total()
	head.add_theme_font_size_override("font_size", 16)
	_unit_box.add_child(head)

	var note := Label.new()
	note.text = "The unit carries the personality. Every actor is that personality plus seeded jitter."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", Color(0.55, 0.60, 0.70))
	note.add_theme_font_size_override("font_size", 12)
	_unit_box.add_child(note)

	for team in [0, 1]:
		var tl := Label.new()
		tl.text = "Team %s" % ("A" if team == 0 else "B")
		tl.add_theme_color_override("font_color", Field.TEAM_COLOR[team])
		tl.add_theme_font_size_override("font_size", 15)
		_unit_box.add_child(tl)
		for i in range(_units.size()):
			if int(_units[i]["team"]) == team:
				_unit_box.add_child(_unit_row(i))
		var add := Button.new()
		add.text = "+ unit"
		add.pressed.connect(func() -> void:
			_units.append(_mk_unit(team, "militia", 40, "rifle"))
			_rebuild_unit_editor()
			_reset_world())
		_unit_box.add_child(add)


func _unit_row(idx: int) -> Control:
	var u: Dictionary = _units[idx]
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	box.add_child(top)

	var preset := OptionButton.new()
	for i in range(D.PRESET_IDS.size()):
		preset.add_item(String(D.PRESETS[D.PRESET_IDS[i]]["name"]), i)
		if D.PRESET_IDS[i] == u["preset"]:
			preset.selected = i
	preset.item_selected.connect(func(i: int) -> void:
		u["preset"] = D.PRESET_IDS[i]
		u["traits"] = D.preset(String(u["preset"]))
		_rebuild_unit_editor()
		_reset_world())
	preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(preset)

	var weapon := OptionButton.new()
	for i in range(D.WEAPON_IDS.size()):
		weapon.add_item(String(D.WEAPONS[D.WEAPON_IDS[i]]["name"]), i)
		if D.WEAPON_IDS[i] == u["weapon"]:
			weapon.selected = i
	weapon.item_selected.connect(func(i: int) -> void:
		u["weapon"] = D.WEAPON_IDS[i]
		_reset_world())
	top.add_child(weapon)

	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 6)
	box.add_child(count_row)
	var cl := Label.new()
	cl.text = "x%d" % int(u["count"])
	cl.custom_minimum_size.x = 46
	count_row.add_child(cl)
	var cs := HSlider.new()
	cs.min_value = 0
	cs.max_value = 250
	cs.step = 5
	cs.value = float(u["count"])
	cs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cs.custom_minimum_size.y = 26
	cs.value_changed.connect(func(v: float) -> void:
		u["count"] = int(v)
		cl.text = "x%d" % int(v)
		_reset_world())
	count_row.add_child(cs)
	var del := Button.new()
	del.text = "x"
	del.pressed.connect(func() -> void:
		_units.remove_at(idx)
		_rebuild_unit_editor()
		_reset_world())
	count_row.add_child(del)

	var toggle := Button.new()
	toggle.text = "hide traits" if u["open"] else "traits…"
	toggle.pressed.connect(func() -> void:
		u["open"] = not bool(u["open"])
		_rebuild_unit_editor())
	box.add_child(toggle)

	if bool(u["open"]):
		for t in D.WAR_TRAITS:
			box.add_child(_trait_slider(u, String(t)))

	var sep := HSeparator.new()
	box.add_child(sep)
	return box


func _trait_slider(u: Dictionary, trait_name: String) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	var l := Label.new()
	l.text = "%s  %.2f" % [trait_name, float(u["traits"][trait_name])]
	l.add_theme_font_size_override("font_size", 12)
	l.tooltip_text = String(D.TRAIT_BLURB[trait_name])
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = float(u["traits"][trait_name])
	s.custom_minimum_size.y = 24
	s.value_changed.connect(func(v: float) -> void:
		(u["traits"] as Dictionary)[trait_name] = v
		l.text = "%s  %.2f" % [trait_name, v]
		_reset_world())
	row.add_child(s)
	return row


# ── run loop ──────────────────────────────────────────────────────
func _reset_world() -> void:
	var defs := _unit_defs()
	if defs.is_empty():
		_world = null
		return
	_world = World.new({"map": D.map_by_id(_map_id), "units": defs, "seed": _seed})
	_accum = 0.0
	_tick_ms = 0.0
	_field.bind(_world)
	_field.sync(_world)
	_refresh_stats()


func _process(delta: float) -> void:
	if _mode == "simulate":
		if _sim_active:
			_simulate_slice()
		return
	if _world == null:
		return
	if _running and not _world.finished():
		# fixed 60 Hz, render decoupled; at most MAX_CATCHUP ticks a frame, so a
		# slow frame drops sim time instead of spiralling
		_accum += delta
		var budget := 1.0 / float(World.SIM_HZ)
		var steps := 0
		var t0 := Time.get_ticks_usec()
		while _accum >= budget and steps < MAX_CATCHUP:
			_world.step()
			_accum -= budget
			steps += 1
		if steps > 0:
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(steps)
			_tick_ms = _tick_ms * 0.9 + ms * 0.1 if _tick_ms > 0.0 else ms
		if _accum > budget * float(MAX_CATCHUP):
			_accum = 0.0
	_field.sync(_world)
	_refresh_stats()
