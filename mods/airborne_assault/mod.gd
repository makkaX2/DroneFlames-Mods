class_name AirborneAssaultMod
extends RefCounted

## Мод «Воздушный Десант (ВДВ)» для DroneFlames PC Port
## Автор: @good_boy_irl
## Позволяет осуществлять тактическую высадку штурмовиков с вертолётов
## и массовый парашютный сброс десанта с военно-транспортных самолётов.

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var overlay_node: Node2D = null
var ui_layer: CanvasLayer = null

# 0 = Нет, 1 = Вертолёт, 2 = Самолёт
var targeting_mode: int = 0
var active_ops: Array = []

func init_mod(mm: Node) -> void:
	mm_ref = mm
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[AirborneAssault] Mod initialized.")

func cleanup_mod(mm: Node) -> void:
	_cleanup_nodes()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[AirborneAssault] Mod cleaned up.")

func _cleanup_nodes() -> void:
	targeting_mode = 0
	active_ops.clear()
	if overlay_node != null and is_instance_valid(overlay_node):
		overlay_node.queue_free()
		overlay_node = null
	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.queue_free()
		ui_layer = null

func _on_world_started(main: Node, world: Node) -> void:
	main_ref = main
	world_ref = world
	_cleanup_nodes()

	# Create In-world overlay for animations & targeting reticle
	overlay_node = AirborneAssaultOverlay.new()
	overlay_node.setup(self, main, world)
	world.add_child(overlay_node)

	# Create UI Layer for HUD buttons and tactical modal dialog
	ui_layer = AirborneAssaultUI.new()
	ui_layer.setup(self, main, world)
	main.add_child(ui_layer)

	print("[AirborneAssault] World started, overlay and UI attached.")

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world
	_tick_operations(delta)
	if overlay_node != null and is_instance_valid(overlay_node):
		overlay_node.queue_redraw()

func toggle_targeting(mode: int) -> void:
	if targeting_mode == mode:
		cancel_targeting()
	else:
		start_targeting(mode)

func start_targeting(mode: int) -> void:
	targeting_mode = mode
	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.hide_dialog()
	var mode_name = "ВЕРТОЛЁТНЫЙ ДЕСАНТ" if mode == 1 else "ПАРАШЮТНЫЙ СБРОС (ИЛ-76)"
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Режим: %s. Укажите точку на карте (ПКМ для отмены)" % mode_name)
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")

func cancel_targeting() -> void:
	if targeting_mode != 0:
		targeting_mode = 0
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Высадка десанта отменена")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_close")

func try_launch_assault(mode: int, world_pos: Vector2) -> bool:
	if world_ref == null or not is_instance_valid(world_ref):
		return false
	var p = world_ref.player
	if p == null or not is_instance_valid(p):
		return false

	var cost: int = 1000 if mode == 1 else 2800

	# 1. Проверяем аэродромы игрока
	var airfields: Array = []
	if "facilities" in world_ref.mil:
		for f in world_ref.mil.facilities:
			if f != null and is_instance_valid(f) and f.kind == Facility.Kind.AIRFIELD and f.country_id == p.id and world_ref.mil.alive(f):
				airfields.append(f)

	if airfields.is_empty():
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Для вылета десанта нужен действующий аэродром!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# 2. Проверяем средства в казне
	if p.money < cost:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств в казне! Требуется: %d" % cost)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# 3. Проверяем точку высадки (суша)
	var target = world_pos
	if world_ref.econ != null and world_ref.econ.has_method("land_point"):
		target = world_ref.econ.land_point(world_pos, 8)

	if target.distance_to(world_pos) > 65.0:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя десантироваться в открытое море!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# Снимаем средства
	p.money -= cost
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_money")

	# Находим ближайший аэродром
	var best_af: Facility = airfields[0]
	var best_d: float = best_af.center_px().distance_to(target)
	for af in airfields:
		var d = af.center_px().distance_to(target)
		if d < best_d:
			best_d = d
			best_af = af

	if mode == 1:
		_launch_heli_mission(p.id, best_af, target)
	else:
		_launch_plane_mission(p.id, best_af, target)

	return true

func _launch_heli_mission(cid: int, af: Facility, target: Vector2) -> void:
	var start_pos = af.center_px()
	var op = {
		"type": "heli",
		"country_id": cid,
		"home_af": af,
		"home_pos": start_pos,
		"pos": start_pos,
		"target_pos": target,
		"phase": "fly_in",
		"hover_time": 0.0,
		"rotor_angle": 0.0,
		"rotor_frame": 0,
		"frame": 0,
		"heading": (target - start_pos).angle(),
		"troops": [Unit.Type.ASSAULT, Unit.Type.ASSAULT, Unit.Type.ATGM, Unit.Type.FPV],
		"dropped": 0,
		"drop_interval": 0.65,
		"next_drop_t": 0.4
	}
	active_ops.append(op)
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Вертолёт Ми-8 с штурмовой группой вылетел в сектор!")

func _launch_plane_mission(cid: int, af: Facility, target: Vector2) -> void:
	var dir = (target - af.center_px()).normalized()
	if dir.length_squared() < 0.1:
		dir = Vector2.RIGHT

	var start_p = target - dir * 420.0
	var end_p = target + dir * 550.0

	var types = [
		Unit.Type.IFV,
		Unit.Type.ASSAULT,
		Unit.Type.ASSAULT,
		Unit.Type.ASSAULT,
		Unit.Type.ASSAULT,
		Unit.Type.INFANTRY,
		Unit.Type.INFANTRY,
		Unit.Type.MORTAR
	]

	var paratroopers_list: Array = []
	for i in types.size():
		var off = Vector2(randf_range(-24.0, 24.0), randf_range(-18.0, 18.0))
		var pt = target + off
		if world_ref.econ != null and world_ref.econ.has_method("land_point"):
			pt = world_ref.econ.land_point(pt, 6)
		paratroopers_list.append({
			"type": types[i],
			"target": pt,
			"alt": 42.0 + float(i) * 2.5,
			"sway": randf() * TAU,
			"landed": false
		})

	var op = {
		"type": "plane",
		"country_id": cid,
		"home_af": af,
		"pos": start_p,
		"start_pos": start_p,
		"end_pos": end_p,
		"target_pos": target,
		"dir": dir,
		"speed": 125.0,
		"frame": posmod(roundi(rad_to_deg(dir.angle()) / 22.5), 16),
		"cargo_dropped": false,
		"paratroopers": paratroopers_list
	}
	active_ops.append(op)
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Военно-транспортный Ил-76 поднялся в воздух!")

func _tick_operations(dt: float) -> void:
	for i in range(active_ops.size() - 1, -1, -1):
		var op = active_ops[i]
		if op["type"] == "heli":
			_tick_heli(op, dt, i)
		elif op["type"] == "plane":
			_tick_plane(op, dt, i)

func _tick_heli(op: Dictionary, dt: float, idx: int) -> void:
	op["rotor_angle"] += dt * 35.0
	op["rotor_frame"] = int(op["rotor_angle"]) % 3

	if op["phase"] == "fly_in":
		var to_tgt = op["target_pos"] - op["pos"]
		var dist = to_tgt.length()
		var spd = 72.0
		var hd = to_tgt.angle()
		op["heading"] = hd
		op["frame"] = posmod(roundi(rad_to_deg(hd) / 22.5), 16)
		if dist <= spd * dt:
			op["pos"] = op["target_pos"]
			op["phase"] = "hover_drop"
			op["hover_time"] = 0.0
			if world_ref != null and "fx" in world_ref and world_ref.fx != null:
				world_ref.fx.spawn("dust_s", op["target_pos"].round(), 5)
		else:
			op["pos"] += to_tgt.normalized() * spd * dt

	elif op["phase"] == "hover_drop":
		op["hover_time"] += dt
		# Slight hovering vertical wave
		op["pos"].y = op["target_pos"].y + sin(op["hover_time"] * 5.0) * 1.5

		if op["dropped"] < op["troops"].size():
			if op["hover_time"] >= op["next_drop_t"]:
				var ut = op["troops"][op["dropped"]]
				var off = Vector2(randf_range(-10, 10), randf_range(-8, 8))
				_spawn_unit(op["country_id"], ut, op["target_pos"] + off, op["home_af"])
				op["dropped"] += 1
				op["next_drop_t"] += op["drop_interval"]
		else:
			if op["hover_time"] >= 3.2:
				op["phase"] = "fly_out"
				if main_ref != null and "hud" in main_ref and main_ref.hud != null:
					main_ref.hud.show_toast("Группа «Вихрь» высадилась! Приступаем к штурму!")

	elif op["phase"] == "fly_out":
		var to_home = op["home_pos"] - op["pos"]
		var dist = to_home.length()
		var spd = 88.0
		var hd = to_home.angle()
		op["heading"] = hd
		op["frame"] = posmod(roundi(rad_to_deg(hd) / 22.5), 16)
		if dist <= spd * dt or dist < 12.0:
			active_ops.remove_at(idx)
		else:
			op["pos"] += to_home.normalized() * spd * dt

func _tick_plane(op: Dictionary, dt: float, idx: int) -> void:
	op["pos"] += op["dir"] * op["speed"] * dt
	var dist_to_tgt = op["pos"].distance_to(op["target_pos"])

	if not op["cargo_dropped"] and (dist_to_tgt <= 25.0 or (op["pos"] - op["target_pos"]).dot(op["dir"]) > 0):
		op["cargo_dropped"] = true
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Пошёл сброс десанта ВДВ на парашютах!")

	var all_landed = true
	if op["cargo_dropped"]:
		for p in op["paratroopers"]:
			if not p["landed"]:
				all_landed = false
				p["alt"] -= 8.5 * dt
				p["sway"] += dt * 3.5
				if p["alt"] <= 0.0:
					p["alt"] = 0.0
					p["landed"] = true
					_spawn_unit(op["country_id"], p["type"], p["target"], op["home_af"])

	var total_dist = op["pos"].distance_to(op["start_pos"])
	if total_dist > 950.0 and all_landed:
		active_ops.remove_at(idx)
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Десант ВДВ успешно закрепился на плацдарме!")

func _spawn_unit(cid: int, ut: int, pos: Vector2, af: Facility) -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	if not ("army" in world_ref and world_ref.army != null):
		return

	var u = Unit.new()
	u.id = world_ref.army._next_id
	world_ref.army._next_id += 1
	u.type = ut
	u.country_id = cid

	# Находим казарму игрока для объединения со штабом
	var barracks: Facility = null
	if "facilities" in world_ref.mil:
		for f in world_ref.mil.facilities:
			if f != null and is_instance_valid(f) and f.kind == Facility.Kind.BARRACKS and f.country_id == cid and world_ref.mil.alive(f):
				barracks = f
				break
	u.home = barracks if barracks != null else af
	u.hp = float(Army.SPEC[ut]["hp"]) if Army.SPEC.has(ut) else 100.0
	u.max_hp = u.hp
	u.pos = pos
	if world_ref.econ != null and world_ref.econ.has_method("land_point"):
		u.pos = world_ref.econ.land_point(pos, 6)
	u.heading = randf() * TAU
	u.update_frame()
	u.state = Unit.State.IDLE
	u.cover = 0.5
	world_ref.army.units.append(u)

	if world_ref.fx != null:
		world_ref.fx.spawn("dust_s", u.pos.round(), 5)


# ==============================================================================
# In-World Overlay (renders reticle, helicopters, planes, ropes & parachutes)
# ==============================================================================
class AirborneAssaultOverlay extends Node2D:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		z_index = 80 # Render above land, below UI

	func _draw() -> void:
		if mod_ref == null:
			return

		# 1. Draw Active Operations
		for op in mod_ref.active_ops:
			if op["type"] == "heli":
				_draw_heli(op)
			elif op["type"] == "plane":
				_draw_plane(op)

		# 2. Draw Targeting Reticle
		if mod_ref.targeting_mode != 0:
			_draw_targeting_reticle()

	func _draw_targeting_reticle() -> void:
		var mouse_w = get_global_mouse_position()
		var is_heli = mod_ref.targeting_mode == 1
		var radius = 28.0 if is_heli else 50.0
		var col = Color(0.3, 1.0, 0.4, 0.85) if is_heli else Color(0.4, 0.8, 1.0, 0.85)

		# Outer pulsing circle
		var pulse = sin(Time.get_ticks_msec() * 0.006) * 3.0
		draw_arc(mouse_w, radius + pulse, 0, TAU, 32, col, 1.5, true)
		draw_circle(mouse_w, radius * 0.25, Color(col.r, col.g, col.b, 0.25))

		# Crosshair brackets
		var s = radius + 6.0
		draw_line(mouse_w + Vector2(-s, 0), mouse_w + Vector2(-s * 0.4, 0), col, 2.0)
		draw_line(mouse_w + Vector2(s * 0.4, 0), mouse_w + Vector2(s, 0), col, 2.0)
		draw_line(mouse_w + Vector2(0, -s), mouse_w + Vector2(0, -s * 0.4), col, 2.0)
		draw_line(mouse_w + Vector2(0, s * 0.4), mouse_w + Vector2(0, s), col, 2.0)

		# Center dot
		draw_circle(mouse_w, 2.0, col)

		# Text label
		var text = "ВЫСАДКА ШТУРМОВИКОВ (МИ-8)" if is_heli else "ЗОНА СБРОСА ВДВ (ИЛ-76)"
		draw_string(ThemeDB.fallback_font, mouse_w + Vector2(radius + 8.0, 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		draw_string(ThemeDB.fallback_font, mouse_w + Vector2(radius + 8.0, 16.0), "[ЛКМ] Запуск  •  [ПКМ / Esc] Отмена", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.9, 0.9, 0.9, 0.75))

	func _draw_heli(op: Dictionary) -> void:
		var p = op["pos"]
		var shadow_p = p + Vector2(10.0, 10.0)
		var hd = op["heading"]

		# Shadow
		draw_circle(shadow_p, 8.0, Color(0.05, 0.05, 0.05, 0.35))
		draw_line(shadow_p, shadow_p + Vector2.RIGHT.rotated(hd + PI) * 12.0, Color(0.05, 0.05, 0.05, 0.35), 2.0)

		# Fuselage (Camouflage green)
		var body_col = Color(0.28, 0.42, 0.25, 1.0)
		var dark_col = Color(0.18, 0.26, 0.16, 1.0)
		var glass_col = Color(0.4, 0.7, 0.9, 0.9)

		# Skids
		draw_line(p + Vector2(-3, 6), p + Vector2(5, 6), dark_col, 1.5)
		draw_line(p + Vector2(-3, -6), p + Vector2(5, -6), dark_col, 1.5)

		# Tail boom
		var tail_end = p + Vector2.RIGHT.rotated(hd + PI) * 14.0
		draw_line(p, tail_end, body_col, 2.5)
		draw_line(tail_end, tail_end + Vector2.UP.rotated(hd) * 4.0, dark_col, 1.5)

		# Main body
		draw_circle(p, 6.0, body_col)
		draw_line(p, p + Vector2.RIGHT.rotated(hd) * 7.0, glass_col, 3.0)

		# Spinning Rotor Blades
		var rotor_ang = op["rotor_angle"]
		for k in 4:
			var ang = rotor_ang + float(k) * (PI * 0.5)
			var r_tip = p + Vector2.RIGHT.rotated(ang) * 16.0
			draw_line(p, r_tip, Color(0.85, 0.85, 0.85, 0.75), 1.2)

		# Fast-ropes during hover_drop
		if op["phase"] == "hover_drop":
			var r1 = op["target_pos"] + Vector2(-6, 0)
			var r2 = op["target_pos"] + Vector2(6, 0)
			draw_line(p, r1, Color(0.15, 0.15, 0.15, 0.85), 1.2)
			draw_line(p, r2, Color(0.15, 0.15, 0.15, 0.85), 1.2)

			# Descending soldier silhouettes
			var t = op["hover_time"]
			var slide = clampf(fmod(t, 0.65) / 0.65, 0.0, 1.0)
			var s_pos1 = p.lerp(r1, slide)
			var s_pos2 = p.lerp(r2, clampf(slide * 0.8, 0.0, 1.0))
			draw_circle(s_pos1, 2.5, Color(0.2, 0.35, 0.2, 0.9))
			draw_circle(s_pos2, 2.5, Color(0.2, 0.35, 0.2, 0.9))

	func _draw_plane(op: Dictionary) -> void:
		var p = op["pos"]
		var shadow_p = p + Vector2(25.0, 25.0)
		var hd = op["dir"].angle()

		# Shadow
		draw_circle(shadow_p, 14.0, Color(0.05, 0.05, 0.05, 0.25))

		# Transport Plane Body (Grey military transport)
		var plane_col = Color(0.48, 0.52, 0.55, 1.0)
		var wing_col = Color(0.42, 0.46, 0.49, 1.0)
		var detail_col = Color(0.28, 0.32, 0.35, 1.0)

		# Wings
		var wing_left = p + Vector2.UP.rotated(hd) * 26.0 - Vector2.RIGHT.rotated(hd) * 6.0
		var wing_right = p + Vector2.DOWN.rotated(hd) * 26.0 - Vector2.RIGHT.rotated(hd) * 6.0
		draw_line(p, wing_left, wing_col, 4.0)
		draw_line(p, wing_right, wing_col, 4.0)

		# Fuselage
		var nose = p + Vector2.RIGHT.rotated(hd) * 22.0
		var tail = p - Vector2.RIGHT.rotated(hd) * 20.0
		draw_line(tail, nose, plane_col, 6.0)

		# T-Tail
		var tail_fin_l = tail + Vector2.UP.rotated(hd) * 10.0
		var tail_fin_r = tail + Vector2.DOWN.rotated(hd) * 10.0
		draw_line(tail, tail_fin_l, detail_col, 2.5)
		draw_line(tail, tail_fin_r, detail_col, 2.5)

		# Paratroopers descending
		if op["cargo_dropped"]:
			for para in op["paratroopers"]:
				if not para["landed"]:
					_draw_paratrooper(para)

	func _draw_paratrooper(para: Dictionary) -> void:
		var ground_p = para["target"]
		var alt = para["alt"]
		var sway_x = sin(para["sway"]) * 3.5
		var pos = ground_p + Vector2(sway_x, -alt)

		# Ground shadow
		draw_circle(ground_p, 3.0, Color(0.05, 0.05, 0.05, 0.3))

		# Suspension Lines
		var canopy_top = pos + Vector2(0, -10.0)
		draw_line(canopy_top + Vector2(-8, 0), pos, Color(0.9, 0.9, 0.9, 0.6), 1.0)
		draw_line(canopy_top + Vector2(-3, 0), pos, Color(0.9, 0.9, 0.9, 0.6), 1.0)
		draw_line(canopy_top + Vector2(3, 0), pos, Color(0.9, 0.9, 0.9, 0.6), 1.0)
		draw_line(canopy_top + Vector2(8, 0), pos, Color(0.9, 0.9, 0.9, 0.6), 1.0)

		# Parachute Canopy (White arched dome)
		var canopy_poly = PackedVector2Array([
			canopy_top + Vector2(-9, 0),
			canopy_top + Vector2(-6, -6),
			canopy_top + Vector2(0, -9),
			canopy_top + Vector2(6, -6),
			canopy_top + Vector2(9, 0),
			canopy_top + Vector2(0, -2)
		])
		draw_colored_polygon(canopy_poly, Color(0.95, 0.95, 0.92, 0.95))
		draw_polyline(canopy_poly, Color(0.7, 0.7, 0.65, 1.0), 1.2)

		# Payload (IFV crate or soldier)
		if para["type"] == Unit.Type.IFV:
			# Armored vehicle pallet
			draw_rect(Rect2(pos - Vector2(4, 2), Vector2(8, 5)), Color(0.25, 0.38, 0.22, 1.0))
			draw_rect(Rect2(pos - Vector2(4, 2), Vector2(8, 5)), Color(0.15, 0.22, 0.12, 1.0), false, 1.0)
		else:
			# Soldier figure
			draw_circle(pos + Vector2(0, -2), 1.8, Color(0.9, 0.75, 0.4, 1.0))
			draw_rect(Rect2(pos - Vector2(1.5, 0), Vector2(3, 4)), Color(0.2, 0.35, 0.2, 1.0))


# ==============================================================================
# UI Layer (HUD button and Tactical Operations Dialog)
# ==============================================================================
class AirborneAssaultUI extends CanvasLayer:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	var hud_btn: Button = null
	var dialog_panel: PanelContainer = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		layer = 16

		_create_hud_button()
		_create_dialog()

	func _create_hud_button() -> void:
		hud_btn = Button.new()
		hud_btn.text = "🪂 ВДВ\n[H / J]"
		hud_btn.custom_minimum_size = Vector2(76, 44)
		hud_btn.anchor_left = 1.0
		hud_btn.anchor_right = 1.0
		hud_btn.anchor_top = 0.0
		hud_btn.anchor_bottom = 0.0
		hud_btn.offset_left = -86.0
		hud_btn.offset_right = -10.0
		hud_btn.offset_top = 220.0
		hud_btn.offset_bottom = 264.0

		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.18, 0.13, 0.92)
		sb.border_color = Color(0.85, 0.72, 0.25, 1.0)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(4)
		sb.set_content_margin_all(2)
		hud_btn.add_theme_stylebox_override("normal", sb)

		var sb_hover = sb.duplicate()
		sb_hover.bg_color = Color(0.18, 0.28, 0.20, 0.95)
		sb_hover.border_color = Color(1.0, 0.85, 0.35, 1.0)
		hud_btn.add_theme_stylebox_override("hover", sb_hover)

		hud_btn.add_theme_font_size_override("font_size", 10)
		hud_btn.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85, 1.0))
		hud_btn.pressed.connect(_on_hud_btn_pressed)
		add_child(hud_btn)

	func _create_dialog() -> void:
		dialog_panel = PanelContainer.new()
		dialog_panel.custom_minimum_size = Vector2(430, 270)
		dialog_panel.anchor_left = 0.5
		dialog_panel.anchor_right = 0.5
		dialog_panel.anchor_top = 0.5
		dialog_panel.anchor_bottom = 0.5
		dialog_panel.offset_left = -215.0
		dialog_panel.offset_right = 215.0
		dialog_panel.offset_top = -135.0
		dialog_panel.offset_bottom = 135.0
		dialog_panel.visible = false

		var psb = StyleBoxFlat.new()
		psb.bg_color = Color(0.09, 0.13, 0.10, 0.96)
		psb.border_color = Color(0.85, 0.72, 0.25, 1.0)
		psb.set_border_width_all(2)
		psb.set_corner_radius_all(6)
		psb.content_margin_left = 16
		psb.content_margin_right = 16
		psb.content_margin_top = 12
		psb.content_margin_bottom = 14
		dialog_panel.add_theme_stylebox_override("panel", psb)

		var vb = VBoxContainer.new()
		vb.add_theme_constant_override("separation", 10)
		dialog_panel.add_child(vb)

		# Title bar
		var hb_title = HBoxContainer.new()
		var lbl_title = Label.new()
		lbl_title.text = "ВОЗДУШНЫЙ ДЕСАНТ (ВДВ)"
		lbl_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl_title.add_theme_font_size_override("font_size", 13)
		lbl_title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.25, 1.0))
		hb_title.add_child(lbl_title)

		var btn_close = Button.new()
		btn_close.text = "✕"
		btn_close.custom_minimum_size = Vector2(24, 24)
		btn_close.pressed.connect(hide_dialog)
		hb_title.add_child(btn_close)
		vb.add_child(hb_title)

		# Subtitle
		var lbl_sub = Label.new()
		lbl_sub.text = "Выберите тип воздушно-десантной операции:"
		lbl_sub.add_theme_font_size_override("font_size", 10)
		lbl_sub.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75, 1.0))
		vb.add_child(lbl_sub)

		# Row 1: Heli Assault
		var btn_heli = Button.new()
		btn_heli.text = "🚁 ВЕРТОЛЁТНЫЙ ДЕСАНТ (Ми-8) — 1 000$\nГруппа: 2 Штурмовика, 1 ПТРК, 1 FPV-дрон • Горячая клавиша: [H]"
		btn_heli.custom_minimum_size = Vector2(0, 48)
		btn_heli.pressed.connect(func(): mod_ref.start_targeting(1))
		vb.add_child(btn_heli)

		# Row 2: Plane Parachute Drop
		var btn_plane = Button.new()
		btn_plane.text = "✈️ ПАРАШЮТНЫЙ СБРОС (Ил-76) — 2 800$\nРота ВДВ: 1 БМД, 4 Штурмовика, 2 Пехоты, 1 Миномёт • Клавиша: [J]"
		btn_plane.custom_minimum_size = Vector2(0, 48)
		btn_plane.pressed.connect(func(): mod_ref.start_targeting(2))
		vb.add_child(btn_plane)

		# Footer hint
		var lbl_hint = Label.new()
		lbl_hint.text = "Требуется наличие действующего аэродрома и достаточного бюджета."
		lbl_hint.add_theme_font_size_override("font_size", 9)
		lbl_hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.6, 1.0))
		vb.add_child(lbl_hint)

		add_child(dialog_panel)

	func _on_hud_btn_pressed() -> void:
		if dialog_panel.visible:
			hide_dialog()
		else:
			show_dialog()

	func show_dialog() -> void:
		dialog_panel.visible = true
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_click")

	func hide_dialog() -> void:
		dialog_panel.visible = false

	func _unhandled_input(event: InputEvent) -> void:
		if mod_ref == null:
			return

		# Check Hotkeys
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_H:
				mod_ref.toggle_targeting(1)
				get_viewport().set_input_as_handled()
				return
			elif event.keycode == KEY_J:
				mod_ref.toggle_targeting(2)
				get_viewport().set_input_as_handled()
				return
			elif event.keycode == KEY_ESCAPE:
				if mod_ref.targeting_mode != 0:
					mod_ref.cancel_targeting()
					get_viewport().set_input_as_handled()
					return
				elif dialog_panel != null and dialog_panel.visible:
					hide_dialog()
					get_viewport().set_input_as_handled()
					return

		# Handle Mouse Targeting Click
		if mod_ref.targeting_mode != 0 and event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var wp = Vector2.ZERO
				if main_ref != null and "cam" in main_ref and main_ref.cam != null:
					wp = main_ref.cam.screen_to_world(event.position)
				elif mod_ref.overlay_node != null and is_instance_valid(mod_ref.overlay_node):
					wp = mod_ref.overlay_node.get_global_mouse_position()

				if mod_ref.try_launch_assault(mod_ref.targeting_mode, wp):
					mod_ref.targeting_mode = 0
				get_viewport().set_input_as_handled()

			elif event.button_index == MOUSE_BUTTON_RIGHT:
				mod_ref.cancel_targeting()
				get_viewport().set_input_as_handled()

	func _process(_delta: float) -> void:
		# Respect main.hud.visible
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			visible = main_ref.hud.visible
