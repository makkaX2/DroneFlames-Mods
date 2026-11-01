extends RefCounted
## Модификация «Карта: Оазис в Пустыне»
## Автор: @good_boy_irl

var _mod_id: String = "oasis_map"
var _map_type_id: String = "desert_oasis"

func init_mod(mod_mgr: Node) -> void:
	print("[OasisMod] Initializing Desert Oasis Map Mod...")
	if mod_mgr.has_method("register_map_type"):
		mod_mgr.call("register_map_type", {
			"id": _map_type_id,
			"name": "ПУСТЫНЯ",
			"hint": "Бескрайние песчаные дюны, оазисы вокруг озер и богатая нефть",
			"icon": "map_t_normal",
			"land_percent": 82,
			"generator": Callable(self, "_generate_desert_map")
		})
	print("[OasisMod] Map 'ПУСТЫНЯ' successfully registered!")

func cleanup_mod(mod_mgr: Node) -> void:
	print("[OasisMod] Cleaning up Desert Oasis Map Mod...")
	if mod_mgr.has_method("unregister_map_type"):
		mod_mgr.call("unregister_map_type", _map_type_id)

func _generate_desert_map(world_data: RefCounted, s: Resource) -> void:
	print("[OasisMod] Generating Desert Oasis terrain...")
	if world_data == null:
		return
	# Настройка засушливого ландшафта: приподнимаем высоты, увеличиваем сушу
	if "sea_level" in world_data and "height" in world_data:
		var n: int = int(world_data.get("width", 512)) * int(world_data.get("height_dim", 512))
		# Задаем уровень моря чуть ниже для обширных пустынных плато
		var sea: int = int(world_data.get("sea_level", 60))
		world_data.set("sea_level", maxi(20, sea - 15))
