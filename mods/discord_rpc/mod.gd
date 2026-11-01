class_name DiscordRpcMod
extends RefCounted

var mm_ref: Node = null
var bridge_pid: int = 0
var state_file_global: String = ""
var timer_node: Timer = null
var match_start_time: int = 0
var in_match: bool = false
var last_main: Node = null
var last_world: Node = null
var launch_time: int = 0
var custom_client_id: String = "1566515978806759500"

func init_mod(mm: Node) -> void:
	mm_ref = mm
	launch_time = int(Time.get_unix_time_from_system())
	match_start_time = launch_time

	# Read custom client_id from settings if configured
	var cfg = ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		var cid = cfg.get_value("discord", "client_id", "")
		if String(cid).strip_edges() != "":
			custom_client_id = String(cid).strip_edges()

	# Resolve absolute path for state file
	state_file_global = ProjectSettings.globalize_path("user://discord_state.json")

	# Write initial menu state immediately
	_write_state(_build_menu_state())

	# Launch bridge background process
	_launch_bridge()

	# Register game hooks
	if mm.has_method("register_hook"):
		mm.call("register_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("register_hook", "on_match_tick", Callable(self, "_on_match_tick"))

	# Create periodic timer attached to ModManager
	if mm and is_instance_valid(mm):
		timer_node = Timer.new()
		timer_node.wait_time = 2.0
		timer_node.autostart = true
		timer_node.timeout.connect(_on_timer_tick)
		mm.add_child(timer_node)

	print("[DiscordRPC] Mod initialized and bridge started.")

func cleanup_mod(mm: Node) -> void:
	# Signal shutdown to bridge
	var f = FileAccess.open("user://discord_state.json", FileAccess.WRITE)
	if f:
		f.store_string('{"shutdown": true}')
		f.close()

	if bridge_pid > 0:
		OS.kill(bridge_pid)
		bridge_pid = 0

	if timer_node != null and is_instance_valid(timer_node):
		timer_node.queue_free()
		timer_node = null

	if mm and mm.has_method("unregister_hook"):
		mm.call("unregister_hook", "on_world_started", Callable(self, "_on_world_started"))
		mm.call("unregister_hook", "on_match_tick", Callable(self, "_on_match_tick"))

	print("[DiscordRPC] Mod cleaned up.")

func _launch_bridge() -> void:
	var base_folder: String = ""
	var scr = get_script()
	if scr:
		base_folder = scr.resource_path.get_base_dir()
	if base_folder == "":
		base_folder = "res://mods/discord_rpc"

	var py_bridge = ProjectSettings.globalize_path(base_folder.path_join("discord_bridge.py"))
	var ps_bridge = ProjectSettings.globalize_path(base_folder.path_join("discord_bridge.ps1"))
	var parent_pid_str = str(OS.get_process_id())

	# Prefer Python bridge if available
	var py_exit = OS.execute("python", ["--version"], [], false)
	if py_exit == 0 and FileAccess.file_exists(base_folder.path_join("discord_bridge.py")):
		bridge_pid = OS.create_process("python", [py_bridge, state_file_global, parent_pid_str])
		if bridge_pid > 0:
			print("[DiscordRPC] Launched Python bridge (PID %d)" % bridge_pid)
			return

	# Fallback to PowerShell bridge
	if FileAccess.file_exists(base_folder.path_join("discord_bridge.ps1")):
		bridge_pid = OS.create_process("powershell.exe", [
			"-NoProfile",
			"-WindowStyle", "Hidden",
			"-ExecutionPolicy", "Bypass",
			"-File", ps_bridge,
			state_file_global,
			parent_pid_str
		])
		if bridge_pid > 0:
			print("[DiscordRPC] Launched PowerShell bridge (PID %d)" % bridge_pid)
			return

	print("[DiscordRPC] Warning: Could not launch bridge process.")

func _on_world_started(main: Node, world: Node) -> void:
	last_main = main
	last_world = world
	in_match = true
	match_start_time = int(Time.get_unix_time_from_system())
	_update_presence()

func _on_match_tick(main: Node, world: Node, _delta: float) -> void:
	last_main = main
	last_world = world
	in_match = true

func _on_timer_tick() -> void:
	# Check if we are in game or in menu
	if last_main != null and is_instance_valid(last_main):
		if "menus" in last_main and last_main.menus != null:
			if last_main.menus.visible:
				in_match = false
	_update_presence()

func _update_presence() -> void:
	var state_dict: Dictionary = {}
	if in_match and last_world != null and is_instance_valid(last_world):
		state_dict = _build_ingame_state()
	else:
		state_dict = _build_menu_state()
	_write_state(state_dict)

func _build_menu_state() -> Dictionary:
	var player_name = _get_player_name()
	var has_save: bool = Save.has_save() if ClassDB.class_exists("Save") or ResourceLoader.exists("res://game/save.gd") else false
	var state_txt = "Готово сохранение" if has_save else "Выбор режима игры"

	var res_dict = {
		"client_id": custom_client_id,
		"details": "В главном меню",
		"state": state_txt,
		"timestamps": {
			"start": launch_time
		},
		"assets": {
			"large_image": "https://raw.githubusercontent.com/makkaX2/DroneFlames-Mods/main/assets/droneflames_logo.png",
			"large_text": "DroneFlames (PC Port by @good_boy_irl)",
			"small_image": "https://raw.githubusercontent.com/makkaX2/DroneFlames-Mods/main/assets/profile_avatar.png",
			"small_text": "Профиль: %s" % player_name
		},
		"buttons": [
			{"label": "GitHub Проект", "url": "https://github.com/makkaX2/DroneFlames-PC-Port"}
		]
	}
	return res_dict

func _build_ingame_state() -> Dictionary:
	var player_name = _get_player_name()
	var world = last_world
	var world_w: int = 1024
	var world_h: int = 1024
	if "data" in world and world.data != null:
		world_w = int(world.data.w)
		world_h = int(world.data.h)

	# Map Name
	var map_name: String = "Обычная"
	var mt_idx: int = 0
	if "settings" in world and world.settings != null:
		mt_idx = int(world.settings.map_type)
	
	var standard_names: Array = ["Обычная", "Архипелаг", "Острова", "Материки"]
	if mt_idx >= 0 and mt_idx < standard_names.size():
		map_name = standard_names[mt_idx]
	elif mm_ref != null and mm_ref.has_method("get_custom_map_types"):
		var custom_maps: Array = mm_ref.call("get_custom_map_types")
		var custom_idx = mt_idx - standard_names.size()
		if custom_idx >= 0 and custom_idx < custom_maps.size():
			map_name = String(custom_maps[custom_idx].get("name", "Особая карта"))
		else:
			map_name = "Особая карта"
	else:
		map_name = "Особая карта"

	# Player Country Stats
	var player_country: Country = null
	if "countries" in world and world.countries is Array:
		for c in world.countries:
			if c != null and is_instance_valid(c) and c.is_player:
				player_country = c
				break

	var cities_count: int = 0
	var wars_count: int = 0
	var treasury: int = 0
	var score: int = 0
	var country_name: String = "Гегемон"

	if player_country != null:
		cities_count = player_country.city_ids.size()
		wars_count = player_country.at_war.size()
		treasury = player_country.money
		score = player_country.score
		if player_country.name != "":
			country_name = player_country.name

	# Units count
	var armies_count: int = 0
	if "army" in world and world.army != null and "units" in world.army:
		for u in world.army.units:
			if u != null and is_instance_valid(u) and u.hp > 0:
				if player_country != null and u.country_id == player_country.id:
					armies_count += 1

	var cash_str = _format_cash(treasury)
	var state_line = "Городов: %d | Армий: %d | Войн: %d | Казна: %s | Очки: %d" % [
		cities_count, armies_count, wars_count, cash_str, score
	]

	return {
		"client_id": custom_client_id,
		"details": "Мир: %s (%dx%d)" % [map_name, world_w, world_h],
		"state": state_line,
		"timestamps": {
			"start": match_start_time
		},
		"assets": {
			"large_image": "https://raw.githubusercontent.com/makkaX2/DroneFlames-Mods/main/assets/droneflames_logo.png",
			"large_text": "DroneFlames (PC Port by @good_boy_irl)",
			"small_image": "https://raw.githubusercontent.com/makkaX2/DroneFlames-Mods/main/assets/profile_avatar.png",
			"small_text": "Профиль: %s (%s)" % [player_name, country_name]
		},
		"buttons": [
			{"label": "GitHub Проект", "url": "https://github.com/makkaX2/DroneFlames-PC-Port"}
		]
	}

func _write_state(dict: Dictionary) -> void:
	var json_str = JSON.stringify(dict)
	var f = FileAccess.open("user://discord_state.json", FileAccess.WRITE)
	if f:
		f.store_string(json_str)
		f.close()

func _get_player_name() -> String:
	var cfg = ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		var n = cfg.get_value("prefs", "my_name", "")
		if String(n).strip_edges() != "":
			return String(n)
	return "@good_boy_irl"

func _format_cash(val: int) -> String:
	if abs(val) >= 1000000:
		return "%.1fM" % (float(val) / 1000000.0)
	if abs(val) >= 1000:
		return "%.1fK" % (float(val) / 1000.0)
	return str(val)
