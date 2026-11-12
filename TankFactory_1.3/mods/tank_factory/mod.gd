extends RefCounted

## Мод «Завод танков и бронетехники» для DroneFlames PC Port
## Полная интеграция в оригинальный интерфейс и движок игры.
## Добавляет слот постройки во вкладку «АРМИЯ» в нижней панели,
## строит аутентичный завод с текстурами из атласа игры,
## поддерживает выбор завода на карте с открытием нативной карточки
## и производство ОБТ Т-90М, БМП-3, САУ «Мста-С» и ТОС-1А «Солнцепёк».

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var world_layer: Node2D = null
var factories: Array[Facility] = []
var scanned_count: int = -1
const Support = preload("res://game/tank_factory_support.gd")

# Режим размещения нового завода через нижнюю панель
var is_placing: bool = false
var selected_fac: Facility = null

const FACTORY_COST_MONEY: int = 1200
const FACTORY_COST_METAL: int = 25
const FACTORY_SIZE: Vector2i = Vector2i(8, 6)

const PRODUCTS: Dictionary = {
	"tank": {
		"id": "tank",
		"name": "ОБТ Т-90М «Прорыв»",
		"short": "ОБТ Т-90М",
		"type": Unit.Type.TANK,
		"cost": 450,
		"metal": 8,
		"time": 18.0,
		"desc": "Основной боевой танк. 125-мм гладкоствольная пушка, тяжелая динамическая защита для прорыва обороны.",
		"icon": "tf_icon_tank"
	},
	"ifv": {
		"id": "ifv",
		"name": "БМП-3",
		"short": "БМП-3",
		"type": Unit.Type.IFV,
		"cost": 320,
		"metal": 5,
		"time": 14.0,
		"desc": "Боевая машина пехоты. 100-мм орудие + 30-мм автоматическая пушка, десантное отделение и поддержка пехоты.",
		"icon": "tf_icon_ifv"
	},
	"arty": {
		"id": "arty",
		"name": "САУ 2С19 «Мста-С»",
		"short": "САУ «МСТА»",
		"type": Unit.Type.ARTY,
		"cost": 600,
		"metal": 10,
		"time": 22.0,
		"desc": "152-мм дивизионная самоходная гаубица. Дальнобойный навесной огонь по опорным пунктам и скоплениям врага.",
		"icon": "tf_icon_arty"
	},
	"mlrs": {
		"id": "mlrs",
		"name": "ТОС-1А «Солнцепёк»",
		"short": "ТОС-1А",
		"type": Unit.Type.MLRS,
		"cost": 750,
		"metal": 12,
		"time": 25.0,
		"desc": "Тяжелая огнеметная система. 220-мм термобарические реактивные снаряды для выжигания укреплений.",
		"icon": "tf_icon_mlrs"
	}
}

func init_mod(mm: Node) -> void:
	mm_ref = mm
	_register_product_icons()
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[TankFactory] Native mod initialized.")

func _register_product_icons() -> void:
	if mm_ref == null:
		return
	for key: String in PRODUCTS:
		var path: String = "res://assets/sprites/tank_factory_icon_%s.png" % key
		var image := Image.new()
		var texture: Texture2D
		if FileAccess.file_exists(path):
			image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
		if not image.is_empty():
			texture = ImageTexture.create_from_image(image)
		elif ResourceLoader.exists(path):
			texture = load(path) as Texture2D
		if texture != null:
			mm_ref.register_texture("tf_icon_" + key, texture)

func cleanup_mod(mm: Node) -> void:
	for key: String in PRODUCTS:
		mm.unregister_texture("tf_icon_" + key)
	if main_ref != null and is_instance_valid(main_ref) and main_ref.hud != null and mm != null and mm.has_method("cleanup_mod_hud"):
		mm.call("cleanup_mod_hud", main_ref.hud, Callable(self, "_on_hud_action"), ["tank_factory"])
	_cleanup_nodes()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[TankFactory] Mod cleaned up.")

func _cleanup_nodes() -> void:
	is_placing = false
	selected_fac = null
	factories.clear()
	scanned_count = -1
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_free()
		world_layer = null

func _ensure_hud(main: Node, world: Node) -> void:
	if main == null or not is_instance_valid(main) or world == null or not is_instance_valid(world):
		return
	main_ref = main
	world_ref = world

	# 1. Встраивание слота постройки напрямую во вкладку «АРМИЯ» (Tab 4) нижней панели
	if main.hud != null and main.hud.pages.size() > 4:
		var army_grid = main.hud.pages[4] as GridContainer
		if army_grid != null and not main.hud.keys.has("tank_factory"):
			var cell = main.hud._cell("tank_factory", "icon_tank", true)
			if main.hud.key_labels.has("tank_factory"):
				var lbl = main.hud.key_labels["tank_factory"] as Label
				if lbl != null:
					lbl.text = "БРОНЕЗАВОД"
			army_grid.add_child(cell)
			army_grid.move_child(cell, 1) # Рядом с казармами

		if not main.hud.action.is_connected(_on_hud_action):
			main.hud.action.connect(_on_hud_action)

	# 2. Слой мира для отображения сетки призрака постройки и частиц цеха
	if world_layer == null or not is_instance_valid(world_layer):
		world_layer = TankFactoryWorldLayer.new()
		world_layer.setup(self, main, world)
		world.add_child(world_layer)

func _on_world_started(main: Node, world: Node) -> void:
	_cleanup_nodes()
	_ensure_hud(main, world)
	_refresh_factories()
	print("[TankFactory] Injected tank_factory cell into Army tab and world layer attached.")

func _on_hud_action(nm: String) -> void:
	match nm:
		"tank_factory":
			if main_ref != null and main_ref.hud != null:
				main_ref.hud.show_tip(
					"Завод бронетехники",
					"Строит тяжёлую технику: Т-90М, БМП-3, САУ «Мста-С», ТОС-1А. 1200 $ · металл 25",
					""
				)
			toggle_placement()
		"tank_prod_tank":
			if selected_fac != null:
				_order_production(selected_fac, "tank")
		"tank_prod_ifv":
			if selected_fac != null:
				_order_production(selected_fac, "ifv")
		"tank_prod_arty":
			if selected_fac != null:
				_order_production(selected_fac, "arty")
		"tank_prod_mlrs":
			if selected_fac != null:
				_order_production(selected_fac, "mlrs")
		"tank_army":
			if selected_fac != null:
				var f: Facility = selected_fac
				main_ref._deselect()
				main_ref.hud.army_ux.open_army(f.id)
		"tank_repair":
			if selected_fac != null:
				_repair_factory(selected_fac)
		"tank_demolish":
			if selected_fac != null:
				_demolish_factory(selected_fac)

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world
	if main != null and (main.hud == null or not main.hud.keys.has("tank_factory") or world_layer == null):
		_ensure_hud(main, world)

	var ts: float = 1.0
	if world != null and "time_scale" in world:
		ts = maxf(0.0, float(world.time_scale))
	var sim_delta: float = delta * ts

	_refresh_factories()
	_tick_factories(sim_delta)

	# Обновление нативной карточки здания внизу экрана, если выбран наш завод
	if main != null and "selected_fac" in main and main.selected_fac != null and is_instance_valid(main.selected_fac):
		var f: Facility = main.selected_fac as Facility
		if f != null and f.has_meta("is_tank_factory") and f.get_meta("is_tank_factory"):
			selected_fac = f
			_update_native_card(f)
		else:
			selected_fac = null
	else:
		selected_fac = null

	if world_layer != null and is_instance_valid(world_layer) and is_placing:
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
	if p == null:
		return

	if p.money < FACTORY_COST_MONEY or p.metal < FACTORY_COST_METAL:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает ресурсов: 1200 $ и 25 металла!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	is_placing = true
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.set_key_pressed("tank_factory", true)
		main_ref.hud.show_toast("БРОНЕЗАВОД: Выберите место на своей территории")

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")

func cancel_placement() -> void:
	is_placing = false
	if is_instance_valid(world_layer):
		world_layer.queue_redraw()
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.set_key_pressed("tank_factory", false)

func can_place_at(cell: Vector2i) -> bool:
	if world_ref == null or not is_instance_valid(world_ref):
		return false
	var d = world_ref.data
	if d == null:
		return false

	if cell.x < 3 or cell.y < 3 or cell.x + FACTORY_SIZE.x >= d.w - 3 or cell.y + FACTORY_SIZE.y >= d.h - 3:
		return false

	var player = world_ref.player
	if player == null:
		return false

	for dy in range(FACTORY_SIZE.y):
		for dx in range(FACTORY_SIZE.x):
			var cx = cell.x + dx
			var cy = cell.y + dy

			# Проверка принадлежности территории игроку
			if d.get_owner_id(cx, cy) != player.id:
				return false

			# Проверка на сушу (не вода)
			var b = d.get_biome(cx, cy)
			if Biome.is_water(b):
				return false

			# Проверка на занятость другими строениями
			if d.has_flag(cx, cy, WorldData.F_OCCUPIED | WorldData.F_CITY | WorldData.F_ROAD | WorldData.F_BRIDGE):
				return false

	var rect := Rect2i(cell, FACTORY_SIZE)
	# Object footprints catch mines and decorations even if map flags are stale.
	for oid in range(world_ref.obj_spr.size()):
		if world_ref.obj_state[oid] == 2 or world_ref.obj_kind[oid] == GameWorld.KIND_TREE:
			continue
		if rect.intersects(world_ref.object_rect(oid)):
			return false
	for f: Facility in world_ref.mil.facilities:
		if not world_ref.mil.is_demolished(f) and not f.get_meta("tank_factory_army", false) and rect.intersects(Rect2i(f.cell, f.size)):
			return false
	return true

func place_factory_at(cell: Vector2i) -> void:
	if not can_place_at(cell):
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя построить здесь: нужна свободная суша на вашей земле")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	var p = world_ref.player
	if p.money < FACTORY_COST_MONEY or p.metal < FACTORY_COST_METAL:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает: 1200 $ и 25 металла!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	if not world_ref.spr_index.has("tank_factory"):
		return

	# Оплата постройки
	p.money -= FACTORY_COST_MONEY
	p.metal -= FACTORY_COST_METAL

	# Создание нативного Facility объекта
	var f = Facility.new()
	f.id = world_ref.mil.facilities.size()
	f.kind = Facility.Kind.BARRACKS
	f.country_id = p.id
	f.cell = cell
	f.size = FACTORY_SIZE
	f.set_meta("is_tank_factory", true)
	f.set_meta("cur_prod", "")
	f.set_meta("prod_t", 0.0)
	f.set_meta("prod_dur", 0.0)
	f.set_meta("producing", false)
	f.set_meta("chimney_t", 0.0)

	# Размещение нативного спрайта фабрики в объектах игрового мира
	f.main_obj = world_ref.add_object("tank_factory", cell, GameWorld.KIND_BUILDING)
	f.obj_ids.append(f.main_obj)
	world_ref.mil.facilities.append(f)
	Support.configure(world_ref, f)

	# Установка занятости клеток и индустриального покрытия
	var d = world_ref.data
	for dy in range(f.size.y):
		for dx in range(f.size.x):
			var cx = cell.x + dx
			var cy = cell.y + dy
			world_ref.remove_tree_at(Vector2i(cx, cy))
			d.add_flag(cx, cy, WorldData.F_OCCUPIED)
			d.set_biome(cx, cy, Biome.INDUSTRIAL)

	cancel_placement()

	# Звук и частицы постройки
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_build")
	if world_ref.fx != null:
		world_ref.fx.spawn("dust_s", Vector2(cell * GameWorld.CELL + Vector2i(18, 12)), 8)

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Завод танков и бронетехники успешно построен!")
		# Сразу выбираем построенный завод, открывая нативную карточку управления
		main_ref.selected_fac = f

func _order_production(f: Facility, prod_id: String) -> void:
	if not _owned(f) or not world_ref.mil.alive(f) or f.restore_t > 0.0 or bool(f.get_meta("producing", false)) or not PRODUCTS.has(prod_id):
		return
	if not Support.has_room(world_ref, f):
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Армия бронезавода заполнена: максимум 12 машин")
		return
	var prod = PRODUCTS[prod_id]
	var p = world_ref.player
	var cost_m = int(prod["cost"])
	var cost_met = int(prod["metal"])

	if p.money < cost_m or p.metal < cost_met:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает ресурсов: требуется %d $ и %d металла!" % [cost_m, cost_met])
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	# Списание ресурсов и запуск цикла производства
	p.money -= cost_m
	p.metal -= cost_met

	f.set_meta("producing", true)
	f.producing = true
	f.prod_t = 0.0
	f.set_meta("cur_prod", prod_id)
	f.set_meta("prod_t", 0.0)
	f.set_meta("prod_dur", float(prod["time"]))

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_build")

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Завод заложил производство: %s" % prod["name"])

func _owned(f: Facility) -> bool:
	return world_ref != null and world_ref.player != null and f != null and f.kind == Facility.Kind.BARRACKS and f.get_meta("is_tank_factory", false) and f.country_id == world_ref.player.id and f.id >= 0 and f.id < world_ref.mil.facilities.size() and world_ref.mil.facilities[f.id] == f

func _repair_factory(f: Facility) -> void:
	if _owned(f):
		world_ref.mil.restore(f, world_ref.player)

func _demolish_factory(f: Facility) -> void:
	if not _owned(f):
		return
	var why: String = world_ref.mil.demolish(world_ref.player, f)
	if why != "":
		main_ref.hud.show_toast(why)
		return
	f.set_meta("producing", false)
	f.set_meta("cur_prod", "")
	factories.erase(f)
	selected_fac = null
	main_ref.call("_deselect")

func _refresh_factories() -> void:
	if world_ref == null or world_ref.mil == null:
		return
	if scanned_count == world_ref.mil.facilities.size():
		return
	factories.clear()
	for f: Facility in world_ref.mil.facilities:
		if not f.get_meta("is_tank_factory", false) or world_ref.mil.is_demolished(f):
			continue
		if f.kind == Facility.Kind.CIV_FACTORY:
			f.set_meta("legacy_footprint", true)
			if f.main_obj >= 0:
				world_ref.set_obj_frame(f.main_obj, "tank_factory_legacy", 0)
		Support.configure(world_ref, f)
		f.producing = bool(f.get_meta("producing", false))
		f.prod_t = float(f.get_meta("prod_t", 0.0))
		factories.append(f)
	Support.migrate(world_ref)
	scanned_count = world_ref.mil.facilities.size()

func _tick_factories(delta: float) -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	if not ("mil" in world_ref and world_ref.mil != null):
		return

	for f: Facility in factories:
		if world_ref.mil.is_demolished(f):
			continue

		if not world_ref.mil.alive(f):
			# A destroyed order is lost; repairing cannot resume or duplicate it.
			f.set_meta("producing", false)
			f.set_meta("cur_prod", "")
			f.set_meta("prod_t", 0.0)
			f.producing = false
			f.prod_t = 0.0
			continue
		if delta <= 0.0:
			continue
		var is_prod = bool(f.get_meta("producing", false))
		if is_prod:
			# Дым из трубы во время производства
			var ct = float(f.get_meta("chimney_t", 0.0)) + delta
			if ct >= 0.35:
				ct = 0.0
				var chimney_pos = Vector2(f.cell * GameWorld.CELL) + Vector2(24, 4)
				if world_ref.fx != null:
					world_ref.fx.spawn("smoke_puff", chimney_pos, 4)
			f.set_meta("chimney_t", ct)

			# Прогресс сборки техники
			var pt = float(f.get_meta("prod_t", 0.0)) + delta
			var dur = float(f.get_meta("prod_dur", 1.0))
			f.set_meta("prod_t", pt)
			f.prod_t = pt

			if pt >= dur and Support.has_room(world_ref, f):
				# Производство завершено!
				f.set_meta("producing", false)
				f.producing = false
				f.flash_until = world_ref.game_time + 0.5
				var prod_id = String(f.get_meta("cur_prod", "tank"))
				f.set_meta("cur_prod", "")
				_spawn_produced_unit(f, prod_id)

func _spawn_produced_unit(f: Facility, prod_id: String) -> void:
	if world_ref == null or not is_instance_valid(world_ref):
		return
	if not ("army" in world_ref and world_ref.army != null):
		return

	var prod = PRODUCTS.get(prod_id, PRODUCTS["tank"])
	var utype: int = int(prod["type"])

	# Use the game's unit initialization, formation slots and stable army IDs.
	if not Support.has_room(world_ref, f):
		return
	var u: Unit = world_ref.army._spawn(f, utype)
	world_ref.changed.emit()

	if world_ref.fx != null:
		world_ref.fx.spawn("dust_s", u.pos.round(), 8)

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_build")

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Бронезавод выпустил: %s!" % prod["name"])

func _update_native_card(f: Facility) -> void:
	if main_ref == null or main_ref.hud == null:
		return

	var p = world_ref.player
	var is_producing = bool(f.get_meta("producing", false))
	var has_room: bool = Support.has_room(world_ref, f)
	var cur_prod = String(f.get_meta("cur_prod", ""))
	var prod_t = float(f.get_meta("prod_t", 0.0))
	var prod_dur = float(f.get_meta("prod_dur", 1.0))
	var hp = 1.0 if world_ref.mil.alive(f) else 0.0
	var max_hp = 1.0

	# Открытие нативной карточки через Hud._card
	main_ref.hud._card(
		"tank_fac_%d" % f.id,
		"icon_tank",
		"ЗАВОД БРОНЕТЕХНИКИ",
		"ПРОИЗВОДСТВО ТЯЖЁЛОЙ БРОНЕТЕХНИКИ И РЕМОНТ",
		false,
		true,
		true
	)

	var acts: Array = []

	# 1. ОБТ Т-90М
	var c_tank = int(PRODUCTS["tank"]["cost"])
	var m_tank = int(PRODUCTS["tank"]["metal"])
	acts.append(main_ref.hud._act(
		"ОБТ Т-90\n%d $" % c_tank,
		"tf_icon_tank",
		"tank_prod_tank",
		p.money >= c_tank and p.metal >= m_tank and not is_producing and has_room and _owned(f) and world_ref.mil.alive(f),
		1 if cur_prod == "tank" else 0
	))

	# 2. БМП-3
	var c_ifv = int(PRODUCTS["ifv"]["cost"])
	var m_ifv = int(PRODUCTS["ifv"]["metal"])
	acts.append(main_ref.hud._act(
		"БМП-3\n%d $" % c_ifv,
		"tf_icon_ifv",
		"tank_prod_ifv",
		p.money >= c_ifv and p.metal >= m_ifv and not is_producing and has_room and _owned(f) and world_ref.mil.alive(f),
		1 if cur_prod == "ifv" else 0
	))

	# 3. САУ «Мста-С»
	var c_arty = int(PRODUCTS["arty"]["cost"])
	var m_arty = int(PRODUCTS["arty"]["metal"])
	acts.append(main_ref.hud._act(
		"САУ МСТА\n%d $" % c_arty,
		"tf_icon_arty",
		"tank_prod_arty",
		p.money >= c_arty and p.metal >= m_arty and not is_producing and has_room and _owned(f) and world_ref.mil.alive(f),
		1 if cur_prod == "arty" else 0
	))

	# 4. ТОС-1А «Солнцепёк»
	var c_mlrs = int(PRODUCTS["mlrs"]["cost"])
	var m_mlrs = int(PRODUCTS["mlrs"]["metal"])
	acts.append(main_ref.hud._act(
		"ТОС-1А\n%d $" % c_mlrs,
		"tf_icon_mlrs",
		"tank_prod_mlrs",
		p.money >= c_mlrs and p.metal >= m_mlrs and not is_producing and has_room and _owned(f) and world_ref.mil.alive(f),
		1 if cur_prod == "mlrs" else 0
	))

	acts.append(main_ref.hud._act("АРМИЯ\n%d/12" % Support.unit_count(world_ref, f), "icon_barracks", "tank_army", Support.unit_count(world_ref, f) > 0 and _owned(f)))

	# 5. Ремонт завода
	var can_rep = _owned(f) and world_ref.mil.can_restore(f) and world_ref.mil.restore_why(f, p) == ""
	acts.append(main_ref.hud._act(
		"РЕМОНТ\n%d $" % world_ref.mil.restore_cost(f),
		"icon_restore",
		"tank_repair",
		can_rep
	))

	# 6. Снос
	var dact = main_ref.hud._act("СНОС\n+%d $" % world_ref.mil.demolish_refund(f), "icon_close", "tank_demolish", _owned(f) and world_ref.mil.demolish_why(p, f) == "")
	dact["red"] = true
	acts.append(dact)

	var status_str = "ГОТОВ К ПРОИЗВОДСТВУ · ЗДАНИЕ ИСПРАВНО"
	if is_producing:
		var prod_info = PRODUCTS.get(cur_prod, {})
		var pname = prod_info.get("short", cur_prod.to_upper())
		var left_s = maxf(0.0, prod_dur - prod_t)
		status_str = "ПРОИЗВОДИТСЯ: %s · ГОТОВО ЧЕРЕЗ %s" % [pname, main_ref.hud._mmss(left_s)]

	if f.restore_t > 0.0:
		status_str = "ВОССТАНОВЛЕНИЕ · " + main_ref.hud._mmss(f.restore_t)
	elif hp <= 0.0:
		status_str = "ЗАВОД РАЗРУШЕН · ЗАКАЗ ПОТЕРЯН"
	main_ref.hud._set_bar(0, prod_t / maxf(0.001, prod_dur) if is_producing else 0.0, "icon_tank")
	main_ref.hud._set_bar(1, hp / max_hp, "icon_restore")
	main_ref.hud._set_info(status_str, hp <= 0.0)
	main_ref.hud.ops_detail.text = "Бронезавод — база армии №%d · %d/12 машин. Закажите технику; прогресс показан над зданием и в карточке. Кнопка АРМИЯ открывает команды и группы. Пополнение — только по заказам этого завода." % [f.army_no, Support.unit_count(world_ref, f)]
	main_ref.hud.ops_detail.visible = true
	main_ref.hud._fill_acts("tank_fac_%d" % f.id, acts)


# ==============================================================================
# Слой игрового мира (Отрисовка призрака постройки по сетке)
# ==============================================================================
class TankFactoryWorldLayer extends Node2D:
	var mod_ref: RefCounted = null
	var main_ref: Node = null
	var world_ref: Node = null

	func setup(m: RefCounted, main: Node, world: Node) -> void:
		mod_ref = m
		main_ref = main
		world_ref = world
		z_index = 65

	func _unhandled_input(event: InputEvent) -> void:
		if mod_ref == null or not mod_ref.is_placing:
			return

		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var mpos = main_ref.cam.screen_to_world(event.position)
				var cell = Vector2i((mpos / float(GameWorld.CELL)).floor())
				mod_ref.place_factory_at(cell)
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				mod_ref.cancel_placement()
				get_viewport().set_input_as_handled()

	func _draw() -> void:
		if mod_ref == null or not mod_ref.is_placing or main_ref == null:
			return

		var mouse_w = main_ref.cam.screen_to_world(get_viewport().get_mouse_position())
		var cell = Vector2i((mouse_w / float(GameWorld.CELL)).floor())
		var valid = mod_ref.can_place_at(cell)

		var pos = Vector2(cell * GameWorld.CELL)
		var sz = Vector2(FACTORY_SIZE * GameWorld.CELL)

		var outline_col = Color(0.2, 1.0, 0.3, 0.9) if valid else Color(1.0, 0.25, 0.25, 0.9)
		var fill_col = Color(0.2, 1.0, 0.3, 0.2) if valid else Color(1.0, 0.25, 0.25, 0.2)

		# Сетка ячеек фундамента
		draw_rect(Rect2(pos, sz), fill_col)
		draw_rect(Rect2(pos, sz), outline_col, false, 2.0)

		for x in range(FACTORY_SIZE.x + 1):
			var lx = pos.x + float(x * GameWorld.CELL)
			draw_line(Vector2(lx, pos.y), Vector2(lx, pos.y + sz.y), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)
		for y in range(FACTORY_SIZE.y + 1):
			var ly = pos.y + float(y * GameWorld.CELL)
			draw_line(Vector2(pos.x, ly), Vector2(pos.x + sz.x, ly), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)

		# Контур корпуса завода
		draw_rect(Rect2(pos + Vector2(2, 4), sz - Vector2(4, 6)), Color(outline_col.r, outline_col.g, outline_col.b, 0.35))
