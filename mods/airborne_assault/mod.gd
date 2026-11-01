class_name AirborneAssaultMod
extends RefCounted

## Мод «Воздушный Десант (ВДВ)» для DroneFlames PC Port
## Автор: @good_boy_irl
## Полноценная интеграция в игровой процесс:
## - Постройка «БАЗА ВДВ» через вкладку «УДАР» нижнего бара (1 200 $)
## - Карточка постройки в стиле игры с действиями [ МИ-8 1000$ ] и [ ИЛ-76 2800$ ]
## - Тактическая высадка штурмовиков на тросах с вертолёта Ми-8
## - Массовый парашютный сброс десанта и техники БМД с самолёта Ил-76

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var overlay_node: Node2D = null

# Состояние базы и режимов
var bases: Array = []
var is_placing_base: bool = false
var hover_cell: Vector2i = Vector2i(-1, -1)

# Режим целеуказания для десанта: 0 = Нет, 1 = Вертолёт Ми-8, 2 = Самолёт Ил-76
var targeting_mode: int = 0
var targeting_base: Facility = null
var target_hover_pos: Vector2 = Vector2.ZERO

var active_ops: Array = []
var last_card_key: String = ""
var last_card_cd: int = -1

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
	is_placing_base = false
	targeting_mode = 0
	targeting_base = null
	active_ops.clear()
	bases.clear()
	if overlay_node != null and is_instance_valid(overlay_node):
		overlay_node.queue_free()
		overlay_node = null

func _on_world_started(main: Node, world: Node) -> void:
	main_ref = main
	world_ref = world
	_cleanup_nodes()

	# In-world overlay node
	overlay_node = AirborneAssaultOverlay.new()
	overlay_node.setup(self, main, world)
	world.add_child(overlay_node)

	# Connect to HUD action signal
	if main != null and "hud" in main and main.hud != null:
		var hud = main.hud
		if not hud.action.is_connected(_on_hud_action):
			hud.action.connect(_on_hud_action)
		_inject_hud_button()

	print("[AirborneAssault] World started, overlay attached.")

func _inject_hud_button() -> void:
	if main_ref == null or not is_instance_valid(main_ref) or main_ref.hud == null:
		return
	var hud = main_ref.hud
	if hud.keys.has("airborne_base"):
		return

	# Add button to tab 2 (УДАР)
	if hud.pages.size() > 2:
		var grid = hud.pages[2]
		if grid != null and is_instance_valid(grid):
			var cell_box = hud._cell("airborne_base", "icon_heli", true)
			grid.add_child(cell_box)
			if hud.key_labels.has("airborne_base"):
				hud.key_labels["airborne_base"].text = "БАЗА ВДВ"

func _on_hud_action(action_name: String) -> void:
	match action_name:
		"airborne_base":
			toggle_base_placement()
		"ab_heli":
			if main_ref != null and main_ref.selected_fac != null and main_ref.selected_fac.get_meta("is_airborne_base", false):
				start_targeting(1, main_ref.selected_fac)
		"ab_plane":
			if main_ref != null and main_ref.selected_fac != null and main_ref.selected_fac.get_meta("is_airborne_base", false):
				start_targeting(2, main_ref.selected_fac)
		"ab_demolish":
			if main_ref != null and main_ref.selected_fac != null and main_ref.selected_fac.get_meta("is_airborne_base", false):
				demolish_base(main_ref.selected_fac)

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world

	# Ensure HUD button exists
	_inject_hud_button()

	# Tick cooldowns for all bases
	for i in range(bases.size() - 1, -1, -1):
		var b = bases[i]
		if b == null or not is_instance_valid(b) or not world.mil.alive(b):
			bases.remove_at(i)
			continue
		var cd = float(b.get_meta("cooldown_left", 0.0))
		if cd > 0.0:
			b.set_meta("cooldown_left", maxf(0.0, cd - delta))

	# Tick aircraft operations
	_tick_operations(delta)

	# Update bottom card if airborne base is selected
	if main.selected_fac != null and is_instance_valid(main.selected_fac) and main.selected_fac.get_meta("is_airborne_base", false):
		_update_base_card(main.selected_fac)
	else:
		last_card_key = ""

	if overlay_node != null and is_instance_valid(overlay_node):
		overlay_node.queue_redraw()

# ==============================================================================
# ПОСТРОЙКА БАЗЫ ВДВ
# ==============================================================================

func toggle_base_placement() -> void:
	if is_placing_base:
		cancel_base_placement()
	else:
		start_base_placement()

func start_base_placement() -> void:
	is_placing_base = true
	cancel_targeting()
	if main_ref != null and main_ref.has_method("_deselect"):
		main_ref._deselect()
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.set_hint("БАЗА ВДВ (1 200 $): ВЫБЕРИТЕ МЕСТО НА СВОЕЙ ЗЕМЛЕ (ТАП ДЛЯ ПОСТРОЙКИ)")
		main_ref.hud.set_key_pressed("airborne_base", true)
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")

func cancel_base_placement() -> void:
	if is_placing_base:
		is_placing_base = false
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.set_key_pressed("airborne_base", false)
			main_ref.hud.set_hint("")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_close")

func is_valid_base_cell(cell: Vector2i) -> bool:
	if world_ref == null or not is_instance_valid(world_ref) or world_ref.data == null:
		return false
	var p = world_ref.player
	if p == null:
		return false

	# 2x2 cells footprint
	for dy in range(2):
		for dx in range(2):
			var c = cell + Vector2i(dx, dy)
			if c.x < 0 or c.y < 0 or c.x >= world_ref.data.w or c.y >= world_ref.data.h:
				return false
			# Must be owned by player
			if world_ref.data.get_owner_id(c.x, c.y) != p.id:
				return false
			# Must be land
			if Biome.is_water(world_ref.data.get_biome(c.x, c.y)):
				return false

	# Check collision with other facilities
	for f in world_ref.mil.facilities:
		if f != null and is_instance_valid(f) and world_ref.mil.alive(f):
			var r = Rect2i(f.cell, f.size)
			if r.intersects(Rect2i(cell, Vector2i(2, 2))):
				return false

	return true

func try_place_base(cell: Vector2i) -> bool:
	if not is_valid_base_cell(cell):
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Строить можно только на своей сухопутной территории!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	var p = world_ref.player
	if p.money < 1200:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает денег: База ВДВ стоит 1 200 $")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# Deduct money
	p.money -= 1200

	# Create Facility
	var f = Facility.new()
	f.id = world_ref.mil.facilities.size()
	f.kind = Facility.Kind.AIRFIELD
	f.cell = cell
	f.size = Vector2i(2, 2)
	f.country_id = p.id
	f.set_meta("is_airborne_base", true)
	f.set_meta("cooldown_left", 0.0)

	world_ref.mil.facilities.append(f)
	bases.append(f)

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_buy")

	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("База ВДВ построена! Нажмите на неё для высадки десанта.")

	cancel_base_placement()

	# Select the new base immediately
	if main_ref != null:
		main_ref.selected_fac = f

	return true

func demolish_base(f: Facility) -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	var p = world_ref.player
	if p != null:
		p.money += 900

	bases.erase(f)
	world_ref.mil.facilities.erase(f)

	if main_ref != null:
		main_ref.selected_fac = null
		if "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.hide_ops()
			main_ref.hud.show_toast("База ВДВ демонтирована (+900 $)")
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_close")

# ==============================================================================
# КАРТОЧКА БАЗЫ ВДВ (ПО СТИЛЮ ИГРЫ)
# ==============================================================================

func _update_base_card(f: Facility) -> void:
	if main_ref == null or main_ref.hud == null or world_ref == null:
		return
	var hud = main_ref.hud
	var p = world_ref.player
	if p == null:
		return

	var cd = float(f.get_meta("cooldown_left", 0.0))
	var key = "airborne_base_%d" % f.id

	# Only rebuild if something changed
	if last_card_key != key or last_card_cd != int(cd):
		last_card_key = key
		last_card_cd = int(cd)

		var sub = "ГОТОВА К ОПЕРАЦИЯМ · МИ-8 И ИЛ-76"
		if cd > 0.0:
			sub = "ПОДГОТОВКА БОРТА: %d С" % int(cd)

		hud._card(key, "icon_heli", "БАЗА ВОЗДУШНОГО ДЕСАНТА (ВДВ)", sub, false, false, true)

		var acts: Array = []
		var can_heli = (p.money >= 1000 and cd <= 0.0)
		var can_plane = (p.money >= 2800 and cd <= 0.0)

		acts.append(hud._act("МИ-8\n1000", "icon_heli", "ab_heli", can_heli))
		acts.append(hud._act("ИЛ-76\n2800", "icon_bomber", "ab_plane", can_plane))
		var act_dem = hud._act("СНЕСТИ\n900", "icon_demolish" if UiKit.has("icon_demolish") else "icon_close", "ab_demolish", true)
		act_dem["red"] = true
		acts.append(act_dem)

		hud.ops_detail.visible = true
		hud.ops_detail.text = "Ми-8 (1 000 $): высадка на тросах тактической группы (2 штурмовика, 1 ПТРК, 1 FPV-дрон).\nИл-76 (2 800 $): парашютный выброс роты ВДВ (1 БМД, 4 штурмовика, 2 пехоты, 1 миномёт)."
		hud._set_info("ШТАБ ВДВ: ВЫСАДКА ДЕСАНТА В ТЫЛ ИЛИ НА ФЛАНГ ПРОТИВНИКА", false)
		hud._fill_acts(key, acts)

# ==============================================================================
# ЦЕЛЕУКАЗАНИЕ И ЗАПУСК ОПЕРАЦИЙ
# ==============================================================================

func start_targeting(mode: int, base: Facility) -> void:
	targeting_mode = mode
	targeting_base = base
	cancel_base_placement()

	var mode_name = "ВЕРТОЛЁТ МИ-8 (1 000 $)" if mode == 1 else "САМОЛЁТ ИЛ-76 (2 800 $)"
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.set_hint("%s: ВЫБЕРИТЕ МЕСТО ВЫСАДКИ ДЕСАНТА (ТАП ПО КАРТЕ, ПКМ — ОТМЕНА)" % mode_name)
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")

func cancel_targeting() -> void:
	if targeting_mode != 0:
		targeting_mode = 0
		targeting_base = null
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.set_hint("")
			main_ref.hud.show_toast("Операция отменена")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_close")

func try_launch_assault(mode: int, base: Facility, world_pos: Vector2) -> bool:
	if world_ref == null or not is_instance_valid(world_ref):
		return false
	var p = world_ref.player
	if p == null or not is_instance_valid(p):
		return false

	if base == null or not is_instance_valid(base) or not world_ref.mil.alive(base):
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("База ВДВ уничтожена или недоступна!")
		return false

	var cd = float(base.get_meta("cooldown_left", 0.0))
	if cd > 0.0:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Борт готовится к вылету (%d с)" % int(cd))
		return false

	var cost: int = 1000 if mode == 1 else 2800
	if p.money < cost:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств в казне! Требуется: %d $" % cost)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# Check land destination
	var target = world_pos
	if world_ref.econ != null and world_ref.econ.has_method("land_point"):
		target = world_ref.econ.land_point(world_pos, 8)

	if target.distance_to(world_pos) > 65.0:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя десантироваться в открытое море!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	# Deduct cost and set cooldown
	p.money -= cost
	base.set_meta("cooldown_left", 14.0)
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_buy")

	if mode == 1:
		_launch_heli_mission(p.id, base, target)
	else:
		_launch_plane_mission(p.id, base, target)

	targeting_mode = 0
	targeting_base = null
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.set_hint("")

	return true

func _launch_heli_mission(cid: int, base: Facility, target: Vector2) -> void:
	var start_pos = base.center_px()
	var op = {
		"type": "heli",
		"country_id": cid,
		"home_af": base,
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
		main_ref.hud.show_toast("Вертолёт Ми-8 с штурмовой группой вылетел с Базы ВДВ!")

func _launch_plane_mission(cid: int, base: Facility, target: Vector2) -> void:
	var dir = (target - base.center_px()).normalized()
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
		"home_af": base,
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
				p["alt"] -= dt * 14.0
				p["sway"] += dt * 3.5
				if p["alt"] <= 0.0:
					p["alt"] = 0.0
					p["landed"] = true
					_spawn_unit(op["country_id"], p["type"], p["target"], op["home_af"])

	var to_end = op["end_pos"] - op["pos"]
	if to_end.dot(op["dir"]) <= 0 and all_landed:
		active_ops.remove_at(idx)

func _spawn_unit(cid: int, utype: int, pos: Vector2, home_af: Facility) -> Unit:
	if world_ref == null or not is_instance_valid(world_ref):
		return null
	if not ("army" in world_ref) or world_ref.army == null:
		return null

	var army = world_ref.army
	var u = Unit.new()
	u.id = army.units.size()
	u.type = utype
	u.country_id = cid
	u.pos = pos
	u.state = Unit.State.IDLE
	u.home = home_af
	u.hp = 120.0 if utype == Unit.Type.ASSAULT else (220.0 if utype == Unit.Type.IFV else 100.0)
	u.max_hp = u.hp

	army.units.append(u)

	if world_ref != null and "fx" in world_ref and world_ref.fx != null:
		world_ref.fx.spawn("dust_s", pos.round(), 3)

	return u


# ==============================================================================
# ОТРИСОВКА В МИРЕ: БАЗЫ ВДВ, АНИМАЦИИ ВЫСАДКИ, ПРИЦЕЛЫ И ТЕХНИКА
# ==============================================================================

class AirborneAssaultOverlay:
	extends Node2D

	var mod_ref: AirborneAssaultMod = null
	var main_ref: Node = null
	var world_ref: Node = null

	func setup(mod: AirborneAssaultMod, main: Node, world: Node) -> void:
		mod_ref = mod
		main_ref = main
		world_ref = world
		z_index = 80

	func _unhandled_input(event: InputEvent) -> void:
		if mod_ref == null or main_ref == null or world_ref == null:
			return

		# Base placement mode input
		if mod_ref.is_placing_base:
			if event is InputEventMouseMotion:
				var m_world = main_ref.cam.screen_to_world(event.position)
				mod_ref.hover_cell = Vector2i((m_world / float(GameWorld.CELL)).floor())
				queue_redraw()
			elif event is InputEventMouseButton and event.pressed:
				if event.button_index == MOUSE_BUTTON_LEFT:
					var m_world = main_ref.cam.screen_to_world(event.position)
					var cell = Vector2i((m_world / float(GameWorld.CELL)).floor())
					mod_ref.try_place_base(cell)
					get_viewport().set_input_as_handled()
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					mod_ref.cancel_base_placement()
					get_viewport().set_input_as_handled()
			elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
				mod_ref.cancel_base_placement()
				get_viewport().set_input_as_handled()
			return

		# Airborne targeting mode input
		if mod_ref.targeting_mode != 0:
			if event is InputEventMouseMotion:
				mod_ref.target_hover_pos = main_ref.cam.screen_to_world(event.position)
				queue_redraw()
			elif event is InputEventMouseButton and event.pressed:
				if event.button_index == MOUSE_BUTTON_LEFT:
					var wp = main_ref.cam.screen_to_world(event.position)
					mod_ref.try_launch_assault(mod_ref.targeting_mode, mod_ref.targeting_base, wp)
					get_viewport().set_input_as_handled()
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					mod_ref.cancel_targeting()
					get_viewport().set_input_as_handled()
			elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
				mod_ref.cancel_targeting()
				get_viewport().set_input_as_handled()
			return

	func _draw() -> void:
		if mod_ref == null:
			return

		_draw_airborne_bases()

		if mod_ref.is_placing_base:
			_draw_base_ghost()

		if mod_ref.targeting_mode != 0:
			_draw_targeting_reticle()

		_draw_active_missions()

	func _draw_airborne_bases() -> void:
		for b in mod_ref.bases:
			if b == null or not is_instance_valid(b) or not world_ref.mil.alive(b):
				continue

			var origin = Vector2(b.cell * GameWorld.CELL)
			var center = b.center_px()
			var base_w = float(b.size.x * GameWorld.CELL)
			var base_h = float(b.size.y * GameWorld.CELL)

			# 1. Бетонный настил вертолётной площадки
			var pad_rect = Rect2(origin - Vector2(2, 2), Vector2(base_w + 4, base_h + 4))
			draw_rect(pad_rect, Color(0.24, 0.27, 0.30, 0.95), true)
			draw_rect(pad_rect, Color(0.12, 0.14, 0.16, 1.0), false, 1.0)

			# 2. Жёлто-чёрная тактическая окантовка ВПП
			draw_line(pad_rect.position, pad_rect.position + Vector2(pad_rect.size.x, 0), Color(0.95, 0.8, 0.1, 0.9), 1.0)
			draw_line(pad_rect.position + Vector2(0, pad_rect.size.y), pad_rect.position + pad_rect.size, Color(0.95, 0.8, 0.1, 0.9), 1.0)

			# 3. Белый посадочный круг с буквой 'H'
			draw_arc(center, 4.2, 0, TAU, 16, Color(1, 1, 1, 0.9), 1.0)
			draw_line(center + Vector2(-2.2, -2.5), center + Vector2(-2.2, 2.5), Color(1, 1, 1, 0.95), 1.2)
			draw_line(center + Vector2(2.2, -2.5), center + Vector2(2.2, 2.5), Color(1, 1, 1, 0.95), 1.2)
			draw_line(center + Vector2(-2.2, 0), center + Vector2(2.2, 0), Color(1, 1, 1, 0.95), 1.2)

			# 4. Командный контейнер / оперативный штаб ВДВ (в углу)
			var hq_rect = Rect2(origin + Vector2(base_w - 5, -5), Vector2(6, 4))
			draw_rect(hq_rect, Color(0.18, 0.35, 0.22, 1.0), true) # Камуфляж
			draw_rect(hq_rect, Color(0.08, 0.16, 0.10, 1.0), false, 1.0)

			# 5. Радиомачта с мигающим красным маяком
			var mast_pt = origin + Vector2(base_w + 2, -6)
			draw_line(origin + Vector2(base_w + 2, 0), mast_pt, Color(0.7, 0.72, 0.75, 1.0), 1.0)
			var flash = (sin(Time.get_ticks_msec() * 0.008) > 0.1)
			draw_circle(mast_pt, 1.4, Color(1.0, 0.1, 0.1, 1.0) if flash else Color(0.4, 0.0, 0.0, 0.5))

			# 6. Флаг ВДВ (сине-зелёный)
			var flag_base = origin + Vector2(-2, -5)
			draw_line(origin + Vector2(-2, 0), flag_base, Color(0.6, 0.6, 0.6), 1.0)
			draw_rect(Rect2(flag_base + Vector2(0, 0), Vector2(3, 1.5)), Color(0.12, 0.55, 0.95)) # Синий верх
			draw_rect(Rect2(flag_base + Vector2(0, 1.5), Vector2(3, 1.5)), Color(0.15, 0.65, 0.25)) # Зелёный низ

			# 7. Подсветка выбранной базы игроком
			if main_ref != null and main_ref.selected_fac == b:
				var sel_r = pad_rect.grow(2)
				draw_rect(sel_r, Color(1.0, 0.85, 0.2, 0.9), false, 1.2)
				# Угловые скобки
				draw_line(sel_r.position, sel_r.position + Vector2(3, 0), Color(1, 0.9, 0.3), 1.5)
				draw_line(sel_r.position, sel_r.position + Vector2(0, 3), Color(1, 0.9, 0.3), 1.5)
				draw_line(sel_r.end, sel_r.end - Vector2(3, 0), Color(1, 0.9, 0.3), 1.5)
				draw_line(sel_r.end, sel_r.end - Vector2(0, 3), Color(1, 0.9, 0.3), 1.5)

			# 8. Индикатор перезарядки (если борт на перезарядке)
			var cd = float(b.get_meta("cooldown_left", 0.0))
			if cd > 0.0:
				var pct = 1.0 - (cd / 14.0)
				draw_arc(center, 6.5, -PI*0.5, -PI*0.5 + TAU * pct, 16, Color(1, 0.4, 0.2, 0.9), 1.5)

	func _draw_base_ghost() -> void:
		var cell = mod_ref.hover_cell
		if cell.x < 0 or cell.y < 0:
			return
		var is_ok = mod_ref.is_valid_base_cell(cell)
		var origin = Vector2(cell * GameWorld.CELL)
		var size = Vector2(2 * GameWorld.CELL, 2 * GameWorld.CELL)
		var col = Color(0.2, 0.85, 0.3, 0.45) if is_ok else Color(0.9, 0.2, 0.2, 0.45)
		var border = Color(0.3, 1.0, 0.4, 0.9) if is_ok else Color(1.0, 0.3, 0.3, 0.9)

		draw_rect(Rect2(origin, size), col, true)
		draw_rect(Rect2(origin, size), border, false, 1.2)

		# Символ вертолёта в центре призрака
		var center = origin + size * 0.5
		draw_arc(center, 4.0, 0, TAU, 16, border, 1.0)
		draw_line(center + Vector2(-2, -2), center + Vector2(-2, 2), border, 1.0)
		draw_line(center + Vector2(2, -2), center + Vector2(2, 2), border, 1.0)
		draw_line(center + Vector2(-2, 0), center + Vector2(2, 0), border, 1.0)

	func _draw_targeting_reticle() -> void:
		var base = mod_ref.targeting_base
		var tgt = mod_ref.target_hover_pos
		var m = mod_ref.targeting_mode
		var col = Color(1.0, 0.55, 0.1, 0.9) if m == 1 else Color(0.2, 0.8, 1.0, 0.9)

		# Линия дальности от базы до цели
		if base != null and is_instance_valid(base):
			var b_pos = base.center_px()
			draw_dashed_line(b_pos, tgt, col * Color(1, 1, 1, 0.6), 1.0, 5.0)

		# Кольцо целеуказания
		var rad = 22.0 if m == 1 else 36.0
		draw_arc(tgt, rad, 0, TAU, 32, col, 1.2)
		draw_arc(tgt, rad * 0.4, 0, TAU, 16, col * Color(1, 1, 1, 0.7), 1.0)

		# Перекрестие
		draw_line(tgt + Vector2(-rad - 6, 0), tgt + Vector2(-rad + 4, 0), col, 1.5)
		draw_line(tgt + Vector2(rad - 4, 0), tgt + Vector2(rad + 6, 0), col, 1.5)
		draw_line(tgt + Vector2(0, -rad - 6), tgt + Vector2(0, -rad + 4), col, 1.5)
		draw_line(tgt + Vector2(0, rad - 4), tgt + Vector2(0, rad + 6), col, 1.5)

	func _draw_active_missions() -> void:
		for op in mod_ref.active_ops:
			if op["type"] == "heli":
				_draw_heli_mission(op)
			elif op["type"] == "plane":
				_draw_plane_mission(op)

	func _draw_heli_mission(op: Dictionary) -> void:
		var pos = op["pos"]
		var hd = float(op["heading"])
		var rot_f = int(op["rotor_frame"])

		# Тень
		draw_circle(pos + Vector2(0, 10), 5.5, Color(0, 0, 0, 0.28))

		# Корпус Ми-8
		var body_col = Color(0.28, 0.38, 0.30)
		draw_circle(pos, 4.8, body_col)
		var tail_dir = -Vector2.RIGHT.rotated(hd)
		draw_line(pos, pos + tail_dir * 12.0, body_col, 2.0)
		draw_line(pos + tail_dir * 12.0, pos + tail_dir * 12.0 + tail_dir.orthogonal() * 3.5, Color(0.2, 0.25, 0.2), 1.5)

		# Кабина
		var nose = pos + Vector2.RIGHT.rotated(hd) * 4.5
		draw_circle(nose, 2.2, Color(0.2, 0.45, 0.65))

		# Несущий винт (вращение)
		var blade_angles = [0.0, 2.1, 4.2]
		for a in blade_angles:
			var ba = a + float(rot_f) * 1.1
			var bp = pos + Vector2(cos(ba), sin(ba)) * 14.0
			draw_line(pos, bp, Color(0.15, 0.15, 0.15, 0.8), 1.2)

		# Фаза высадки: спусковые тросы и штурмовики
		if op["phase"] == "hover_drop":
			var drop_t = float(op["hover_time"])
			# Трос 1
			draw_line(pos + Vector2(-3, 2), op["target_pos"] + Vector2(-3, 0), Color(0.2, 0.18, 0.15, 0.9), 1.0)
			# Трос 2
			draw_line(pos + Vector2(3, 2), op["target_pos"] + Vector2(3, 0), Color(0.2, 0.18, 0.15, 0.9), 1.0)

			# Скользящие по тросам бойцы
			for k in range(2):
				var slide_pct = clampf((drop_t - float(k) * 0.4) * 1.6, 0.0, 1.0)
				if slide_pct > 0.0 and slide_pct < 1.0:
					var soldier_pos = pos.lerp(op["target_pos"], slide_pct) + Vector2(3 if k == 1 else -3, 0)
					draw_circle(soldier_pos, 1.6, Color(0.12, 0.25, 0.14)) # Боец
					draw_circle(soldier_pos + Vector2(0, -1.2), 0.9, Color(0.85, 0.75, 0.6)) # Каска

	func _draw_plane_mission(op: Dictionary) -> void:
		var pos = op["pos"]
		var dir = op["dir"] as Vector2

		# Тень
		draw_circle(pos + Vector2(0, 24), 9.0, Color(0, 0, 0, 0.22))

		# Ил-76 (фюзеляж, стреловидные крылья, 4 турбины)
		var f_col = Color(0.72, 0.75, 0.78)
		var wing_col = Color(0.65, 0.68, 0.72)

		draw_circle(pos, 6.0, f_col)
		draw_line(pos - dir * 18.0, pos + dir * 16.0, f_col, 4.0)

		# Крылья
		var ortho = dir.orthogonal()
		draw_line(pos - ortho * 28.0 - dir * 4.0, pos + ortho * 28.0 - dir * 4.0, wing_col, 3.0)

		# 4 двигателя
		for m in [-20.0, -10.0, 10.0, 20.0]:
			draw_line(pos + ortho * m - dir * 6.0, pos + ortho * m + dir * 3.0, Color(0.3, 0.32, 0.35), 2.0)

		# Хвостовое оперение Т-образное
		var tail_root = pos - dir * 17.0
		draw_line(tail_root - ortho * 10.0, tail_root + ortho * 10.0, wing_col, 2.0)

		# Парашютисты и десантируемая БМД
		if op["cargo_dropped"]:
			for p in op["paratroopers"]:
				if not p["landed"]:
					var alt = float(p["alt"])
					var sway = sin(float(p["sway"])) * 2.5
					var p_pos = p["target"] + Vector2(sway, -alt)

					var is_ifv = (p["type"] == Unit.Type.IFV)
					var chute_r = 7.0 if is_ifv else 4.0

					# Купол парашюта (бело-голубой)
					var ch_col = Color(0.95, 0.95, 0.98) if not is_ifv else Color(0.9, 0.6, 0.2)
					draw_arc(p_pos + Vector2(0, -chute_r), chute_r, -PI, 0, 16, ch_col, 1.5)
					draw_line(p_pos + Vector2(-chute_r, -chute_r), p_pos, Color(0.7, 0.7, 0.7, 0.6), 1.0)
					draw_line(p_pos + Vector2(chute_r, -chute_r), p_pos, Color(0.7, 0.7, 0.7, 0.6), 1.0)

					# Подвешенный груз (БМД или парашютист)
					if is_ifv:
						draw_rect(Rect2(p_pos + Vector2(-3, 0), Vector2(6, 4)), Color(0.25, 0.4, 0.25), true)
					else:
						draw_circle(p_pos + Vector2(0, 1), 1.4, Color(0.15, 0.3, 0.18))
