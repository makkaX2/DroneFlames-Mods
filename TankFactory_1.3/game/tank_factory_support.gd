extends RefCounted

static var _atlas: SpriteAtlas

static func atlas() -> SpriteAtlas:
	if _atlas == null:
		_atlas = SpriteAtlas.new()
		_atlas.sprites = JSON.parse_string(FileAccess.get_file_as_string("res://assets/sprites/tank_factory.json"))["sprites"]
		# Source distributions run without an editor import pass. Load their
		# loose PNG directly, with a ResourceLoader fallback for exported builds.
		var image := Image.new()
		if FileAccess.file_exists("res://assets/sprites/tank_factory.png"):
			image.load_png_from_buffer(FileAccess.get_file_as_bytes("res://assets/sprites/tank_factory.png"))
		if image != null and not image.is_empty():
			_atlas.texture = ImageTexture.create_from_image(image)
		else:
			_atlas.texture = load("res://assets/sprites/tank_factory.png") as Texture2D
	return _atlas

# The visible factory is the original game's army base. No proxy facilities.
static func configure(world: GameWorld, factory: Facility) -> void:
	factory.kind = Facility.Kind.BARRACKS
	factory.army_build = "tank_factory"
	factory.auto_refill = false
	factory.filled = true
	world.army._number(factory)

static func unit_count(world: GameWorld, factory: Facility) -> int:
	var count: int = world.army.units_of(factory).size()
	if world.naval != null:
		count += world.naval.aboard_of(factory).size()
	return count

static func has_room(world: GameWorld, factory: Facility) -> bool:
	return unit_count(world, factory) < world.army.cap_of(factory)

static func migrate(world: GameWorld) -> void:
	var remap: Dictionary = {}
	for old: Facility in world.mil.facilities:
		if not old.get_meta("tank_factory_army", false):
			continue
		var origin: int = int(old.get_meta("tank_factory_origin", -1))
		if origin < 0 or origin >= world.mil.facilities.size():
			continue
		var factory: Facility = world.mil.facilities[origin]
		if not factory.get_meta("is_tank_factory", false) or world.mil.is_demolished(factory):
			continue
		configure(world, factory)
		remap[old.id] = factory.id
		for u: Unit in world.army.units:
			if u.home == old:
				u.home = factory
		if world.naval != null:
			for u: Unit in world.naval.aboard_of(old):
				u.home = factory
			for landing: Dictionary in world.naval.landings:
				if landing.get("home") == old:
					landing["home"] = factory
		if world.rail != null and world.rail.troops != null:
			for ride: Dictionary in world.rail.troops.rides:
				if ride.get("home") == old:
					ride["home"] = factory
		world.ops.list.erase(old)
		world.army.tac.ops.erase(old)
		# Stable tombstone: retain ID/index without leaving any selectable base.
		old.kind = Facility.Kind.TRENCH_H
		old.cells.clear()
		old.pending.clear()
		old.obj_ids = PackedInt32Array()
		old.main_obj = -1
		old.producing = false
		old.remove_meta("tank_factory_army")
	if remap.is_empty():
		return
	for country: Country in world.countries:
		for group: Dictionary in country.army_groups:
			for key: String in ["fids", "out_fids"]:
				if not group.has(key):
					continue
				var ids := PackedInt32Array()
				for fid: int in group[key]:
					var mapped: int = int(remap.get(fid, fid))
					if not ids.has(mapped):
						ids.append(mapped)
				group[key] = ids
		preload("res://game/army_groups.gd").prune(world, country.id)
