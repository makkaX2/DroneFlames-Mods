extends RefCounted

## Мод «Ядерный арсенал (МБР и Шахты)» для DroneFlames PC Port
## Полная аутентичная интеграция в интерфейс, меню и движок игры.
## Добавляет шахтный комплекс МБР во вкладку «АРМИЯ» нижней панели.
## Позволяет обогащать уран и собирать термоядерные боеголовки.
## Производит пуск межконтинентальной баллистической ракеты с глобальным радиусом поражения,
## кинематографичной ослепляющей вспышкой, гигантским ядерным грибом и выжиганием радиоактивной пустоши.

var mm_ref: Node = null
var main_ref: Node = null
var world_ref: Node = null

var world_layer: Node2D = null
var flash_layer: CanvasLayer = null
var flash_rect: ColorRect = null
var ctl_layer: CanvasLayer = null
var ctl_panel: PanelContainer = null
var ctl_btns: Dictionary = {}

var is_placing: bool = false
var is_targeting: bool = false
var selected_fac: Facility = null
var targeting_silo: Facility = null
var target_point: Vector2 = Vector2.INF

const SILO_COST_MONEY: int = 3500
const SILO_COST_URANIUM: int = 10
const WARHEAD_COST_MONEY: int = 1500
const WARHEAD_COST_URANIUM: int = 8
const WARHEAD_TIME: float = 24.0

const SILO_SIZE: Vector2i = Vector2i(4, 4)
const SILO_MAX_HP: float = 650.0
const SILO_REFUND: int = 1750
const SILO_REPAIR_COST: int = 400

var active_missiles: Array = []
var active_explosions: Array = []

func init_mod(mm: Node) -> void:
	mm_ref = mm
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[NuclearStrike] Native mod initialized.")

func cleanup_mod(mm: Node) -> void:
	if main_ref != null and is_instance_valid(main_ref) and main_ref.hud != null and mm != null and mm.has_method("cleanup_mod_hud"):
		mm.call("cleanup_mod_hud", main_ref.hud, Callable(self, "_on_hud_action"), ["nuclear_silo"])
	_cleanup_nodes()
	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))
	print("[NuclearStrike] Mod cleaned up.")

func _cleanup_nodes() -> void:
	is_placing = false
	is_targeting = false
	selected_fac = null
	targeting_silo = null
	target_point = Vector2.INF
	active_missiles.clear()
	active_explosions.clear()
	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_free()
		world_layer = null
	if flash_layer != null and is_instance_valid(flash_layer):
		flash_layer.queue_free()
		flash_layer = null
	if ctl_layer != null and is_instance_valid(ctl_layer):
		ctl_layer.queue_free()
	ctl_layer = null
	ctl_panel = null
	ctl_btns.clear()

func _on_world_started(main: Node, world: Node) -> void:
	main_ref = main
	world_ref = world
	_cleanup_nodes()

	# 1. Встраивание слота постройки МБР во вкладку «АРМИЯ» (Tab 4) нижней панели
	if main.hud != null:
		if main.hud.pages.size() > 4:
			var army_grid = main.hud.pages[4] as GridContainer
			if army_grid != null and not main.hud.keys.has("nuclear_silo"):
				var cell = main.hud._cell("nuclear_silo", "icon_m_ballistic", true)
				if main.hud.key_labels.has("nuclear_silo"):
					var lbl = main.hud.key_labels["nuclear_silo"] as Label
					if lbl != null:
						lbl.text = "ШАХТА\nМБР"
				army_grid.add_child(cell)
				army_grid.move_child(cell, 2)

		if not main.hud.action.is_connected(_on_hud_action):
			main.hud.action.connect(_on_hud_action)

	# 2. Слой мира для визуализации призрака, шахты, полёта МБР и ядерных грибов
	world_layer = NuclearWorldLayer.new()
	world_layer.setup(self, main, world)
	world.add_child(world_layer)

	# 3. CanvasLayer для кинематографичной ослепляющей ядерной вспышки
	flash_layer = CanvasLayer.new()
	flash_layer.layer = 120
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 0.96, 0.75, 0.0)
	flash_layer.add_child(flash_rect)
	main.add_child(flash_layer)
	_build_controls(main)

	print("[NuclearStrike] Injected nuclear_silo cell into Army tab and world layers created.")

func _on_hud_action(nm: String) -> void:
	match nm:
		"nuclear_silo":
			if main_ref != null and main_ref.hud != null:
				main_ref.hud.show_tip(
					"Шахтный комплекс МБР",
					"Стратегический ракетный комплекс шахтного базирования. Требует 3500 $ и 10 урана (с урановых шахт). Снаряжается термоядерными МБР.",
					""
				)
			toggle_placement()
		"nuke_craft":
			if selected_fac != null:
				_order_warhead(selected_fac)
		"nuke_target":
			if selected_fac != null:
				_start_targeting(selected_fac)
		"nuke_target_reset":
			target_point = Vector2.INF
			if main_ref != null and main_ref.hud != null:
				main_ref.hud.show_toast("Точка ядерного удара сброшена. Укажите новый квадрат на карте.")
			if ClassDB.class_exists("UiKit"):
				UiKit.snd("ui_select")
		"nuke_launch_confirm":
			if target_point != Vector2.INF and targeting_silo != null:
				launch_strike(target_point)
			elif main_ref != null and main_ref.hud != null:
				main_ref.hud.show_toast("Сначала укажите точку удара на карте!")
				if ClassDB.class_exists("UiKit"):
					UiKit.snd("ui_error")
		"nuke_cancel_target":
			_cancel_targeting()
		"nuke_repair":
			if selected_fac != null:
				_repair_silo(selected_fac)
		"nuke_demolish":
			if selected_fac != null:
				_demolish_silo(selected_fac)
		"nuke_close":
			selected_fac = null
			if main_ref != null and "selected_fac" in main_ref:
				main_ref.selected_fac = null
			if main_ref != null and main_ref.hud != null:
				main_ref.hud.hide_ops()

func _is_silo(f: Facility) -> bool:
	if f == null:
		return false
	if f.army_build == "nuclear_silo" or f.lower_sprite == "nuclear_silo" or bool(f.get_meta("is_nuclear_silo", false)):
		# ГАРАНТИЯ: Шахта — это стационарный железобетонный комплекс (CIV_FACTORY), ни в коем случае НЕ TEL!
		# Блокируем любые попытки движка двигать шахту.
		f.kind = Facility.Kind.CIV_FACTORY
		f.moving = false
		f.mdest = Vector2.ZERO
		f.mpos = f.center_px()
		if not f.has_meta("is_nuclear_silo"):
			f.set_meta("is_nuclear_silo", true)
			f.set_meta("hp", f.hp if f.hp > 0.0 else SILO_MAX_HP)
			f.set_meta("max_hp", SILO_MAX_HP)
			f.set_meta("has_warhead", f.missiles > 0)
			f.set_meta("producing", f.producing)
			f.set_meta("prod_t", f.prod_t)
		return true
	return false

func _on_match_tick(main: Node, world: Node, delta: float) -> void:
	main_ref = main
	world_ref = world
	_tick_silos(delta)
	_tick_missiles(delta)
	_tick_explosions(delta)

	# 1. Если активен режим наведения термоядерного удара — отображаем специальную карточку прицеливания
	if is_targeting and targeting_silo != null and is_instance_valid(targeting_silo):
		_update_targeting_card()
	# 2. Иначе обновляем карточку выбранной шахты
	elif main != null and "selected_fac" in main and main.selected_fac != null and is_instance_valid(main.selected_fac):
		var f: Facility = main.selected_fac as Facility
		if _is_silo(f):
			selected_fac = f
			_update_native_card(f)
		else:
			if selected_fac != null and selected_fac == f:
				selected_fac = null
	else:
		selected_fac = null

	_update_controls()

	if world_layer != null and is_instance_valid(world_layer):
		world_layer.queue_redraw()

# Собственные кнопки мода: создаются один раз и не пересоздаются каждый кадр,
# поэтому клик (нажатие + отпускание) всегда попадает в одну и ту же кнопку.
func _build_controls(main: Node) -> void:
	ctl_layer = CanvasLayer.new()
	ctl_layer.layer = 119
	ctl_panel = PanelContainer.new()
	ctl_panel.visible = false
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	ctl_panel.add_child(row)
	var defs: Array = [
		["target", "ЯДЕРНЫЙ УДАР", "nuke_target"],
		["launch", "ПУСК МБР (Enter)", "nuke_launch_confirm"],
		["reset", "СБРОС ЦЕЛИ", "nuke_target_reset"],
		["cancel", "ОТМЕНА", "nuke_cancel_target"],
	]
	for d: Array in defs:
		var b: Button = Button.new()
		b.text = String(d[1])
		b.custom_minimum_size = Vector2(150, 42)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_hud_action.bind(String(d[2])))
		row.add_child(b)
		ctl_btns[String(d[0])] = b
	ctl_layer.add_child(ctl_panel)
	main.add_child(ctl_layer)

func _update_controls() -> void:
	if ctl_panel == null or not is_instance_valid(ctl_panel):
		return
	var tgt_mode: bool = is_targeting and targeting_silo != null and is_instance_valid(targeting_silo)
	var armed: bool = (not tgt_mode) and selected_fac != null and is_instance_valid(selected_fac) and bool(selected_fac.get_meta("has_warhead", false))
	var has_tgt: bool = target_point != Vector2.INF
	ctl_panel.visible = tgt_mode or armed
	(ctl_btns["target"] as Button).visible = armed
	(ctl_btns["launch"] as Button).visible = tgt_mode
	(ctl_btns["launch"] as Button).disabled = not has_tgt
	(ctl_btns["reset"] as Button).visible = tgt_mode and has_tgt
	(ctl_btns["cancel"] as Button).visible = tgt_mode
	if not ctl_panel.visible:
		return
	var vp: Vector2 = ctl_panel.get_viewport().get_visible_rect().size
	var hy: float = vp.y
	if main_ref != null and main_ref.hud != null and main_ref.hud.get("holder") != null:
		hy = float(main_ref.hud.holder.position.y)
	ctl_panel.position = Vector2(floorf((vp.x - ctl_panel.size.x) * 0.5), hy - ctl_panel.size.y - 12.0)

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

	if p.money < SILO_COST_MONEY or p.uranium < SILO_COST_URANIUM:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает ресурсов: требуется 3500 $ и 10 Урана (добывается на урановых шахтах)!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	is_placing = true
	is_targeting = false
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.set_key_pressed("nuclear_silo", true)
		main_ref.hud.show_toast("ШАХТА МБР: Выберите безопасное место на своей территории (ЛКМ/Тап — построить, ПКМ — отмена)")

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")

func cancel_placement() -> void:
	is_placing = false
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.set_key_pressed("nuclear_silo", false)

func place_why(cell: Vector2i) -> String:
	if world_ref == null or not is_instance_valid(world_ref):
		return "Мир недоступен"
	var d = world_ref.data
	if d == null:
		return "Данные карты недоступны"

	if cell.x < 2 or cell.y < 2 or cell.x + SILO_SIZE.x >= d.w - 2 or cell.y + SILO_SIZE.y >= d.h - 2:
		return "Не помещается у края карты"

	var player = world_ref.player
	if player == null:
		return "Игрок не найден"

	for dy in range(SILO_SIZE.y):
		for dx in range(SILO_SIZE.x):
			var cx = cell.x + dx
			var cy = cell.y + dy
			if not d.inside(cx, cy):
				return "За пределами карты"
			
			var owner_id = d.get_owner_id(cx, cy) if d.has_method("get_owner_id") else d.get_owner(cx, cy)
			if owner_id != player.id:
				return "Стройте только на своей территории"

			var b = d.get_biome(cx, cy)
			if Biome.is_water(b):
				return "Нельзя строить на воде"

			var fl = d.flags[cy * d.w + cx]
			if (fl & (WorldData.F_CITY | WorldData.F_BRIDGE)) != 0:
				return "Место занято: городские постройки"

			if (fl & WorldData.F_OCCUPIED) != 0:
				if world_ref.tree_at.has(cy * d.w + cx):
					continue
				if world_ref.mil != null and world_ref.mil.has_method("facility_at"):
					var fac_at = world_ref.mil.facility_at(Vector2i(cx, cy))
					if fac_at != null and is_instance_valid(fac_at):
						return "Место занято: постройка или ПВО"
				return "Место занято другими объектами"

	return ""

func can_place_at(cell: Vector2i) -> bool:
	return place_why(cell) == ""

func place_silo_at(cell: Vector2i) -> void:
	var why = place_why(cell)
	if why != "":
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Нельзя построить здесь: " + why)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	var p = world_ref.player
	if p.money < SILO_COST_MONEY or p.uranium < SILO_COST_URANIUM:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает: 3500 $ и 10 урана!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	p.money -= SILO_COST_MONEY
	p.uranium -= SILO_COST_URANIUM

	var f = Facility.new()
	f.id = world_ref.mil.facilities.size()
	# ВАЖНО: CIV_FACTORY — неподвижное сооружение. Ни при каких обстоятельствах не поедет!
	f.kind = Facility.Kind.CIV_FACTORY
	f.country_id = p.id
	f.cell = cell
	f.size = SILO_SIZE
	f.army_build = "nuclear_silo"
	f.lower_sprite = "nuclear_silo"
	f.hp = SILO_MAX_HP
	f.moving = false
	f.mdest = Vector2.ZERO
	f.mpos = f.center_px()
	f.missiles = 1
	f.set_meta("is_nuclear_silo", true)
	f.set_meta("hp", SILO_MAX_HP)
	f.set_meta("max_hp", SILO_MAX_HP)
	f.set_meta("has_warhead", true)
	f.set_meta("producing", false)
	f.set_meta("prod_t", 0.0)

	var spr_name = "eco_silo" if world_ref.spr_index.has("eco_silo") else ("missile_factory" if world_ref.spr_index.has("missile_factory") else "npp_core")
	f.main_obj = world_ref.add_object(spr_name, cell, GameWorld.KIND_BUILDING)
	f.obj_ids.append(f.main_obj)
	world_ref.mil.facilities.append(f)

	var d = world_ref.data
	for dy in range(f.size.y):
		for dx in range(f.size.x):
			var cx = cell.x + dx
			var cy = cell.y + dy
			world_ref.remove_tree_at(Vector2i(cx, cy))
			d.add_flag(cx, cy, WorldData.F_OCCUPIED)
			d.set_biome(cx, cy, Biome.INDUSTRIAL)

	cancel_placement()

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_build")
	if ClassDB.class_exists("Sfx"):
		Sfx.play("vls_hatch_open", f.center_px())
	if world_ref.fx != null:
		world_ref.fx.spawn("dust_s", Vector2(cell * GameWorld.CELL + Vector2i(8, 8)), 8)

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Шахтный комплекс МБР построен! Стратегическая ракета с термоядерной БЧ на боевом дежурстве.")
		main_ref.selected_fac = f

func _order_warhead(f: Facility) -> void:
	var p = world_ref.player
	if p == null:
		return
	if p.money < WARHEAD_COST_MONEY or p.uranium < WARHEAD_COST_URANIUM:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает: требуется 1500 $ и 8 урана (из урановых шахт или торговли)!")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return

	p.money -= WARHEAD_COST_MONEY
	p.uranium -= WARHEAD_COST_URANIUM

	f.set_meta("producing", true)
	f.set_meta("prod_t", 0.0)
	f.producing = true
	f.prod_t = 0.0

	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_build")
	if ClassDB.class_exists("Sfx"):
		Sfx.play("vls_hatch_open", f.center_px())
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Сборка термоядерной боеголовки запущена (требуется 24 сек)...")

func _start_targeting(f: Facility) -> void:
	if not bool(f.get_meta("has_warhead", false)):
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("В шахте нет готовой боеголовки! Сначала произведите ЯБЧ.")
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return
	is_targeting = true
	is_placing = false
	targeting_silo = f
	target_point = Vector2.INF

	if ClassDB.class_exists("Sfx"):
		Sfx.play("alarm_general_quarters")
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("БОЕВАЯ ТРЕВОГА! Выберите точку нанесения термоядерного удара на карте.")

func _cancel_targeting() -> void:
	is_targeting = false
	targeting_silo = null
	target_point = Vector2.INF
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Наведение ядерного удара отменено.")
		if selected_fac != null:
			_update_native_card(selected_fac)
		else:
			main_ref.hud.hide_ops()
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")

func set_target_point(wpos: Vector2) -> void:
	target_point = wpos
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")
	if main_ref != null and "overlay" in main_ref and main_ref.overlay != null:
		main_ref.overlay.ripple(target_point, "alert_red")
	var cell: Vector2i = Vector2i(floori(wpos.x / float(GameWorld.CELL)), floori(wpos.y / float(GameWorld.CELL)))
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Цель зафиксирована: квадрат (%d, %d). Нажмите «ПУСК МБР» в меню!" % [cell.x, cell.y])

func launch_strike(target_world_pos: Vector2) -> void:
	if targeting_silo == null or not is_instance_valid(targeting_silo):
		_cancel_targeting()
		return

	var f = targeting_silo
	f.set_meta("has_warhead", false)
	f.missiles = 0
	is_targeting = false
	targeting_silo = null
	target_point = Vector2.INF

	var start_pos = f.center_px()
	var dist = start_pos.distance_to(target_world_pos)
	var flight_duration = clampf(5.5 + dist * 0.002, 6.5, 9.5)

	# Звук и эффекты пуска
	if ClassDB.class_exists("Sfx"):
		Sfx.play("vls_hatch_open", start_pos)
		Sfx.play("missile_launch", start_pos)
		Sfx.play("hyper_launch", start_pos)
	if world_ref.fx != null:
		world_ref.fx.spawn("tel_flash", start_pos.round(), 6)
		world_ref.fx.spawn("launch_cloud", start_pos.round(), 5)
		world_ref.fx.spawn("shockwave", start_pos.round(), 1)
	if world_ref.has_method("camera_shake_launch"):
		world_ref.camera_shake_launch(start_pos)

	var p = world_ref.player
	var m = {
		"from": start_pos,
		"target": target_world_pos,
		"t": 0.0,
		"duration": flight_duration,
		"whistled": false,
		"country_id": p.id if p != null else 1,
		"trail": []
	}
	active_missiles.append(m)

	if world_ref.has_method("say") and p != null:
		world_ref.say(p, Loc.mk("ВНИМАНИЕ: Произведён запуск стратегической МБР «Сармат»!"))

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Пуск МБР «Сармат» выполнен! Подлёт к цели через %d сек." % int(ceil(flight_duration)))
		main_ref.hud.hide_ops()

func _repair_silo(f: Facility) -> void:
	var p = world_ref.player
	if p == null:
		return
	var cur_hp = float(f.get_meta("hp", SILO_MAX_HP))
	if cur_hp >= SILO_MAX_HP:
		return
	if p.money < SILO_REPAIR_COST:
		if main_ref != null and main_ref.hud != null:
			main_ref.hud.show_toast("Не хватает средств на ремонт шахты (требуется %d $)" % SILO_REPAIR_COST)
		if ClassDB.class_exists("UiKit"):
			UiKit.snd("ui_error")
		return
	p.money -= SILO_REPAIR_COST
	f.set_meta("hp", SILO_MAX_HP)
	f.hp = SILO_MAX_HP
	if ClassDB.class_exists("Sfx"):
		Sfx.play("repair_work", f.center_px())
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Шахтный комплекс МБР полностью отремонтирован!")

func _demolish_silo(f: Facility) -> void:
	var p = world_ref.player
	if p != null:
		p.money += SILO_REFUND

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
	if main_ref != null and "selected_fac" in main_ref:
		main_ref.selected_fac = null
	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Шахтный комплекс МБР демонтирован (+%d $ возврат)." % SILO_REFUND)
		main_ref.hud.hide_ops()
	if ClassDB.class_exists("UiKit"):
		UiKit.snd("ui_select")

func _tick_silos(delta: float) -> void:
	if world_ref == null or world_ref.mil == null:
		return
	for f in world_ref.mil.facilities:
		if f == null or not is_instance_valid(f):
			continue
		if not _is_silo(f):
			continue
		# Железная блокировка любого движения
		f.kind = Facility.Kind.CIV_FACTORY
		f.moving = false
		f.mdest = Vector2.ZERO
		f.mpos = f.center_px()

		if bool(f.get_meta("producing", false)):
			var t = float(f.get_meta("prod_t", 0.0)) + delta
			f.set_meta("prod_t", t)
			f.prod_t = t
			if t >= WARHEAD_TIME:
				f.set_meta("producing", false)
				f.producing = false
				f.set_meta("has_warhead", true)
				f.missiles = 1
				if ClassDB.class_exists("UiKit"):
					UiKit.snd("ui_victory")
				if ClassDB.class_exists("Sfx"):
					Sfx.play("vls_hatch_open", f.center_px())
				if main_ref != null and main_ref.hud != null:
					main_ref.hud.show_toast("Боеголовка смонтирована! МБР готова к ядерному удару.")

func _tick_missiles(delta: float) -> void:
	for i in range(active_missiles.size() - 1, -1, -1):
		var m = active_missiles[i]
		m["t"] += delta
		var k = clampf(m["t"] / m["duration"], 0.0, 1.0)
		var cur_ground = (m["from"] as Vector2).lerp(m["target"], k)
		var alt = 4.0 * 420.0 * k * (1.0 - k)
		var m_pos = cur_ground - Vector2(0, alt)

		var trail = m["trail"] as Array
		trail.append({"pos": m_pos, "t": 0.0})
		if trail.size() > 60:
			trail.pop_front()

		for tp in trail:
			tp["t"] += delta

		if not bool(m["whistled"]) and (m["duration"] - m["t"]) <= 1.8:
			m["whistled"] = true
			if ClassDB.class_exists("Sfx"):
				Sfx.play("missile_whistle", m["target"])

		if k >= 1.0:
			_detonate_nuclear(m)
			active_missiles.remove_at(i)

func _detonate_nuclear(m: Dictionary) -> void:
	var target_pos: Vector2 = m["target"]
	var cell: Vector2i = Vector2i(floori(target_pos.x / float(GameWorld.CELL)), floori(target_pos.y / float(GameWorld.CELL)))
	var country_id: int = int(m["country_id"])

	# 1. Регистрация гигантского ядерного взрыва (гриб + огненный купол + ударная волна)
	var puffs: Array = []
	for p_i in range(50):
		var ang = randf() * TAU
		var rad = randf_range(15.0, 115.0)
		puffs.append({
			"offset": Vector2(cos(ang) * rad, sin(ang) * rad * 0.65),
			"size": randf_range(32.0, 64.0),
			"burn": randf() > 0.4
		})

	var exp = {
		"pos": target_pos,
		"cell": cell,
		"t": 0.0,
		"duration": 12.0,
		"country_id": country_id,
		"max_radius": 260.0,
		"cloud_height": 190.0,
		"sound_phase": 0,
		"puffs": puffs
	}
	active_explosions.append(exp)

	# 2. Ослепляющая вспышка экрана
	if flash_rect != null and is_instance_valid(flash_rect):
		flash_rect.color = Color(1.0, 1.0, 0.95, 1.0)
		var tw = flash_rect.create_tween()
		tw.tween_property(flash_rect, "color", Color(1.0, 0.75, 0.25, 0.75), 0.5).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(flash_rect, "color:a", 0.0, 2.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# 3. Каскад сокрушительных звуков
	if ClassDB.class_exists("Sfx"):
		Sfx.play("expl_big", target_pos, 4.0)
		Sfx.play("far_boom_1", target_pos, 4.0)
		Sfx.play("building_collapse", target_pos, 3.5)

	# 4. Мощнейшее сотрясение экрана
	if world_ref != null and world_ref.camera != null:
		world_ref.camera.shake_pattern([
			Vector2(20, -10), Vector2(-18, 14), Vector2(16, -16),
			Vector2(-15, 12), Vector2(12, 10), Vector2(-10, -12),
			Vector2(10, 8), Vector2(-8, -8), Vector2(6, 6), Vector2(-5, -4),
			Vector2(3, 3), Vector2(0, 0)
		], 0.06)

	# 5. Массивное формирование кратеров и разрушение построек
	var strike_offsets = [
		Vector2i(0, 0),
		Vector2i(-6, 0), Vector2i(6, 0), Vector2i(0, -6), Vector2i(0, 6),
		Vector2i(-4, -4), Vector2i(4, -4), Vector2i(-4, 4), Vector2i(4, 4),
		Vector2i(-10, 0), Vector2i(10, 0), Vector2i(0, -10), Vector2i(0, 10),
		Vector2i(-8, -6), Vector2i(8, -6), Vector2i(-8, 6), Vector2i(8, 6),
		Vector2i(-12, -4), Vector2i(12, -4), Vector2i(-12, 4), Vector2i(12, 4)
	]
	for off in strike_offsets:
		if world_ref.has_method("_apply_strike"):
			world_ref._apply_strike(cell + off, 12, "crater_l", 75.0, country_id)

	# 6. Тотальное выжигание ландшафта (радиус 30 клеток = более 60 клеток в ширину!)
	var d = world_ref.data
	if d != null:
		var burn_radius = 30
		for dy in range(-burn_radius, burn_radius + 1):
			for dx in range(-burn_radius, burn_radius + 1):
				if dx * dx + dy * dy <= burn_radius * burn_radius:
					var cx = cell.x + dx
					var cy = cell.y + dy
					if d.inside(cx, cy):
						var b = d.get_biome(cx, cy)
						if Biome.is_natural_land(b):
							d.set_biome(cx, cy, Biome.BURNT)

	# 7. Уничтожение всей армии и техники в радиусе 260 пикселей
	if world_ref.army != null and world_ref.army.units != null:
		var blast_r_sq = 260.0 * 260.0
		for u in world_ref.army.units:
			if u != null and is_instance_valid(u) and u.alive:
				if u.pos.distance_squared_to(target_pos) <= blast_r_sq:
					u.hp = 0.0
					u.alive = false

	# 8. Разрушение военных баз и заводов врага
	if world_ref.mil != null and world_ref.mil.facilities != null:
		for f_item in world_ref.mil.facilities:
			if f_item == null or not is_instance_valid(f_item):
				continue
			if f_item.center_px().distance_to(target_pos) <= 260.0:
				f_item.hp = 0.0
				f_item.restore_t = 180.0
				if f_item.kind == Facility.Kind.NUCLEAR_PLANT or f_item.kind == Facility.Kind.POWER_PLANT:
					f_item.u_fuel = 0.0
					f_item.u_hits = 3
					var vict = world_ref.country_by_id(f_item.country_id)
					if vict != null:
						vict.power_cap = maxi(0, vict.power_cap - 60)
						if world_ref.has_method("say"):
							world_ref.say(vict, Loc.mk("КАТАСТРОФА! В результате термоядерного удара разрушена энергостанция! Полный блэкаут сети."))

	# 9. Множественные очаги пожара и дымовые завесы
	if world_ref.fx != null:
		world_ref.fx.spawn("shockwave", target_pos, 1)
		for k in range(30):
			var r_dist = randf_range(12.0, 210.0)
			var f_ang = randf() * TAU
			var fire_pos = target_pos + Vector2(cos(f_ang), sin(f_ang)) * r_dist
			world_ref.fx.spawn("fire_small", fire_pos, 4, world_ref.game_time + 55.0, true)
			world_ref.fx.spawn("smoke_black_loop", fire_pos + Vector2(0, -10), 6, world_ref.game_time + 60.0, true)

	if world_ref.has_method("say"):
		world_ref.say(world_ref.country_by_id(country_id), Loc.mk("ТЕРМОЯДЕРНЫЙ УДАР НАНЕСЁН ПО КВАДРАТУ (%d, %d)! Зона полностью уничтожена.", [cell.x, cell.y]))

	if main_ref != null and main_ref.hud != null:
		main_ref.hud.show_toast("Ядерный удар МБР нанесён! Цель и окружающая территория стёрты с лица земли.")

func _tick_explosions(delta: float) -> void:
	for i in range(active_explosions.size() - 1, -1, -1):
		var exp = active_explosions[i]
		exp["t"] += delta
		var t = float(exp["t"])
		if exp["sound_phase"] == 0 and t >= 1.2:
			exp["sound_phase"] = 1
			if ClassDB.class_exists("Sfx"):
				Sfx.play("expl_big", exp["pos"], 3.5)
				Sfx.play("building_collapse", exp["pos"], 3.0)
		elif exp["sound_phase"] == 1 and t >= 2.5:
			exp["sound_phase"] = 2
			if ClassDB.class_exists("Sfx"):
				Sfx.play("far_boom_1", exp["pos"], 3.0)
		if t >= exp["duration"]:
			active_explosions.remove_at(i)

func _update_native_card(f: Facility) -> void:
	if main_ref == null or main_ref.hud == null:
		return
	var h = main_ref.hud
	var p = world_ref.player
	if p == null:
		return

	var has_w = bool(f.get_meta("has_warhead", false))
	var prod = bool(f.get_meta("producing", false))
	var hp = float(f.get_meta("hp", SILO_MAX_HP))
	var max_hp = float(f.get_meta("max_hp", SILO_MAX_HP))

	var title = "Шахтный комплекс МБР «Сармат»"
	var sub = "РВСН · Стратегический арсенал · Шахта #%d" % f.id
	h._card("nuclear_silo_%d" % f.id, "icon_m_ballistic", title, sub, false, false, true)

	var info = ""
	if has_w:
		info = Loc.t("СТАТУС: БОЕГОЛОВКА СМОНТИРОВАНА · МБР НА ДЕЖУРСТВЕ · ДАЛЬНОСТЬ: ГЛОБАЛЬНАЯ\nЗАПАС УРАНА В СТРАНЕ: %d ШТ. · ПРОЧНОСТЬ ШАХТЫ: %d/%d") % [p.uranium, int(hp), int(max_hp)]
	elif prod:
		var left_s = maxf(0.0, WARHEAD_TIME - float(f.get_meta("prod_t", 0.0)))
		info = Loc.t("СТАТУС: ОБОГАЩЕНИЕ УРАНА И МОНТАЖ ЯБЧ... %s\nЗАПАС УРАНА В СТРАНЕ: %d ШТ. · ПРОЧНОСТЬ ШАХТЫ: %d/%d") % [h._mmss(left_s), p.uranium, int(hp), int(max_hp)]
	else:
		info = Loc.t("СТАТУС: ШАХТА ПУСТА · ТРЕБУЕТСЯ СБОРКА ТЕРМОЯДЕРНОЙ БЧ (1500$ · 8 УРАНА)\nЗАПАС УРАНА В СТРАНЕ: %d ШТ. · ПРОЧНОСТЬ ШАХТЫ: %d/%d") % [p.uranium, int(hp), int(max_hp)]

	h._set_info(info, not has_w and not prod)
	h.ops_detail.text = "Стратегический ракетный комплекс шахтного базирования. Заглублённая железобетонная шахта с броневой крышкой способна выдержать бомбардировку. Оснащается межконтинентальной баллистической ракетой с разделяющейся головной частью термоядерного оснащения. Для сборки боеголовки требуется обогащённый уран с урановых шахт."
	h.ops_detail.visible = true

	var acts: Array = []
	if has_w:
		acts.append(h._act("ЯДЕРНЫЙ\nУДАР", "icon_target", "nuke_target", true))
	elif prod:
		var left_s = maxf(0.0, WARHEAD_TIME - float(f.get_meta("prod_t", 0.0)))
		acts.append(h._act("ИДЁТ\nСБОРКА", "icon_r_uranium", "none", false, 0, "%s" % h._mmss(left_s)))
	else:
		var can_craft = p.money >= WARHEAD_COST_MONEY and p.uranium >= WARHEAD_COST_URANIUM
		acts.append(h._act("СБОРКА ЯБЧ\n1500$ · 8 У", "icon_r_uranium", "nuke_craft", can_craft))

	if hp < max_hp:
		acts.append(h._act("РЕМОНТ\n400$", "icon_restore", "nuke_repair", p.money >= SILO_REPAIR_COST))

	acts.append(h._act("СНОС\n+1750$", "icon_close", "nuke_demolish", true))
	acts.append(h._act("ЗАКРЫТЬ", "icon_arrow_down", "nuke_close", true))
	h._fill_acts("nuclear_silo_acts_%d" % f.id, acts)

func _update_targeting_card() -> void:
	if main_ref == null or main_ref.hud == null or targeting_silo == null:
		return
	var h = main_ref.hud
	var title = "БОЕВАЯ ТРЕВОГА: НАВЕДЕНИЕ МБР"
	var sub = "Укажите квадрат удара на карте (ЛКМ/Тап — выбор, ПКМ — отмена)"
	h._card("nuke_targeting", "icon_m_ballistic", title, sub, false, false, true)

	if target_point == Vector2.INF:
		h._set_info("ТАПНИТЕ ПО КАРТЕ, ЧТОБЫ ВЫБРАТЬ ЦЕЛЬ ДЛЯ ТЕРМОЯДЕРНОГО УДАРА", false)
	else:
		var cell: Vector2i = Vector2i(floori(target_point.x / float(GameWorld.CELL)), floori(target_point.y / float(GameWorld.CELL)))
		var dist_km = targeting_silo.center_px().distance_to(target_point) * 0.004
		var flight_s = int(ceil(clampf(5.5 + targeting_silo.center_px().distance_to(target_point) * 0.002, 6.5, 9.5)))
		h._set_info("ЦЕЛЬ: КВАДРАТ (%d, %d) · ДИСТАНЦИЯ: %.1f КМ · ВРЕМЯ ПОЛЁТА: %d СЕК\nРАДИУС ПОРАЖЕНИЯ: 30 КЛЕТОК · ГЛОБАЛЬНЫЙ ТЕРМОЯДЕРНЫЙ ВЗРЫВ" % [cell.x, cell.y, dist_km, flight_s], false)

	h.ops_detail.text = "Наведение стратегической МБР «Сармат». После подтверждения пуска ракета выйдет из шахты на твердотопливном ускорителе, выйдет на баллистическую траекторию и сокрушит цель. Все строения, войска и ПВО противника в зоне будут полностью стёрты."
	h.ops_detail.visible = true

	var acts: Array = []
	var has_tgt = target_point != Vector2.INF
	acts.append(h._act("ПУСК МБР", "icon_target", "nuke_launch_confirm", has_tgt))
	if has_tgt:
		acts.append(h._act("СБРОС\nЦЕЛИ", "icon_refresh", "nuke_target_reset", true))
	acts.append(h._act("ОТМЕНА", "icon_close", "nuke_cancel_target", true))
	h._fill_acts("nuclear_targeting_acts", acts)

# -------------------------------------------------------------
# Внутренний класс визуального слоя мира для NuclearStrike
# -------------------------------------------------------------
class NuclearWorldLayer extends Node2D:
	var mod = null
	var main: Node = null
	var world: Node = null

	func setup(p_mod, p_main: Node, p_world: Node) -> void:
		mod = p_mod
		main = p_main
		world = p_world
		z_index = 85

	func _unhandled_input(event: InputEvent) -> void:
		if mod == null or world == null or main == null:
			return

		var is_press: bool = false
		var is_cancel: bool = false
		var ev_pos: Vector2 = Vector2.ZERO

		if event is InputEventMouseButton:
			if event.pressed:
				if event.button_index == MOUSE_BUTTON_LEFT:
					is_press = true
					ev_pos = event.position
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					is_cancel = true
		elif event is InputEventScreenTouch:
			if event.pressed:
				is_press = true
				ev_pos = event.position

		if event is InputEventKey and event.pressed and not event.echo:
			if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not event.alt_pressed:
				if mod.is_targeting and mod.target_point != Vector2.INF:
					mod._on_hud_action("nuke_launch_confirm")
					get_viewport().set_input_as_handled()
					return
			if event.keycode == KEY_ESCAPE:
				if mod.is_placing:
					mod.cancel_placement()
					get_viewport().set_input_as_handled()
					return
				elif mod.is_targeting:
					mod._cancel_targeting()
					get_viewport().set_input_as_handled()
					return

		if is_press:
			var wp: Vector2 = main.cam.screen_to_world(ev_pos) if main.cam != null else ev_pos
			var cell = Vector2i((wp / float(GameWorld.CELL)).floor())

			if mod.is_placing:
				mod.place_silo_at(cell)
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
				mod._cancel_targeting()
				get_viewport().set_input_as_handled()
				return

	func _draw() -> void:
		if mod == null or world == null or main == null:
			return

		var mouse_sp: Vector2 = get_viewport().get_mouse_position()
		var mouse_w: Vector2 = main.cam.screen_to_world(mouse_sp) if main.cam != null else mouse_sp

		# 1. Отрисовка призрака при постройке шахты по сетке
		if mod.is_placing:
			var cell = Vector2i((mouse_w / float(GameWorld.CELL)).floor())
			var valid = mod.can_place_at(cell)

			var pos = Vector2(cell * GameWorld.CELL)
			var sz = Vector2(mod.SILO_SIZE * GameWorld.CELL)

			var fill_col = Color(0.2, 1.0, 0.3, 0.25) if valid else Color(1.0, 0.25, 0.25, 0.25)
			var outline_col = Color(0.2, 1.0, 0.3, 0.95) if valid else Color(1.0, 0.25, 0.25, 0.95)

			draw_rect(Rect2(pos, sz), fill_col)
			draw_rect(Rect2(pos, sz), outline_col, false, 2.0)

			for x in range(mod.SILO_SIZE.x + 1):
				var lx = pos.x + float(x * GameWorld.CELL)
				draw_line(Vector2(lx, pos.y), Vector2(lx, pos.y + sz.y), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)
			for y in range(mod.SILO_SIZE.y + 1):
				var ly = pos.y + float(y * GameWorld.CELL)
				draw_line(Vector2(pos.x, ly), Vector2(pos.x + sz.x, ly), Color(outline_col.r, outline_col.g, outline_col.b, 0.3), 1.0)

			var center_p = pos + sz * 0.5
			draw_circle(center_p, 6.0, Color(0.15, 0.18, 0.22, 0.85))
			draw_arc(center_p, 6.0, 0.0, TAU, 24, outline_col, 1.5)
			draw_circle(center_p, 2.5, Color(outline_col.r, outline_col.g, outline_col.b, 0.9))
			draw_arc(center_p, 22.0, 0.0, TAU, 32, Color(outline_col.r, outline_col.g, outline_col.b, 0.4), 1.0)

		# 2. Отрисовка тактического прицела при ядерном наведении
		if mod.is_targeting:
			var t_time = float(Time.get_ticks_msec()) * 0.005
			var pulse = 0.8 + 0.2 * sin(t_time * 5.0)
			var aim_pos = mod.target_point if mod.target_point != Vector2.INF else mouse_w

			if mod.targeting_silo != null and is_instance_valid(mod.targeting_silo):
				var silo_pos = mod.targeting_silo.center_px()
				draw_line(silo_pos, aim_pos, Color(1.0, 0.8, 0.2, 0.4 * pulse), 1.5)
				draw_circle(silo_pos, 4.0, Color(1.0, 0.85, 0.2, 0.8))

			# Окружность радиуса поражения (радиус 260px)
			draw_circle(aim_pos, 260.0, Color(1.0, 0.15, 0.1, 0.15 * pulse))
			draw_arc(aim_pos, 260.0, 0.0, TAU, 64, Color(1.0, 0.85, 0.2, 0.9 * pulse), 2.5)
			draw_arc(aim_pos, 130.0, 0.0, TAU, 48, Color(1.0, 0.3, 0.1, 0.5 * pulse), 1.5)

			# Тактическое перекрестье
			draw_line(aim_pos - Vector2(36, 0), aim_pos + Vector2(36, 0), Color(1.0, 0.2, 0.1, 0.95), 2.0)
			draw_line(aim_pos - Vector2(0, 36), aim_pos + Vector2(0, 36), Color(1.0, 0.2, 0.1, 0.95), 2.0)
			draw_circle(aim_pos, 5.0, Color(1.0, 0.9, 0.15, 1.0))

		# 3. Отрисовка построенных шахт на карте (железобетонный бронекупол и статус)
		if world.mil != null and world.mil.facilities != null:
			for f in world.mil.facilities:
				if f == null or not is_instance_valid(f):
					continue
				if not f.has_meta("is_nuclear_silo"):
					continue
				var f_pos = Vector2(f.cell * GameWorld.CELL)
				var f_sz = Vector2(f.size * GameWorld.CELL)
				var center_px = f.center_px()

				# Плита фундамента
				draw_rect(Rect2(f_pos, f_sz), Color(0.2, 0.22, 0.25, 0.45))
				draw_rect(Rect2(f_pos, f_sz), Color(0.35, 0.38, 0.42, 0.9), false, 1.5)

				# Бронелюк шахты
				draw_circle(center_px, 8.0, Color(0.12, 0.14, 0.16, 0.95))
				draw_arc(center_px, 8.0, 0.0, TAU, 24, Color(0.5, 0.55, 0.6), 1.5)

				# Индикатор готовности
				var has_w = bool(f.get_meta("has_warhead", false))
				var prod = bool(f.get_meta("producing", false))
				var led_col = Color(0.2, 1.0, 0.3, 0.95) if has_w else (Color(1.0, 0.8, 0.2, 0.95) if prod else Color(1.0, 0.25, 0.25, 0.8))
				draw_circle(center_px, 3.0, led_col)

		# 4. Отрисовка летящей МБР и дымного инверсионного следа
		for m in mod.active_missiles:
			var k = clampf(m["t"] / m["duration"], 0.0, 1.0)
			var cur_ground = (m["from"] as Vector2).lerp(m["target"], k)
			var alt = 4.0 * 420.0 * k * (1.0 - k)
			var m_pos = cur_ground - Vector2(0, alt)

			# Тень на земле
			draw_circle(cur_ground, 4.5, Color(0.0, 0.0, 0.0, 0.45))

			# Дымный след
			var trail = m["trail"] as Array
			for tp in trail:
				var tr_age = float(tp["t"])
				var tr_a = clampf(1.0 - tr_age / 2.0, 0.0, 0.7)
				var tr_sz = 3.0 + tr_age * 4.0
				draw_circle(tp["pos"], tr_sz, Color(0.85, 0.88, 0.92, tr_a))

			# Корпус ракеты
			var next_k = minf(1.0, k + 0.01)
			var next_g = (m["from"] as Vector2).lerp(m["target"], next_k)
			var next_alt = 4.0 * 420.0 * next_k * (1.0 - next_k)
			var next_pos = next_g - Vector2(0, next_alt)
			var dir = (next_pos - m_pos).normalized()
			if dir == Vector2.ZERO:
				dir = Vector2.UP

			draw_line(m_pos - dir * 14.0, m_pos + dir * 6.0, Color(0.92, 0.94, 0.96), 3.5)
			draw_circle(m_pos + dir * 6.0, 2.5, Color(0.2, 0.22, 0.25)) # Головная часть
			# Пламя двигателя
			draw_line(m_pos - dir * 14.0, m_pos - dir * 26.0, Color(1.0, 0.75, 0.15), 3.0)
			draw_circle(m_pos - dir * 24.0, 4.0, Color(1.0, 0.35, 0.05, 0.85))

		# 5. Отрисовка колоссального термоядерного гриба и ударной волны
		for exp in mod.active_explosions:
			var pos: Vector2 = exp["pos"]
			var t: float = float(exp["t"])
			var max_rad: float = float(exp["max_radius"])
			var cloud_h: float = float(exp["cloud_height"])

			# А) Сверхзвуковая ударная волна (0 .. 3.5 сек)
			if t < 3.5:
				var sw_prog = clampf(t / 3.0, 0.0, 1.0)
				var sw_rad = sin(sw_prog * PI * 0.5) * max_rad
				var sw_alpha = (1.0 - sw_prog) * 0.95
				draw_circle(pos, sw_rad, Color(1.0, 0.45, 0.1, sw_alpha * 0.18))
				draw_arc(pos, sw_rad, 0, TAU, 72, Color(1.0, 0.95, 0.6, sw_alpha), 4.5)
				draw_arc(pos, sw_rad * 0.93, 0, TAU, 64, Color(1.0, 0.38, 0.05, sw_alpha * 0.75), 2.5)

			# Б) Огненный шар в эпицентре (0 .. 4.5 сек)
			if t < 4.5:
				var fb_rad = (sin(clampf(t / 0.9, 0.0, 1.0) * PI * 0.5) * 95.0) if t <= 0.9 else maxf(0.0, 95.0 - (t - 0.9) * 20.0)
				var fb_alpha = clampf(1.0 - (t - 0.5) / 3.8, 0.0, 1.0)
				if fb_rad > 0.0 and fb_alpha > 0.0:
					draw_circle(pos, fb_rad * 1.35, Color(0.95, 0.25, 0.05, fb_alpha * 0.45))
					draw_circle(pos, fb_rad, Color(1.0, 0.65, 0.1, fb_alpha * 0.85))
					draw_circle(pos, fb_rad * 0.65, Color(1.0, 0.98, 0.88, fb_alpha * 0.98))

			# В) Гигантский ядерный гриб (ножка и шапка) (0.3 .. 12 сек)
			if t > 0.3:
				var rise_k = clampf((t - 0.3) / 4.2, 0.0, 1.0)
				var cur_h = rise_k * cloud_h
				var cap_pos = pos - Vector2(0, cur_h)
				var smoke_a = clampf(1.0 - (t - 4.5) / 7.2, 0.0, 0.95) if t > 4.5 else clampf((t - 0.3) / 1.0, 0.0, 0.95)

				# Ножка гриба (поднимающийся столб кипящего дыма и огня)
				for step in range(11):
					var st_k = float(step) / 10.0
					var st_p = pos.lerp(cap_pos, st_k)
					var st_rad = (22.0 + sin(st_k * PI) * 14.0) * (0.6 + 0.4 * rise_k)
					draw_circle(st_p, st_rad * 1.25, Color(0.12, 0.11, 0.1, smoke_a * 0.85))
					draw_circle(st_p, st_rad * 0.8, Color(0.85, 0.35, 0.05, smoke_a * (1.0 - st_k * 0.5) * 0.55))

				# Шапка ядерного гриба (расползающийся наковальнеобразный купол)
				for puff in exp["puffs"]:
					var puff_p = cap_pos + puff["offset"] * rise_k
					var puff_sz = puff["size"] * (0.55 + 0.45 * rise_k)
					var puff_col = Color(0.14, 0.13, 0.12, smoke_a * 0.9) if not puff["burn"] else Color(0.8, 0.32, 0.06, smoke_a * 0.65)
					draw_circle(puff_p, puff_sz, puff_col)

				# Кольца конденсации Вильсона (0.7 .. 3.8 сек)
				if t >= 0.7 and t <= 3.8:
					var w_prog = clampf((t - 0.7) / 3.0, 0.0, 1.0)
					var w_rad = w_prog * 110.0
					var w_a = (1.0 - w_prog) * 0.65
					draw_arc(pos - Vector2(0, cur_h * 0.45), w_rad, 0, TAU, 48, Color(0.9, 0.94, 1.0, w_a), 2.5)
					draw_arc(pos - Vector2(0, cur_h * 0.75), w_rad * 0.75, 0, TAU, 36, Color(0.9, 0.94, 1.0, w_a * 0.7), 2.0)
