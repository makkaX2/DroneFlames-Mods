class_name TankFactoryMod
extends RefCounted

## Мод «Завод бронетехники и танков» для DroneFlames PC Port
## Автор: @good_boy_irl
## Добавляет на карту полноценные заводы тяжёлой бронетехники.
## Позволяет строить танковые заводы, производить ОБТ (Т-90М), БМП-3,
## тяжёлые САУ 2С19 «Мста» и РСЗО «Град» с аутентичной анимацией выезда из цеха.

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var world_layer: Node2D = null
var ui_layer: CanvasLayer = null

# Список построенных заводов
var factories: Array = []
var next_factory_id: int = 1

# Режим размещения нового завода
var is_placing: bool = false
var selected_factory: Object = null

const FACTORY_COST: int = 1400
const FACTORY_SIZE: Vector2i = Vector2i(7, 5) # 7x5 клеток
const FACTORY_MAX_HP: float = 350.0

const PRODUCTS: Dictionary = {
	"tank": {
		"id": "tank",
		"name": "ОБТ Т-90М «Прорыв»",
		"short": "ОБТ Т-90М",
		"type": Unit.Type.TANK,
		"cost": 450,
		"time": 18.0,
		"desc": "Основной боевой танк. 120 HP, 125-мм гладкоствольная пушка, тяжёлая броня для прорыва укреплений.",
		"icon": "🚜"
	},
	"ifv": {
		"id": "ifv",
		"name": "БМП-3 «Курганец»",
		"short": "БМП-3",
		"type": Unit.Type.IFV,
		"cost": 320,
		"time": 14.0,
		"desc": "Боевая машина пехоты. 80 HP, автоматическая 30-мм пушка + ПТУР, высокая скорость и огневая поддержка.",
		"icon": "🛡️"
	},
	"arty": {
		"id": "arty",
		"name": "САУ 2С19 «Мста-С»",
		"short": "САУ «МСТА»",
		"type": Unit.Type.ARTY,
		"cost": 600,
		"time": 22.0,
		"desc": "Тяжёлая 152-мм самоходная гаубица. Дальность 700 м, сокрушительный навесной огонь по целям.",
		"icon": "🎯"
	},
	"mlrs": {
		"id": "mlrs",
		"name": "РСЗО «Торнадо-Г»",
		"short": "РСЗО «ГРАД»",
		"type": Unit.Type.MLRS,
		"cost": 850,
		"time": 26.0,
		"desc": "Реактивная система залпового огня. Дальность 950 м, залп 12 реактивных снарядов по площади.",
		"icon": "🚀"
	},
	"fist": {
		"id": "fist",
		"name": "Ударный танковый взвод",
		"short": "БРОНЕГРУППА",
		"type": -1, # Composite
		"cost": 1350,
		"time": 32.0,
		"desc": "Сводный бронетанковый кулак: 2 ОБТ Т-90М и 2 БМП-3. Мощная штурмовая группа выкатывается колонной.",
		"icon": "⚔️"
	}
}

func init_mod(mm: Node) -> void:
	mm_ref = mm
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[TankFactory] Mod initialized.")

func cleanup_mod(mm: Node) -> void:
	_cleanup_nodes()
	factories.clear()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[TankFactory] Mod cleaned up.")

func _cleanup_nodes() -> void:
	is_placing = false
	selected_factory = null
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
	factories.clear()

	# Create In-world overlay for building rendering, chimneys, smoke & rollout
	world_layer = TankFactoryWorldLayer.new()
	world_layer.setup(self, main, world)
	world.add_child(world_layer)

	# Create UI Layer for HUD buttons and Factory Control Card
	ui_layer = TankFactoryUILayer.new()
	ui_layer.setup(self, main, world)
	main.add_child(ui_layer)

	print("[TankFactory] World started, factory layers attached.")

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world
	_tick_factories(delta)
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_redraw()

func toggle_placement() -> void:
	if is_placing:
		cancel_placement()
	else:
		start_placement()

func start_placement() -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	var p = world_ref.player
	if p == null or not is_instance_valid(p):
		return

	if p.money < FACTORY_COST:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств! Требуется: %d$" % FACTORY_COST)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	is_placing = true
	selected_factory = null
	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.hide_card()
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Выберите ровный участок на своей территории для танкового завода (ПКМ для отмены)")
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")

func cancel_placement() -> void:
	if is_placing:
		is_placing = false
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Строительство завода отменено")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_close")

func can_place_at(nw_cell: Vector2i) -> bool:
	if world_ref == null or not is_instance_valid(world_ref):
		return false
	var p = world_ref.player
	if p == null or not is_instance_valid(p):
		return false

	var d = world_ref.data
	if d == null:
		return false

	# Bounds check
	if nw_cell.x < 2 or nw_cell.y < 2:
		return false
	if nw_cell.x + FACTORY_SIZE.x >= world_ref.cells_x - 2:
		return false
	if nw_cell.y + FACTORY_SIZE.y >= world_ref.cells_y - 2:
		return false

	# Territory & Land checks
	for y in range(nw_cell.y, nw_cell.y + FACTORY_SIZE.y):
		for x in range(nw_cell.x, nw_cell.x + FACTORY_SIZE.x):
			var c = Vector2i(x, y)
			# Must be on land
			if not world_ref.is_land(c):
				return false
			# Must be player's territory
			if world_ref.cell_owner(c) != p.id:
				return false
			# Must not be occupied by other buildings or city center
			if d.has_flag(x, y, WorldData.F_OCCUPIED):
				return false
			var b = d.get_biome(x, y)
			if Biome.is_water(b) or b == Biome.ROCK:
				return false

	# Must not overlap other tank factories
	for f in factories:
		var r = Rect2i(f.cell, f.size)
		if r.intersects(Rect2i(nw_cell, FACTORY_SIZE)):
			return false

	return true

func try_build_factory(nw_cell: Vector2i) -> bool:
	if not can_place_at(nw_cell):
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя построить завод здесь! Нужна свободная суша на вашей территории.")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	var p = world_ref.player
	if p.money < FACTORY_COST:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств в казне! Требуется: %d$" % FACTORY_COST)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	p.money -= FACTORY_COST
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_money")
	if ClassDB.class_exists("Sfx"):
		Sfx.play("concrete_thud", Vector2(nw_cell * GameWorld.CELL))

	# Mark cells occupied and set industrial terrain
	var d = world_ref.data
	for y in range(nw_cell.y, nw_cell.y + FACTORY_SIZE.y):
		for x in range(nw_cell.x, nw_cell.x + FACTORY_SIZE.x):
			world_ref.remove_tree_at(Vector2i(x, y))
			d.add_flag(x, y, WorldData.F_OCCUPIED)
			d.set_biome(x, y, Biome.INDUSTRIAL)

	var f = {
		"id": next_factory_id,
		"country_id": p.id,
		"cell": nw_cell,
		"size": FACTORY_SIZE,
		"pos_px": Vector2(nw_cell * GameWorld.CELL),
		"center_px": Vector2(nw_cell * GameWorld.CELL) + Vector2(FACTORY_SIZE * GameWorld.CELL) * 0.5,
		"gate_px": Vector2(nw_cell * GameWorld.CELL) + Vector2(float(FACTORY_SIZE.x * GameWorld.CELL) * 0.5, float(FACTORY_SIZE.y * GameWorld.CELL)),
		"hp": FACTORY_MAX_HP,
		"max_hp": FACTORY_MAX_HP,
		"state": "building", # "building", "idle", "producing", "ruined"
		"build_t": 0.0,
		"build_duration": 8.0,
		"cur_prod": "",
		"prod_t": 0.0,
		"prod_dur": 0.0,
		"units_made": 0,
		"smoke_particles": [],
		"spark_timer": 0.0,
		"rollouts": []
	}
	next_factory_id += 1
	factories.append(f)

	is_placing = false
	selected_factory = f
	if ui_layer != null and is_instance_valid(ui_layer):
		ui_layer.show_card_for(f)

	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Начато возведение Танкового Завода! Спецтехника закладывает фундамент цехов.")

	return true

func _tick_factories(dt: float) -> void:
	for f in factories:
		# 1. Scaffolding / Construction phase
		if f["state"] == "building":
			f["build_t"] += dt
			if f["build_t"] >= f["build_duration"]:
				f["state"] = "idle"
				if ClassDB.class_exists("Sfx"):
					Sfx.play("ui_build", f["center_px"])
				if main_ref != null and "hud" in main_ref and main_ref.hud != null:
					main_ref.hud.show_toast("Танковый Завод №%d введён в эксплуатацию! Конвейеры готовы к работе." % f["id"])

		# 2. Production phase
		elif f["state"] == "producing":
			f["prod_t"] += dt
			f["spark_timer"] += dt
			if f["spark_timer"] >= 0.18:
				f["spark_timer"] = 0.0

			if f["prod_t"] >= f["prod_dur"]:
				_complete_production(f)

		# 3. Ambient chimney smoke
		_tick_smoke(f, dt)

		# 4. Rollout vehicles
		_tick_rollouts(f, dt)

func _tick_smoke(f: Dictionary, dt: float) -> void:
	var c_left = f["pos_px"] + Vector2(6.0, 4.0)
	var c_right = f["pos_px"] + Vector2(18.0, 4.0)
	var is_busy = f["state"] == "producing" or f["state"] == "building"

	var spawn_rate = 0.25 if is_busy else 0.75
	if not f.has("last_smoke_t"):
		f["last_smoke_t"] = 0.0
	f["last_smoke_t"] += dt

	if f["last_smoke_t"] >= spawn_rate:
		f["last_smoke_t"] = 0.0
		var orig = c_left if randf() < 0.5 else c_right
		var puff = {
			"pos": orig + Vector2(randf_range(-1.5, 1.5), 0),
			"vel": Vector2(randf_range(1.0, 3.5), randf_range(-6.0, -10.0)),
			"r": 2.0,
			"alpha": 0.7 if is_busy else 0.45,
			"life": 2.2,
			"dark": is_busy
		}
		f["smoke_particles"].append(puff)

	for i in range(f["smoke_particles"].size() - 1, -1, -1):
		var p = f["smoke_particles"][i]
		p["life"] -= dt
		if p["life"] <= 0.0:
			f["smoke_particles"].remove_at(i)
		else:
			p["pos"] += p["vel"] * dt
			p["r"] += dt * 2.2
			p["alpha"] = maxf(0.0, p["alpha"] - dt * 0.28)

func _tick_rollouts(f: Dictionary, dt: float) -> void:
	for i in range(f["rollouts"].size() - 1, -1, -1):
		var ro = f["rollouts"][i]
		ro["t"] += dt
		var prog = clampf(ro["t"] / ro["dur"], 0.0, 1.0)
		ro["pos"] = ro["start"].lerp(ro["dest"], prog)

		if prog >= 1.0:
			# Fully exit gate, spawn live Army unit!
			_spawn_live_unit(f["country_id"], ro["type"], ro["pos"])
			f["rollouts"].remove_at(i)

func start_production(f: Dictionary, prod_key: String) -> bool:
	if f["state"] != "idle":
		return false
	if not PRODUCTS.has(prod_key):
		return false

	var prod = PRODUCTS[prod_key]
	var p = world_ref.player
	if p.money < prod["cost"]:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств для заказа: %s (%d$)" % [prod["short"], prod["cost"]])
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	p.money -= prod["cost"]
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_money")
	if ClassDB.class_exists("Sfx"):
		Sfx.play("ui_select", f["center_px"])

	f["state"] = "producing"
	f["cur_prod"] = prod_key
	f["prod_t"] = 0.0
	f["prod_dur"] = float(prod["time"])

	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Заказ запущен: %s (готовность через %d с)" % [prod["short"], int(prod["time"])])

	return true

func _complete_production(f: Dictionary) -> void:
	var prod_key = f["cur_prod"]
	f["state"] = "idle"
	f["cur_prod"] = ""
	f["units_made"] += 1

	if ClassDB.class_exists("Sfx"):
		Sfx.play("tank_cannon", f["gate_px"])

	if prod_key == "fist":
		# Spawn composite strike fist: 2 Tanks + 2 IFVs
		var types = [Unit.Type.TANK, Unit.Type.TANK, Unit.Type.IFV, Unit.Type.IFV]
		for k in types.size():
			var off_x = float(k - 1.5) * 8.0
			var start_p = f["gate_px"] + Vector2(off_x * 0.4, -4.0)
			var dest_p = f["gate_px"] + Vector2(off_x, 24.0 + float(k % 2) * 8.0)
			f["rollouts"].append({
				"type": types[k],
				"start": start_p,
				"dest": dest_p,
				"pos": start_p,
				"t": 0.0,
				"dur": 1.8 + float(k) * 0.4
			})
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Ударный танковый взвод (2 Танка + 2 БМП) вышел из ворот завода!")
	else:
		var prod = PRODUCTS[prod_key]
		var start_p = f["gate_px"] + Vector2(0, -4.0)
		var dest_p = f["gate_px"] + Vector2(randf_range(-6.0, 6.0), 22.0)
		f["rollouts"].append({
			"type": prod["type"],
			"start": start_p,
			"dest": dest_p,
			"pos": start_p,
			"t": 0.0,
			"dur": 2.0
		})
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("%s сошёл с конвейера и заступил на боевое дежурство!" % prod["short"])

func _spawn_live_unit(cid: int, ut: int, pos: Vector2) -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	if not ("army" in world_ref and world_ref.army != null):
		return

	var u = Unit.new()
	u.id = world_ref.army._next_id
	world_ref.army._next_id += 1
	u.type = ut
	u.country_id = cid

	# Connect to nearest player barracks
	var barracks: Facility = null
	if "facilities" in world_ref.mil:
		for fac in world_ref.mil.facilities:
			if fac != null and is_instance_valid(fac) and fac.kind == Facility.Kind.BARRACKS and fac.country_id == cid and world_ref.mil.alive(fac):
				barracks = fac
				break
	u.home = barracks

	u.hp = float(Army.SPEC[ut]["hp"]) if Army.SPEC.has(ut) else 100.0
	u.max_hp = u.hp
	u.pos = pos
	if world_ref.econ != null and world_ref.econ.has_method("land_point"):
		u.pos = world_ref.econ.land_point(pos, 6)
	u.heading = PI * 0.5 # Pointing south/downward out of gate
	u.update_frame()
	u.state = Unit.State.IDLE
	u.cover = 1.0
	world_ref.army.units.append(u)

	if world_ref.fx != null:
		world_ref.fx.spawn("dust_s", u.pos.round(), 5)

func repair_factory(f: Dictionary) -> bool:
	if f["hp"] >= f["max_hp"]:
		return false
	var rep_cost = int((f["max_hp"] - f["hp"]) * 1.5)
	var p = world_ref.player
	if p.money < rep_cost:
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			main_ref.hud.show_toast("Недостаточно средств для ремонта! Требуется: %d$" % rep_cost)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return false

	p.money -= rep_cost
	f["hp"] = f["max_hp"]
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_money")
	if ClassDB.class_exists("Sfx"):
		Sfx.play("ui_build", f["center_px"])
	if main_ref != null and "hud" in main_ref and main_ref.hud != null:
		main_ref.hud.show_toast("Танковый завод полностью отремонтирован!")
	return true


# ==============================================================================
# In-World Node2D (Draws Factory Complexes, Scaffolding, Smoke, Rollouts & Ghost)
# ==============================================================================
class TankFactoryWorldLayer extends Node2D:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		z_index = 45 # Same depth as heavy industrial buildings

	func _draw() -> void:
		if mod_ref == null:
			return

		# 1. Draw Built Factories
		for f in mod_ref.factories:
			_draw_factory(f)

		# 2. Draw Placement Ghost Blueprint
		if mod_ref.is_placing:
			_draw_placement_ghost()

	func _draw_factory(f: Dictionary) -> void:
		var p = f["pos_px"]
		var sz = Vector2(f["size"] * GameWorld.CELL)
		var is_building = f["state"] == "building"
		var is_producing = f["state"] == "producing"
		var hp_ratio = clampf(f["hp"] / f["max_hp"], 0.0, 1.0)

		# Ground Foundation (Reinforced concrete apron)
		var concrete_col = Color(0.38, 0.40, 0.36, 1.0)
		var dark_concrete = Color(0.24, 0.26, 0.22, 1.0)
		draw_rect(Rect2(p - Vector2(2, 2), sz + Vector2(4, 6)), dark_concrete)
		draw_rect(Rect2(p, sz + Vector2(0, 4)), concrete_col)

		# Safety perimeter striping on the front apron
		var apron_y = p.y + sz.y
		for sx in range(int(p.x), int(p.x + sz.x), 8):
			draw_line(Vector2(sx, apron_y + 1), Vector2(sx + 4, apron_y + 4), Color(0.9, 0.75, 0.2, 0.85), 1.5)

		if is_building:
			# Scaffolding & Foundation grid during construction
			var bprog = clampf(f["build_t"] / f["build_duration"], 0.0, 1.0)
			var scaffold_col = Color(0.85, 0.7, 0.25, 0.9)
			draw_rect(Rect2(p + Vector2(4, 4), sz - Vector2(8, 8)), Color(0.3, 0.32, 0.28, 0.8))
			# Scaffolding cross beams
			for x in range(int(p.x + 4), int(p.x + sz.x - 4), 10):
				draw_line(Vector2(x, p.y + 4), Vector2(x, p.y + sz.y - 4), scaffold_col, 1.2)
			for y in range(int(p.y + 4), int(p.y + sz.y - 4), 8):
				draw_line(Vector2(p.x + 4, y), Vector2(p.x + sz.x - 4, y), scaffold_col, 1.2)
			# Construction crane arm
			var crane_p = p + Vector2(sz.x * 0.75, 2.0)
			draw_line(crane_p, crane_p + Vector2(16, -14), Color(0.95, 0.8, 0.1, 1.0), 2.0)
			draw_line(crane_p + Vector2(16, -14), crane_p + Vector2(16, 2), Color(0.2, 0.2, 0.2, 0.9), 1.0)

			# Construction Progress Bar
			_draw_custom_bar(p + Vector2(sz.x * 0.5, -8.0), bprog, Color(0.3, 0.9, 0.3, 1.0), "СТРОИТЕЛЬСТВО %d%%" % int(bprog * 100))
			return

		# Main Industrial Assembly Hangar
		# Steel walls
		var wall_col = Color(0.28, 0.32, 0.26, 1.0)
		var roof_col = Color(0.48, 0.52, 0.55, 1.0)
		var roof_dark = Color(0.32, 0.36, 0.38, 1.0)
		draw_rect(Rect2(p + Vector2(2, 6), sz - Vector2(4, 8)), wall_col)

		# Sawtooth corrugated industrial roof sections
		var section_w = (sz.x - 4.0) / 3.0
		for k in 3:
			var rx = p.x + 2.0 + float(k) * section_w
			var r_poly = PackedVector2Array([
				Vector2(rx, p.y + 6.0),
				Vector2(rx + section_w * 0.85, p.y - 3.0),
				Vector2(rx + section_w, p.y + 6.0)
			])
			draw_colored_polygon(r_poly, roof_col)
			draw_polyline(r_poly, roof_dark, 1.2)

			# Skylight windows (illuminated yellow when producing)
			var win_col = Color(1.0, 0.85, 0.3, 0.95) if is_producing else Color(0.35, 0.55, 0.7, 0.75)
			var w_poly = PackedVector2Array([
				Vector2(rx + section_w * 0.85, p.y - 3.0),
				Vector2(rx + section_w, p.y + 6.0),
				Vector2(rx + section_w * 0.85, p.y + 6.0)
			])
			draw_colored_polygon(w_poly, win_col)

		# Heavy Industrial Smokestacks (Chimneys)
		var ch1 = p + Vector2(8.0, -8.0)
		var ch2 = p + Vector2(20.0, -10.0)
		# Chimney 1
		draw_rect(Rect2(ch1, Vector2(5, 14)), Color(0.55, 0.25, 0.20, 1.0)) # Red brick
		draw_rect(Rect2(ch1 + Vector2(-1, 0), Vector2(7, 3)), Color(0.2, 0.2, 0.2, 1.0))
		# Chimney 2
		draw_rect(Rect2(ch2, Vector2(6, 16)), Color(0.50, 0.22, 0.18, 1.0))
		draw_rect(Rect2(ch2 + Vector2(-1, 0), Vector2(8, 3)), Color(0.2, 0.2, 0.2, 1.0))

		# Heavy Vehicle Exit Bay / Hangar Door
		var bay_w = 26.0
		var bay_h = 14.0
		var bay_x = p.x + (sz.x - bay_w) * 0.5
		var bay_y = p.y + sz.y - bay_h + 2.0
		# Door opening
		draw_rect(Rect2(bay_x, bay_y, bay_w, bay_h), Color(0.12, 0.14, 0.10, 1.0))

		# Roll-up door slats or interior welding sparks
		if is_producing:
			# Welding flash flickering inside bay
			var flash = sin(Time.get_ticks_msec() * 0.04) > 0.0
			if flash:
				draw_circle(Vector2(bay_x + bay_w * 0.5, bay_y + bay_h * 0.6), 6.0, Color(1.0, 0.95, 0.7, 0.85))
				draw_line(Vector2(bay_x + bay_w * 0.5, bay_y + bay_h * 0.6), Vector2(bay_x + bay_w * 0.5 + 4, bay_y + bay_h * 0.6 - 3), Color(1.0, 0.8, 0.2, 0.9), 1.5)
		else:
			for sy in range(int(bay_y + 2), int(bay_y + bay_h), 3):
				draw_line(Vector2(bay_x + 1, sy), Vector2(bay_x + bay_w - 1, sy), Color(0.25, 0.28, 0.22, 1.0), 1.0)

		# Door frame with chevron caution border
		draw_rect(Rect2(bay_x, bay_y, bay_w, 2.5), Color(0.9, 0.75, 0.2, 1.0))
		draw_line(Vector2(bay_x, bay_y), Vector2(bay_x, bay_y + bay_h), Color(0.9, 0.75, 0.2, 1.0), 1.5)
		draw_line(Vector2(bay_x + bay_w, bay_y), Vector2(bay_x + bay_w, bay_y + bay_h), Color(0.9, 0.75, 0.2, 1.0), 1.5)

		# Overhead Heavy Gantry Crane over the yard
		var gantry_y = p.y + 4.0
		draw_line(Vector2(p.x - 2, gantry_y), Vector2(p.x + sz.x + 2, gantry_y), Color(0.8, 0.68, 0.25, 0.9), 2.0)
		draw_line(Vector2(p.x - 2, gantry_y), Vector2(p.x - 2, p.y + sz.y), Color(0.4, 0.42, 0.38, 1.0), 1.5)
		draw_line(Vector2(p.x + sz.x + 2, gantry_y), Vector2(p.x + sz.x + 2, p.y + sz.y), Color(0.4, 0.42, 0.38, 1.0), 1.5)

		# Pallets with tank hulls / armor plates in the side yard
		draw_rect(Rect2(p.x + 3.0, p.y + sz.y - 10.0, 8.0, 6.0), Color(0.32, 0.38, 0.30, 1.0), true)
		draw_rect(Rect2(p.x + 3.0, p.y + sz.y - 10.0, 8.0, 6.0), Color(0.18, 0.22, 0.16, 1.0), false, 1.0)

		# Selection Highlight Bracket
		if mod_ref.selected_factory == f:
			var pulse = sin(Time.get_ticks_msec() * 0.008) * 1.5
			var sel_rect = Rect2(p - Vector2(4, 4), sz + Vector2(8, 10)).grow(pulse)
			draw_rect(sel_rect, Color(1.0, 0.8, 0.2, 0.9), false, 1.5)

		# Health Bar (if damaged)
		if hp_ratio < 0.99:
			var bar_col = Color(0.2, 0.9, 0.3, 0.9) if hp_ratio > 0.5 else Color(0.9, 0.2, 0.2, 0.9)
			_draw_custom_bar(p + Vector2(sz.x * 0.5, -6.0), hp_ratio, bar_col, "ХП %d%%" % int(hp_ratio * 100))

		# Production Progress Bar
		if is_producing:
			var prog = clampf(f["prod_t"] / f["prod_dur"], 0.0, 1.0)
			var prod_info = PRODUCTS.get(f["cur_prod"], {})
			var prod_lbl = prod_info.get("short", "ПРОИЗВОДСТВО")
			_draw_custom_bar(p + Vector2(sz.x * 0.5, -12.0), prog, Color(0.95, 0.75, 0.2, 1.0), "%s (%d с)" % [prod_lbl, int(f["prod_dur"] - f["prod_t"])])

		# Chimney Smoke Puffs
		for sm in f["smoke_particles"]:
			var sm_col = Color(0.35, 0.33, 0.30, sm["alpha"]) if sm["dark"] else Color(0.75, 0.72, 0.68, sm["alpha"])
			draw_circle(sm["pos"], sm["r"], sm_col)

		# Rollout Vehicles
		for ro in f["rollouts"]:
			_draw_rollout_vehicle(ro)

	func _draw_rollout_vehicle(ro: Dictionary) -> void:
		var pos = ro["pos"]
		var ut = ro["type"]

		# Vehicle silhouette exiting the hangar
		# Shadow
		_draw_custom_ellipse(pos + Vector2(0, 1), 7.0, 4.0, Color(0.05, 0.05, 0.05, 0.4))

		# Vehicle Hull (Camouflage green)
		var hull_col = Color(0.35, 0.45, 0.30, 1.0) if ut == Unit.Type.TANK else Color(0.40, 0.48, 0.35, 1.0)
		draw_rect(Rect2(pos - Vector2(5, 7), Vector2(10, 14)), hull_col)
		draw_rect(Rect2(pos - Vector2(5, 7), Vector2(10, 14)), Color(0.18, 0.22, 0.15, 1.0), false, 1.0)

		# Tracks
		draw_line(pos + Vector2(-6, -7), pos + Vector2(-6, 7), Color(0.2, 0.2, 0.2, 1.0), 2.0)
		draw_line(pos + Vector2(6, -7), pos + Vector2(6, 7), Color(0.2, 0.2, 0.2, 1.0), 2.0)

		# Turret & Cannon pointing forward
		draw_circle(pos, 3.5, Color(0.28, 0.36, 0.24, 1.0))
		draw_line(pos, pos + Vector2(0, 9.0), Color(0.2, 0.25, 0.18, 1.0), 2.0)

		# Track dirt dust particles
		draw_circle(pos + Vector2(-5, -6), 1.5, Color(0.6, 0.55, 0.45, 0.6))
		draw_circle(pos + Vector2(5, -6), 1.5, Color(0.6, 0.55, 0.45, 0.6))

	func _draw_custom_bar(center: Vector2, frac: float, col: Color, text: String = "") -> void:
		var bw = 46.0
		var bh = 4.0
		var bx = center.x - bw * 0.5
		var by = center.y

		# Bar Background
		draw_rect(Rect2(bx - 1, by - 1, bw + 2, bh + 2), Color(0.1, 0.12, 0.1, 0.85))
		draw_rect(Rect2(bx, by, bw, bh), Color(0.2, 0.22, 0.18, 0.95))
		# Filled Bar
		draw_rect(Rect2(bx, by, bw * frac, bh), col)

		# Label
		if text != "":
			draw_string(ThemeDB.fallback_font, center + Vector2(-bw * 0.5, -2.0), text, HORIZONTAL_ALIGNMENT_CENTER, bw, 8, Color(0.95, 0.95, 0.9, 0.9))

	func _draw_placement_ghost() -> void:
		var mouse_w = get_global_mouse_position()
		var cell = Vector2i((mouse_w / float(GameWorld.CELL)).floor())
		var valid = mod_ref.can_place_at(cell)

		var pos = Vector2(cell * GameWorld.CELL)
		var sz = Vector2(FACTORY_SIZE * GameWorld.CELL)

		var outline_col = Color(0.2, 1.0, 0.3, 0.9) if valid else Color(1.0, 0.25, 0.25, 0.9)
		var fill_col = Color(0.2, 1.0, 0.3, 0.2) if valid else Color(1.0, 0.25, 0.25, 0.2)

		# Footprint grid cells
		draw_rect(Rect2(pos, sz), fill_col)
		draw_rect(Rect2(pos, sz), outline_col, false, 2.0)

		for x in range(FACTORY_SIZE.x + 1):
			var lx = pos.x + float(x * GameWorld.CELL)
			draw_line(Vector2(lx, pos.y), Vector2(lx, pos.y + sz.y), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)
		for y in range(FACTORY_SIZE.y + 1):
			var ly = pos.y + float(y * GameWorld.CELL)
			draw_line(Vector2(pos.x, ly), Vector2(pos.x + sz.x, ly), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)

		# Ghost building layout preview
		draw_rect(Rect2(pos + Vector2(2, 6), sz - Vector2(4, 8)), Color(outline_col.r, outline_col.g, outline_col.b, 0.35))
		draw_rect(Rect2(pos + Vector2(sz.x * 0.3, sz.y - 10), Vector2(sz.x * 0.4, 10)), Color(outline_col.r, outline_col.g, outline_col.b, 0.5))

		# Status hint
		var hint = "ТАНКОВЫЙ ЗАВОД (1 400$ • 2 МВт)" if valid else "НЕДОСТУПНО ДЛЯ ПОСТРОЙКИ"
		draw_string(ThemeDB.fallback_font, pos + Vector2(sz.x * 0.5 - 70.0, -8.0), hint, HORIZONTAL_ALIGNMENT_CENTER, 140, 10, outline_col)

	func _draw_custom_ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
		var pts = PackedVector2Array()
		for i in 16:
			var a = float(i) / 16.0 * TAU
			pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
		draw_colored_polygon(pts, col)


# ==============================================================================
# UI Layer (HUD Button & Native-style Facility Card)
# ==============================================================================
class TankFactoryUILayer extends CanvasLayer:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	var hud_btn: Button = null
	var card_panel: PanelContainer = null

	var lbl_title: Label = null
	var lbl_status: Label = null
	var lbl_prod: Label = null
	var prod_bar: ProgressBar = null
	var acts_box: HBoxContainer = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		layer = 16

		_create_hud_button()
		_create_card()

	func _create_hud_button() -> void:
		hud_btn = Button.new()
		hud_btn.text = "🏭 БРОНЕЗАВОД\n[B]"
		hud_btn.custom_minimum_size = Vector2(96, 44)
		hud_btn.anchor_left = 1.0
		hud_btn.anchor_right = 1.0
		hud_btn.anchor_top = 0.0
		hud_btn.anchor_bottom = 0.0
		hud_btn.offset_left = -106.0
		hud_btn.offset_right = -10.0
		hud_btn.offset_top = 270.0
		hud_btn.offset_bottom = 314.0

		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.14, 0.17, 0.13, 0.94)
		sb.border_color = Color(0.85, 0.72, 0.25, 1.0)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(4)
		sb.set_content_margin_all(2)
		hud_btn.add_theme_stylebox_override("normal", sb)

		var sb_hover = sb.duplicate()
		sb_hover.bg_color = Color(0.20, 0.26, 0.18, 0.98)
		sb_hover.border_color = Color(1.0, 0.85, 0.35, 1.0)
		hud_btn.add_theme_stylebox_override("hover", sb_hover)

		hud_btn.add_theme_font_size_override("font_size", 9)
		hud_btn.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85, 1.0))
		hud_btn.pressed.connect(_on_hud_btn_pressed)
		add_child(hud_btn)

	func _create_card() -> void:
		card_panel = PanelContainer.new()
		card_panel.custom_minimum_size = Vector2(620, 145)
		card_panel.anchor_left = 0.5
		card_panel.anchor_right = 0.5
		card_panel.anchor_top = 1.0
		card_panel.anchor_bottom = 1.0
		card_panel.offset_left = -310.0
		card_panel.offset_right = 310.0
		card_panel.offset_top = -160.0
		card_panel.offset_bottom = -15.0
		card_panel.visible = false

		var psb = StyleBoxFlat.new()
		psb.bg_color = Color(0.10, 0.13, 0.11, 0.96)
		psb.border_color = Color(0.85, 0.72, 0.25, 1.0)
		psb.set_border_width_all(2)
		psb.set_corner_radius_all(6)
		psb.content_margin_left = 14
		psb.content_margin_right = 14
		psb.content_margin_top = 10
		psb.content_margin_bottom = 10
		card_panel.add_theme_stylebox_override("panel", psb)

		var vb = VBoxContainer.new()
		vb.add_theme_constant_override("separation", 6)
		card_panel.add_child(vb)

		# Title bar
		var hb_title = HBoxContainer.new()
		lbl_title = Label.new()
		lbl_title.text = "🏭 ЗАВОД БРОНЕТЕХНИКИ И ТАНКОВ"
		lbl_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl_title.add_theme_font_size_override("font_size", 12)
		lbl_title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.25, 1.0))
		hb_title.add_child(lbl_title)

		var btn_close = Button.new()
		btn_close.text = "✕"
		btn_close.custom_minimum_size = Vector2(24, 22)
		btn_close.pressed.connect(hide_card)
		hb_title.add_child(btn_close)
		vb.add_child(hb_title)

		# Status line
		lbl_status = Label.new()
		lbl_status.text = "ПИТАНИЕ: 2 МВт (ПОДКЛЮЧЕНО) · СОСТОЯНИЕ: 100% · ВЫПУЩЕНО: 0 ЕД."
		lbl_status.add_theme_font_size_override("font_size", 9)
		lbl_status.add_theme_color_override("font_color", Color(0.75, 0.85, 0.75, 1.0))
		vb.add_child(lbl_status)

		# Production progress line
		var hb_prog = HBoxContainer.new()
		hb_prog.add_theme_constant_override("separation", 8)
		lbl_prod = Label.new()
		lbl_prod.text = "КОНВЕЙЕР: ОЖИДАНИЕ ЗАКАЗА"
		lbl_prod.add_theme_font_size_override("font_size", 9)
		lbl_prod.add_theme_color_override("font_color", Color(0.9, 0.9, 0.8, 1.0))
		hb_prog.add_child(lbl_prod)

		prod_bar = ProgressBar.new()
		prod_bar.custom_minimum_size = Vector2(220, 12)
		prod_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		prod_bar.show_percentage = false
		hb_prog.add_child(prod_bar)
		vb.add_child(hb_prog)

		# Action buttons row
		acts_box = HBoxContainer.new()
		acts_box.add_theme_constant_override("separation", 6)
		vb.add_child(acts_box)

		_build_action_buttons()
		add_child(card_panel)

	func _build_action_buttons() -> void:
		for ch in acts_box.get_children():
			ch.queue_free()

		# Product buttons
		for pkey in ["tank", "ifv", "arty", "mlrs", "fist"]:
			var pinfo = PRODUCTS[pkey]
			var btn = Button.new()
			btn.text = "%s %s\n%d$" % [pinfo["icon"], pinfo["short"], pinfo["cost"]]
			btn.custom_minimum_size = Vector2(105, 42)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.add_theme_font_size_override("font_size", 9)
			btn.tooltip_text = "%s\n%s" % [pinfo["name"], pinfo["desc"]]
			var captured_key = pkey
			btn.pressed.connect(func(): _on_product_pressed(captured_key))
			acts_box.add_child(btn)

		# Repair button
		var btn_rep = Button.new()
		btn_rep.text = "⚙️ РЕМОНТ"
		btn_rep.custom_minimum_size = Vector2(80, 42)
		btn_rep.add_theme_font_size_override("font_size", 9)
		btn_rep.pressed.connect(_on_repair_pressed)
		acts_box.add_child(btn_rep)

	func _on_hud_btn_pressed() -> void:
		mod_ref.toggle_placement()

	func _on_product_pressed(prod_key: String) -> void:
		if mod_ref.selected_factory != null:
			mod_ref.start_production(mod_ref.selected_factory, prod_key)
			_update_card_ui()

	func _on_repair_pressed() -> void:
		if mod_ref.selected_factory != null:
			mod_ref.repair_factory(mod_ref.selected_factory)
			_update_card_ui()

	func show_card_for(f: Dictionary) -> void:
		card_panel.visible = true
		_update_card_ui()
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_click")

	func hide_card() -> void:
		card_panel.visible = false
		mod_ref.selected_factory = null

	func _update_card_ui() -> void:
		if mod_ref.selected_factory == null or not card_panel.visible:
			return
		var f = mod_ref.selected_factory

		lbl_title.text = "🏭 БРОНЕТАНКОВЫЙ ЗАВОД №%d" % f["id"]
		var hp_pct = int((f["hp"] / f["max_hp"]) * 100.0)
		lbl_status.text = "ПИТАНИЕ: 2 МВт (СЕТЬ В НОРМЕ) · ЦЕЛОСТНОСТЬ: %d%% · ВЫПУЩЕНО: %d ЕД." % [hp_pct, f["units_made"]]

		if f["state"] == "building":
			var bprog = clampf(f["build_t"] / f["build_duration"], 0.0, 1.0)
			lbl_prod.text = "ВОЗВЕДЕНИЕ ЦЕХОВ: %d%%" % int(bprog * 100)
			prod_bar.value = bprog * 100.0
		elif f["state"] == "producing":
			var pinfo = PRODUCTS.get(f["cur_prod"], {})
			var rem = int(f["prod_dur"] - f["prod_t"])
			lbl_prod.text = "ПРОИЗВОДСТВО: %s (Осталось: %d с)" % [pinfo.get("short", ""), rem]
			prod_bar.value = clampf(f["prod_t"] / f["prod_dur"], 0.0, 1.0) * 100.0
		else:
			lbl_prod.text = "КОНВЕЙЕР: СВОБОДЕН (ВЫБЕРИТЕ ТЕХНИКУ ДЛЯ ЗАКАЗА)"
			prod_bar.value = 0.0

	func _unhandled_input(event: InputEvent) -> void:
		if mod_ref == null:
			return

		# Hotkeys
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_B:
				mod_ref.toggle_placement()
				get_viewport().set_input_as_handled()
				return
			elif event.keycode == KEY_ESCAPE:
				if mod_ref.is_placing:
					mod_ref.cancel_placement()
					get_viewport().set_input_as_handled()
					return
				elif card_panel.visible:
					hide_card()
					get_viewport().set_input_as_handled()
					return

		# Mouse Click Handling
		if event is InputEventMouseButton and event.pressed:
			var wp = Vector2.ZERO
			if main_ref != null and "cam" in main_ref and main_ref.cam != null:
				wp = main_ref.cam.screen_to_world(event.position)
			elif mod_ref.world_layer != null and is_instance_valid(mod_ref.world_layer):
				wp = mod_ref.world_layer.get_global_mouse_position()

			if mod_ref.is_placing:
				if event.button_index == MOUSE_BUTTON_LEFT:
					var cell = Vector2i((wp / float(GameWorld.CELL)).floor())
					mod_ref.try_build_factory(cell)
					get_viewport().set_input_as_handled()
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					mod_ref.cancel_placement()
					get_viewport().set_input_as_handled()

			else:
				# Check if clicked on an existing Tank Factory
				if event.button_index == MOUSE_BUTTON_LEFT:
					var clicked_f: Dictionary = {}
					for f in mod_ref.factories:
						var r = Rect2(f["pos_px"], Vector2(f["size"] * GameWorld.CELL))
						if r.has_point(wp):
							clicked_f = f
							break

					if not clicked_f.is_empty():
						mod_ref.selected_factory = clicked_f
						show_card_for(clicked_f)
						get_viewport().set_input_as_handled()

	func _process(_delta: float) -> void:
		if card_panel.visible:
			_update_card_ui()
		if main_ref != null and "hud" in main_ref and main_ref.hud != null:
			visible = main_ref.hud.visible
