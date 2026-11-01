class_name ATGMClusterMod
extends RefCounted

## Мод «Кассетные боеприпасы для ПТРК» для DroneFlames PC Port
## Автор: @good_boy_irl
## Реализует кассетное разделение боевой части ракет ПТРК (9М133-К / BGM-71K).
## На подлёте к цели (50 м) ракета раскрывается и выбрасывает 8 кумулятивно-осколочных
## суббоеприпасов, накрывающих бронегруппы и пехоту каскадом взрывов.
## Горячая клавиша: [K] для переключения режимов (Кассетный / Тандемный).

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var world_layer: Node2D = null
var ui_layer: CanvasLayer = null

# 0 = Тандемный моноблок (Одиночные цели), 1 = Кассетная БЧ (Площадной удар)
var cluster_mode: bool = true

# Активные суббоеприпасы и эффекты разведения
var active_submunitions: Array = []
var separation_fx: Array = []
var impact_shockwaves: Array = []

func init_mod(mm: Node) -> void:
	mm_ref = mm
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[ATGMCluster] Mod initialized.")

func cleanup_mod(mm: Node) -> void:
	_cleanup_nodes()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[ATGMCluster] Mod cleaned up.")

func _cleanup_nodes() -> void:
	active_submunitions.clear()
	separation_fx.clear()
	impact_shockwaves.clear()
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_free()
		world_layer = null
	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.queue_free()
		ui_layer = null

func _on_world_started(main: Node, world: Node) -> void:
	main_ref = main
	world_ref = world
	_cleanup_nodes()

	# Create In-world overlay for submunitions, trails and shockwaves
	world_layer = ATGMClusterWorldLayer.new()
	world_layer.setup(self, main, world)
	world.add_child(world_layer)

	# Create UI Layer for HUD munition switcher
	ui_layer = ATGMClusterUILayer.new()
	ui_layer.setup(self, main, world)
	main.add_child(ui_layer)

	print("[ATGMCluster] World started, cluster layers attached.")

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world
	_tick_rockets(delta)
	_tick_submunitions(delta)
	_tick_fx(delta)
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_redraw()

func toggle_mode() -> void:
	cluster_mode = not cluster_mode
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")

	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.update_btn_text()

	var msg = "ПТРК: Взят на вооружение КАССЕТНЫЙ боеприпас 9М133-К (Суббоеприпасы)" if cluster_mode else "ПТРК: Взят на вооружение КУМУЛЯТИВНЫЙ тандемный заряд (Одиночные цели)"
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast(msg)

func _tick_rockets(dt: float) -> void:
	if not cluster_mode:
		return
	if world_ref == null or not is_instance_valid(world_ref):
		return
	if not ("army" in world_ref and world_ref.army != null):
		return

	var army = world_ref.army
	var p = world_ref.player
	var player_cid = p.id if p != null and is_instance_valid(p) else -1

	# Iterate backwards over active army rockets
	for k in range(army.rockets.size() - 1, -1, -1):
		var r = army.rockets[k]
		if r["kind"] != "atgm":
			continue

		# Process player ATGMs (or all ATGMs if desired)
		if int(r["c"]) != player_cid:
			continue

		var t = r["target"]
		var alive_t: bool = (t is Unit and (t as Unit).alive()) or (t is Facility and world_ref.mil.alive(t as Facility))
		if not alive_t:
			continue

		var r_pos: Vector2 = r["pos"]
		var tp: Vector2 = army._target_pos(t, r_pos)
		var dist = r_pos.distance_to(tp)

		# Terminal Dispersal Trigger: within 52 px of target or almost expired
		if dist <= 52.0 or float(r["life"]) <= 0.35:
			_trigger_cluster_dispersal(r, tp, k)

func _trigger_cluster_dispersal(r: Dictionary, target_center: Vector2, rocket_idx: int) -> void:
	var army = world_ref.army
	var sep_pos: Vector2 = r["pos"]
	var heading: float = float(r["heading"])
	var cid: int = int(r["c"])

	# 1. Play Separation Sound & FX
	if ClassDB.class_exists("Sfx"):
		Sfx.play("intercept_pop", sep_pos)
		Sfx.play("atgm_launch", sep_pos)

	# Add Visual Casing Separation Ring
	separation_fx.append({
		"pos": sep_pos,
		"heading": heading,
		"r": 2.0,
		"alpha": 1.0,
		"life": 0.35
	})

	# 2. Release 8 HEAT-FRAG Submunitions (кумулятивно-осколочные элементы)
	var sub_count = 8
	var forward_dir = Vector2.from_angle(heading)
	var perp_dir = Vector2(-forward_dir.y, forward_dir.x)

	for i in sub_count:
		# Elliptical dispersion fan pattern around the target
		var angle_off = randf_range(-PI * 0.45, PI * 0.45)
		var lateral_dist = randf_range(-22.0, 22.0)
		var forward_dist = randf_range(-14.0, 26.0)

		var impact_pt = target_center + perp_dir * lateral_dist + forward_dir * forward_dist
		if world_ref.econ != null and world_ref.econ.has_method("land_point"):
			impact_pt = world_ref.econ.land_point(impact_pt, 6)

		# Staggered fall delay creates an intense rolling cascade barrage
		var fall_dur = randf_range(0.12, 0.42)

		active_submunitions.append({
			"start": sep_pos,
			"target": impact_pt,
			"pos": sep_pos,
			"t": 0.0,
			"dur": fall_dur,
			"cid": cid,
			"alt": 28.0 + randf_range(-4.0, 6.0),
			"trail": []
		})

	# 3. Remove original single-point rocket
	army.rockets.remove_at(rocket_idx)

	# Toast notification
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("БЧ ПТРК раскрыта: 8 кумулятивных суббоеприпасов накрывают сектор!")

func _tick_submunitions(dt: float) -> void:
	for i in range(active_submunitions.size() - 1, -1, -1):
		var sub = active_submunitions[i]
		sub["t"] += dt
		var prog = clampf(sub["t"] / sub["dur"], 0.0, 1.0)

		# Submunition trajectory with descending altitude
		var base_p = (sub["start"] as Vector2).lerp(sub["target"], prog)
		var cur_alt = sub["alt"] * (1.0 - prog * prog)
		sub["pos"] = base_p + Vector2(0, -cur_alt)

		# Particle trail history
		sub["trail"].append(sub["pos"])
		if sub["trail"].size() > 6:
			sub["trail"].remove_at(0)

		# Detonation at impact!
		if prog >= 1.0:
			_detonate_submunition(sub)
			active_submunitions.remove_at(i)

func _detonate_submunition(sub: Dictionary) -> void:
	var hit_pos: Vector2 = sub["target"]
	var cid: int = sub["cid"]

	# Ground blast effects
	if world_ref != null and "fx" in world_ref and world_ref.fx != null:
		world_ref.fx.spawn("atgm_hit", hit_pos.round(), 6)
		world_ref.fx.spawn("dirt_burst", (hit_pos + Vector2(randf_range(-2, 2), randf_range(-2, 2))).round(), 5)

	# Sound with pitch variation
	if ClassDB.class_exists("Sfx"):
		Sfx.play("atgm_hit" if randf() < 0.5 else "expl_small", hit_pos)

	# Expanding Shockwave Ring
	impact_shockwaves.append({
		"pos": hit_pos,
		"r": 2.0,
		"max_r": 18.0,
		"alpha": 0.85,
		"life": 0.28
	})

	# Damage to Units within 28px
	var burst_r: float = 28.0
	if world_ref != null and "army" in world_ref and world_ref.army != null:
		for u in world_ref.army.units:
			if u != null and is_instance_valid(u) and u.alive() and u.country_id != cid:
				var dist = u.pos.distance_to(hit_pos)
				if dist <= burst_r:
					var dmg = 0.0
					if u.vehicle():
						# Top-armor cumulative penetration against Tanks and IFVs
						dmg = randf_range(28.0, 38.0) * (1.0 - (dist / burst_r) * 0.4)
					else:
						# Devastating HE-FRAG shrapnel against infantry & crew
						dmg = randf_range(42.0, 56.0) * (1.0 - (dist / burst_r) * 0.3)
						u.supp = minf(1.0, u.supp + 0.6) # Pinning/suppression

					world_ref.army._damage(u, dmg, cid, hit_pos)

		# Damage to Fortifications & Facilities within 32px
		if "mil" in world_ref and "facilities" in world_ref.mil:
			for f in world_ref.mil.facilities:
				if f != null and is_instance_valid(f) and f.country_id != cid and world_ref.mil.alive(f):
					var f_center = f.center_px()
					if f_center.distance_to(hit_pos) <= 32.0:
						world_ref.army._damage(f, randf_range(24.0, 34.0), cid, hit_pos)

func _tick_fx(dt: float) -> void:
	# Casing separation rings
	for i in range(separation_fx.size() - 1, -1, -1):
		var fx = separation_fx[i]
		fx["life"] -= dt
		if fx["life"] <= 0.0:
			separation_fx.remove_at(i)
		else:
			fx["r"] += dt * 48.0
			fx["alpha"] = maxf(0.0, fx["alpha"] - dt * 2.8)

	# Impact shockwave rings
	for i in range(impact_shockwaves.size() - 1, -1, -1):
		var sw = impact_shockwaves[i]
		sw["life"] -= dt
		if sw["life"] <= 0.0:
			impact_shockwaves.remove_at(i)
		else:
			sw["r"] += dt * 55.0
			sw["alpha"] = maxf(0.0, sw["alpha"] - dt * 3.0)


# ==============================================================================
# In-World Node2D (Draws Submunitions, Contrails, Separation Rings & Shockwaves)
# ==============================================================================
class ATGMClusterWorldLayer extends Node2D:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		z_index = 82 # Render above ground units, below HUD

	func _draw() -> void:
		if mod_ref == null:
			return

		# 1. Separation Rings (Expanding white/orange gas rings)
		for fx in mod_ref.separation_fx:
			var col = Color(1.0, 0.75, 0.25, fx["alpha"])
			draw_arc(fx["pos"], fx["r"], 0, TAU, 24, col, 1.8, true)
			draw_arc(fx["pos"], fx["r"] * 0.6, 0, TAU, 16, Color(1.0, 1.0, 1.0, fx["alpha"]), 1.2, true)

		# 2. Descending Submunitions & Kinetic Contrails
		for sub in mod_ref.active_submunitions:
			var pts: Array = sub["trail"]
			if pts.size() > 1:
				for k in range(pts.size() - 1):
					var a1 = float(k) / float(pts.size())
					var line_col = Color(1.0, 0.75, 0.2, a1 * 0.9)
					draw_line(pts[k], pts[k + 1], line_col, 1.5)

			var pos = sub["pos"]
			# Glowing submunition core (HEAT dart)
			draw_circle(pos, 2.0, Color(1.0, 0.95, 0.7, 1.0))
			draw_circle(pos, 3.5, Color(1.0, 0.6, 0.1, 0.6))

		# 3. Ground Impact Shockwaves
		for sw in mod_ref.impact_shockwaves:
			var col = Color(1.0, 0.8, 0.3, sw["alpha"])
			draw_arc(sw["pos"], sw["r"], 0, TAU, 20, col, 1.5, true)
			draw_circle(sw["pos"], sw["r"] * 0.4, Color(0.9, 0.4, 0.1, sw["alpha"] * 0.35))


# ==============================================================================
# UI Layer (HUD Munition Switcher Button)
# ==============================================================================
class ATGMClusterUILayer extends CanvasLayer:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	var toggle_btn: Button = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		layer = 16

		_create_hud_button()

	func _create_hud_button() -> void:
		toggle_btn = Button.new()
		toggle_btn.custom_minimum_size = Vector2(96, 44)
		toggle_btn.anchor_left = 1.0
		toggle_btn.anchor_right = 1.0
		toggle_btn.anchor_top = 0.0
		toggle_btn.anchor_bottom = 0.0
		toggle_btn.offset_left = -106.0
		toggle_btn.offset_right = -10.0
		toggle_btn.offset_top = 320.0
		toggle_btn.offset_bottom = 364.0

		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.15, 0.18, 0.94)
		sb.border_color = Color(1.0, 0.55, 0.15, 1.0)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(4)
		sb.set_content_margin_all(2)
		toggle_btn.add_theme_stylebox_override("normal", sb)

		var sb_hover = sb.duplicate()
		sb_hover.bg_color = Color(0.18, 0.22, 0.28, 0.98)
		sb_hover.border_color = Color(1.0, 0.75, 0.25, 1.0)
		toggle_btn.add_theme_stylebox_override("hover", sb_hover)

		toggle_btn.add_theme_font_size_override("font_size", 9)
		toggle_btn.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85, 1.0))
		toggle_btn.tooltip_text = "ПТРК «КОРНЕТ-К» / BGM-71K\nТип БЧ: Кассетная (8 суббоеприпасов)\nНажмите [K] для переключения режима"
		toggle_btn.pressed.connect(_on_btn_pressed)
		add_child(toggle_btn)

		update_btn_text()

	func update_btn_text() -> void:
		if toggle_btn == null:
			return
		if mod_ref.cluster_mode:
			toggle_btn.text = "🚀 ПТРК: 💥 КАССЕТА\n[K]"
			var sb = toggle_btn.get_theme_stylebox("normal") as StyleBoxFlat
			if sb != null:
				sb.border_color = Color(1.0, 0.55, 0.15, 1.0)
		else:
			toggle_btn.text = "🎯 ПТРК: 🎯 ТАНДЕМ\n[K]"
			var sb = toggle_btn.get_theme_stylebox("normal") as StyleBoxFlat
			if sb != null:
				sb.border_color = Color(0.45, 0.75, 0.95, 1.0)

	func _on_btn_pressed() -> void:
		mod_ref.toggle_mode()

	func _unhandled_input(event: InputEvent) -> void:
		if mod_ref == null:
			return
		# Hotkey K to toggle ATGM munition mode
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_K:
				mod_ref.toggle_mode()
				get_viewport().set_input_as_handled()

	func _process(_delta: float) -> void:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			visible = main_ref.hud.visible
