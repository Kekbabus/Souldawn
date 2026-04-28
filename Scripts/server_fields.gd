# server_fields.gd -- Magic field system (fire/poison/energy fields, walls, bombs)
#
# Manages persistent field tiles placed by runes or spells.
# Fields deal damage-over-time to creatures/players standing on them.
# Magic walls block movement. Fields decay after a duration.
extends Node

const FIELD_TICK_INTERVAL := 2.0  # Seconds between field damage ticks
const FIELD_DURATION := 45.0      # Default field lifetime in seconds
const MAGIC_WALL_DURATION := 20.0 # Magic wall lifetime

var server: Node = null
var _fields: Dictionary = {}      # Vector3i -> field data Dictionary
var _tick_acc: float = 0.0


## Places a field at the given position. Broadcasts to nearby players.
func place_field(pos: Vector3i, field_type: String, element: String,
		damage_per_tick: int = 20, duration: float = FIELD_DURATION,
		owner_peer_id: int = -1) -> void:
	# Remove existing field at this position
	if _fields.has(pos):
		remove_field(pos)
	_fields[pos] = {
		"type": field_type,       # "fire_field", "poison_field", "energy_field", "magic_wall"
		"element": element,       # "fire", "poison", "energy", "physical"
		"damage": damage_per_tick,
		"duration": duration,
		"owner": owner_peer_id,
		"created_ms": Time.get_ticks_msec(),
	}
	# Broadcast field spawn to nearby players
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_field_spawn", pos.x, pos.y, pos.z, field_type, duration)


## Removes a field at the given position and broadcasts despawn.
func remove_field(pos: Vector3i) -> void:
	if not _fields.has(pos):
		return
	_fields.erase(pos)
	for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
		server.rpc_id(pid, "rpc_field_despawn", pos.x, pos.y, pos.z)


## Places multiple fields in a pattern (for bombs, walls).
func place_field_pattern(center: Vector3i, pattern_name: String, field_type: String,
		element: String, damage: int, duration: float, owner: int, facing: int = 2) -> void:
	var tiles: Array = server.spells.resolve_area_tiles(pattern_name, center, facing)
	for tile in tiles:
		var pos := Vector3i(int(tile.x), int(tile.y), center.z)
		if not server.map.is_blocking(pos):
			place_field(pos, field_type, element, damage, duration, owner)


## Places a wall (line of fields perpendicular to facing direction).
func place_wall(center: Vector3i, field_type: String, element: String,
		damage: int, duration: float, owner: int, facing: int, length: int = 5) -> void:
	# Wall is perpendicular to facing direction
	for i in range(-length / 2, length / 2 + 1):
		var pos: Vector3i
		match facing:
			0, 2:  # North/South -- wall goes East-West
				pos = Vector3i(center.x + i, center.y, center.z)
			1, 3:  # East/West -- wall goes North-South
				pos = Vector3i(center.x, center.y + i, center.z)
			_:
				pos = Vector3i(center.x + i, center.y, center.z)
		if not server.map.is_blocking(pos):
			place_field(pos, field_type, element, damage, duration, owner)


## Returns true if there's a magic wall at the given position (blocks movement).
func is_wall_at(pos: Vector3i) -> bool:
	if not _fields.has(pos):
		return false
	return _fields[pos]["type"] == "magic_wall"


## Returns true if there's any field at the given position.
func has_field_at(pos: Vector3i) -> bool:
	return _fields.has(pos)


## Returns the field type at a position, or "" if none.
func get_field_type(pos: Vector3i) -> String:
	if _fields.has(pos):
		return str(_fields[pos]["type"])
	return ""


## Ticks field damage and decay. Called from server_main._process().
func process_fields(delta: float) -> void:
	# Decay fields
	var to_remove: Array = []
	for pos in _fields:
		var field: Dictionary = _fields[pos]
		field["duration"] = float(field["duration"]) - delta
		if float(field["duration"]) <= 0.0:
			to_remove.append(pos)
	for pos in to_remove:
		remove_field(pos)

	# Tick damage
	_tick_acc += delta
	if _tick_acc < FIELD_TICK_INTERVAL:
		return
	_tick_acc -= FIELD_TICK_INTERVAL

	for pos in _fields:
		var field: Dictionary = _fields[pos]
		if field["type"] == "magic_wall":
			continue  # Walls don't deal damage
		var damage: int = int(field["damage"])
		var element: String = str(field["element"])
		if damage <= 0:
			continue
		# Damage players on this tile and apply conditions
		for pid in server._sessions:
			var s: Dictionary = server._sessions[pid]
			if s.get("is_dead", false) or s.get("_orphan", false):
				continue
			if s["position"] == pos:
				server.combat.damage_player(pid, damage, element)
				# Apply condition based on field element
				match element:
					"fire":
						if not server.combat.has_condition(pid, "burning"):
							server.combat.apply_condition(pid, "burning")
					"energy":
						if not server.combat.has_condition(pid, "electrified"):
							server.combat.apply_condition(pid, "electrified")
					"poison", "earth":
						if not server.combat.has_condition(pid, "poisoned"):
							server.combat.apply_condition(pid, "poisoned")
		# Damage entities on this tile
		var cell_key: String = server.cell_key(pos)
		if server.entities._entity_grid.has(cell_key):
			for eid in server.entities._entity_grid[cell_key]:
				if server.entities._entities.has(eid):
					var ent: Dictionary = server.entities._entities[eid]
					if int(ent.get("health", 0)) <= 0:
						continue
					if ent["position"] == pos:
						# Check element immunity
						var immunities: Dictionary = ent.get("immunities", {})
						if immunities.get(element, false):
							continue
						var dmg := randi_range(int(damage * 0.5), damage)
						ent["health"] = maxi(int(ent["health"]) - dmg, 0)
						for pid in server.get_players_in_range(pos, server.NEARBY_RANGE):
							server.rpc_id(pid, "rpc_entity_damage", eid, dmg, element,
								int(ent["health"]), int(ent["max_health"]))
						if int(ent["health"]) <= 0:
							server.combat._on_entity_death(eid, int(field.get("owner", -1)))


## Sends all active fields near a position to a player (on login/chunk load).
func send_nearby_fields(peer_id: int, pos: Vector3i) -> void:
	for fpos in _fields:
		var fp: Vector3i = fpos
		if fp.z == pos.z and absi(fp.x - pos.x) <= server.NEARBY_RANGE and absi(fp.y - pos.y) <= server.NEARBY_RANGE:
			server.rpc_id(peer_id, "rpc_field_spawn", fp.x, fp.y, fp.z, str(_fields[fpos]["type"]), float(_fields[fpos]["duration"]))
