extends RefCounted
## Модификация «ОТРК «Искандер-М» (Высокоточный тактический ракетный комплекс)»
## Автор: @CryptoAngelazaz & Community
##
## Полная нативная интеграция во вкладку «АРМИЯ» нижней панели (Tab 4).
## Добавляет постройку мобильного ракетного комплекса 9К720 «Искандер-М».
## Позволяет наносить сверхдальние высокоточные квазибаллистические удары
## ракетами 9М723 с огненным стартом, баллистической дугой и мощным проникающим взрывом.

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var world_layer: Node2D = null
var input_overlay: Node2D = null

var is_placing: bool = false
var is_targeting: bool = false
var selected_fac: Facility = null
var targeting_tel: Facility = null
var target_point: Vector2 = Vector2.INF

const TEL_COST_MONEY: int = 2200
const TEL_COST_METAL: int = 12
const RELOAD_COST_MONEY: int = 800
const RELOAD_COST_METAL: int = 4
const RELOAD_TIME: float = 16.0

const TEL_SIZE: Vector2i = Vector2i(3, 3)
const TEL_MAX_HP: float = 550.0
const TEL_REFUND: int = 1100

var active_missiles: Array = []
var active_explosions: Array = []

class IskanderInputOverlay extends Node2D:
	var mod: RefCounted
	var main: Node
	var world: Node

	func _init(p_mod: RefCounted, p_main: Node, p_world: Node) -> void:
		mod = p_mod
		main = p_main
		world = p_world
		z_index = 86

	func _unhandled_input(event: InputEvent) -> void:
		if mod == null or world == null or main == null:
			return

		var is_press: bool = false
		var is_cancel: bool = false
		var ev_pos: Vector2 = Vector2.ZERO

		if (mod.is_placing or mod.is_targeting) and (event is InputEventMouseButton or event is InputEventScreenTouch) and not event.pressed:
			get_viewport().set_input_as_handled()
			return

		if event is InputEventMouseButton:
			if event.pressed:
				if event.button_index == MOUSE_BUTTON_LEFT:
					is_press = true
					ev_pos = event.position
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					is_cancel = true
		elif event is InputEventScreenTouch and event.pressed:
			is_press = true
			ev_pos = event.position

		if event is InputEventKey and event.pressed and not event.echo:
			if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not event.alt_pressed:
				if mod.is_targeting and mod.target_point != Vector2.INF:
					mod._on_hud_action("iskander_launch_confirm")
					get_viewport().set_input_as_handled()
					return
			if event.keycode == KEY_ESCAPE:
				if mod.is_placing:
					mod.cancel_placement()
					get_viewport().set_input_as_handled()
					return
				elif mod.is_targeting:
					mod.cancel_targeting()
					get_viewport().set_input_as_handled()
					return

		if is_press:
			var wp: Vector2 = main.cam.screen_to_world(ev_pos) if main.cam != null else ev_pos
			var cell = Vector2i((wp / float(GameWorld.CELL)).floor())

			if mod.is_placing:
				mod.place_tel_at(cell)
				get_viewport().set_input_as_handled()
				return
			elif mod.is_targeting:
				mod.set_target_point(wp)
				get_viewport().set_input_as_handled()
				return

		elif is_cancel:
			if mod.is_placing:
				mod.cancel_placement()
				get_viewport().set_input_as_handled()
				return
			elif mod.is_targeting:
				mod.cancel_targeting()
				get_viewport().set_input_as_handled()
				return

func init_mod(mm: Node) -> void:
	mm_ref = mm
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[IskanderStrike] Mod initialized.")

func cleanup_mod(mm: Node) -> void:
	if main_ref != null and is_instance_valid(main_ref) and main_ref.hud != null and mm != null and mm.has_method("cleanup_mod_hud"):
		mm.call("cleanup_mod_hud", main_ref.hud, Callable(self, "_on_hud_action"), ["iskander_tel"])
	_cleanup_nodes()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[IskanderStrike] Mod cleaned up.")

func _cleanup_nodes() -> void:
	is_placing = false
	is_targeting = false
	selected_fac = null
	targeting_tel = null
	target_point = Vector2.INF
	active_missiles.clear()
	active_explosions.clear()
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_free()
		world_layer = null
	if input_overlay != null and is_instance_valid(input_overlay):
		input_overlay.queue_free()
		input_overlay = null

func _ensure_hud(main: Node, world: Node) -> void:
	if main == null or not is_instance_valid(main) or world == null or not is_instance_valid(world):
		return
	main_ref = main
	world_ref = world

	# Добавление кнопки ОТРК в нижнюю панель «АРМИЯ» (Tab 4)
	if main.hud != null and main.hud.pages.size() > 4:
		var army_grid = main.hud.pages[4] as GridContainer
		if army_grid != null and not main.hud.keys.has("iskander_tel"):
			var cell = main.hud._cell("iskander_tel", "icon_target", true)
			if main.hud.key_labels.has("iskander_tel"):
				var lbl = main.hud.key_labels["iskander_tel"] as Label
				if lbl != null:
					lbl.text = "ОТРК ИСКАНДЕР"
			army_grid.add_child(cell)
		if not main.hud.action.is_connected(_on_hud_action):
			main.hud.action.connect(_on_hud_action)

	# Слой отрисовки ракет, трассеров и взрывов
	if world_layer == null or not is_instance_valid(world_layer):
		world_layer = Node2D.new()
		world_layer.z_index = 85
		world_layer.draw.connect(_on_draw_world)
		world.add_child(world_layer)

	# Слой перехвата кликов при размещении и наведении
	if input_overlay == null or not is_instance_valid(input_overlay):
		input_overlay = IskanderInputOverlay.new(self, main, world)
		world.add_child(input_overlay)

func _on_world_started(main: Node, world: Node) -> void:
	_cleanup_nodes()
	_ensure_hud(main, world)

func _on_hud_action(action_name: String) -> void:
	match action_name:
		"iskander_tel":
			toggle_placement()
		"iskander_target":
			if selected_fac != null and is_instance_valid(selected_fac):
				start_targeting(selected_fac)
		"iskander_launch_confirm":
			if is_targeting and targeting_tel != null and is_instance_valid(targeting_tel) and target_point != Vector2.INF:
				launch_missile(targeting_tel, target_point)
				cancel_targeting()
		"iskander_reload":
			if selected_fac != null and is_instance_valid(selected_fac):
				start_reload(selected_fac)
		"iskander_demolish":
			if selected_fac != null and is_instance_valid(selected_fac):
				demolish_tel(selected_fac)
		"cancel_select", "iskander_close", "iskander_cancel_target":
			cancel_targeting()
			selected_fac = null
			if main_ref != null and "selected_fac" in main_ref:
				main_ref.selected_fac = null
			if main_ref != null and main_ref.hud != null:
				main_ref.hud.hide_ops()
		"iskander_repair":
			if selected_fac != null and is_instance_valid(selected_fac):
				var p = world_ref.player
				if p != null and p.money >= 250:
					p.money -= 250
					selected_fac.set_meta("hp", TEL_MAX_HP)
					if ClassDB.class_exists("UiKit"):
						UiKit.snd("ui_build")
					if main_ref != null and main_ref.hud != null:
						main_ref.hud.show_toast("Комплекс ОТРК «Искандер-М» полностью отремонтирован!")

func toggle_placement() -> void:
	if is_placing:
		cancel_placement()
	else:
		start_placement()

func start_placement() -> void:
	is_placing = true
	is_targeting = false
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Выберите территорию для развёртывания ОТРК «Искандер-М» (ПКМ — отмена)")

func cancel_placement() -> void:
	is_placing = false

func start_targeting(f: Facility) -> void:
	is_targeting = true
	is_placing = false
	targeting_tel = f
	target_point = Vector2.INF
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Укажите точку удара для 9М723 (ЛКМ — выбор цели, Enter — пуск)")

func cancel_targeting() -> void:
	is_targeting = false
	targeting_tel = null
	target_point = Vector2.INF

func set_target_point(pos: Vector2) -> void:
	target_point = pos
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Цель захвачена! Нажмите [ПУСК 9М723] или клавишу Enter.")

func can_place_at(cell: Vector2i) -> bool:
	if world_ref == null or world_ref.player == null or world_ref.data == null:
		return false
	var p = world_ref.player
	var d = world_ref.data
	if cell.x < 2 or cell.y < 2 or cell.x + TEL_SIZE.x >= d.w - 2 or cell.y + TEL_SIZE.y >= d.h - 2:
		return false
	for dy in range(TEL_SIZE.y):
		for dx in range(TEL_SIZE.x):
			var cx = cell.x + dx
			var cy = cell.y + dy
			if not d.inside(cx, cy):
				return false
			if d.has_flag(cx, cy, WorldData.F_OCCUPIED):
				return false
			var b = d.get_biome(cx, cy)
			if Biome.is_water(b) or b == Biome.ROCK:
				return false
			var owner_id = d.get_owner_id(cx, cy) if d.has_method("get_owner_id") else d.get_owner(cx, cy)
			if owner_id != p.id:
				return false
	return true

func place_tel_at(cell: Vector2i) -> void:
	if not can_place_at(cell):
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя разместить здесь! Требуется свободная территория своей страны.")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	var p = world_ref.player
	if p.money < TEL_COST_MONEY or p.metal < TEL_COST_METAL:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает ресурсов: требуется %d $ и %d металла!" % [TEL_COST_MONEY, TEL_COST_METAL])
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	p.money -= TEL_COST_MONEY
	p.metal -= TEL_COST_METAL
	cancel_placement()

	var f: Facility = Facility.new()
	f.id = world_ref.mil.facilities.size()
	f.kind = Facility.Kind.CIV_FACTORY
	f.country_id = p.id
	f.cell = cell
	f.size = TEL_SIZE
	f.set_meta("is_iskander_tel", true)
	f.set_meta("mod_facility", true)
	f.set_meta("hp", TEL_MAX_HP)
	f.set_meta("has_missile", true)
	f.set_meta("is_reloading", false)
	f.set_meta("reload_timer", 0.0)

	f.main_obj = world_ref.add_object("civ_factory", cell, GameWorld.KIND_BUILDING)
	f.obj_ids.append(f.main_obj)
	world_ref.mil.facilities.append(f)

	var d = world_ref.data
	for dy in range(TEL_SIZE.y):
		for dx in range(TEL_SIZE.x):
			var cx = cell.x + dx
			var cy = cell.y + dy
			world_ref.remove_tree_at(Vector2i(cx, cy))
			d.add_flag(cx, cy, WorldData.F_OCCUPIED)

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("build_done")
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("ОТРК «Искандер-М» развёрнут и готов к пуску!")

func start_reload(f: Facility) -> void:
	var p = world_ref.player
	if p == null:
		return
	if bool(f.get_meta("has_missile", false)):
		return
	if bool(f.get_meta("is_reloading", false)):
		return
	if p.money < RELOAD_COST_MONEY or p.metal < RELOAD_COST_METAL:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает ресурсов: перезарядка стоит %d $ и %d металла!" % [RELOAD_COST_MONEY, RELOAD_COST_METAL])
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	p.money -= RELOAD_COST_MONEY
	p.metal -= RELOAD_COST_METAL
	f.set_meta("is_reloading", true)
	f.set_meta("reload_timer", RELOAD_TIME)
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_click")
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("ОТРК «Искандер-М»: началась доставка ракеты 9М723...")

func launch_missile(f: Facility, target_world_pos: Vector2) -> void:
	f.set_meta("has_missile", false)
	var start_pos: Vector2 = (Vector2(f.cell) + Vector2(TEL_SIZE) * 0.5) * float(GameWorld.CELL)
	var flight_duration: float = clampf(start_pos.distance_to(target_world_pos) / 380.0, 4.5, 9.0)

	var m: Dictionary = {
		"start": start_pos,
		"target": target_world_pos,
		"t": 0.0,
		"duration": flight_duration,
		"trail": []
	}
	active_missiles.append(m)

	if ClassDB.class_exists("Sfx"):
		Sfx.play("rocket_launch", start_pos)
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("🚀 ОТРК «ИСКАНДЕР-М»: Ракета 9М723 стартовала! Подлёт через %.1f сек." % flight_duration)

func demolish_tel(f: Facility) -> void:
	var p = world_ref.player
	if p != null:
		p.money += TEL_REFUND
	var d = world_ref.data
	if d != null:
		for dy in range(f.size.y):
			for dx in range(f.size.x):
				var cx = f.cell.x + dx
				var cy = f.cell.y + dy
				d.clear_flag(cx, cy, WorldData.F_OCCUPIED)
	if f.main_obj >= 0 and world_ref.has_method("remove_object"):
		world_ref.remove_object(f.main_obj)
	world_ref.mil.facilities.erase(f)
	selected_fac = null
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Комплекс ОТРК «Искандер-М» демонтирован (+%d $)." % TEL_REFUND)

func _update_native_card(f: Facility) -> void:
	if main_ref == null or main_ref.hud == null:
		return
	var h: Variant = main_ref.hud
	var p: Variant = world_ref.player
	if p == null:
		return
	var has_missile = bool(f.get_meta("has_missile", false))
	var is_reloading = bool(f.get_meta("is_reloading", false))
	var rem_t = float(f.get_meta("reload_timer", 0.0))
	var hp = float(f.get_meta("hp", TEL_MAX_HP))

	h._card("iskander_tel_%d" % f.id, "icon_target", "ОТРК «Искандер-М» (9К720)", "Оперативно-тактический ракетный комплекс · Расчёт #%d" % f.id, false, false, true)
	var info: String = ""
	if has_missile:
		info = "СТАТУС: БОЕГОТОВ · КВАЗИБАЛЛИСТИЧЕСКАЯ РАКЕТА 9М723 НА НАПРАВЛЯЮЩЕЙ\nДАЛЬНОСТЬ: ГЛОБАЛЬНАЯ · УРОН: 650 ЕД. · ПРОЧНОСТЬ: %d/%d" % [int(hp), int(TEL_MAX_HP)]
	elif is_reloading:
		info = "СТАТУС: ТРАНСПОРТНО-ЗАРЯЖАЮЩАЯ МАШИНА ВЕДЁТ ПЕРЕЗАРЯДКУ... %s\nПРОЧНОСТЬ: %d/%d" % [h._mmss(rem_t), int(hp), int(TEL_MAX_HP)]
	else:
		info = "СТАТУС: ПУСКОВАЯ УСТАНОВКА ПУСТА · ТРЕБУЕТСЯ ПЕРЕЗАРЯДКА (%d$ · %d МЕТАЛЛА)\nПРОЧНОСТЬ: %d/%d" % [RELOAD_COST_MONEY, RELOAD_COST_METAL, int(hp), int(TEL_MAX_HP)]
	h._set_info(info, has_missile)
	h.ops_detail.text = "Высокоточный оперативно-тактический комплекс ракетных войск. Запускает квазибаллистическую ракету 9М723 по любой точке карты: проникающая боевая часть сокрушает узлы обороны, базы ПВО, мосты и бронетехнику."
	h.ops_detail.visible = true

	var acts: Array = []
	if has_missile:
		acts.append(h._act("УДАР 9М723", "icon_target", "iskander_target", true))
	elif is_reloading:
		acts.append(h._act("ЗАРЯЖАНИЕ\n%s" % h._mmss(rem_t), "icon_restore", "none", false))
	else:
		var can_reload = p.money >= RELOAD_COST_MONEY and p.metal >= RELOAD_COST_METAL
		acts.append(h._act("ЗАРЯДИТЬ\n%d $ · %d М" % [RELOAD_COST_MONEY, RELOAD_COST_METAL], "icon_restore", "iskander_reload", can_reload))

	if hp < TEL_MAX_HP:
		acts.append(h._act("РЕМОНТ\n250 $", "icon_restore", "iskander_repair", p.money >= 250))

	var dact = h._act("СНОС\n+%d $" % TEL_REFUND, "icon_close", "iskander_demolish", true)
	dact["red"] = true
	acts.append(dact)

	acts.append(h._act("ЗАКРЫТЬ", "icon_close", "iskander_close", true))
	h._fill_acts("iskander_acts_%d" % f.id, acts)

func _update_targeting_card() -> void:
	if main_ref == null or main_ref.hud == null:
		return
	var h: Variant = main_ref.hud
	h._card("iskander_targeting", "icon_target", "НАВЕДЕНИЕ ОТРК «ИСКАНДЕР-М»", "Укажите цель для ракеты 9М723 (ЛКМ/Тап — выбор, Enter/Кнопка — пуск)", false, false, true)
	if target_point == Vector2.INF:
		h._set_info("КЛИКНИТЕ ПО КАРТЕ, ЧТОБЫ ВЫБРАТЬ ЦЕЛЬ ДЛЯ КВАЗИБАЛЛИСТИЧЕСКОГО УДАРА", false)
	else:
		var cell: Vector2i = Vector2i(floori(target_point.x / float(GameWorld.CELL)), floori(target_point.y / float(GameWorld.CELL)))
		h._set_info("ЦЕЛЬ: КВАДРАТ (%d, %d) · НАЖМИТЕ [ПУСК 9М723] ИЛИ ENTER ДЛЯ СТАРТА!" % [cell.x, cell.y], true)
	h.ops_detail.visible = false

	var acts: Array = []
	var has_tgt = target_point != Vector2.INF
	acts.append(h._act("ПУСК 9М723", "icon_target", "iskander_launch_confirm", has_tgt))
	acts.append(h._act("ОТМЕНА", "icon_close", "iskander_cancel_target", true))
	h._fill_acts("iskander_target_acts", acts)

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	if main != null:
		main_ref = main
	if world != null:
		world_ref = world
	if main != null and (main.hud == null or not main.hud.keys.has("iskander_tel") or world_layer == null or input_overlay == null):
		_ensure_hud(main, world_ref if world_ref != null else world)
	var ts: float = 1.0
	if world_ref != null and "time_scale" in world_ref:
		ts = maxf(0.0, float(world_ref.time_scale))
	var sim_delta: float = delta * ts

	if is_targeting and targeting_tel != null and is_instance_valid(targeting_tel):
		_update_targeting_card()
	elif main_ref != null and "selected_fac" in main_ref and main_ref.selected_fac != null and is_instance_valid(main_ref.selected_fac):
		var f: Facility = main_ref.selected_fac as Facility
		if f != null and bool(f.get_meta("is_iskander_tel", false)):
			f.set_meta("mod_facility", true)
			selected_fac = f
			_update_native_card(f)
		else:
			if selected_fac != null and selected_fac == f:
				selected_fac = null
	else:
		selected_fac = null

	# Перезарядка комплексов
	if world_ref != null and world_ref.mil != null:
		for fac in world_ref.mil.facilities:
			if fac != null and bool(fac.get_meta("is_iskander_tel", false)):
				if bool(fac.get_meta("is_reloading", false)):
					var rem_t = float(fac.get_meta("reload_timer", 0.0)) - sim_delta
					if rem_t <= 0.0:
						fac.set_meta("is_reloading", false)
						fac.set_meta("has_missile", true)
						if ClassDB.class_exists("UiKit"):
							UiKit.snd("build_done")
						if main_ref != null and main_ref.hud != null:
							main_ref.hud.show_toast("ОТРК «Искандер-М»: Ракета 9М723 готова к пуску!")
					else:
						fac.set_meta("reload_timer", rem_t)

	# Обновление полёта ракет
	var i = active_missiles.size() - 1
	while i >= 0:
		var m: Dictionary = active_missiles[i]
		m["t"] += sim_delta
		var dur: float = float(m["duration"])
		var progress: float = clampf(float(m["t"]) / dur, 0.0, 1.0)
		var cur_pos: Vector2 = (m["start"] as Vector2).lerp(m["target"] as Vector2, progress)
		# Баллистическая высота дуги
		var arc_h: float = sin(progress * PI) * 160.0
		cur_pos.y -= arc_h
		(m["trail"] as Array).append(cur_pos)
		if (m["trail"] as Array).size() > 24:
			(m["trail"] as Array).pop_front()

		if progress >= 1.0:
			_explode_missile(m["target"] as Vector2)
			active_missiles.remove_at(i)
		i -= 1

	# Обновление взрывов
	var ei = active_explosions.size() - 1
	while ei >= 0:
		var exp: Dictionary = active_explosions[ei]
		exp["t"] += sim_delta
		if float(exp["t"]) >= float(exp["duration"]):
			active_explosions.remove_at(ei)
		ei -= 1

	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_redraw()

func _explode_missile(pos: Vector2) -> void:
	if world_ref == null or world_ref.data == null:
		return

	var cell: Vector2i = Vector2i((pos / float(GameWorld.CELL)).floor())
	var d = world_ref.data

	# Кратер и выжженная земля
	if d.inside(cell.x, cell.y):
		d.set_biome(cell.x, cell.y, Biome.CRATER)
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var cx = cell.x + dx
			var cy = cell.y + dy
			if d.inside(cx, cy) and (cx != cell.x or cy != cell.y):
				if (dx * dx + dy * dy) <= 5 and d.get_biome(cx, cy) > Biome.RIVER:
					d.set_biome(cx, cy, Biome.BURNT)

	# Урон постройкам и войскам в радиусе
	if world_ref.mil != null:
		for f in world_ref.mil.facilities:
			if f != null and is_instance_valid(f):
				var f_pos: Vector2 = (Vector2(f.cell) + Vector2(f.size) * 0.5) * float(GameWorld.CELL)
				if f_pos.distance_to(pos) <= float(GameWorld.CELL) * 4.5:
					var cur_hp = float(f.get_meta("hp", 400.0)) - 650.0
					f.set_meta("hp", cur_hp)
					if cur_hp <= 0.0:
						f.hp = 0

	# Тряска камеры и взрыв
	if main_ref != null and main_ref.cam != null and main_ref.cam.has_method("shake"):
		main_ref.cam.call("shake", 12.0)
	if ClassDB.class_exists("Sfx"):
		Sfx.play("bomb_impact", pos)

	active_explosions.append({
		"pos": pos,
		"t": 0.0,
		"duration": 2.2,
		"radius": 56.0
	})

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("💥 Удар ОТРК «Искандер-М»: Цель уничтожена, сектор поражён!")

func _on_draw_world() -> void:
	if world_layer == null:
		return

	# 1. Прицельная метка цели при наведении
	if is_targeting and target_point != Vector2.INF:
		world_layer.draw_circle(target_point, 32.0, Color(1.0, 0.2, 0.2, 0.25))
		world_layer.draw_arc(target_point, 32.0, 0, TAU, 32, Color(1.0, 0.2, 0.2, 0.9), 2.5)
		world_layer.draw_line(target_point - Vector2(40, 0), target_point + Vector2(40, 0), Color(1.0, 0.1, 0.1, 0.9), 2.0)
		world_layer.draw_line(target_point - Vector2(0, 40), target_point + Vector2(0, 40), Color(1.0, 0.1, 0.1, 0.9), 2.0)

	# 2. Отрисовка летящих ракет и огненного шлейфа
	for m in active_missiles:
		var trail: Array = m["trail"]
		for t_idx in range(trail.size() - 1):
			var alpha: float = float(t_idx) / float(trail.size())
			var c: Color = Color(1.0, 0.6, 0.15, alpha * 0.8)
			world_layer.draw_line(trail[t_idx], trail[t_idx + 1], c, 3.5 * alpha + 1.0)
		if trail.size() > 0:
			var tip: Vector2 = trail[-1]
			world_layer.draw_circle(tip, 5.0, Color(1.0, 0.95, 0.8, 1.0))
			world_layer.draw_circle(tip, 8.0, Color(1.0, 0.4, 0.1, 0.6))

	# 3. Отрисовка взрывов
	for exp in active_explosions:
		var p: Vector2 = exp["pos"]
		var prog: float = clampf(float(exp["t"]) / float(exp["duration"]), 0.0, 1.0)
		var rad: float = float(exp["radius"]) * sin(prog * PI * 0.5)
		var alpha: float = 1.0 - prog
		world_layer.draw_circle(p, rad, Color(1.0, 0.4 + 0.5 * (1.0 - prog), 0.1, alpha * 0.7))
		world_layer.draw_arc(p, rad * 1.25, 0, TAU, 32, Color(1.0, 0.8, 0.3, alpha), 3.0)
